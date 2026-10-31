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

## Not taken, and why

| item | from | why not |
|---|---|---|
| `DEFAULT_NET_SCH="cake"` | SuiKernel | making CAKE the default qdisc puts a heavier shaper in the wifi path on every packet, with no measurement on this phone. Available instead. |
| Custom drivers: `Yamada Touch Boost`, `Moona`, `Sandevistan`, `Tenebrion`, `Inaho`, `Sparxie` | SuiKernel | anime-named in-house drivers from a self-described **Experimental** kernel, ~50 commits of refactors and "Drivers: I actually have no idea about this". Nothing to verify them against, and the rule is boot first. |
| ReSukiSU root (`KSU_MULTI_MANAGER_SUPPORT`) | Aetherium | we ship KernelSU-Next + SUSFS, which is what the phone's manager (v3.4.2-50) is. Swapping the root driver for a root flavour we do not use is a config rebuild for no gain. |
| `Mahiru`: no root at all | Mahiru | not a feature. |
| `mm: Tweak memory pressure for 3/4GB RAM devices` | Mahiru | targets 3–4 GB devices. `marble` has 8–12 GB. Wrong device class, and it changes reclaim behaviour. |
| `fs: Lower reclaim segment and threshold` | Mahiru | same family as above, no rationale recorded in the commit, and reclaim is where the MGLRU experiment already hurt this phone. |
| `ANDROID: sched/fair: unlink misfit from cpu overutilized` | Mahiru | genuinely good upstream work, but it edits `kernel/sched/fair.c`, and this tree already carries `CONFIG_SCHED_BORE`. Two scheduler rewrites interacting is exactly the kind of change that boots fine and misbehaves under load — and the person is away, so nobody can report a regression for hours. Candidate for a later, measured build. |
| `fs: file_blocker` (Yaroslav Furman) | Mahiru | root-hiding support for userspace tools we do not run; needs a matching userspace to mean anything. |
| `HZ=300` | SuiKernel | we moved to 250 on purpose and Mahiru's revert agrees. |

## Method

`Desktop\Arkael\FORK` → each zip extracted with `tar`, each `Image` parsed for
`IKCFG_ST`…`IKCFG_ED`, gzip-inflated, diffed per symbol family against
`configs/marble-working.config`. The zips are binaries; the config is the only
honest statement a binary makes about itself.
