# unbothered-tune, a KernelSU-Next module

Memory tuning that does not require flashing a kernel. Version 3.1.

## Why a module instead of a kernel patch

Every value in here is a sysctl or a `/sys` write. As a kernel patch that would
mean a flash and a reboot through a broken-kernel risk for something that touches
no code, no way back except another flash, and a rebuild for every number to try.

As a module it is one switch: disable it in KernelSU-Next Manager, reboot, done.

This is not a shortcut. It is the only place the values can live: a compile-time
default is a fallback for the first seconds of boot, and this ROM writes the same
knobs afterwards from `/vendor/bin/init.kernel.post_boot.sh`, `init.rc` and
`/system/bin/extra_free_kbytes.sh`. Measured on the phone: a kernel built with
`watermark_scale_factor = 150` was running with **1**. The module runs at
`boot_completed`, after all of them.

## What it does

1. **zram, as a fallback only.** The ROM's own init brings zram up (8 GB,
   lzo-rle) before this runs; the module reads `/proc/swaps`, sees it, and leaves
   it alone.
2. **Three tunables that only make sense with compressed swap:** `swappiness 100`
   (swapping into RAM is cheap; 60 assumes a disk costing milliseconds per page),
   `page-cluster 0` (read-ahead against zram only decompresses pages nobody asked
   for), and `sched_schedstats 0`.
3. **Writeback as a byte cap** (`dirty_bytes` 128 MiB / `dirty_background_bytes`
   32 MiB) instead of a percentage of RAM, so a 12 GB phone does not try to flush
   2.4 GB in one go.
4. **I/O and scheduler bookkeeping** that nothing on a phone reads.
5. **A 12-hour app-cache sweep** at idle priority that skips apps in use and
   offline media (see `clean.sh` on the device).

### 3.1: two values userspace was disarming

Both were compiled into the diagnostics kernel and both were being switched off
by something that runs later:

- **`vm.watermark_scale_factor = 43`.** This is Xiaomi's own number for this
  model, from a branch of their post-boot script that never runs because it
  compares `ro.product.name` against `"marble"` while the property reads
  `"marble_global"`. The phone gets the generic `1` instead. Measured on marble:
  `1` gives a 43.9 MB low watermark, `43` gives 89.1 MB (`zoneinfo` Normal
  low/high went from 11,245/11,969 to 22,813/35,104 pages).
- **The hung-task and panic watchdogs.** `init.rc:372` writes
  `hung_task_timeout_secs 0`, so `CONFIG_BOOTPARAM_HUNG_TASK_PANIC` can never
  fire, and the live `panic` sysctl read `0` against a compiled
  `CONFIG_PANIC_TIMEOUT=5`. With `hung_task_timeout_secs 300` and `panic 5`, a
  real hang dumps itself into ramoops and reboots instead of leaving a frozen
  screen and no record. 300 s rather than the kernel default 120 so that a task
  waiting on slow storage for two minutes does not cost a reboot.

Both are one line in the config file and `WATCHDOG=0` / `WATERMARK_SCALE=0`
switch them off.

## This directory is a partial mirror

`service.sh`, `common.sh`, `config.example` and `module.prop` are kept here so a
wiped phone cannot take them with it. `action.sh`, `clean.sh` and `uninstall.sh`
live only on the device at `/data/adb/modules/unbothered-tune/`; they were not
mirrored yet. Nothing here is installable as-is until it is complete.

`service.sh` here is the authoritative copy: it is the version running on the
phone (3.1), including `apply_late()`.

## Check it worked

```
adb shell cat /data/local/tmp/unbothered-tune/status
```

That file is written from the kernel's own readback at boot, not from what the
module wrote, so a value the ROM overrode later shows up as what actually stuck.
It now includes `watermark_scale`, `hung_task_timeout_secs` and `panic`.

## Undo

Disable the module in the manager and reboot. The sysctls return to what the ROM
sets, and zram, if this module created it, disappears with them.
