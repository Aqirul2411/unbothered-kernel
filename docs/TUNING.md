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

**Verdict: do not retry.**

> **Superseded 2026-11-02.** The verdict above was written against a *runtime*
> enable, and the hang it describes is `lru_gen_change_state()` migrating every
> resident page under `pgdat->lru_lock` - not a bug in the merge. Enabling at
> boot removes that transition entirely, and MGLRU has since merged into
> `unbothered-5.10` cleanly (`35a478789`). The first attempt at a cautious
> middle ground, `b63ed8289` with the page-table walks disabled, reproduced a
> quieter version of the same verdict: fine for hours, then sluggish, because
> reclaim without walks evicts in allocation order. Current state, the code
> evidence, and the readback that would kill the experiment for good are in
> [MGLRU.md](MGLRU.md). This entry is kept because "MGLRU hung this phone" is
> still true of the way it was first tried. Not "retry carefully" — the failure mode is a hang,
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

---

### Batch 5 - power-efficient workqueues

`CONFIG_WQ_POWER_EFFICIENT_DEFAULT=y`, the candidate named in batch 4.

Unset in our config and in the phone's, so it has never been tested here. The
feature stops opting-in workqueues — and the two system-level ones — from being
pinned to the CPU that queued the work; the scheduler chooses, and it can choose
a core that is already awake. For a phone the point is the short work item that
currently pays a wake-up and an idle-state exit because the wrong CPU got it.

LWN's article on the feature quotes "up to 15% for some use cases" on ARM and
Android. That is the reason to test it, not a number to expect.

The trade is stated up front: work that moves CPU loses warm cache, so this can
cost responsiveness in exchange for energy. That is exactly what a one-change
flash is for — if it feels worse, deleting one line reverts it.

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



### Pandora `5.10.247` and Nexus `4.19.325` (2026-11-02)

Two zips handed over from a Telegram channel. Neither can be flashed here, and
that is a finding rather than a disappointment:

| zip | kernel | for | evidence |
|---|---|---|---|
| `Kernel-Pandora-5.10-26w08d` | `5.10.247-android12-9-Pandora-26w08d` | one build of a multi-device series, this one for the 8-series | the Image carries `cape` (SM8475) platform strings and **no** `ukee` |
| `Nexus-BETA-alioth` | `4.19.325-cip136-st20-perf` | `alioth` (POCO F3) | its own `device.name1=alioth` gate |

Pandora's AnyKernel names our SoC in its AVB exception (`sku != cape && sku !=
ukee`), so the project does target marble - just not in this artifact. Nexus is a
generation out of reach (4.19, WALT, a different SoC).

**Their sources are not public.** No repository contains `pandora_kfas` or
`pandora_config`, so there is nothing to fork in the literal sense. The one
public tree that touches this kernel family is `wenrouhao/hfdem-PowerTune`, the
tuning module that probes `/sys/module/pandora_config/parameters/enable_mm_vhs`;
it is forked to `Aqirul2411/hfdem-PowerTune` and is where the values below come
from. `TxGoldenstar/android_kernel_xiaomi_sm8250-bakasu` (`4.19.325-cip135-st19`)
is the nearest public source to the Nexus zip's `stXX` lineage and is forked too.

#### The memory block, checked line by line against our own source

Five of its eight writes are already our defaults, which is worth knowing before
copying them:

| their write | our tree at `4a8a27860` | verdict |
|---|---|---|
| `watermark_boost_factor=15000` | `page_alloc.c:375` already 15000 | no-op |
| `swappiness=60` | `vmscan.c:182` already 60 | no-op |
| `compaction_proactiveness=20` | `compaction.c:2655` already 20 | no-op |
| `watermark_scale_factor=150` | `page_alloc.c:377` is 10 | **taken** |
| `min_free_kbytes=65536` | baselines 1024, computed to about 14 MB | rejected for now: 4.5x the reserve, on top of the wider margin |
| MGLRU `0x0007` + `min_ttl_ms=1000` | no `lru_gen` in this build | inert; it is the retry recipe, not a change |
| THP `always` | `TRANSPARENT_HUGEPAGE_MADVISE` | rejected: fights the vendor default we inherit |
| zram + `swappiness` | not built | rejected: removed by measurement |

**Taken:** `46128b05a`, `watermark_scale_factor` 10 -> 150. Watermarks are the
margin kswapd keeps ahead of allocation; at 0.1% a burst can outrun it and land
in direct reclaim, where the task that asked for the page frees pages itself -
a stall mid-scroll rather than a slow page. Read it back with
`cat /proc/sys/vm/watermark_scale_factor`; if it is not 150, a vendor init script
overwrote it later in boot and any measurement is of the vendor, not this commit.

**Rejected, with reasons.** `full LTO` (build time, no measured gain),
`kryo785` and `heapgrowthlimit=512m` (SM8475 and RAM-size specific),
`BFQ` (candidate for a later A/B, not for a batch), `WALT` (4.19 plumbing),
the `ro.lmk.*` props and the Xiaomi `mms`/`spc`/`mfz` disabling (userspace, a
module's business, not the kernel's - and they belong to a ROM build).

**One thing to remember from their installer:** they deliberately skip
`avbctl disable-verity` and `disable-verification` on `cape` and `ukee`. Our SoC
is `ukee`. If AVB handling is ever added to our AnyKernel script, that is the
place it is known to go wrong.

### Oxygen+ "5.10.248" `alioth` (2026-11-02)

`5.10.248-alioth-AOSP-Oxygen+-1703-08052026.zip`, 30.87 MB, "Oxygen+ by Danda".
**The file name is wrong about its own kernel.** The `Image` inside reports

    Linux version 4.19.420BPF-Oxygen+ (danda@pavilion)
    (Oxygen clang version 20.0.0, LLD 20.0.0) #1 SMP PREEMPT
    Fri May 8 17:04:07 WIB 2026

so it is a 4.19 tree, not a 5.10.272-adjacent one, and the config settles what it
is for: `CONFIG_ARCH_KONA=y` (SM8250), `CONFIG_LOCALVERSION="-perf"`. The build
timestamp in the name (17:03, 08-05-2026) matches the Image to the minute, so the
zip is that build - only the `5.10.248` prefix is fiction. `Image-ksu.gz` is the
same tree with `KernelSU` compiled in (`#2`, two minutes later).

