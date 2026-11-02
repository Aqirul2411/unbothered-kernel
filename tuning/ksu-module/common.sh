#!/system/bin/sh
# common.sh ΓÇö the one place that decides "is the cleaner running?".
# Sourced by service.sh, clean.sh and action.sh. Reads only /proc and its own
# lock directory; writes nothing until ut_lock_acquire() is called.
#
# Why a lock DIRECTORY, and not a PID file, and not flock:
#
#   * A PID file lies. PIDs are recycled, so `kill -0 $(cat cleaner.pid)`
#     answers "yes" for whatever unrelated process inherited that number. That
#     is not theory: it is how 2.0-2.2 ran with no cache sweep at all while the
#     log said `cache cleaner already running (pid 7501)`.
#
#   * flock is the textbook answer, and it is genuinely broken on this device's
#     toybox. Measured, not assumed: `flock -n 9` returns "Bad file descriptor"
#     even for an fd the kernel lists as open, children do not inherit fds above
#     2 at all (`sh: >&9 : bad file descriptor`), and two holders on fd 0
#     coexisted with no exclusion. Shipping it would have been worse than the
#     PID bug it replaced.
#
#   * `mkdir` is atomic on every filesystem Android uses, and failure is
#     unambiguous: whoever creates the directory owns the lock. Death of the
#     owner cannot be detected by the kernel here, so the owner file inside the
#     directory carries BOTH the pid and the boot id, and the pid must still be
#     a live process whose /proc/<pid>/cmdline is this module's clean.sh.
#     A lock left by a previous boot can therefore never look alive, and a
#     recycled pid can never look alive either.
#
# The owner file is written immediately after mkdir. The window in which the
# directory exists without one is a few milliseconds; a lock in that state is
# only treated as abandoned after 60 s.

UT_STATE=${UT_STATE:-/data/adb/unbothered-tune}
UT_LOCK=$UT_STATE/cleaner.lock

# Serialises "judge the lock, replace it if stale, create it if free".
#
# Without it there is a real race: process A reads the lock and sees it stale,
# and before A can replace it process B finishes the same replacement and starts
# holding a fresh lock. A's `mv` then moves and deletes B's live lock, both
# create the directory, and both believe they own it. Measured on this device:
# five contenders on one stale lock produced two winners. The gate makes the
# whole check-and-create one critical section, so exactly one can win.
UT_GATE=$UT_STATE/acquire.gate

# Current boot. Used to prove a lock is not from a previous boot. Empty means
# /proc/sys/kernel/random/boot_id is unreadable, and the boot check degrades to
# pid + cmdline only (which is still what 2.3 did, and still better than a bare
# pidfile).
UT_BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)

ut_proc_cmdline() {
  tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null
}

# 0 if <pid> is a live process that really is this module's cleaner.
#   <daemon_only>=1  the long-running `clean.sh --daemon`
#   <daemon_only>=0  any clean.sh run (used for the per-pass run lock)
# A zombie passes `kill -0` but has an empty cmdline, so it fails here.
ut_proc_is_cleaner() {
  _p=$1
  _d=${2:-1}
  case "$_p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_p" 2>/dev/null || return 1
  _c=$(ut_proc_cmdline "$_p")
  case "$_c" in *clean.sh*) : ;; *) return 1 ;; esac
  [ "$_d" = "1" ] || return 0
  case "$_c" in *daemon*) return 0 ;; *) return 1 ;; esac
}

# Age of a directory in seconds. stat first; find -mmin as the fallback, since
# both are present but only stat gives a number worth printing.
ut_lock_age_s() {
  _t=$(stat -c %Y "$1" 2>/dev/null)
  case "$_t" in
    ''|*[!0-9]*)
      if [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        echo 999999
      else
        echo 0
      fi
      ;;
    *) echo $(( $(date +%s) - _t )) ;;
  esac
}

