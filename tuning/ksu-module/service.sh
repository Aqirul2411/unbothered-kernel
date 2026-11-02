#!/system/bin/sh
# unbothered-tune 3.0 ΓÇö boot-time memory, writeback and I/O tuning, plus a
# cache sweep started in the background (see clean.sh).
#
# Everything here is a sysctl read or a /sys write. Disable the module in
# KernelSU-Next / Magisk and reboot: the stock values come back by themselves.
# Settings: /data/adb/unbothered-tune.conf (copy config.example, edit, reboot).
#
# Deliberately out of scope, and never written by this module: audio (props,
# HAL, mixer paths, any audio module), CPU governor / frequencies / boost,
# LMKD and lowmemorykiller limits, KSM, cgroups, and vm.min_free_kbytes.

MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/unbothered-tune

if [ ! -f "$MODDIR/common.sh" ]; then
  echo "service.sh: $MODDIR/common.sh is missing, module is incomplete" >&2
  exit 1
fi

STATE=${UNBOTHERED_STATE:-/data/adb/unbothered-tune}
CONF=${UNBOTHERED_CONF:-/data/adb/unbothered-tune.conf}
LOG=$STATE/service.log
ZRAM=/sys/block/zram0

# The cleaner lock and its state machine live in common.sh.
UT_STATE=$STATE
. "$MODDIR/common.sh"
LOCK=$UT_LOCK

# World-readable mirror of the log plus a one-shot status file, so
#   adb shell cat /data/local/tmp/unbothered-tune/status
# answers "what did it do" without root. Nothing private goes in it: only
# tuning values and cache-sweep counters, never a package list or app path.
MIRROR=${UNBOTHERED_MIRROR:-/data/local/tmp/unbothered-tune}
MLOG=$MIRROR/service.log

mkdir -p "$STATE" 2>/dev/null
mkdir -p "$MIRROR" 2>/dev/null
chmod 0755 "$MIRROR" 2>/dev/null

VERSION=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)
VERSION=${VERSION:-3.0}

# --- defaults, one per line in $CONF overrides any of them ---------------
ZRAM_ENABLE=1
ZRAM_PERCENT=50
ZRAM_MAX_MB=4096
ZRAM_ALGO=auto
SYSCTL_TUNING=1
IO_TUNING=1
CACHE_CLEAN=1
CACHE_INTERVAL_H=12

# Writeback: a fixed cap in MiB beats a percentage on big-RAM phones, where
# 20% of 12 GB is 2.4 GB of dirty pages and one flush is a visible stall.
WRITEBACK_CAP=1
DIRTY_BG_MB=32
DIRTY_MB=128

# 0 = no reclaim boost bursts; 15000 = stock. See apply_sysctls().
WATERMARK_BOOST=0
# 0 = do not dump every task's stack to kmsg on the way to an OOM kill.
OOM_DUMP_TASKS=0

# The free-memory margin kswapd keeps ahead of allocation, in 1/10000 of managed
# pages. 43 is not our number: it is what /vendor/bin/init.kernel.post_boot.sh
# intends for this model and never writes, because it compares ro.product.name
# against "marble" while the property reads "marble_global" - so the phone gets
# the generic 1. Measured on marble: 1 gives a 43.9 MB low watermark, 43 gives
# 89.1 MB. 0 leaves whatever the ROM set.
WATERMARK_SCALE=43

# Watchdogs, off in userspace but compiled into the kernel. init.rc:372 writes
# hung_task_timeout_secs 0, so CONFIG_BOOTPARAM_HUNG_TASK_PANIC can never fire,
# and the live panic sysctl reads 0 rather than the compiled CONFIG_PANIC_TIMEOUT.
# With these set, a hang writes its dump to ramoops and the phone reboots instead
# of sitting on a frozen screen with no record of why. 0 = leave them alone.
#
# 300 s rather than the kernel's default 120: the point is to catch a real hang,
# and a task waiting on storage for two minutes is not one. Five minutes of
# D-state is a phone that is already unusable, so the reboot costs nothing.
WATCHDOG=1
HUNG_TASK_SECS=300
PANIC_TIMEOUT=5

[ -f "$CONF" ] && . "$CONF"

