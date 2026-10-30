# Boot test: the only way to know a kernel boots

The rule for this project: **the verdict on a build comes from the phone, and
the phone must always have a way back.** Two things have to be true before a
single byte is written to `boot`:

1. the current boot image is on the PC, pulled from the phone, with a hash you
   wrote down;
2. `fastboot` works on this PC and the bootloader is unlocked, so a dead kernel
   is a 30-second fix instead of a service centre visit.

Check both. "It will probably be fine" is not one of the two.

## What the flashable actually touches

The pinned AnyKernel3 has `BLOCK=boot` and `IS_SLOT_DEVICE=auto`, and its
installer has two paths:

| what your `boot` partition holds | what the zip does |
|---|---|
| kernel only (GKI with a separate `init_boot`, i.e. Android 13+) | `flash_boot`: writes the kernel, touches nothing else |
| kernel + ramdisk | injects `ramdisk/sbin/vortex.sh` and rewrites the boot image |

`marble` shipped with Android 13, so the first row is the expected one. That
matters: it means the flashable **does not** carry the thermal/printk script on
this phone, and your ramdisk is not modified. Confirm it rather than assume it:
`tools/ak3-core.sh` prints `split_boot` output, and a missing
`split_img/ramdisk.cpio` is the tell.

Either way it writes to the **current slot only**. It does not touch `init_boot`,
`vendor_boot`, `dtbo` or `vbmeta`.

## Why the A/B "fallback" is not a plan

An A/B phone will, after a few failed boots, mark the slot unbootable and go back
to the other one. That is a real safety net, and it is also not something to rely
on: it depends on the bootloader's retry counter, it costs several minutes of
bootloop to trigger, and if the other slot was also flashed at some point, both
slots are now bad. The backup is the plan. The fallback is the second net.

## 1. Identify

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
& $adb devices -l
& $adb shell getprop ro.product.device            # expect: marble
& $adb shell getprop ro.boot.slot_suffix          # _a or _b
& $adb shell ls /dev/block/by-name | Select-String 'boot|vbmeta|dtbo'
```

## 2. Back up `boot` for both slots

With root (the phone currently has it):

```powershell
& $adb shell su -c "'dd if=/dev/block/by-name/boot_a of=/sdcard/boot_a.img'"
& $adb shell su -c "'dd if=/dev/block/by-name/boot_b of=/sdcard/boot_b.img'"
& $adb pull /sdcard/boot_a.img backup/boot_a.img
& $adb pull /sdcard/boot_b.img backup/boot_b.img
Get-FileHash backup\boot_a.img, backup\boot_b.img -Algorithm SHA256
```

Record both hashes. `scripts/phone-backup.ps1` does this and refuses to continue
if a file comes back empty or suspiciously small.

Note the current slot's image is the kernel that is booting **right now**, so it
is a known-good kernel by definition. That file is the whole safety net.

## 3. Make the boot image for the new kernel

The kernel `Image` is not a boot image; `boot` expects the Android boot format.
The pinned package ships `tools/magiskboot` (32-bit ARM, runs on the phone), so
the repack happens on the device, using the header from your own backup:

```powershell
& $adb push work\out\arch\arm64\boot\Image /data/local/tmp/new-kernel
& $adb push <ak3-unzipped>\tools\magiskboot /data/local/tmp/magiskboot
& $adb shell su -c "'chmod 755 /data/local/tmp/magiskboot'"
& $adb shell su -c "'cd /data/local/tmp && ./magiskboot unpack /sdcard/boot_<slot>.img'"
& $adb shell su -c "'cd /data/local/tmp && cp new-kernel kernel && ./magiskboot repack /sdcard/boot_<slot>.img new-boot.img'"
& $adb pull /data/local/tmp/new-boot.img backup/new-boot.img
```

`magiskboot repack` prints the header it read and the image it wrote. If it says
anything about a missing kernel or an unsupported header, stop there.

## 4. Check the image before it goes anywhere near the phone

```powershell
$img = [IO.File]::ReadAllBytes("backup\new-boot.img")
# Android boot image magic
[Text.Encoding]::ASCII.GetString($img[0..7])   # expect: ANDROID!
```

Then confirm the kernel inside is the one we built:

```powershell
$text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes("work\out\arch\arm64\boot\Image"))
([regex]'\d+\.\d+\.\d+-[^ ]+ SMP preempt mod_unload [a-zA-Z0-9_ ]*aarch64').Match($text).Value
```

That string must be exactly what `scripts/20-verify.sh` printed. If it is not, do
not flash: the image is not the image that was verified.

Size sanity: `new-boot.img` must be no larger than the `boot` partition, and
within a few hundred KB of the backup's size (only the kernel payload differs).

## 5. Flash

Either push the zip to the phone, reboot to your recovery (if you have one) and
install it, or write the repacked image straight to the current slot:

```powershell
& $adb shell su -c "'dd if=/data/local/tmp/new-boot.img of=/dev/block/by-name/boot_<slot>'"
& $adb reboot
```

`dd` with no `conv=fsync` can return before the write reaches the flash. Add it:
`dd if=... of=... conv=fsync`. A truncated boot image is a bootloop that looks
like a kernel bug.

The `fastboot` route is equivalent, and is what you want if the phone is already
in the bootloader:

```powershell
& $fastboot flash boot backup\new-boot.img
& $fastboot reboot
```

## 6. Did it boot?

```powershell
& $adb wait-for-device
& $adb shell getprop sys.boot_completed      # 1
& $adb shell uname -r                        # the new localversion
& $adb shell dmesg | Select-String 'version magic|module verification'
```

Then on the phone, in this order — these are what vendor modules provide, and a
kernel that boots but lost them fails a few seconds later:

1. screen on, brightness responds
2. touch
3. Wi-Fi reconnects
4. camera opens
5. charging shows
6. a call connects
7. Home / recents / a streamed video

If `sys.boot_completed` never becomes 1, wait a full two minutes before
declaring failure: first boot with a new kernel re-runs dex2oat and can sit on
the logo.

## 7. Rollback

From the bootloader, no root, no recovery, no phone cooperation needed:

```powershell
& $fastboot flash boot backup\boot_<slot>.img
& $fastboot reboot
```

Or switch slots, which is instant and reversible:

```powershell
& $fastboot --set-active=<other>
& $fastboot reboot
```

Check the hash of the file you flash against the hash you wrote down in step 2.
A rollback you have not verified is not a rollback.

## 8. What "done" means

A kernel is accepted when, in one session:

- it boots to `sys.boot_completed=1` without the bootloader falling back to the
  other slot (`adb shell getprop ro.boot.slot_suffix` still shows the slot you
  flashed, and `dmesg` shows no slot retry);
- the eight checks in step 6 pass;
- the phone survives a reboot and a second boot.

Anything less is a promising build, not a working kernel.