# ut_lock_state <dir> [daemon_only]
# Prints exactly one of:
#   missing         no lock directory: nobody holds it
#   busy            directory just created, owner file not written yet
#   alive           held by a live clean.sh on this boot
#   stale-boot      left by a previous boot
#   stale-dead      owner pid is gone, or is now some other process
#   stale-noowner   owner file never appeared (>= 60 s)
#   stale-garbage   owner pid is not a number
ut_lock_state() {
  _dir=$1
  _d=${2:-1}
  [ -d "$_dir" ] || { echo missing; return 0; }

  _p=$(cat "$_dir/pid" 2>/dev/null)
  _b=$(cat "$_dir/boot_id" 2>/dev/null)

  if [ -z "$_p" ] || [ -z "$_b" ]; then
    if [ "$(ut_lock_age_s "$_dir")" -ge 60 ] 2>/dev/null; then
      echo stale-noowner
    else
      echo busy
    fi
    return 0
  fi

  case "$_p" in ''|*[!0-9]*) echo stale-garbage; return 0 ;; esac

  if [ -n "$UT_BOOT" ] && [ "$_b" != "$UT_BOOT" ]; then
    echo stale-boot
    return 0
  fi

  if ut_proc_is_cleaner "$_p" "$_d"; then
    echo alive
  else
    echo stale-dead
  fi
}

# Take the acquire gate. Held only across the check-and-create below, which is
# a few file operations, never across any work. A gate left behind by a crash
# in that window is removed once it is clearly abandoned: 5 s is generous for a
# section that takes single-digit milliseconds.
#
# Note on sleeping: fractional sleep is unreliable and expensive on this device
# (`sleep 0.1` measured at 0.2-0.7 s per call, so a 0.1 s poll loop ran 7 s for
# ten iterations). The gate is held for microseconds, so spin freely first and
# only start sleeping once the wait is genuinely long.
ut_gate_take() {
  _n=0
  while [ "$_n" -lt 300 ]; do
    if mkdir "$UT_GATE" 2>/dev/null; then
      return 0
    fi
    if [ "$(ut_lock_age_s "$UT_GATE")" -ge 5 ] 2>/dev/null; then
      rm -rf "$UT_GATE" 2>/dev/null
    fi
    if [ "$_n" -ge 60 ]; then
      sleep 1 2>/dev/null
    fi
    _n=$((_n + 1))
  done
  return 1
}

ut_gate_drop() {
  rmdir "$UT_GATE" 2>/dev/null
  return 0
}

# ut_lock_acquire <dir> <pid> [daemon_only]
# 0 = this process now owns the lock, 1 = someone else does.
ut_lock_acquire() {
  _dir=$1
  _pid=$2
  _d=${3:-1}

  mkdir -p "$UT_STATE" 2>/dev/null
  ut_gate_take || return 1

  if [ -d "$_dir" ]; then
    case "$(ut_lock_state "$_dir" "$_d")" in
      alive|busy)
        ut_gate_drop
        return 1
        ;;
      *)
        # Rename is atomic: only one process can move a given directory, and
        # the mkdir below then has a free name to claim.
        _aside="$_dir.reap.$_pid"
        rm -rf "$_aside" 2>/dev/null
        mv "$_dir" "$_aside" 2>/dev/null
        rm -rf "$_aside" 2>/dev/null
        ;;
    esac
  fi

  if ! mkdir "$_dir" 2>/dev/null; then
    ut_gate_drop
    return 1
  fi
  printf '%s\n' "$_pid" > "$_dir/pid" 2>/dev/null
  printf '%s\n' "$UT_BOOT" > "$_dir/boot_id" 2>/dev/null
  ut_gate_drop
  return 0
}

# ut_lock_release <dir> <pid>
# Only removes a lock this pid still owns, so a delayed release can never free
# a lock some later process legitimately took.
ut_lock_release() {
  _dir=$1
  _pid=$2
  [ -d "$_dir" ] || return 0
  ut_gate_take || return 1
  _p=$(cat "$_dir/pid" 2>/dev/null)
  _b=$(cat "$_dir/boot_id" 2>/dev/null)
  if [ "$_p" = "$_pid" ] && { [ -z "$UT_BOOT" ] || [ "$_b" = "$UT_BOOT" ]; }; then
    rm -rf "$_dir" 2>/dev/null
  fi
  ut_gate_drop
  return 0
}

# The daemon lock: only `clean.sh --daemon` may hold it.
ut_cleaner_state() {
  ut_lock_state "$UT_LOCK" 1
}

ut_cleaner_pid() {
  cat "$UT_LOCK/pid" 2>/dev/null
}

# The per-pass lock: any clean.sh run may hold it, so the action button and the
# scheduled pass cannot walk the same cache directories at the same time.
ut_run_state() {
  ut_lock_state "$UT_STATE/run.lock" 0
}

ut_run_acquire() {
  mkdir -p "$UT_STATE" 2>/dev/null
  ut_lock_acquire "$UT_STATE/run.lock" "$1" 0
}

ut_run_release() {
  ut_lock_release "$UT_STATE/run.lock" "$1"
}
