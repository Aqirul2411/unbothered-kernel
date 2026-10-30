# Unbothered

A GKI 5.10 kernel for `marble` (POCO F5 / Redmi Note 12 Turbo), built from a
pinned, public source tree — and verified against a kernel that is already
known to boot on the phone before anything gets flashed.

## Why this exists

The starting point was a prebuilt `Image` (an AnyKernel3 package) that boots.
A binary is not a spec you can edit, so the workflow is:

```
                   working Image on the phone
                              |
                    (extract: IKCONFIG, vermagic)
                              v
   pinned source  ----->  build  ----->  verify  -----> flash
   8eab6f338                            (must diff clean)
```

The verdict comes before the flash, not after the bootloop.

Two kernels in this folder are known to boot on this exact phone, and they are
used as brackets rather than guesses:

| | version | root | LTO | config |
|---|---|---|---|---|
| Arkael (the tree we build) | 5.10.272 | KernelSU-Next + SUSFS | thin | `configs/marble-working.config` |
| Templar (second opinion) | 5.10.271 | KernelSU-Next + SUSFS | full | `configs/templar-working.config` |

They only differ on 229 config lines, and those differences are taste and
toolchain, not boot-critical. So "does this Image look like something this phone
boots" has an answer that isn't a feeling.

## What is pinned

Everything that changes the output, in `configs/pins.env`. That file is longer
than you'd expect, because the pinned build script is a fetch machine: besides
the kernel it pulls a KSU driver, a SUSFS patch set, a KSU setup script and a
binary patch from branches that move.

| input | pin | why it matters |
|---|---|---|
| `Arkael-Dev/arkael-kernel-a12-5.10` | `8eab6f338` | the exact tree behind the working image |
| `Arkael-Dev/build-arkael` | `f84770a5` (`fix-susfs-510`) | the build script that produced it |
| `inject_ksu/gki_defconfig.sh` | same commit | appends the tuning/root defconfig lines; fetched from branch `6.x` by default |
| `Arkael-Dev/BakaSU` setup + `Baka-SU/BakaSU` driver | `8450dd28` / `d5e9e025` | supplies the ReSukiSU driver and its `CONFIG_KSU_SAMSUNG_*` options |
| `pershoot/KernelSU-Next` | `b427a3f9` | the driver and setup script for `own`; fetched from branch `dev-susfs` by default |
| `simonpunk/susfs4ksu` | `5419f4ee` (`gki-android12-5.10`) | the SUSFS patches themselves |
| `SukiSU_patch/kpm/patch_linux` | `547ae94b` | binary KPM patch applied to the finished Image |
| `Arkael-Dev/AnyKernel3` | `26b22266` | packaging only; cannot change the Image |
| Infinix camera patch (5.10) | `4fe04b60009e`, sha256-checked | source patch the build applies to `v4l2-ctrls.c` |
| Neutron clang `30072026` | URL inside the pinned `build.sh` | toolchain version changes codegen and CFI hashes |

Three of those shas are not documented by anyone: they are the commits that
were HEAD at **2026-10-25 03:44 UTC**, the moment the working Image was built.
That is a guess, and it is a testable one — if the first `repro` build disagrees
with `configs/marble-working.config` on the `CONFIG_KSU` block, these are the
numbers to move.

Residual drift, accepted and named: the Neutron tarball has no sha256 check (the
config diff catches a different toolchain anyway), and the GNU assembler comes
from `android.googlesource.com` at whatever HEAD is.

## How the pinned script is edited

`scripts/10-build.sh` does not reimplement Arkael's build script and does not
pipe it through a pile of `sed`. It hands the pinned file to a small embedded
python patcher with thirteen exact-string replacements, each annotated with the
number of occurrences it expects. If a pin moves and a line no longer matches,
the build stops with the edit's name, the expected count and the text it looked
for — before compiling anything.

Thirteen, not the seven you'd guess, because that is how many places the pinned
script reaches outside itself: identity (3), the kernel checkout, the
localversion suffix, the Infinix camera patch, the `inject_ksu` base URL (3
files), the ReSukiSU setup, KernelSU-Next for `own`, the SUSFS clone in its
quoted and unquoted spelling, the KPM binary patch, and AnyKernel3.

The unmodified script is kept beside it as `work/build.sh.pinned`, so
`diff work/build.sh.pinned work/build.sh` always shows exactly what we changed
in this run.

## Identity: `repro` vs `own`

Both identities build the same tree with the same root stack. The only thing
that changes between them is the kernel name and builder:

| | name | root | vermagic | purpose |
|---|---|---|---|---|
| `IDENTITY=repro` | `Arkael` | `KSU=yes` (KernelSU-Next) | `5.10.272-Arkael/8eab6f338 SMP preempt mod_unload modversions aarch64` | prove the pipeline reproduces a kernel that boots |
| `IDENTITY=own` | `Unbothered` | `KSU=yes` (KernelSU-Next) | `5.10.272-Unbothered/8eab6f338 SMP preempt mod_unload modversions aarch64` | our kernel |

