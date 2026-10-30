# patches/

Empty on purpose. Phase 0 builds an unmodified pinned tree, so anything here
would be a lie about what is being built.

## How phase-1 changes will work

Every change becomes a numbered patch, applied by the build wrapper in order,
so that a bad build is a one-line revert instead of an archaeology dig:

```
patches/0001-config-keep-thermal-enabled.patch
patches/0002-remove-vortex-printk-silencing.patch
patches/0003-...
```

Rules:

1. One patch, one idea. If the subject needs "and", split it.
2. Generate with `git format-patch`, not hand-edited diffs.
3. A patch that changes the config goes with the patch that needs it.
4. The build wrapper records every applied patch and its sha256 in
   `work/verify/patches.txt`, so an image can always be traced back.

## Not wired yet

The wrapper does not apply `patches/` yet — deliberately. It gets wired the same
commit that adds patch 0001, so there is never a directory that looks like it
does something but doesn't.