**Not flashable here**, for two independent reasons:

| gate | theirs | ours |
|---|---|---|
| device | `device.name1=alioth`, `name2=aliothin`, `do.devicecheck=1` | `marble` (`ukee`) |
| SoC | `CONFIG_ARCH_KONA=y`, SM8250 | SM7475, `ukee` |

AnyKernel's device gate aborts on the codename before it touches a partition, and
even past it the kernel is for a different SoC on a different boot layout. It also
patches **both** `boot` and `vendor_boot` with the same `Image` - correct for a
4.19 device, but it means this zip is not a source of installer logic for us.

**Installer, for the record.** Two variants in one zip, chosen at flash time by
reading `getevent` for a volume key (`tools/oxygen.sh`), plus a `dtbo.img` /
`dtbo-5k.img` battery-capacity choice for alioth; `kernel.conf` overrides both for
unattended sideload. A reasonable design, and 30.87 MB to deliver what we deliver
in 16.6 MB, because they build two variants for a device family and we build one
for one phone. Nothing to copy.

**Config against ours** (`built.config` at `46128b05a`; 2050 to 5192 symbols,
different tree generations, so this is not a diff, only a reading of the
differences that could decide behaviour):

| symbol | theirs | ours | verdict |
|---|---|---|---|
| `HZ` | 250 | 250 | third independent vote for 250, already ours |
| `SCHED_WALT` + `SCHED_TUNE` | y | not built | their 4.19 scheduler plumbing; nothing to inherit on 5.10 |
| `SCHED_BORE` | not built | y | ours, kept |
| `SCHED_AUTOGROUP` | y | n | rejected before: fights Android's own cgroups |
| `ZRAM` + `ZSMALLOC` | y | n | rejected by measurement on this phone |
| `IOSCHED_BFQ`, `IOSCHED_DEADLINE`, `IOSCHED_CFQ` | y | n | 4.19 scheduler menu; BFQ stays a later A/B, not a batch |
| `BLK_WBT` | y | n | desktop writeback trade; no measured need |
| `DAMON`/`DAMON_RECLAIM` | not built | y | ours, inert until configured |
| `KSM`, `TRANSPARENT_HUGEPAGE` | n | y | ours, both vendor-inherited defaults |
| `DAMON_VADDR` | n | y | ours (5.10 backport), passive |
| `DEBUG_INFO` | y | n | theirs ships DWARF; nothing to take |
| `KASAN` | n | **y** | **cannot follow** - see "REVERTED, do not add back" above: the KASAN-off build hangs this phone at the POCO logo |
| `LTO_CLANG_THIN`, `CFI_CLANG`, `SHADOW_CALL_STACK`, `INIT_ON_ALLOC_DEFAULT_ON` | n | y | Google GKI defaults; dropping one is its own measured argument |
| `DEFAULT_TCP_CONG` | `cubic` | `bbr3` | ours |
| `PANIC_TIMEOUT` | -1 | 5 | ours is the temporary diagnostic |

