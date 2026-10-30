#!/system/bin/sh
# Runs at late_start on every boot, through KernelSU-Next.
#
# Why this exists as a module and not as a kernel change: everything here is a
# sysctl or a /sys write. A kernel patch would need a flash and a reboot through
# a broken-kernel risk to change the same values, and would be a pain to undo.
# This is one toggle in the manager.

MODDIR=${0%/*}
LOG=/data/local/tmp/unbothered-tune.log
log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

# Wait for the ROM's own init to finish: if init sets up zram, we must not race
# it, and if it does not, we want to be sure before we do it ourselves.
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 120 ]; do
  sleep 1
  i=$((i + 1))
done

: > "$LOG"
log "boot completed after ${i}s, starting"

# --- 1. zram, only if nothing else did it --------------------------------
ZRAM=/sys/block/zram0
if [ -d "$ZRAM" ]; then
  if grep -q zram0 /proc/swaps 2>/dev/null; then
    log "zram0 already in use, leaving it alone: $(grep zram0 /proc/swaps)"
  else
    memtotal_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    # Half of RAM. On 12 GB that is a 6 GB swap file that lives in RAM
    # compressed, which is a very different thing from swapping to flash.
    size=$((memtotal_kb * 1024 / 2))

    algo=lzo-rle
    if ! grep -qw lzo-rle "$ZRAM/comp_algorithm" 2>/dev/null; then
      algo=$(tr -d '[]' < "$ZRAM/comp_algorithm" | awk '{print $1}')
    fi

    log "configuring zram0: ${size} bytes, ${algo}"
    echo "$algo" > "$ZRAM/comp_algorithm" 2>/dev/null
    echo "$size" > "$ZRAM/disksize" || log "ERROR: could not set disksize"
    mkswap /dev/block/zram0 >/dev/null 2>&1 || log "ERROR: mkswap failed"
    swapon /dev/block/zram0 2>/dev/null && log "swapon ok" || log "ERROR: swapon failed"
  fi
else
  log "no /sys/block/zram0: this kernel has no zram built in, nothing to do"
fi

# --- 2. the three tunables that only make sense with zram ----------------
# swappiness 100: pages in zram are cheap to swap in again, unlike flash, so
#   there is no reason to avoid swapping cold pages. Default 60 assumes a disk
#   that costs milliseconds per page.
# page-cluster 0: read one page at a time. Read-ahead exists for spinning rust;
#   against zram it just wastes CPU decompressing pages nobody asked for.
# schedstats 0: per-task scheduling accounting that nothing on a phone reads.
#   Same effect a CONFIG change would have, without a rebuild.
for kv in \
  "vm.swappiness=100" \
  "vm.page-cluster=0" \
  "kernel.sched_schedstats=0"
do
  key=${kv%%=*}; val=${kv#*=}
  if [ -w "/proc/sys/$(echo "$key" | tr . /)" ]; then
    echo "$val" > "/proc/sys/$(echo "$key" | tr . /)" && log "$key = $val" || log "could not set $key"
  else
    log "$key not present on this kernel"
  fi
done

# --- 3. what actually happened, so the next boot can be compared ---------
log "meminfo: $(grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo | tr '\n' ' ')"
[ -r "$ZRAM/mm_stat" ] && log "zram mm_stat: $(cat "$ZRAM/mm_stat")"
[ -r "$ZRAM/comp_algorithm" ] && log "zram algorithms: $(cat "$ZRAM/comp_algorithm")"
log "done"
