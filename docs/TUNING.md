# Tuning log

Every change to the kernel, and every idea that was tried and rejected. A
rejected idea is worth as much as an accepted one: it is the only thing that
stops the same hang being rediscovered in six months.

Rules for this file:

1. An entry says what changed, why, and what happened on the device.
2. "Should be faster" is not a reason. A reason names a cost or a bottleneck.
3. One batch per flash. If two things land together, neither result means
   anything.
4. Anything rejected stays here with the symptom, not just the verdict.

---

## Rejected

### MGLRU (multi-generational LRU) backport

**Tried:** by a developer on Arkael's tree, before this repository existed.

**Result on this phone:** hangs, then the device restarts itself.

**Verdict: do not retry.** Not "retry carefully" — the failure mode is a hang,
which means no log and no way to see what went wrong, and a restart loop on a
phone that is someone's daily driver.

**Why it is tempting anyway:** MGLRU is the single biggest available
memory-management win — it fixes LRU thrash under memory pressure, which is
exactly the "background apps die, then get cold-started" pattern that costs
battery on a phone. It is in 6.1, and 5.10 trees only have it as a backport, so
it is a large patch set against a tree that already carries Android patches,
vendor patches, SUSFS and BBRv3.

**What would change the verdict:** a backport from a source that is proven on
5.10 with this exact patch stack, tested on a spare device, with serial console
or last_kmsg capture so a hang is diagnosable. None of that is true today.

**Side effect worth knowing:** `inject_ksu/gki_defconfig.sh` still carries
`CONFIG_MGLRU=y` and `CONFIG_MGLRU_ENHANCEMENTS=y`, left behind when the code
was removed. Kconfig silently ignores unknown symbols, so those lines have been
doing nothing. That is why the built config is worth reading instead of trusting
the script that generates it.

---

## Accepted

### Batch 1 — stop paying for debug instrumentation

Applied only to `IDENTITY=own`, via `configs/tuning.fragment`.

| change | reason |
|---|---|
| `CONFIG_KASAN` off (and `KASAN_HW_TAGS` with it) | memory tagging in a daily driver: CPU on every allocation, memory for tags. A fuzzing tool, not a runtime feature. |
| `CONFIG_ZRAM=y`, `CONFIG_ZSMALLOC=y` | the tree had the drivers but built neither, so there was no swap at all. Android killed apps instead of compressing cold pages. lzo-rle for the lowest cost per byte. |
| `CONFIG_DEBUG_INFO` off | ~1 GB of `vmlinux` that never reaches the phone. Build time and artifact size only. |

Untouched on purpose: CFI, PAC, BTI, hardened usercopy, stack protector (security
that is worth its cost), `CONFIG_FTRACE` (perfetto/System Tracing uses tracefs),
`CONFIG_KALLSYMS_ALL` (SUSFS and KernelSU-Next resolve symbols through it).

**Device result:** _pending — waiting for the first flash of this batch._