rotate() {
  [ -f "$LOG" ] || return 0
  size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  [ "$size" -gt 131072 ] 2>/dev/null || return 0
  tail -n 400 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
}

rotate_mirror() {
  [ -f "$MLOG" ] || return 0
  size=$(wc -c < "$MLOG" 2>/dev/null || echo 0)
  [ "$size" -gt 65536 ] 2>/dev/null || return 0
  tail -n 300 "$MLOG" > "$MLOG.tmp" 2>/dev/null && mv "$MLOG.tmp" "$MLOG" 2>/dev/null
}

log() {
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  printf '%s\n' "$line" >> "$LOG" 2>/dev/null
  printf '%s\n' "$line" >> "$MLOG" 2>/dev/null
}

# status_line <key> <value>: collected into $MIRROR/status.tmp and renamed into
# place at the end, so a reader never sees a half-written file.
status_line() {
  printf '%s=%s\n' "$1" "$2" >> "$MIRROR/status.tmp" 2>/dev/null
}

# put <path> <value>; 0 = written, 1 = write failed, 2 = no such file
put() {
  [ -e "$1" ] || return 2
  printf '%s\n' "$2" > "$1" 2>/dev/null || return 1
  return 0
}

set_sysctl() { # key value
  p="/proc/sys/$(printf '%s' "$1" | tr . /)"
  if [ ! -e "$p" ]; then
    log "sysctl $1: not on this kernel, skipped"
    return 0
  fi
  if put "$p" "$2"; then
    actual=$(cat "$p" 2>/dev/null)
    if [ "$actual" = "$2" ]; then
      log "sysctl $1 = $2"
    else
      log "sysctl $1 = $2 (kernel reports '$actual')"
    fi
  else
    log "sysctl $1: write failed"
  fi
}

zram_active() { grep -qw zram0 /proc/swaps 2>/dev/null; }

# daemon_locked: 0 = a cleaner holds the lock, 1 = nobody does.
#
# 2.0-2.2 asked "is the cleaner running?" with `kill -0 $(cat cleaner.pid)`.
# PIDs are reused, so a stale pidfile whose number now belonged to any other
# process answered yes, service.sh started nothing, and the phone ran with no
# sweep at all while the log said "cache cleaner already running (pid 7501)".
# That is no longer decided here: common.sh owns the lock and its state machine,
# and `alive` means a live clean.sh --daemon on *this* boot owns it.
daemon_locked() {
  [ -d "$STATE" ] || return 1
  [ "$(ut_cleaner_state)" = "alive" ]
}

zram_algos() { tr -d '[]' < "$ZRAM/comp_algorithm" 2>/dev/null; }

pick_algo() {
  case "$ZRAM_ALGO" in
    auto)
      avail=$(zram_algos)
      # lz4 first: cheapest decompression on swap-in, which is what the UI
      # waits for. lzo-rle compresses a little better but costs more CPU.
      for want in lz4 lzo-rle lzo zstd lz4hc; do
        for have in $avail; do
          [ "$have" = "$want" ] && { echo "$want"; return 0; }
        done
      done
      set -- $avail
      echo "${1:-lzo}"
      ;;
    *) echo "$ZRAM_ALGO" ;;
  esac
}