**Nothing taken.** The one row that looks like a win - KASAN off - is the exact
thing that made this phone unbootable, and the rest is either a 4.19 menu we do
not have, a decision already measured here, or a GKI hardening default that
deserves its own A/B rather than a ride-along.

**On that KASAN row:** a second, much more famous kernel reviewed earlier also
ships with KASAN on, which is a useful reminder that "other kernels disable it"
was never the argument here - this phone's own boot test was.
### Measured on the phone: `watermark_scale_factor` never took effect (2026-11-02)

Read over adb from the running `46128b05a-diag` kernel, `/proc/zoneinfo` (the
sysctl itself is root-only for `shell`):

    Node 0, zone Normal    min 2896    low 11245    high 11969    managed 2858738

That settles it without root. This tree uses the CAF variant of
`__setup_per_zone_wmarks()` (`mm/page_alloc.c`), not mainline:

    watermark[LOW]  = min + extra_free_kbytes_share + max(min/4, managed*scale/10000)
    watermark[HIGH] = min + extra_free_kbytes_share + 2 * that

`high - low = 724` and `min/4 = 724` exactly, so the scale term contributed
nothing: the value in effect is 0-2, not 150 (150 on 2,858,738 managed pages is
42,881, which would put LOW at about 209 MB instead of the 43.9 MB measured).
`low - min - 724 = 7625` pages, and `sys.sysctl.extra_free_kbytes` is 30,375 kB
= 7,593 pages, so the rest of the arithmetic closes to 0.4%.

**Who overwrites it.** `/system/etc/init/hw/init.rc` has the MIUI hook

    on property:persist.vendor.watermark_scale_factor=*
        write /proc/sys/vm/watermark_scale_factor ${persist.vendor.watermark_scale_factor}

but that property is empty on this ROM, so the hook never fires. The domain with
write access to `proc_watermark_scale_factor` is `extra_free_kbytes` - the
`/system/bin/extra_free_kbytes.sh` script, which init runs from
`on property:sys.sysctl.extra_free_kbytes=*` and which the framework calls at
boot with 30375. One script, both values: it sets the fixed reserve and drops the
proportional one.

**What it means.** The phone was never running a thin margin. It runs a low
watermark of 43.9 MB: GKI's own default here would be 22.5 MB (min 11.6 MB +
`managed*10/10000`), and Xiaomi replaces the proportional scale with a flat
30 MB `extra_free_kbytes`. Forcing 150 on top of that is not "restoring a margin
that was missing", it is 4.7x the reserve the vendor chose, and the kernel code
default cannot win against a boot script that runs after it.

**And there is no reclaim to fix.** Sampled 61 s while the phone was dozing:
`pgscan_direct` 0, `pgsteal_direct` 0, `allocstall_normal/movable` 0. The 4.39M
`pgscan_direct` in the since-boot total accumulated during the boot after the
flash (dex2oat and cache rebuild), not in steady state.

**Verdict:** `46128b05a` is dead code on this ROM. Either revert it or clamp the
scale in `__setup_per_zone_wmarks()` - but the clamp would quadruple a reserve the
vendor tuned deliberately, on a phone that is not reclaiming, so reverting is the
honest move until some measurement asks for more free margin.

**Open question from the same read (settled further down):** `lsmod` shows `zram`
and `zsmalloc` loaded (8 GB swap, 4.1 GB in use, 1.3 GB physical), while this
build's `built.config` has `# CONFIG_ZSMALLOC is not set` and no `CONFIG_ZRAM` at
all. At the time this looked like the kernel loading something it should refuse;
with root available it turned out to be ordinary `CONFIG_MODVERSIONS` behaviour -
see "foreign vermagic" below. It does mean the old "zram removed by measurement"
claim describes the config, not the phone.

### Who actually owns the VM knobs on this ROM (root shell, 2026-11-02)

With root on the phone (`su -c`), every value is readable. The order of writers
matters more than the values:

