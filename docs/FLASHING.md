# Flashing, and getting back

The rule: **never flash a kernel you cannot undo.** Do the backup first, every
session, even if nothing changed on the phone since last time.

`marble` is an A/B device with a GKI layout, so the kernel lives in `boot` and
the ramdisk in `init_boot` / `vendor_boot`. Confirm the actual names on your
phone rather than trusting this list:

```bash
adb shell ls /dev/block/by-name | grep -E 'boot|init_boot|vendor_boot|vbmeta'
```

## 1. Back up the current kernel (once per ROM update)

Preferred, no root needed:

```bash
fastboot getvar current-slot                 # a or b
fastboot fetch boot_a boot_a.img             # if your fastboot supports it
```

Or with root (KernelSU):

```bash
adb shell su -c 'dd if=/dev/block/by-name/boot_a of=/sdcard/boot_a.img'
adb shell su -c 'dd if=/dev/block/by-name/boot_b of=/sdcard/boot_b.img'
adb pull /sdcard/boot_a.img
adb pull /sdcard/boot_b.img
```

Keep those two files somewhere that is not the phone, with the ROM version in
the filename. They are your way back.

## 2. Flash

Two routes, both fine:

**Recovery (what the packaging is built for).** The build produces an
AnyKernel3 zip in `work/`. Flash it in your recovery of choice. AnyKernel3
unpacks the existing boot, swaps the kernel in, keeps your ramdisk and root.

**fastboot.** Repack the image yourself:

```bash
magiskboot unpack boot_a.img
cp work/out/arch/arm64/boot/Image kernel
magiskboot repack boot_a.img new-boot.img
fastboot flash boot new-boot.img
fastboot reboot
```

Never `fastboot flash` a raw kernel `Image` onto `boot` — it expects a packed
boot image.

### The zip only carries the tuning script when `boot` has a ramdisk

The pinned AnyKernel3 (`BLOCK=boot`, `IS_SLOT_DEVICE=auto`) has two install
paths, and which one runs depends on your phone's partition layout:

| `boot` contains | what the installer does |
|---|---|
| kernel only (GKI + separate `init_boot`, Android 13+) | `flash_boot`: writes the kernel, nothing else |
| kernel + ramdisk | injects `ramdisk/sbin/vortex.sh` and rewrites the boot image |

`marble` shipped with Android 13, so the expected path is `flash_boot`: the
flashable is a kernel-only install, your ramdisk is untouched, and the
thermal/printk script is not injected. When `vortex.sh` *is* injected, it turns
thermals off, forces the `performance` governor, sets `panic=0` and silences
printk at every boot — and for a kernel you are still testing, silencing printk
means a hang produces no log at all.

Two things to know before flashing from recovery:

- the installer aborts if the **running** kernel version is not in
  `5.10 6.1 6.6`, and in recovery "running kernel" is the recovery's own kernel,
  not your installed one. A recovery built on a 4.19 or 6.12 kernel will refuse;
- it writes the **current slot** only, and never touches `init_boot`,
  `vendor_boot`, `dtbo` or `vbmeta`.

`docs/BOOT-TEST.md` covers the backup and the rollback, which is the part that
matters more than the flash.

## 3. First boot checks

If it boots at all, check these in order — a kernel that boots but lost its
vendor modules looks fine for a few seconds and then falls apart:

```bash
adb shell uname -a                                   # version + our name
adb shell cat /proc/version
adb shell dmesg | grep -iE 'version magic|module verification|disagrees'
adb shell ls /vendor/lib/modules | head              # stock vendor modules present
adb shell getprop sys.boot_completed                 # 1
```

Then on the phone: display brightness, touch, Wi-Fi, camera, charging, a call.
Those are the things vendor modules provide; if one is missing, the module
side is the suspect, not the kernel.

## 4. Getting back

```bash
fastboot flash boot boot_a.img     # the file you saved in step 1
fastboot reboot
```

or switch slots, which is the cheapest undo on an A/B device:

```bash
fastboot --set-active=b            # or a, whichever is not current
fastboot reboot
```

A broken kernel on the inactive slot costs nothing. That is why the A/B slot is
worth knowing before you start.

## 5. If it does not boot

- No logo at all, black screen: kernel never started. Wrong image format, or
  the boot image is bigger than the partition. Reflash the backup.
- Logo then reboot loop: kernel started and died early. You need a log — see
  the printk note in the README; with printk silenced there is nothing to read.
- Boots, then the UI dies or the screen stays dark: vendor modules did not
  load. Suspect vermagic/CFI compatibility patches, not your driver work.