setup_zram() {
  [ "$ZRAM_ENABLE" = "1" ] || { log "zram setup disabled in config"; return 0; }
  [ -d "$ZRAM" ] || { log "no /sys/block/zram0: kernel has no zram, nothing to do"; return 0; }

  if zram_active; then
    log "zram0 already in use, leaving it alone: $(grep zram0 /proc/swaps | tr -s ' ' ' ')"
    return 0
  fi

  memtotal_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  [ -n "$memtotal_kb" ] || { log "ERROR: could not read MemTotal"; return 0; }

  [ "$ZRAM_PERCENT" -lt 10 ] 2>/dev/null && ZRAM_PERCENT=10
  [ "$ZRAM_PERCENT" -gt 80 ] 2>/dev/null && ZRAM_PERCENT=80
  [ "$ZRAM_MAX_MB" -gt 0 ] 2>/dev/null || ZRAM_MAX_MB=4096

  size_kb=$((memtotal_kb * ZRAM_PERCENT / 100))
  cap_kb=$((ZRAM_MAX_MB * 1024))
  [ "$size_kb" -gt "$cap_kb" ] && size_kb=$cap_kb
  size_bytes=$((size_kb * 1024))
  algo=$(pick_algo)

  put "$ZRAM/reset" 1
  if put "$ZRAM/comp_algorithm" "$algo"; then
    :
  else
    log "compressor $algo not accepted, keeping the kernel default"
  fi

  if ! put "$ZRAM/disksize" "$size_bytes"; then
    log "ERROR: could not set zram disksize, leaving swap alone"
    return 0
  fi
  log "zram0 configured: ${size_kb} KiB ($((size_kb / 1024)) MiB, $ZRAM_PERCENT% of RAM, cap ${ZRAM_MAX_MB} MiB), compressor $algo"

  dev=/dev/block/zram0
  [ -e "$dev" ] || dev=/dev/zram0
  if ! mkswap "$dev" >/dev/null 2>&1; then
    log "ERROR: mkswap $dev failed"
    return 0
  fi
  if swapon "$dev" 2>/dev/null; then
    log "swapon $dev ok"
  else
    log "ERROR: swapon $dev failed"
  fi
}

apply_sysctls() {
  [ "$SYSCTL_TUNING" = "1" ] || { log "sysctl tuning disabled in config"; return 0; }

  if zram_active; then
    # Pages parked in zram cost CPU to swap back, not milliseconds of flash
    # I/O, so hoarding free RAM (swappiness 60) is the wrong trade.
    set_sysctl vm.swappiness 100
    # Read-ahead against compressed swap only decompresses pages nobody asked
    # for; one page at a time is the right unit here.
    set_sysctl vm.page-cluster 0
  else
    log "no compressed swap active: leaving vm.swappiness and vm.page-cluster at stock"
  fi

  # Writeback, two modes. A byte cap is the better one on a phone: the burst
  # that has to reach flash is bounded whatever the RAM size, so a 12 GB phone
  # does not try to flush 2.4 GB in one go. Ratios stay as the fallback.
  if [ "$WRITEBACK_CAP" = "1" ] && [ "$DIRTY_MB" -gt 0 ] 2>/dev/null; then
    [ "$DIRTY_BG_MB" -gt 0 ] 2>/dev/null || DIRTY_BG_MB=32
    [ "$DIRTY_BG_MB" -ge "$DIRTY_MB" ] 2>/dev/null && DIRTY_BG_MB=$((DIRTY_MB / 4))
    set_sysctl vm.dirty_background_bytes $((DIRTY_BG_MB * 1024 * 1024))
    set_sysctl vm.dirty_bytes $((DIRTY_MB * 1024 * 1024))
  else
    set_sysctl vm.dirty_ratio 20
    set_sysctl vm.dirty_background_ratio 5
  fi
  set_sysctl vm.dirty_writeback_centisecs 1500
  set_sysctl vm.dirty_expire_centisecs 3000

  # Reclaim "boost" after an allocation spike: kswapd reclaims 1.5x the
  # target for a while, which is extra CPU and flash I/O exactly when an app
  # is trying to start. 0 trades a little extra direct-reclaim risk for fewer
  # latency spikes; set WATERMARK_BOOST=15000 to get stock behaviour back.
  set_sysctl vm.watermark_boost_factor "$WATERMARK_BOOST"

  # An OOM kill already costs a janky frame; dumping every task's stack to
  # kmsg first makes it worse and nothing on a phone reads the dump.
  set_sysctl vm.oom_dump_tasks "$OOM_DUMP_TASKS"

  # Per-task scheduler accounting and per-task delay accounting: both are
  # bookkeeping for tools a phone does not run.
  set_sysctl kernel.sched_schedstats 0
  set_sysctl kernel.task_delayacct 0
  # Hard-lockup detector: wakes a CPU every 10 s forever, and nothing on a
  # phone consumes the perf events it produces.
  set_sysctl kernel.nmi_watchdog 0
}

