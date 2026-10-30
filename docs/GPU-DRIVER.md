# GPU driver, 0863.1 on marble

Adreno userspace driver **V@0863.1** (GIT@ffdf89, 12/24/25), installed by writing
into `/vendor` from recovery. This is the one operation in this project that
flashes something other than the kernel, and it is recorded here with the
safety work that made it worth attempting.

**Result on the device: booted, driver reports 0863.1, camera working.**

## Why not the module

The KernelSU module (same blobs) is the safe route: one overlay, one toggle to
undo, no partition writes. It was tried first and did nothing, for two reasons
that both have to be true before a module can mount anything:

1. `ksud` was not running, so there was no root at all.
2. KernelSU does not mount modules itself — it delegates to a **metamodule**
   (`meta-overlayfs`). Without one, a module installs, appears in the list, and
   changes nothing.

So the module route is still the correct one, and is unblocked the moment
`ksud` works. The `/vendor` route below exists because it needs neither.

## The two failures before this worked

| attempt | what happened |
|---|---|
| Magisk/KernelSU module (original packaging) | installed, did nothing. Relied on Magisk's `set_perm_recursive`; ran every step twice; wiped the dalvik cache; no root anyway |
| TWRP zip writing `/vendor` (reference packaging) | wrote into a read-only mount and reported success; wiped package_cache; chcon'd paths that do not exist on this device |
| TWRP zip, hardened, verity gate | **refused** — `ro.boot.veritymode=enforcing`. Nothing written |
| TWRP zip, FORCE (verity gate = warning + 10s) | **worked** |

## What the hardened installer does

`v0863-marble-twrp-FORCE.zip`:

- checks `ro.product.device` is `marble`, else writes nothing
- remounts `/vendor` rw and **tests** a write before touching anything
- backs up every file it replaces to `/sdcard/AdrenoBackup-0863-<ts>/`
- writes `etc/ firmware/ gpu/ lib64/`
- `sync` — without it a reboot can lose the writes
- verifies the copy by comparing sizes of the three critical libs
- clears shader caches only; dalvik/package caches untouched
- on a non-disabled verity, prints the risk and continues after 10 seconds

## What was NOT covered

- **32-bit apps keep the old driver.** The 0863.1 package is 64-bit only; this
  ROM also has `/vendor/lib/egl` (0615.95). No 32-bit 0863.1 set was found.
- **ROM updates overwrite `/vendor`**, so a firmware update silently reverts the
  driver. Reinstall after updating.
- **Verity**: `ro.boot.veritymode` reported `enforcing` and the device still
  booted after the write. That means the property alone does not prove a write
  will be fatal — it may be spoofed by the ROM, or verification is not applied
  to `/vendor` on this configuration. It is still not evidence that it is safe
  in general, and the comment in the installer says so.

## The safety net that made it testable

```
blockdev --getsize64 /dev/block/by-name/super
dd if=/dev/block/by-name/super of=/sdcard/super_stock.img bs=4M
md5sum /sdcard/super_stock.img
```

Restore:

```
fastboot boot melt.img
dd if=/sdcard/super_stock.img of=/dev/block/by-name/super bs=4M
sync
```

Keep that image off the phone. `/vendor` lives inside `super`, so a kernel
flash cannot repair a bad write; this image can.

## Verify

```
adb shell dumpsys SurfaceFlinger | grep -i Adreno
# GLES: Qualcomm, Adreno (TM) 725, OpenGL ES 3.2 V@0863.1 ...
```

If the installer said `- copy verified by size` and this still shows the old
version, the files landed but are not loading: that is an SELinux context
problem, not a blob problem, and does not need a reflash.
