# patches/

Kernel source patches, applied by `scripts/10-build.sh` after the tree is
checked out and before anything is configured.

## How it works

- Every `*.patch` in this directory is applied in filename order, `patch -p1
  --forward --fuzz=2`.
- Any `.rej` file afterwards fails the build and lists the files. A half-merged
  kernel must never reach the compiler quietly.
- Applied to `IDENTITY=own` only. `repro` stays an exact copy of the phone's
  tree, which is the whole point of it.
- `kernel.org` incremental patches carry `index` lines, but those blob ids are
  upstream 5.10.272 and do not exist in this tree, so `git apply --3way` has
  nothing to merge against. `patch` with fuzz is the honest tool here.

## Why this exists

Before this directory had anything in it, the kernel was Arkael's tree plus a
name. Keeping stable updates here — rather than forking the tree — means every
change to the source is a file with a header explaining it, and reverting one is
deleting a file.

## What is in here

### `0001-stable-5.10.273.patch`

Upstream stable update, 5.10.272 → 5.10.273, from
`https://cdn.kernel.org/pub/linux/kernel/v5.x/incr/patch-5.10.272-273.xz`
(sha256 of the .xz: `efeded3814b6db9682846e2fda622305518ef5178f9653a1d1d1bf5dfd5f9646`).

494 files: drivers/gpu, drivers/usb, drivers/net, fs/xfs, fs/cifs, net/ipv4,
sound, and the usual scattering of stable fixes.

**Known conflict risk:** this tree carries Arkael's BBRv3 backport, which rewrote
much of `net/ipv4/tcp_*.c`. The stable update touches `net/ipv4/tcp_input.c`.
If it applies with fuzz, the merged result needs reading, not just trusting —
a silently fuzzed hunk inside TCP congestion control is exactly the kind of
thing that behaves fine until the network is under load.

**Verification after it lands:**

```
cat /proc/version        -> 5.10.273-Unbothered/...
```