# The two things this module holds because userspace would otherwise win.
#
# Both are written here rather than compiled in for the same reason: a kernel
# default is only a fallback for the first seconds of boot, and the ROM's own
# scripts run after it. Measured on this phone - the kernel built with
# watermark_scale_factor 150 was running with 1, because init.kernel.post_boot.sh
# set it, and the hung-task timeout is one init.rc disables at boot.
apply_late() {
  if [ "${WATERMARK_SCALE:-0}" -gt 0 ] 2>/dev/null; then
    set_sysctl vm.watermark_scale_factor "$WATERMARK_SCALE"
    # Report the reserve the kernel computed, not the number written: zoneinfo
    # is the only place the value becomes real, and it is what proves the write
    # was not overwritten again afterwards.
    zone=$(awk '/zone   Normal/ {found=1} found && /^        low/ {l=$2} found && /^        high/ {print l, $2; exit}' /proc/zoneinfo 2>/dev/null)
    [ -n "$zone" ] && log "zoneinfo Normal low/high pages (4 KiB each): $zone"
  else
    log "watermark_scale_factor left as the ROM set it"
  fi

  [ "${WATCHDOG:-1}" = "1" ] || { log "watchdogs left as the ROM set them"; return 0; }

  # Order matters. The timeout is what makes the panic possible at all; panic
  # is set last so that a hang reboots instead of parking the phone in panic
  # forever, which would be a worse outcome than the hang.
  set_sysctl kernel.hung_task_panic 1
  set_sysctl kernel.hung_task_timeout_secs "$HUNG_TASK_SECS"
  set_sysctl kernel.softlockup_panic 1
  set_sysctl kernel.panic "$PANIC_TIMEOUT"
}

apply_io() {
  [ "$IO_TUNING" = "1" ] || { log "i/o tuning disabled in config"; return 0; }

  for q in /sys/block/*/queue; do
    [ -d "$q" ] || continue
    dev=${q%/queue}
    dev=${dev##*/}
    case "$dev" in
      zram*|loop*|ram*|dm-*|sr*) continue ;;
    esac

    [ "$(cat "$q/rotational" 2>/dev/null)" = "1" ] && { log "i/o $dev: rotational, skipped"; continue; }

    if [ -r "$q/scheduler" ]; then
      sch=$(cat "$q/scheduler" 2>/dev/null)
      case "$sch" in
        *\[none\]*) : ;;
        *none*) put "$q/scheduler" none >/dev/null && log "i/o $dev: scheduler none (flash has no seek cost)" ;;
        *) log "i/o $dev: scheduler left as $(printf '%s' "$sch" | tr -d '[]')" ;;
      esac
    fi

    # I/O accounting is per-request work whose output only tools read.
    put "$q/iostats" 0 >/dev/null && log "i/o $dev: iostats off"
    put "$q/add_random" 0 >/dev/null
    put "$q/read_ahead_kb" 128 >/dev/null && log "i/o $dev: read_ahead 128 KiB"
  done
}

launch_cleaner() {
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$MODDIR/clean.sh" --daemon >/dev/null 2>&1 &
  else
    sh "$MODDIR/clean.sh" --daemon >/dev/null 2>&1 &
  fi
}

# wait_for_cleaner <seconds>: poll the lock until it is held.
# The daemon normally takes the lock in well under a second, so burst cheap
# checks first and only then wait in whole seconds: fractional sleep costs
# 0.2-0.7 s per call on this device, which made the old 80 x 0.1 s loop take 20 s.
wait_for_cleaner() {
  n=0
  while [ "$n" -le "$1" ]; do
    if daemon_locked; then
      unset n
      return 0
    fi
    if [ "$n" -lt 5 ]; then
      sleep 0 2>/dev/null
    else
      sleep 1
    fi
    n=$((n + 1))
  done
  unset n
  return 1
}

