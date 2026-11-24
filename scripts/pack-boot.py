#!/usr/bin/env python3
"""Repack an Android boot image with a different kernel.

Why this exists: our installer is AnyKernel3, which is flashed from a recovery.
When a kernel does not boot, recovery is not reachable either (the recovery
ramdisk lives in the same `boot` partition), so the only way back is
`fastboot flash boot <img>` - and that needs a boot image, not a zip.

Given a boot image that is known to boot on this ROM (the OrangeFox backup of
the `boot` partition is one, and it is a raw partition dump with the real
ramdisk), this swaps the kernel and keeps everything else byte for byte:
ramdisk, boot signature, dtb, header flags and cmdline. That produces an image
`fastboot flash boot` accepts, with no toolchain and no device access.

    python pack-boot.py <base-boot.img> <Image> <out.img>

Only header v3/v4 are handled, which is what this device has (v4, 4096-byte
pages, header_size 1584).
"""

import struct
import sys

BOOT_MAGIC = b"ANDROID!"
HDR_V3 = 1580
HDR_V4 = 1584


def parse(d):
    if d[:8] != BOOT_MAGIC:
        sys.exit("not an Android boot image (magic %r)" % d[:8])
    ks, rs, osver, hsize = struct.unpack_from("<IIII", d, 8)
    (hver,) = struct.unpack_from("<I", d, 0x28)
    if hver not in (3, 4):
        sys.exit("header v%d: only v3/v4 supported" % hver)
    if hsize not in (HDR_V3, HDR_V4):
        sys.exit("unexpected header_size %d" % hsize)

    # page size: the kernel always starts on the first page boundary after the
    # header, and on this device the ramdisk starts with the LZ4 legacy magic.
    page = None
    for p in (4096, 2048, 8192, 16384):
        kstart = -(-hsize // p) * p
        rstart = kstart + -(-ks // p) * p
        sig = d[rstart:rstart + 4]
        if sig == b"\x02\x21\x4c\x18" or sig[:2] == b"\x1f\x8b" or sig[:2] == b"07":
            page = p
            break
    if page is None:
        page = 4096
        print("  warning: ramdisk magic not recognised, assuming 4096-byte pages")
    kstart = -(-hsize // page) * page
    rstart = kstart + -(-ks // page) * page
    return dict(page=page, hver=hver, hsize=hsize, ks=ks, rs=rs,
                kstart=kstart, rstart=rstart, header=d[:hsize])


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    base_p, kernel_p, out_p = sys.argv[1:4]
    d = open(base_p, "rb").read()
    h = parse(d)
    kernel = open(kernel_p, "rb").read()

    print("  base   : %d bytes, header v%d, %d-byte pages" % (len(d), h["hver"], h["page"]))
    print("  kernel : old %d -> new %d bytes" % (h["ks"], len(kernel)))

    # Everything from the ramdisk onwards is kept exactly as it is: ramdisk,
    # (v4) the 4096-byte boot signature, the dtb if this image carries one, and
    # any padding. Only the first page-aligned block changes size.
    tail = d[h["rstart"]:]
    trimmed = tail.rstrip(b"\0")
    if len(trimmed) != len(tail):
        print("  tail   : %d bytes, %d of trailing zeros dropped"
              % (len(tail), len(tail) - len(trimmed)))

    header = bytearray(h["header"])
    struct.pack_into("<I", header, 8, len(kernel))   # kernel_size
    # ramdisk_size and everything else are untouched.

    page = h["page"]
    out = bytearray()
    out += header
    out += b"\0" * (-len(out) % page)
    out += kernel
    out += b"\0" * (-len(out) % page)
    out += trimmed

    open(out_p, "wb").write(out)
    print("  wrote  : %s (%d bytes, %.1f MB)" % (out_p, len(out), len(out) / 1048576.0))

    # Re-parse what we just wrote. A boot image that does not parse is a brick,
    # so this is not optional.
    chk = parse(bytes(out))
    assert chk["ks"] == len(kernel), "kernel_size did not stick"
    assert chk["rs"] == h["rs"], "ramdisk_size changed"
    assert out[chk["rstart"]:chk["rstart"] + 4] == d[h["rstart"]:h["rstart"] + 4], \
        "ramdisk no longer starts where the header says it does"
    print("  verify : header and ramdisk offsets agree with the written file")


if __name__ == "__main__":
    main()
