### AnyKernel install

# boot shell variables
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;
NO_BLOCK_DISPLAY=1;
NO_MAGISK_CHECK=1;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# Kernel version gate: flashing a 5.10 kernel over a different kernel line is how
# you get a phone that does not boot. Note that in recovery this reads the
# recovery's own kernel, not the installed one.
supported_kvers='5.10 6.1 6.6'
kernel_version=$(cat /proc/version | awk -F '-' '{print $1}' | awk '{print $3}' | cut -f1-2 -d'.')

supported=false
for ver in $supported_kvers; do
  if [ "$kernel_version" == "$ver" ]; then
    supported=true
    break
  fi
done

if ! $supported; then
  abort "- Unsupported kernel version: $kernel_version, abort."
fi

# Boot install.
#
# This is the pinned AnyKernel3 script with one block removed, deliberately:
# the original injected ramdisk/sbin/vortex.sh and patched init.rc to run it at
# boot_completed. That script stops every thermal service, chmod 000s the
# thermal zones, forces the performance governor on all CPUs, sets panic=0 and
# silences printk. On a phone somebody uses every day that is heat, battery drain
# and no way to read a hang.
#
# So: the kernel goes in, nothing else changes. The ramdisk is unpacked and
# written back untouched (write_boot), which keeps the device's own init, AVB
# handling and fstab exactly as they were. On a boot image with no ramdisk the
# installer takes flash_boot instead, which is the same deal by a different path.
split_boot
if [ -f "split_img/ramdisk.cpio" ]; then
    unpack_ramdisk
    ui_print " " "Unbothered: kernel only, ramdisk left untouched"
    write_boot
else
    flash_boot
fi

## end boot install