| who | when | what it writes |
|---|---|---|
| our kernel | compile | `watermark_scale_factor = 150`, `swappiness = 60`, `min_free_kbytes` computed, THP madvise, `watermark_boost_factor = 15000`, `compaction_proactiveness = 20` |
| `/system/etc/init/hw/init.rc` | early boot | `watermark_boost_factor 0`, `hung_task_timeout_secs 0`, `overcommit_memory 1`, `dirty_expire_centisecs 200`, `dirty_background_ratio 5` |
| `/vendor/bin/init.kernel.post_boot.sh` (service `kernel-post-boot`) | after init | `swappiness 100`, `watermark_scale_factor 43 or 1`, `watermark_boost_factor 0`, `compaction_proactiveness 0`, THP `never`, `min_free_kbytes 11584` |
| `/system/bin/extra_free_kbytes.sh` (framework sets `sys.sysctl.extra_free_kbytes`) | later | `extra_free_kbytes 30375` (this kernel has the knob, so the script exits before touching the scale factor) |
| KernelSU module `unbothered-tune` | `boot_completed` | `swappiness 100`, `page-cluster 0`, `dirty_bytes 128M` / `dirty_background_bytes 32M`, `dirty_writeback_centisecs 1500`, `watermark_boost_factor 0`, `oom_dump_tasks 0`, schedstats 0, i/o none + 128 KiB readahead |
| `/data/adb/service.d/templar_power_daily.sh` | `boot_completed` | `compaction_proactiveness 0`, `page_cluster 0`, `watermark_boost_factor 0`, `stat_interval 10`, `dirty_writeback_centisecs 1500` |

So a compile-time default is a fallback for the first seconds of boot and nothing
more. Any tunable we want to *hold* has to be written after
`kernel-post-boot` runs - which is exactly what the KernelSU module does.

**The vendor bug worth knowing about.** The marble branch never runs:

    ProductName=`getprop ro.product.name`          # "marble_global" on this phone
    if [ "$ProductName" == "marble" ]; then
        echo 43 > /proc/sys/vm/watermark_scale_factor
    else
        echo 1 > /proc/sys/vm/watermark_scale_factor
    fi

`ro.product.name` is `marble_global`, `ro.product.device` is `marble`. The string
comparison misses, so this phone runs the generic value 1 while Xiaomi's own
statement of intent for this model is 43. Measured low watermark with 1: 43.9 MB.
With 43: `max(min/4, managed*43/10000)` = 12,292 pages, so about 89 MB.

That reframes `46128b05a` twice over: 150 was 3.5x the vendor's own number for
this device, *and* it was overwritten anyway. 43 is a defensible value because it
is not our guess - it is the ROM's, restored.

**The watchdogs are half-defeated by userspace.** `init.rc:372` writes
`hung_task_timeout_secs 0`, so `hung_task_panic=1` can never fire, and the live
`panic` sysctl is 0, not the 5 this build was configured with, so a panic would
park the phone instead of rebooting it. `softlockup_panic=1` and
`panic_on_oops=1` are live. ramoops is registered (`ramoops@0xa7000000`, 2 MB
console + 4 MB pmsg) and empty, so a panic would still leave a record.

**zram was never off.** The ROM's own `zram.ko` from `/vendor_dlkm` is loaded -
`vermagic=5.10.160-gki-g496a309247f6`, while the running kernel is
`5.10.272-Unbothered/46128b05a-diag SMP preempt mod_unload modversions aarch64`.
It works: 4.4 GB in swap, 1.2 GB of compressed pages, lzo-rle. Taint is 5636,
which is out-of-tree + staging + a WARN, **not** `TAINT_FORCED_MODULE`, so nothing
was force-loaded. So "zram removed by measurement" described the config and never
the phone.

**And the "foreign vermagic" alarm was my mistake, not a finding.** A module whose
release string differs from the kernel's is *supposed* to load here, because this
kernel is built with `CONFIG_MODVERSIONS=y` and upstream `same_magic()` in
`kernel/module.c` skips the release prefix in exactly that case:

    static inline int same_magic(const char *amagic, const char *bmagic,
                                 bool has_crcs)
    {
            if (has_crcs) {
                    amagic += strcspn(amagic, " ");
                    bmagic += strcspn(bmagic, " ");
            }
            return strcmp(amagic, bmagic) == 0;
    }

`check_modinfo()` passes `info->index.vers` (present: the module has a `__versions`
section), so only `" SMP preempt mod_unload modversions aarch64"` is compared and
the symbol CRCs do the real compatibility check. That is the mechanism GKI vendor
DLKMs rely on across stable bumps, and it is why 418 modules from `/vendor_dlkm`
are loaded on this phone with our kernel in place. Nothing unvalidated is running;
`MODULE_FORCE_LOAD` being off is irrelevant to it.

