# MGLRU on this tree

Notes for the 5.10.272 backport that now lives on `unbothered-5.10` as a merge
plus one commit. Everything here is read off `mm/vmscan.c` at `b63ed8289`, not
off a blog post.

## What came in

`mglru-5.10` (Arkael's branch off the same `8eab6f338` base) merged 3-way into
the main line: Google's BACKPORT series plus the fixes that followed it
(cgroup-migration crash, workingset accounting, per-zone reclaim, inc_min_seq
race, CMA pages, retry-writeback, the two ANDROID swap fixes).

Clean merge, tree `6d6587f6`, `config.significant.diff` 0 bytes. About 3000
lines of `mm/vmscan.c` plus 800 of `mm/Kconfig`, `mm/Makefile`,
`include/linux/mmzone.h`, `mm/huge_memory.c`, `mm/memory.c`, `mm/rmap.c`.

## The four capabilities

`/sys/kernel/mm/lru_gen/enabled` is a bitmap, not a boolean:

| bit | name | what it does |
|---|---|---|
| `0x1` | `LRU_GEN_CORE` | generations replace the active/inactive LRU lists |
| `0x2` | `LRU_GEN_MM_WALK` | **walks page tables during aging to promote touched pages** |
| `0x4` | `LRU_GEN_NONLEAF_YOUNG` | skip non-leaf page-table entries with no young children |
| | `LRU_GEN_STATS` | a Kconfig symbol referenced zero times in `vmscan.c`. Not a knob. |

Reading back `0x0001` means: generations, and no page-table walk.

## Why core-only is the wrong half

Aging is `try_to_inc_max_seq()`. Its first decision, line 3957:

```c
	if (!force_scan && !(arch_has_hw_pte_young() && get_cap(LRU_GEN_MM_WALK))) {
		success = iterate_mm_list_nowalk(lruvec, max_seq);
		goto done;
	}
```

With `0x0002` off, that branch is taken and the sequence advances **without
scanning anything**. Promotion to a newer generation (`page_update_gen()`) then
has only three call sites in the whole file:

| line | caller | reachable with walks off? |
|---|---|---|
| 3493 | `walk_pte_range()` | no |
| 3573 | `walk_pmd_range_locked()` | no |
| 4249 | `lru_gen_look_around()` | yes, but only for pages already in an rmap walk on the way out, one 2 MB window at a time |

So with `0x0001`, a page is generally evicted in the generation it was *born*
in. Reclaim order becomes allocation order: FIFO, with a small local rescue for
whatever happens to sit next to a page being unmapped.

That is strictly less information than the legacy LRU, which reads the accessed
bit during `page_referenced()` and gets `mark_page_accessed()` on every fault.
Google's design does not hide this: the walks are what make MGLRU better than
LRU, not an optional extra on top of it.

**Field report, 2026-11-02:** on `b63ed8289` the phone became sluggish after
hours of use, not at boot. That is the signature: nothing is reclaimed while
there is free memory, so a FIFO victim policy costs nothing until the caches
fill, and then every reclaim pass picks a page that is in use, which faults
straight back in.

The user's own description, which is worth keeping because it is the shape of
every reclaim-quality bug: idle the phone, then pick it up, and app opens take
seconds and scrolling stutters, until a reboot. No heat involved.

**Fix, `41fac00aa`:** that late_initcall is deleted. `mm/vmscan.c` is back to the
merge commit's version, where `CONFIG_LRU_GEN_ENABLED=y` means
`DEFINE_STATIC_KEY_ARRAY_TRUE` - every capability on at boot, aging walks
included. Nothing turns anything on at runtime, so the `change_state()` stall
still never happens.

Expected readback is `0x0003`: core and walk. This tree has no
`CONFIG_ARCH_HAS_NONLEAF_PMD_YOUNG`, so the third bit cannot appear in the
mapping at all.

**A readback of `0x0001` after that fix would be decisive in the other
direction.** `show_enabled()` masks the walk bit with `arch_has_hw_pte_young()`,
which on arm64 is `cpu_has_hw_af()`. If the walk bit refuses to appear, the SoC
does not offer a hardware accessed bit, the walk is not available, MGLRU cannot
be better than the LRU here, and the right move is to drop MGLRU rather than keep
paying 3000 lines of merge conflict for nothing.

## Why it is on at boot

Enabling core at runtime calls `lru_gen_change_state(true)`, which walks every
memcg and node and runs `fill_evictable()` under `pgdat->lru_lock` in batches
until the lists are converted (line 4901). On a phone with several GB cached
that is a lot of lock time; writing `0x7` on a loaded system froze the screen
with no panic and no reboot.

At boot the lists are nearly empty, the same conversion is free, and
`LRU_GEN_ENABLED=y` does it before anything can be watching.

The same call is symmetric: `enabled=false` drains the generation lists back
into the conventional ones. **`echo 0` is not free on a loaded phone** - it is
the same migration in the other direction. If it has to be done, do it right
after boot.

## `min_ttl_ms` is 0 here, which means off

`age_lruvec()` protects the working set only if `min_ttl` is non-zero:

```c
	if (min_ttl) {
		int gen = lru_gen_from_seq(min_seq[LRU_GEN_FILE]);
		unsigned long birth = READ_ONCE(lruvec->lrugen.timestamps[gen]);

		if (time_is_after_jiffies(birth + min_ttl))
			return false;      /* don't age, don't evict */
```

`lru_gen_min_ttl` is a plain `__read_mostly` unsigned long initialised to 0, and
the only writer in the tree is `store_min_ttl()`. So on this build it reads 0 and
recently-touched pages get no protection at all. It is writable at runtime and
the write is a single variable store - no migration, no lock, cannot stall:

```
echo 1000 > /sys/kernel/mm/lru_gen/min_ttl_ms
```

## Where the evidence stands

| claim | status |
|---|---|
| merges cleanly into 5.10.272 | verified, twice |
| boots with core on | verified on device, `0x0001` |
| survives an hour | verified |
| better than the legacy LRU for a full day | **contradicted once**: sluggish after hours on `b63ed8289`, regardless of whether MGLRU was the newest thing on the phone |
| walks are safe on this vendor tree | untested - `41fac00aa` is the first build that runs them |

The next honest test is the one `41fac00aa` sets up: core *and* walks at boot,
because core alone is a configuration whose only distinguishing feature is that
it drops the information the algorithm needs.

If it is still sluggish, the honest fallback is not another MGLRU variant. It is
`d85d42b7c`, which is this same kernel with the merge absent - and if the
sluggishness survives *that*, then it was never memory management and the four
scheduler commits are next on the list, because those are the only other thing
that changed since the build the phone ran happily for a day.
