# patches/

Kernel source patches, applied by `scripts/10-build.sh` after the tree is
checked out and before anything is configured.

## How it works

- Every `*.patch` in **this directory** (not in subdirectories) is applied in
  filename order, `patch -p1 --forward --fuzz=2`.
- Any `.rej` afterwards fails the build and lists the files. A half-merged
  kernel must never reach the compiler quietly.
- Applied to `IDENTITY=own` only. `repro` stays an exact copy of the phone's
  tree, which is the whole point of it.
- Files under `experimental/` are **not** applied. They are kept for the record
  and to stop someone re-deriving the same conclusion.

## Why this exists

Before this directory had anything in it, the kernel was Arkael's tree plus a
name. Keeping changes here — rather than forking the tree — means every change
to the source is a file with a header explaining it, and reverting one is
deleting a file.

## experimental/stable-5.10.273-vanilla.patch — rejected

Upstream stable update 5.10.272 → 5.10.273, from
`https://cdn.kernel.org/pub/linux/kernel/v5.x/incr/patch-5.10.272-273.xz`
(sha256 of the .xz: `efeded3814b6db9682846e2fda622305518ef5178f9653a1d1d1bf5dfd5f9646`).

**Result: 477 of 494 files applied, 17 rejected.**

```
include/net/net_namespace.h      include/linux/property.h
include/linux/fsnotify_backend.h arch/arm64/include/asm/cpucaps.h
arch/arm64/mm/fault.c            fs/nfsd/nfs4proc.c
fs/f2fs/{super,file,gc}.c        fs/f2fs/gc.h
net/core/{filter,net_namespace}.c
net/bluetooth/hci_core.c         drivers/base/property.c
drivers/usb/typec/tcpm/tcpm.c    mm/mmap.c
kernel/time/tick-broadcast.c
```

**Why it fails, and why it is not a fuzz problem:** this kernel is
**AOSP `android12-5.10`**, not vanilla `linux-5.10.x`. Those 17 files are where
Android carries its own changes. Kernel.org's stable patch is written against
upstream code that this tree does not have, so no amount of `--fuzz` will merge
them correctly.

**The correct route, if a newer stable is ever wanted:** re-base onto a newer
commit of Google's `android12-5.10` branch, which takes the stable merges
itself. That is a tree-level operation, not a patch, and it is a multi-day job
with a full re-verification.

**Do not hand-merge the 17 rejects.** They sit in arm64 fault handling, f2fs,
net core and the timer broadcast path: exactly the places where a subtle
mismatch shows up minutes or days later, on a phone that is somebody's daily
driver.