start_cleaner() {
  [ "$CACHE_CLEAN" = "1" ] || { log "cache sweep disabled in config"; return 0; }
  [ -f "$MODDIR/clean.sh" ] || { log "clean.sh missing next to service.sh, sweep not started"; return 0; }

  st=$(ut_cleaner_state)
  if [ "$st" = "alive" ]; then
    log "cache cleaner already running (pid $(ut_cleaner_pid))"
    return 0
  fi
  if [ "$st" != "missing" ]; then
    log "cleaner lock is $st: replacing it and starting a fresh daemon"
  fi

  launch_cleaner
  if wait_for_cleaner 10; then
    log "cache cleaner started (pid $(ut_cleaner_pid), every ${CACHE_INTERVAL_H}h)"
    return 0
  fi

  log "WARN: cleaner did not take the lock on the first launch ($(ut_cleaner_state)), retrying directly"
  launch_cleaner
  if wait_for_cleaner 5; then
    log "cache cleaner started on the retry (pid $(ut_cleaner_pid))"
    return 0
  fi

  log "ERROR: the cache cleaner did not start. No sweep will run until it does."
  log "ERROR: lock state is $(ut_cleaner_state), owner pid '$(ut_cleaner_pid)'"
  log "ERROR: recover without rebooting with: su -c 'sh $MODDIR/clean.sh --restart'"
}

# --- run ------------------------------------------------------------------
# Do not race the ROM's init: if it brings zram up, it has already done so by
# the time boot_completed is set, and setup_zram() then backs off.
i=0
if command -v getprop >/dev/null 2>&1; then
  while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 120 ]; do
    sleep 1
    i=$((i + 1))
  done
fi

rotate
rotate_mirror
log "boot completed after ${i}s, starting v$VERSION"

setup_zram
apply_sysctls
apply_io
apply_late
start_cleaner

log "--- state ---"
log "meminfo: $(grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree|Dirty):' /proc/meminfo 2>/dev/null | tr -s ' ' ' ' | tr '\n' ' ')"
zram_active && log "swaps: $(grep zram0 /proc/swaps | tr -s ' ' ' ')"
[ -r "$ZRAM/mm_stat" ] && log "zram0 mm_stat: $(cat "$ZRAM/mm_stat" 2>/dev/null)"
[ -r "$ZRAM/comp_algorithm" ] && log "zram0 compressors: $(cat "$ZRAM/comp_algorithm" 2>/dev/null)"

# Status snapshot. Read back from the kernel, not from what was written, so a
# value the ROM overrode later shows up as the value that actually stuck.
rm -f "$MIRROR/status.tmp" 2>/dev/null
status_line version "$VERSION"
status_line booted "$(date '+%Y-%m-%d %H:%M:%S')"
status_line boot_settle_s "$i"
status_line swappiness "$(cat /proc/sys/vm/swappiness 2>/dev/null)"
status_line page_cluster "$(cat /proc/sys/vm/page-cluster 2>/dev/null)"
status_line dirty_bytes "$(cat /proc/sys/vm/dirty_bytes 2>/dev/null)"
status_line dirty_background_bytes "$(cat /proc/sys/vm/dirty_background_bytes 2>/dev/null)"
status_line dirty_writeback_centisecs "$(cat /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null)"
status_line watermark_boost "$(cat /proc/sys/vm/watermark_boost_factor 2>/dev/null)"
status_line watermark_scale "$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)"
status_line hung_task_timeout_secs "$(cat /proc/sys/kernel/hung_task_timeout_secs 2>/dev/null)"
status_line panic "$(cat /proc/sys/kernel/panic 2>/dev/null)"
status_line oom_dump_tasks "$(cat /proc/sys/vm/oom_dump_tasks 2>/dev/null)"
status_line schedstats "$(cat /proc/sys/kernel/sched_schedstats 2>/dev/null)"
status_line zram_algo "$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ZRAM/comp_algorithm" 2>/dev/null)"
status_line zram_size_mb "$(awk '{print int($1 / 1048576)}' "$ZRAM/disksize" 2>/dev/null)"
status_line zram_active "$(zram_active && echo yes || echo no)"
# The lock state, not just yes/no: `stale-boot` at boot is normal and gets
# replaced a moment later, while `NO` on a running system means no sweep.
status_line cleaner_lock "$(ut_cleaner_state)"
status_line cleaner_pid "$(ut_cleaner_pid)"
if daemon_locked; then
  status_line cleaner_alive yes
else
  status_line cleaner_alive NO
fi
status_line last_clean_epoch "$(cat "$STATE/last-clean" 2>/dev/null)"
status_line next_clean_epoch "$(cat "$STATE/next-clean" 2>/dev/null)"
mv "$MIRROR/status.tmp" "$MIRROR/status" 2>/dev/null
chmod 0644 "$MIRROR/status" "$MLOG" 2>/dev/null

log "done"
