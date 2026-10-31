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

## Batches

### Batch 1 - KASAN off: REVERTED, it hangs this phone

Applied only to `IDENTITY=own`, via `configs/tuning.fragment`.

**Result on the device: stuck at the POCO logo.** No adb, and the key combo did
not reach recovery; recovered with `fastboot boot melt.img` and reinstalling the
previous kernel. Nothing was lost - `boot` was the only partition touched.

**How we know it was KASAN and not the moved driver.** Batch 1 changed two things
at once, so a build was made with the *same new driver* and the phone's original
config (`TUNING=off`). It **boots**. Same driver, no hang. That leaves the config,
and inside the config only KASAN can affect runtime - `DEBUG_INFO` never appears
in the Image at all. The sizes agree: 35,873,484 bytes with KASAN, 35,805,516
without.

There is no explanation yet for *why*, and a hang leaves no log to test guesses
against. The empirical fact is enough to stop.

| change | verdict |
|---|---|
| `CONFIG_KASAN` off | **reverted.** Hangs at the logo on this phone. A theoretical benefit on an unbootable kernel is zero. |
| `CONFIG_DEBUG_INFO` off | kept. ~1 GB of vmlinux that never reaches the phone; build time and artifact size only. |

Untouched on purpose: CFI, PAC, BTI, hardened usercopy, stack protector (security
that is worth its cost), `CONFIG_FTRACE` (perfetto/System Tracing uses tracefs),
`CONFIG_KALLSYMS_ALL` (SUSFS and KernelSU-Next resolve symbols through it).

**Lesson about method, not kernels:** batch 1 moved the config *and* the driver in
one flash. That turned a five-minute bisect into an hour and a phone that would
not boot. One change per flash is the difference between a symptom and a
diagnosis. The `TUNING` switch exists so the next question costs one dispatch.
### Dropped from batch 1 - zram
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


---

### Batch 2 - HZ=250, one line

**Built and verified** (run 41054425557): accepted diff is the rename, `HZ 300 -> 250`
and the `DEBUG_INFO` family. `significant.diff` is 0 bytes, the KSU block still
matches the phone exactly, and the Image is 35,871,068 bytes - the same size as
the previous build, which is what a tick-rate change should look like.

**Why 250:** SilverCore 5.10.200 (2023) and GrayRavens (same GKI base, 2026) both
chose it over the 300 that Arkael's inject script sets. 17% fewer timer
interrupts, paid at idle as well as under load.

**Deliberately alone.** Batch 1 moved a config and a driver in one flash and
turned a five-minute bisect into a phone stuck at the logo.

_Device result: pending flash. Revert if idle drain moves less than the noise
floor (~0.2 %/h), rather than carrying a change that did nothing._

---

### Batch 4 - schedutil drops frequency without idling

**The gap in batch 3:** TEO decides when the CPU goes to sleep. Nothing so far
changed what clock it comes back to when it cannot sleep — and that is the
screen-on cost, which is where a phone spends most of its energy.

`patches/0004-cpufreq-schedutil-drop-without-idling.patch` removes the guard in
`schedutil` that refuses to lower a single-CPU policy's frequency unless that CPU
has entered idle since the last update. Sultan Alsawaf's argument, which is hard
to argue with: the clock is already gated in the shallowest idle state, so
waiting for an idle call before slowing down is putting the cart before the
horse. A rate limiter on frequency changes already exists; the heuristic is
redundant. For long-running low-compute work — scrolling, video — it holds the
clock higher than the work needs.

His measurement on a Pixel 8, not ours: **7.5% lower CPU power** in a browsing
workload (270 mW → 250 mW), no visible performance loss.

Checked before taking it: `CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y`, so this is
the governor the phone actually runs. A patch against a governor nobody uses is
a comment.

Cut against our own `kernel/sched/cpufreq_schedutil.c` (their commit is +1 −30
but two of its hunks do not fit our file), applied and re-read after applying:
29 lines removed, no leftover references, `sugov_update_single()` still coherent.

**What to watch:** unevenness in scrolling or video. Interactions are the risk,
not the mechanism.

**Known but not taken yet:** `CONFIG_WQ_POWER_EFFICIENT_DEFAULT` is unset in our
config and in the phone's. Upstream describes it as letting unbound work run on
a core that is already awake instead of waking an idle one; LWN quotes "up to
15% for some use cases" on ARM. It is a real idle-drain lever, and it is a
one-line config change for a later batch — kept out of this one so the schedutil
result stays readable.

---

### Batch 3 - CAKE compiled in, still not the default

`CONFIG_NET_SCH_CAKE=y` only. `net/sched/sch_cake.c` has been in this tree the
whole time with no symbol to build it; SuiKernel's config is the only place it
turned up enabled. Compiling a scheduler in that nothing selects cannot change
how the phone runs, so this batch is safe to carry while batch 2 is still being
measured — but it is also expected to be **inert**, which is why it is recorded
as a capability rather than a win.

Reverting is one line in `configs/tuning.fragment` and changes nothing observable
either way, unless something selects cake:

    su -c 'tc qdisc replace dev wlan0 root cake'

**And one source patch, the only behaviour change in this batch:**
`patches/0003-sched-fair-unlink-misfit-from-overutilized.patch`, +12 −11 in
`kernel/sched/fair.c`. A misfit task — one that does not fit the CPU it is on —
now gets moved off a little core even when the system is not overutilized. Before,
the EAS early-out returned first, so the misfit check only ran once the whole
system was loaded enough to be called overutilized.

Why this one and no other scheduler change: `CONFIG_SCHED_BORE` is already in
this tree, and stacking a second scheduler rewrite on it is how a kernel boots
fine and then misbehaves under load. This patch is upstream Android work that
many shipping kernels carry, it is twelve lines, and it applies to our file with
a clean offset — not a fork's invention.

**What to watch:** wake latency and battery. The trade is more core migration
(shorter time-to-completion, a little more big-core time). If the phone feels
worse or drains faster, delete `patches/0003-*` and rebuild — it is the only
behaviour change here.

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

### SuiKernel `5.10.264`, Aetherium `5.10.269`, Mahiru `5.10.265` (2026)

Three zips handed over as fork candidates. All three are **older than the tree
we build** (5.10.272), and their scheduling, memory, idle and build blocks are
identical to ours or a subset of it. None of them sets `CONFIG_SCHED_BORE`, which
we already have. Full evidence, symbol by symbol, in
[FORK-AUDIT.md](FORK-AUDIT.md).

| theirs | verdict for us |
|---|---|
| `DEFAULT_NET_SCH="cake"` (Sui) | reject here, as above: CPU per packet. But `NET_SCH_CAKE=y` **is** taken below — built, not default |
| `HZ=250` (Mahiru reverted 300 → 250) | already taken; fourth independent vote for 250 |
| Sui custom drivers (`Yamada`, `Moona`, `Sandevistan`, `Tenebrion`, `Inaho`) | reject: in-house drivers in a self-described Experimental kernel, no way to verify, and boot comes first |
| ReSukiSU root (Aetherium) | reject: the phone runs KernelSU-Next + SUSFS, this is a rebuild for a flavour we do not use |
| Mahiru `mm` pressure tweaks | reject: written for 3–4 GB devices, ours has 8–12 GB |
| Mahiru `sched/fair: unlink misfit from cpu overutilized` | **taken** in batch 3: +12 −11, upstream ACK work, applies cleanly. See the batch note below for the risk this carries |


