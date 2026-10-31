# MGLRU on Unbothered: what it is, how it is switched on, and what can go wrong

**Status:** experimental branch only. `main` is untouched and keeps the kernel
that is known to boot. This ships as its own zip and is never "the latest".

## What was actually merged

Arkael's `mglru-5.10` branch carried Google's **BACKPORT series** for 5.10, plus
the fixes that followed it:

```
BACKPORT  mm: x86, arm64: add arch_has_hw_pte_young()
BACKPORT  mm: multi-gen LRU: groundwork / minimal implementation
BACKPORT  mm: multi-gen LRU: exploit locality in rmap / support page table walks
BACKPORT  mm: multi-gen LRU: optimize multiple memcgs / kill switch / debugfs
UPSTREAM  mm: multi-gen LRU: thrashing prevention / admin guide / design doc
ANDROID   GKI: Build multi-gen LRU
ANDROID   MGLRU: Don't skip anon reclaim if swap low
ANDROID   MGLRU: Avoid reactivation of anon pages on swap full
UPSTREAM  fix crash during cgroup migration
UPSTREAM  fix workingset accounting
BACKPORT  retry pages written back while isolated
FROMGIT   Fix per-zone reclaim / Avoid race in inc_min_seq() / skip CMA pages
ANDROID   Make MGLRU aware of speculative faults
```

27 commits, 39 files, roughly 4,000 lines. In this backport the implementation
lives **inside `mm/vmscan.c`** (162 `lru_gen` references, ~7,300 lines total) —
there is no separate `mm/lru_gen.c`, and looking for one is the wrong test.

**Merged, not patched.** The branch's merge base was 655 commits behind our pin.
A patch that applies with fuzz across that distance can mean something different
than it did at its base; a 3-way merge either produces the right tree or reports
a conflict. It reported none:

```
merge base   dc60f035cd39
merge-tree   exit 0, tree c24766b2
merge commit dae6f7204c0bdb0270163781762cb513b461fefa
Makefile     5.10.272   <- the LTS level survived the merge
```

## Why it hung before

The previous attempt on this hardware hung with no log. The series above includes
the commits that would explain that: `fix crash during cgroup migration`,
`Avoid race in inc_min_seq()`, `Fix per-zone reclaim`. Those are exactly the kind
of bug that produces a silent hang rather than a visible failure. So the version
that hung is not this version — but "fixed upstream" is not "verified here", and
that distinction is the whole point of the switch below.

## How it is switched on

Compiled in, **off at boot**:

```
CONFIG_LRU_GEN=y
# CONFIG_LRU_GEN_ENABLED is not set
```

At boot the legacy LRU runs, exactly as it does today. The backport exposes:

| path | meaning |
|---|---|
| `/sys/kernel/mm/lru_gen/enabled` | bitmask read/write, 0644. Reads back as `0x%04x` |
| `/sys/kernel/mm/lru_gen/min_ttl_ms` | eviction TTL floor, 0644 |

Bits: `1` = core, `2` = page-table walks, `4` = non-leaf PMD young.

```
su -c 'cat /sys/kernel/mm/lru_gen/enabled'      # 0x0000 while off
su -c 'echo 0x7 > /sys/kernel/mm/lru_gen/enabled'
su -c 'cat /sys/kernel/mm/lru_gen/enabled'      # 0x0007 when all three bits are on
su -c 'echo 0 > /sys/kernel/mm/lru_gen/enabled' # back to the legacy LRU
```

Useful when it *is* on: `min_ttl_ms` sets the minimum time a page must live before
it can be evicted; raising it protects the working set, lowering it makes reclaim
more aggressive.

## What can still go wrong, stated plainly

The kill switch protects the **runtime** path, not the boot. This merge also
touches `include/linux/mm_types.h`, `memcontrol.h` and `mmzone.h`, which the
kernel sets up before any toggle is read. If the merge broke a core structure,
the switch cannot save the boot — only the rollback zip can.

Combined with the fact that the merge was textual (git compares text, not
semantics), the honest expectation is: **it may not boot**. That is why it is a
separate zip, and why the zip you keep is the one that already works.

## What to expect if it does boot and you enable it

MGLRU changes reclaim policy, not scheduling or frequency. Expected, from its own
documentation and the measurements around the series:

- fewer cold starts under memory pressure — background apps survive longer
- more scanning work when memory *is* tight: it can cost CPU to save memory
- no change to idle drain in a phone that is not under memory pressure

So the measurement that matters is not overnight drain, it is: does the phone
stop evicting your background apps, and does it feel slower when memory is full.

## Measuring it: debugfs, and a Kconfig trap

`CONFIG_DEBUG_FS=y` is on, so the backport registers two nodes unconditionally at
`late_initcall(init_lru_gen)`:

| node | mode | what it is |
|---|---|---|
| `/sys/kernel/debug/lru_gen` | 0644 | live per-memcg view; writable, can force aging |
| `/sys/kernel/debug/lru_gen_full` | 0444 | full generation detail, read-only |

**The trap:** `CONFIG_LRU_GEN_STATS` exists in `mm/Kconfig` ("Full stats for
debugging"), which reads like the switch to turn counters on. It is not:
`grep -c LRU_GEN_STATS mm/vmscan.c` returns **0**. The symbol is dead in this
backport — a build with it would compile, verify, and change nothing. The
debugfs nodes above are registered regardless. Anyone "enabling stats" here is
enabling a placebo.

## Reverting

Flash the main-line `unbothered.zip` from `Desktop\Unbothered\` and the
experimental kernel is gone. Nothing persists on the device: the zip replaces the
`boot` partition wholesale, and there is no vendor or data-side state to clean up.

In the build repo, the experiment is one branch — `git checkout main` and the
next build is the kernel that is known to boot.