Consequence worth keeping in mind: `CONFIG_ZRAM`/`CONFIG_ZSMALLOC` in our config
cannot switch zram off on this device, because init loads the vendor .ko from
`vendor_dlkm` before anything we control, and a kernel-only flash never touches
that partition. If zram is ever to be reduced, it has to be done from userspace
(`/sys/block/zram0/disksize`, or the module), not from the config.

### watermark_scale_factor = 43, measured live on the phone (2026-11-02)

Written with root and read back through `/proc/zoneinfo`, one second apart, with
the original value restored immediately afterwards:

    before   1    min 2896   low 11245   high 11969   (43.9 MB / 46.8 MB)
    after   43    min 2896   low 22812   high 35104   (89.1 MB / 137.1 MB)

`high - low` went to 12,292 pages = 2,858,738 * 43 / 10000 exactly, which confirms
this tree's CAF watermark formula (`high = min + extra + 2*scale_term`,
`low = min + extra + scale_term`) and confirms the knob is a live, working lever -
it was only ever losing to `/vendor/bin/init.kernel.post_boot.sh` at boot.

So the number Xiaomi intended for this device is reachable without a rebuild; it
just has to be written after `kernel-post-boot` has run. The KernelSU module is
the only writer that runs late enough.

**Also from the command line (this is Xiaomi's boot image, which we never touch):**
`kasan=off`, `slub_debug=-`, `cpufreq.default_governor=performance`,
`log_buf_len=2M`, `cgroup_disable=pressure`. KASAN=y and SLUB_DEBUG=y therefore
cost nothing at runtime - which is consistent with the earlier KASAN experiment
having been about the build, not the sanitizer.

### 342 s of an in-use phone, no adb traffic: there is no reclaim stall (2026-11-02)

The earlier 61 s sample was taken while the phone was dozing, and a later one was
contaminated by our own `logcat -b all -d` dump: 25k lines allocate, and the
reclaim it triggered was ours, not the phone's. This window has nothing from us
in it. Same build (`46128b05a-diag`), uptime 2995 -> 3337 s:

| counter | delta | per second |
|---|---|---|
| `pgscan_kswapd` | +618,068 | 1,807 pages/s |
| `pgsteal_kswapd` | +391,434 | 1,144 pages/s (~4.6 MB/s) |
| `pswpout` | +72,405 | 212 pages/s (~0.85 MB/s) |
| `pswpin` | +61,814 | 181 pages/s |
| `pgmajfault` | +65,043 | 190 faults/s |
| `allocstall_normal` | 0 | 0 |
| `allocstall_movable` | 0 | 0 |
| `pgscan_direct` | 0 | 0 |
| `pgsteal_direct` | 0 | 0 |

Zone Normal: free 28,794 pages, min 2,896, low 11,307, high 12,031. MemFree
123,744 kB, MemAvailable 4,385,832 kB, 4.3 GB of the 8 GB zram in use. PSI
memory `some avg10` ended at 0.34%; load average 5.38.

**Reading it.** Reclaim is entirely background kswapd, and the phone is not
short of memory: 4.4 GB is available, and the 4.3 GB in zram is Xiaomi's choice
of an 8 GB swap device, not a symptom. Page-cache churn at 4.6 MB/s is what a
phone running `system_server`, Facebook, an e-wallet, Telegram, Intune and
SurfaceFlinger at the same time looks like - `top` had `com.facebook.katana` at
11.5% CPU and `system_server` at 13.1%.

**What this rules out.** `pgscan_direct` and `allocstall` at exactly zero for the
whole window means no allocation ever had to reclaim in the caller's context. A
taller watermark cannot prevent a stall that is not happening, which is the
third independent reason `46128b05a` was reverted (see `5d78169f7`).

**What it does not explain.** "Slow after idle" is still unaccounted for. The
kernel's own stall counters are flat, so the next honest step is to sample while
it is happening rather than from a quiet phone - the phone also has to be
observed, not just the kernel: an app burning 11.5% CPU during an "idle" sample
is a better explanation than any tunable on this list.

**Two writers settled, one still not.** `/system/etc/init/hw/init.rc:372` writes
`hung_task_timeout_secs 0` and line 371 writes `panic_on_oops 1`; nothing else on
the ROM writes either. But no rc file, no post-boot script, no module and no
`/proc/cmdline` argument writes `kernel.panic`, and the cmdline carries no
`panic=` (only `kernel.panic_on_rcu_stall=1`), so the live `panic 0` against
`CONFIG_PANIC_TIMEOUT=5` still has no identified author. It is written after
kernel init or not at all; a module write at `boot_completed` outranks anything
from init either way.