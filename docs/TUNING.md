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

**Checked, 2026-10-30:**

| thing | result |
|---|---|
| our tree (`8eab6f338`) has `mm/lru_gen.c` | no |
| our tree's `mm/Kconfig` has `LRU_GEN` | no |
| our `mm/vmscan.c` has MGLRU hooks | no (only stock `lruvec_` helpers) |
| Melt kernel (marble, Xiaomi sm8450 5.10, most used custom kernel here) has MGLRU | no |
| a working 5.10 backport known on this hardware | none found |

So MGLRU here is not a feature being switched on: it is replacing the LRU core
(`vmscan`, `mmzone`, `memcontrol`, `swap`, `page_alloc`, `workingset`) with
roughly ten thousand lines from 6.1, against a tree that also carries Android
and vendor patches. That is the largest possible change available on this
kernel, and the only prior attempt on this phone hung.

**If it is ever attempted**, the only defensible shape is: compiled in but
disabled by default (`CONFIG_LRU_GEN_ENABLED=n`), enabled at runtime through
`/sys/kernel/mm/lru_gen/enabled`, in a separate experimental zip, never in the
same build as the kernel people rely on. A hang then costs a power cycle rather
than a recovery session, because nothing persists and the next boot is back on
the legacy LRU. Compiled-but-off still is not free: a broken backport can corrupt
core structures at init, before any toggle matters.


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
| `CONFIG_DEBUG_INFO` off | ~1 GB of `vmlinux` that never reaches the phone. Build time and artifact size only. |

Untouched on purpose: CFI, PAC, BTI, hardened usercopy, stack protector (security
that is worth its cost), `CONFIG_FTRACE` (perfetto/System Tracing uses tracefs),
`CONFIG_KALLSYMS_ALL` (SUSFS and KernelSU-Next resolve symbols through it).

### Dropped from batch 1 — zram

The first attempt also enabled `CONFIG_ZRAM`, `CONFIG_ZSMALLOC` and
`CONFIG_CRYPTO_LZO`, on the reasoning that the config showed no swap, so Android
must be killing apps instead of compressing cold pages.

**The device disproved it.** `unbothered-tune.log` from the phone:

```
zram0 already in use: /dev/block/zram0  partition  8388604  0  -2
meminfo: SwapTotal: 8388604 kB  SwapFree: 8388604 kB
algorithms: lzo [lzo-rle] lz4 zstd
```

There is already 8 GB of zram swap, and the default compressor is already
lzo-rle. The kernel config looks empty because the ROM loads zram as a **vendor
module** from `vendor_dlkm`; built-in config cannot describe a module.

So the change was redundant and slightly harmful (a second driver registering
`zram0` alongside the vendor module). Deleted rather than kept "just in case".

**Lesson recorded:** `configs/marble-working.config` describes what is built
into the kernel, not what the phone actually has. Vendor modules are invisible
to it, and "the config has no zram" is not the same sentence as "the phone has
no swap".

### Batch 1 — device result

**Built and verified** (run 41026583256): config diff is exactly KASAN off,
DEBUG_INFO off and their side effects; `ksu-marble-working.config.diff` is 0
bytes, i.e. the root stack still matches the phone exactly.

_Pending flash._ Batch 0 is the one currently on the phone and known to boot
twice; it is kept as `unbothered-batch0-boots.zip` in the handover folder.

---

## Peers analysed

Two other kernels' embedded configs were extracted and read, because a config
disagreement between people shipping to the same hardware is the cheapest
research there is.

### SilverCore `5.10.200` (2023, Xiaomi sm8450 vendor tree)

Shipped in a PixelOS-era marble ROM. Notable: `KASAN` off, `DEBUG_INFO` off,
`LRU_GEN=y` + `LRU_GEN_ENABLED=y` (**MGLRU working on this hardware** — this is
what re-opened that question), `HZ=250`, `INIT_ON_ALLOC` off, zram not built in.

### GrayRavens / Zenithed V8.0 (`android12-5.10`, LTS 5.10.258, 2026)

Same base as this project. Custom `ZENITH` CPU governor, `ZIOS` I/O scheduler,
`HIKARI`/`IYASHI`/`KASUMI` scheduler and placement patches, GPU governor
auto-switcher.

**It bootloops on marble.** Reported by the phone's owner, and consistent with
what is in it: the features are large home-grown subsystems, not flags.

What it does inform:

| theirs | verdict for us |
|---|---|
| `HZ=250` | **take it** — third independent vote for 250 |
| `WQ_POWER_EFFICIENT_DEFAULT=y` | candidate, separate batch: real idle-drain knob, mild behaviour change |
| `SCHED_PREFER_SILVER=y` | candidate for a later, measured batch; idle-battery win, responsiveness cost |
| `KASAN=y` + `kasan.stacktrace=off` | keeps the sanitizer but makes it cheap on MTE hardware. Our removal is still valid (matches Google's production `gki_defconfig`), but this is why KASAN was not the huge win it was described as here |
| `SCHED_AUTOGROUP`, `DEFAULT_CAKE`, `BFQ`, `PAGE_POISONING`, `DAMON_*`, `ZRAM_WRITEBACK` | reject: fights Android cgroups, CPU per packet, desktop scheduler, debug cost, no userspace driver, needs a backing device |
| `ZENITH`, `ZIOS`, `HIKARI`, `IYASHI`, `KASUMI` | reject: thousands of lines, no public source in a releases-only repo, and a bootloop on the exact phone |

**Lesson:** a famous kernel is one data point, not a template. GrayRavens also
ships `DEBUG_INFO=y`, which is nobody's idea of a performance decision.


