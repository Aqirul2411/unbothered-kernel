# Fork audit: the three kernels in `Desktop\Arkael\FORK`

Three flashable zips were handed over as candidates to fork from. This is what
is actually inside them, read from their own embedded `IKCONFIG` and version
banner — not from what the file names claim.

## What they are

| zip | version string | root | HZ | vs us |
|---|---|---|---|---|
| `5.10.264-SuiKernel-Experimental-KernelSU-Next-PERMISSIVE.zip` | `5.10.264-SuiKernel-Experimental-KernelSU-Next-PERMISSIVE` | KernelSU-Next, **no SUSFS** | 300 | 8 releases older |
| `Aetherium4.5C-5.10-base-only-ReSukiSU-SuSFS-Neutron-20260912-3.zip` | `5.10.269-Aetherium4.5C` | **ReSukiSU** + SUSFS | 250 | 3 older |
| `Mahiru-20260824-Millennium.zip` | `5.10.265-Mahiru-MillenniumTeam-android12-9+` | **none** (`CONFIG_KSU` absent) | 250 | 7 older |

Ours is `5.10.272-Unbothered/8eab6f338`. All three are **older than the tree we
already build**, so "fork it" would be a downgrade of 3 to 8 stable releases for
whatever feature the fork adds.

## Config comparison against `configs/marble-working.config`

The audit script read every family that decides how a phone feels: scheduling,
memory, networking, idle, build hardening. Differing symbols per family:

| family | SuiKernel | Aetherium | Mahiru |
|---|---|---|---|
| version | `LOCALVERSION` only | `HZ 300→250`, `LOCALVERSION` | `HZ 300→250`, `LOCALVERSION` |
| root | SUSFS block **absent** | KSU-Next block → ReSukiSU | `CONFIG_KSU` **absent** |
| sched | `SCHED_BORE` absent | `SCHED_BORE` absent | `SCHED_BORE` absent |
| memory (MGLRU, zram, THP) | identical | identical | identical |
| build | identical | identical | `CFI_FORCE_SKIP_CHECK` absent |
| idle | identical | identical | identical |

Two findings worth keeping:

1. **None of the three has `CONFIG_SCHED_BORE`.** Our tree does. The thing that
   usually justifies forking a "performance" kernel is already in what we build.
2. **Mahiru reverted `CONFIG_HZ_300` to 250** (`Revert "gki_defconfig: Set
   CONFIG_HZ_300 to y"`). That is independent confirmation of the first tuning
   change we made, from someone else's tree, without our measurements.

## Taken

| item | from | why |
|---|---|---|
| `CONFIG_NET_SCH_CAKE=y` | SuiKernel | the only symbol any of the three sets that we do not have. `net/sched/sch_cake.c` is already in our tree and simply not compiled. Built, not default, so nothing changes until something asks for it. |
| `ANDROID: sched/fair: unlink misfit from cpu overutilized` | Mahiru | +12 −11 in `kernel/sched/fair.c`, Qais Yousef's upstream ACK patch. Hoists the misfit check above the EAS early-out in `find_busiest_group()`, so a task that does not fit its little core is moved off it **before** the whole system is called overutilized. Applied with a 71-line offset, verified with `patch -p1 --dry-run` first. `patches/0003-sched-fair-unlink-misfit-from-overutilized.patch`. |

## Not taken, and why

| item | from | why not |
|---|---|---|
| `DEFAULT_NET_SCH="cake"` | SuiKernel | making CAKE the default qdisc puts a heavier shaper in the wifi path on every packet, with no measurement on this phone. Available instead. |
| Custom drivers: `Yamada Touch Boost`, `Moona`, `Sandevistan`, `Tenebrion`, `Inaho`, `Sparxie` | SuiKernel | anime-named in-house drivers from a self-described **Experimental** kernel, ~50 commits of refactors and "Drivers: I actually have no idea about this". Nothing to verify them against, and the rule is boot first. |
| ReSukiSU root (`KSU_MULTI_MANAGER_SUPPORT`) | Aetherium | we ship KernelSU-Next + SUSFS, which is what the phone's manager (v3.4.2-50) is. Swapping the root driver for a root flavour we do not use is a config rebuild for no gain. |
| `Mahiru`: no root at all | Mahiru | not a feature. |
| `mm: Tweak memory pressure for 3/4GB RAM devices` | Mahiru | targets 3–4 GB devices. `marble` has 8–12 GB. Wrong device class, and it changes reclaim behaviour. |
| `fs: Lower reclaim segment and threshold` | Mahiru | same family as above, no rationale recorded in the commit, and reclaim is where the MGLRU experiment already hurt this phone. |
| `block/blk-throttle: tweak for flash` | Mahiru | `THROTL_QUANTUM 32→64`, SSD slice `HZ/50→HZ/100`, baseline latency `4000→2000`. Only has an effect when blk-throttle is actually limiting a cgroup's IO; there is no measurement of that on this phone, and "tweak" with no rationale is not a reason. |

## Pandora `5.10.247` (Telegram, 2026-11-01)

`Kernel-Pandora-5.10-26w08d-120358.zip`. Audited by the same method: `Image.gz`
decompressed, `IKCFG` extracted, 5,351 symbols read.

```
version   5.10.247-android12-9-Pandora-26w08d    (25 stable releases behind us)
root      none - CONFIG_KSU absent, no SUSFS
sched     CONFIG_SCHED_BORE absent
memory    identical to ours (no MGLRU, no zram built in)
tcp       default cubic, BBR and BBR3 not even compiled
idle      no DAMON
build     full LTO instead of our thin LTO
HZ        250
installer refuses anything below 5.10.198 or below Android 14
```

Nothing to take. It is the same story as the three zips in `Desktop\Arkael\FORK`:
an older tree, rootless, without BORE, and without the networking stack we build.
Its one difference — full LTO — buys nothing measurable at runtime and costs a
much heavier build; thin LTO is what AOSP and GKI ship.

The binary advertises two knobs of its own, `pandora_config` and `pandora_kfas`,
with no source, no documentation and nothing in the config to describe them.
That is not a feature to fork; it is a name.

**Fifth independent confirmation of `HZ=250`**, which is now the most agreed-on
single setting in this project: SilverCore, GrayRavens, Mahiru, SuiKernel and
Pandora — five unrelated trees, one choice.
| `fs: file_blocker` (Yaroslav Furman) | Mahiru | root-hiding support for userspace tools we do not run; needs a matching userspace to mean anything. |
| `HZ=300` | SuiKernel | we moved to 250 on purpose and Mahiru's revert agrees. |

## Method

`Desktop\Arkael\FORK` → each zip extracted with `tar`, each `Image` parsed for
`IKCFG_ST`…`IKCFG_ED`, gzip-inflated, diffed per symbol family against
`configs/marble-working.config`. The zips are binaries; the config is the only
honest statement a binary makes about itself.
