# unbothered-tune — a KernelSU-Next module

Memory tuning that does not require flashing a kernel.

## Why a module instead of a kernel patch

Every value in here is a sysctl or a `/sys` write. Doing the same thing as a
kernel patch would mean:

- a flash and a reboot through a broken-kernel risk, for a change that touches
  no code;
- no way back except another flash;
- a rebuild for every number you want to try.

As a module it is one switch: disable it in KernelSU-Next Manager, reboot, done.
Nothing persists.

The kernel-side changes (KASAN off, debug symbols off) are in
`configs/tuning.fragment`, because those genuinely are code.

## What it does

1. **zram, if nothing else has — as a fallback only.** On this phone the ROM's
   own init already brings zram up (8 GB, lzo-rle), so the module reads
   `/proc/swaps`, sees it, and leaves it alone. The setup path exists for ROMs
   that do not, and is skipped entirely when they do.
2. **Three tunables that only make sense with compressed swap:**
   - `vm.swappiness=100` — swapping into compressed RAM is cheap; the default of
     60 assumes a disk that costs milliseconds per page.
   - `vm.page-cluster=0` — one page at a time; read-ahead against zram just
     decompresses pages nobody asked for.
   - `kernel.sched_schedstats=0` — per-task scheduling accounting nothing reads.
3. **Logs what it did** to `/data/local/tmp/unbothered-tune.log`, including
   `mm_stat`, so the next boot can be compared instead of guessed.

## Install

Zip this folder's contents (module.prop at the zip root) and install it in
KernelSU-Next Manager, or:

```
adb push unbothered-tune.zip /sdcard/
# Manager -> Modules -> Install from storage
```

## Check it worked

```
adb shell cat /data/local/tmp/unbothered-tune.log
adb shell grep zram0 /proc/swaps
adb shell cat /sys/block/zram0/mm_stat    # orig size, compressed size, ...
```

A `mm_stat` with a compressed size roughly 2-3x smaller than the original size
means the compressor is doing its job. SwapTotal in `/proc/meminfo` should be
about half your RAM.

## Undo

Disable the module in the manager and reboot. The sysctls go back to their
defaults, and swap disappears with them.