`repro` must diff clean against `configs/marble-working.config`, which was
extracted from the kernel the phone is running. `own` may differ only in
`CONFIG_LOCALVERSION` (and in `CONFIG_KSU_*`, because it tracks the KernelSU-Next
tip instead of a frozen commit). So shipping `own` is one rename away from a
kernel that already boots here, which is the whole reason to trust it.

**Which root flavour, and how we know.** The first repro build came out with
`CONFIG_KSU_MULTI_MANAGER_SUPPORT`, `KSU_TOOLKIT_SUPPORT` and no Samsung
support; the phone's config has the opposite: `KSU_SAMSUNG_KDP/RKP/DEFEX`,
`KSU_CONTAINER_COMPAT`, `KSU_THRONE_TRACKER_ALWAYS_THREADED`, and none of
BakaSU's options. That set belongs to **pershoot/KernelSU-Next** — the driver
`build.sh` installs for `KSU=yes` — not to BakaSU, which is what `KSU=sukisu`
installs. The phone runs KernelSU-Next, so both identities do too.

Do not skip `repro`. It is the only cheap way to learn that a failure belongs
to your change and not to your pipeline.

## Running it

On GitHub (recommended — this is what the build script was written for):

```
Actions -> build -> Run workflow -> identity: repro
```

Locally (Linux or WSL2, tree must live on the Linux filesystem, not `/mnt/c`):

```bash
./scripts/00-fetch.sh            # pinned source + build system
IDENTITY=repro ./scripts/10-build.sh
```

Outputs:

```
work/out/arch/arm64/boot/Image    the kernel
work/*.zip                        AnyKernel3 flashable
work/verify/config.diff           what changed against the known-good kernel
work/build.log
```

## The verify step

`scripts/20-verify.sh` runs automatically after every build and fails the build
if the image is not comparable:

1. extracts the embedded `.config` (IKCONFIG) and diffs it against
   `configs/marble-working.config` — that file was extracted from the working
   `Image` and is the source of truth
2. checks vermagic against the expected string for the identity
3. checks `CONFIG_KSU`, `CONFIG_KSU_SUSFS`, thin LTO and CFI are on, and that
   `KSU=no` really produced no `CONFIG_KSU`
4. checks the `CONFIG_KSU` block against a reference that boots: Arkael's for
   `repro`, Templar's for `own`

For `repro`, the only config line allowed to differ is `CONFIG_LOCALVERSION` —
which does not differ either, so the diff has to be empty. Anything else is a
change nobody asked for.

For `own`, `configs/verify-allow.txt` lists the exceptions we chose on purpose:
the rename and the `CONFIG_KSU`/`CONFIG_KPM` block. Everything else still fails
the build, and every accepted line is printed so it can't quietly grow.

```
work/verify/config.diff              everything that changed
work/verify/config.allowed.diff      the accepted part of it
work/verify/config.significant.diff  must be empty
work/verify/ksu.diff                 our root block vs the booting reference (own only)
```

The build also refuses to hand you an image it cannot explain: a non-empty
`config.significant.diff` fails the job, and the artifacts still get uploaded so
the diff can be read without re-running anything.

## Rules for changing things

1. One change per build. One.
2. `repro` must boot before any change lands.
3. A change that is not in `configs/` or `patches/` does not exist: no ad-hoc
   `sed` on a scratch tree that only lives on your laptop.
4. Keep the flashable known-good. `docs/FLASHING.md` explains the backup.

## Do not ship the tuning script as-is

The original package injects `vortex.sh` into the ramdisk, which at every boot:

- stops every `init.svc.*thermal*` service and `chmod 000`s every thermal zone
- forces `performance` on all CPU/GPU governors
- sets `panic=0`, `panic_on_oops=0`, `panic_on_warn=0`
- silences printk entirely (`0 0 0 0`, `printk_devkmsg=off`)

While developing a kernel, silencing printk means a hang produces no log at
all. Keep it off until the kernel is stable, then bring it back one line at a
time.

## Credit and licence

Kernel source: GPL-2.0. This is a fork of work by **Arkael-Dev**
(`arkael-kernel-a12-5.10`, `build-arkael`). Keep the licences, keep the source
public, keep the attribution.

## Result so far

`own` build, run 41017537032, commit `16291d9`:

```
config.changed  =  2 lines, one pair:
  -CONFIG_LOCALVERSION="-Arkael/8eab6f338"
  +CONFIG_LOCALVERSION="-Unbothered/8eab6f338"
config.significant.diff = 0 bytes
vermagic        =  5.10.272-Unbothered/8eab6f338 SMP preempt mod_unload modversions aarch64
image header    =  identical to the phone's Image (ARMd, text_offset 0,
                   image_size 35651584, same flags, PE offset 64)
```

So the shipped kernel differs from the one already booting on this phone in the
name, and in the KernelSU-Next commit it was built against. That is the whole
distance between "compiles" and "should boot".

The bytes are not identical and should not be expected to be: build timestamp,
build path and LTO ordering differ between any two machines. The config, the
header and the module ABI are what decide a boot, and all three match.

## Next

- first `repro` run: confirm the config diff is empty, then flash it
- `own`: rename only, no feature changes, and check the accepted diff is exactly
  the rename plus the root block
- move phase-1 changes into `patches/NNNN-*.patch` and have the wrapper apply them
- once stable: rebuild the flashable without the thermal/printk script
