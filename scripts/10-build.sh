#!/usr/bin/env bash
# Build the kernel.
#
# We do NOT reimplement Arkael's build script. It is the thing that produces a
# kernel which boots on this phone, so we pin it and wrap it. Everything this
# wrapper changes is listed below, as an exact string replacement: if the pinned
# script ever stops containing one of those strings, the build aborts before it
# compiles anything instead of quietly building something else.
#
# What is changed, and why:
#   - kernel name / builder / host        -> identity
#   - kernel clone                        -> check out KERNEL_SHA, not a branch tip
#   - localversion suffix                 -> KERNEL_SHORT_SHA, not git's choice
#   - Infinix camera patch                -> download checked against a sha256
#   - inject_ksu scripts                  -> pinned to BUILD_SHA, not branch 6.x
#   - ReSukiSU setup + driver             -> pinned shas, not branch main
#   - KernelSU-Next setup + driver        -> pinned sha, not branch dev-susfs
#   - susfs4ksu clone                     -> pinned sha
#   - KPM Image patch                     -> pinned sha
#   - AnyKernel3 clone                    -> pinned sha
#
# Outputs:
#   work/out/arch/arm64/boot/Image
#   work/*.zip                        (AnyKernel3 flashable)
#   work/build.log
#
# Locally, the pinned script calls `sudo timedatectl set-timezone`: on WSL that
# will wait for a password in the middle of the build. Run `sudo -v` first, or
# just let CI do the build.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/configs/pins.env"
# shellcheck source=/dev/null
source "$ROOT/configs/identity.env"

# One-run override of the root driver pin, for bisecting a boot failure without
# a commit per attempt. configs/pins.env stays the source of truth; this only
# changes what this one run builds.
if [ -n "${KSUN_OVERRIDE:-}" ]; then
  KSUN_SHA="$KSUN_OVERRIDE"
fi

die()  { echo "ERROR: $*" >&2; exit 1; }
say()  { echo "[build] $*"; }

WORK="$ROOT/work"
[ -d "$ROOT/src/build-arkael/.git" ] || die "run scripts/00-fetch.sh first"

# --- scratch copy of the pinned build system -------------------------------
if [ ! -d "$WORK/.git" ]; then
  say "creating work/ from the pinned build system"
  rm -rf "$WORK"
  git clone -q "$ROOT/src/build-arkael" "$WORK"
fi
git -C "$WORK" -c advice.detachedHead=false checkout -q "$BUILD_SHA"
[ "$(git -C "$WORK" rev-parse HEAD)" = "$BUILD_SHA" ] || die "work/ is not at $BUILD_SHA"

# --- identity --------------------------------------------------------------
case "$IDENTITY" in
  repro) NAME="$REPRO_NAME"; KUSER="$REPRO_USER"; KHOST="$REPRO_HOST" ;;
  own)   NAME="$KERNEL_NAME"; KUSER="$KERNEL_USER"; KHOST="$KERNEL_HOST" ;;
  *)     die "IDENTITY must be 'repro' or 'own', got '$IDENTITY'" ;;
esac

# Root flavour is fixed per identity, because it is part of what verify proves.
# Both identities use KernelSU-Next: that is what the phone runs (see
# configs/identity.env for the config evidence), so reproducing it and shipping
# our own are the same root stack.
if [ "$KSU" != "yes" ]; then
  die "IDENTITY=$IDENTITY expects KSU=yes (KernelSU-Next), got KSU=$KSU.
  The phone runs KernelSU-Next: its config carries CONFIG_KSU_SAMSUNG_KDP/RKP/
  DEFEX, CONTAINER_COMPAT and THRONE_TRACKER, and none of BakaSU's options.
  A different root flavour changes the CONFIG_KSU_* block, so the config diff
  would stop proving that we built the kernel the phone already boots."
fi

say "identity: $IDENTITY  (kernel name: $NAME, built by $KUSER@$KHOST)"

# --- tuning ----------------------------------------------------------------
# Only `own` gets the tuning fragment, and only when TUNING=on. `repro` exists to
# be byte-identical to the phone's kernel, so it must not have opinions about
# zram or debug options: an empty config diff is the whole point of it.
#
# TUNING=off builds the same commit with the tuning removed. That is the bisect
# switch: when a tuned build fails to boot, one run with TUNING=off says whether
# the setting or something else (the root driver) is responsible.
TUNING="${TUNING:-on}"
rm -f "$WORK/tuning.fragment"
rm -f "$WORK/banner"
if [ "$IDENTITY" = "own" ]; then
  # Branding is not tuning: a build with the config tuning switched off is still
  # an Unbothered build, and its installer should say so.
  cp "$ROOT/assets/banner" "$WORK/banner"
  # And the installer script itself: the pinned one injects Arkael's vortex.sh
  # into the ramdisk, which disables thermals and forces the performance
  # governor. Ours installs the kernel and nothing else.
  cp "$ROOT/assets/anykernel.sh" "$WORK/anykernel.sh"
fi
if [ "$IDENTITY" = "own" ] && [ "$TUNING" != "off" ]; then
  case "$TUNING" in
    on)      TUNING_FILE="$ROOT/configs/tuning.fragment" ;;
    nodebug) TUNING_FILE="$ROOT/configs/tuning-nodebug.fragment" ;;
    *)       die "TUNING must be on, off or nodebug, got '$TUNING'" ;;
  esac
  cp "$TUNING_FILE" "$WORK/tuning.fragment"
  say "tuning: $TUNING ($(grep -cE '^(CONFIG_|# CONFIG_)' "$WORK/tuning.fragment") settings from $(basename "$TUNING_FILE"))"
else
  say "tuning: off (no config changes this build)"
fi

# --- edit the pinned build script ------------------------------------------
# Done in python, not sed: every replacement is a plain exact string with a
# count assertion, so a moved line is a one-line error message instead of an
# edit that silently did nothing.
export NAME KUSER KHOST
export KERNEL_REPO KERNEL_BRANCH KERNEL_SHA KERNEL_CLONE_DEPTH KERNEL_SHORT_SHA
export BUILD_SHA BAKASU_SETUP_SHA BAKASU_DRIVER_SHA KSUN_SHA
export INFINIX_CAM_SHA256
export SUSFS_SHA SUSFS_CLONE_DEPTH SUKISU_PATCH_SHA ANYKERNEL_SHA

python3 - "$WORK/build.sh" <<'PY'
import os, sys, pathlib

path = pathlib.Path(sys.argv[1])
# Explicit utf-8: build.sh contains emoji in its log strings, and on a runner
# with a C locale the default encoding can be ascii or something else.
src = path.read_text(encoding="utf-8")
env = os.environ
e = env.__getitem__

def want(key):
    value = env.get(key, "")
    if not value:
        sys.exit("ERROR: %s is empty, check configs/pins.env" % key)
    return value

edits = []

def edit(label, old, new, count=1):
    edits.append((label, old, new, count))

# identity
edit("kernel name",
     'KERNEL_NAME="Arkael"',
     'KERNEL_NAME="%s"' % e("NAME"))
edit("builder user",
     'USER="arqzey"',
     'USER="%s"' % e("KUSER"))
edit("builder host",
     'HOST="Arch-linux"',
     'HOST="%s"' % e("KHOST"))

# kernel at the pinned commit, not at the branch tip
depth = want("KERNEL_CLONE_DEPTH")
sha = want("KERNEL_SHA")
edit("kernel clone",
     "git clone -q --depth=1 $KERNEL_REPO -b $KERNEL_BRANCH $KSRC",
     "\n".join([
         "git clone -q --depth=1 $KERNEL_REPO -b $KERNEL_BRANCH $KSRC",
         "git -C $KSRC fetch -q --depth=%s origin $KERNEL_BRANCH" % depth,
         "git -C $KSRC checkout -q %s" % sha,
         '[ "$(git -C $KSRC rev-parse HEAD)" = "%s" ]' % sha,
     ]))

# the localversion suffix. build.sh asks git for a short hash and lets git
#    choose how short: it derives the length from the repository's object count,
#    so the same commit prints as 7 or 9 hex digits depending on how it was
#    cloned -- and that lands in CONFIG_LOCALVERSION and therefore in vermagic.
#    Both identities want the same 9 digits the working kernel carries, so the
#    value is pinned instead of derived.
edit("localversion suffix",
     "LATEST_COMMIT_HASH=$(git rev-parse --short HEAD)",
     "LATEST_COMMIT_HASH=%s" % want("KERNEL_SHORT_SHA"))

# the camera patch build.sh curls for KVER=5.10. A commit URL is immutable in
#    content, but "immutable" here means GitHub still serves the same bytes, so
#    the download is checked before it is applied.
edit("infinix camera patch",
     'curl -L "https://github.com/ramabondanp/android_kernel_common-5.10/commit/4fe04b60009e.patch" -o infinix_cam.patch',
     "\n".join([
         'curl -L "https://github.com/ramabondanp/android_kernel_common-5.10/commit/4fe04b60009e.patch" -o infinix_cam.patch',
         'echo "%s  infinix_cam.patch" | sha256sum -c -' % want("INFINIX_CAM_SHA256"),
     ]))

# our tuning, appended to the defconfig right before the build turns it into a
# .config, so it gets the last word on every symbol it sets. The file only
# exists for IDENTITY=own (see the copy step earlier): reproducing the phone's
# kernel must not have opinions.
edit("tuning fragment",
     'log "Generating config..."\nmake ${MAKE_ARGS[@]} $KERNEL_DEFCONFIG',
     "\n".join([
         'log "Generating config..."',
         'if [ -f "$WORKDIR/tuning.fragment" ]; then',
         '  log "Applying local tuning fragment..."',
         '  cat "$WORKDIR/tuning.fragment" >> "$KSRC/arch/arm64/configs/gki_defconfig"',
         'fi',
         'make ${MAKE_ARGS[@]} $KERNEL_DEFCONFIG',
     ]))

# the defconfig injection script, fetched from a moving branch by default.
#    Three files: Inject_300hz.sh, gki_defconfig.sh (KVER 5.10) and
#    gki-deconfig-6.1.sh. Only the second one runs at KVER=5.10, but leaving two
#    of the three unpinned would be a pin that only mostly pins.
#    Note the script tests for KSU=="SukiSU" while build.sh passes "sukisu", so
#    the KSU_SUSFS branch runs. That is what Arkael's own build did, so the block
#    we get is the block the phone runs: leave it exactly as it is.
edit("inject_ksu ref",
     "build-arkael/refs/heads/6.x/inject_ksu/",
     "build-arkael/%s/inject_ksu/" % want("BUILD_SHA"),
     count=3)

# ReSukiSU: pin the setup script and the driver commit it checks out.
#    setup.sh takes a commit as $1, so "bash -s -- <sha>" is all it needs.
edit("bakasu setup",
     'curl -LSs "https://raw.githubusercontent.com/Arkael-Dev/BakaSU/refs/heads/main/kernel/setup.sh" | bash',
     'curl -LSs "https://raw.githubusercontent.com/Arkael-Dev/BakaSU/%s/kernel/setup.sh" | bash -s -- %s'
     % (want("BAKASU_SETUP_SHA"), want("BAKASU_DRIVER_SHA")))

# KernelSU-Next: the KSU=yes path, i.e. IDENTITY=own only. install_ksu curls
#    kernel/setup.sh from a branch and then checks that branch out. This does the
#    same fetch at a fixed commit, and then proves it: setup.sh ends with
#    `git checkout "$1" ... || echo "Checkout default branch"`, so a commit that
#    has been rebased away becomes a silent fallback to dev. That is how a build
#    here once shipped a driver nobody pinned.
ksun = want("KSUN_SHA")
edit("ksun setup (own only)",
     "install_ksu 'pershoot/KernelSU-Next' 'dev-susfs'",
     "\n".join([
         'curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/%s/kernel/setup.sh" | bash -s -- %s' % (ksun, ksun),
         'git -C "$KSRC/KernelSU-Next" fetch -q origin "%s" 2>/dev/null || true' % ksun,
         'git -C "$KSRC/KernelSU-Next" checkout -q "%s" 2>/dev/null || true' % ksun,
         'if [ "$(git -C "$KSRC/KernelSU-Next" rev-parse HEAD 2>/dev/null)" != "%s" ]; then' % ksun,
         '  echo "ERROR: KernelSU-Next is not at the pinned commit %s" >&2' % ksun,
         '  echo "ERROR: this repository is force-pushed, so pins go stale." >&2',
         '  echo "ERROR: the build would have used dev, which is not a pin." >&2',
         '  echo "ERROR: pick a reachable commit and update KSUN_SHA in configs/pins.env." >&2',
         '  exit 1',
         'fi',
     ]))

# SUSFS: both clone spellings in the script (quoted for susfs_included,
#    unquoted for the standard path used by KSU=yes).
susfs_sha = want("SUSFS_SHA")
susfs_depth = want("SUSFS_CLONE_DEPTH")
edit("susfs clone (quoted)",
     'git clone --depth=1 -q https://gitlab.com/simonpunk/susfs4ksu -b "$SUSFS_BRANCH" "$SUSFS_DIR"',
     "\n".join([
         'git clone --depth=1 -q https://gitlab.com/simonpunk/susfs4ksu -b "$SUSFS_BRANCH" "$SUSFS_DIR"',
         'git -C "$SUSFS_DIR" fetch -q --depth=%s origin "$SUSFS_BRANCH"' % susfs_depth,
         'git -C "$SUSFS_DIR" checkout -q %s' % susfs_sha,
     ]))
edit("susfs clone (unquoted)",
     "git clone --depth=1 -q https://gitlab.com/simonpunk/susfs4ksu -b $SUSFS_BRANCH $SUSFS_DIR",
     "\n".join([
         "git clone --depth=1 -q https://gitlab.com/simonpunk/susfs4ksu -b $SUSFS_BRANCH $SUSFS_DIR",
         "git -C $SUSFS_DIR fetch -q --depth=%s origin $SUSFS_BRANCH" % susfs_depth,
         "git -C $SUSFS_DIR checkout -q %s" % susfs_sha,
     ]))

# the binary KPM patch applied to the finished Image
edit("kpm patch",
     "SukiSU_patch/raw/refs/heads/main/kpm/patch_linux",
     "SukiSU_patch/raw/%s/kpm/patch_linux" % want("SUKISU_PATCH_SHA"))

# AnyKernel3 packaging
edit("anykernel clone",
     "git clone -q --depth=1 $ANYKERNEL_REPO -b $ANYKERNEL_BRANCH anykernel",
     "\n".join([
         "git clone -q --depth=1 $ANYKERNEL_REPO -b $ANYKERNEL_BRANCH anykernel",
         "git -C anykernel fetch -q --depth=64 origin $ANYKERNEL_BRANCH",
         "git -C anykernel checkout -q %s" % want("ANYKERNEL_SHA"),
         # The install-time banner is text, printed by AK3's update-binary.
         # Only present for `own`; see the copy step earlier in this script.
         '[ -f "$WORKDIR/banner" ] && cp -f "$WORKDIR/banner" anykernel/banner',
         # Same for the install script: ours takes the kernel and leaves the
         # ramdisk alone. See assets/anykernel.sh for what was removed and why.
         '[ -f "$WORKDIR/anykernel.sh" ] && cp -f "$WORKDIR/anykernel.sh" anykernel/anykernel.sh',
     ]))

for label, old, new, count in edits:
    found = src.count(old)
    if found != count:
        sys.exit(
            "ERROR: pinned build.sh no longer matches this wrapper.\n"
            "  edit    : %s\n"
            "  expected: %d occurrence(s)\n"
            "  found   : %d\n"
            "  text    : %s\n"
            "The pin moved, or upstream changed the line. Fix scripts/10-build.sh."
            % (label, count, found, old[:160])
        )
    src = src.replace(old, new)

path.write_text(src, encoding="utf-8")
print("[build] patched %d hunks in the pinned build.sh" % len(edits))
for label, _, _, _ in edits:
    print("        - %s" % label)
PY

# Keep an unmodified copy next to it, so the diff is always reproducible.
git -C "$WORK" show "$BUILD_SHA:build.sh" > "$WORK/build.sh.pinned"

# --- clean per-run state ---------------------------------------------------
# build.sh clones into these paths and skips the download if they exist.
rm -rf "$WORK/ksrc" "$WORK/anykernel" "$WORK/susfs" "$WORK/susfs4ksu" "$WORK/out"

export KVER
export KSU KSU_SUSFS
export TODO="kernel"
# BETA = localversion is just "/<short-sha>", which is what the phone runs.
# RELEASE would make it "/v0.3@<short-sha>" and change the vermagic.
export STATUS="${STATUS:-BETA}"
export LAST_BUILD="false"
export GOVERNOR_CHOICE
# No Telegram: upload_file() returns 1 when these are empty, which trips the
# ERR trap *after* a successful build. We handle that exit code below.
export TG_CHAT_ID="" TG_BOT_TOKEN=""
# We are not on GitHub Actions locally.
export GITHUB_ENV="${GITHUB_ENV:-$WORK/.github_env}"
: > "$GITHUB_ENV"

say "KVER=$KVER KSU=$KSU KSU_SUSFS=$KSU_SUSFS STATUS=$STATUS governor=$GOVERNOR_CHOICE"
say "driver: KernelSU-Next $KSUN_SHA"
say "config reference: configs/$REF_CONFIG   root reference: ${KSU_REF_CONFIG:-none}"

# --- run -------------------------------------------------------------------
cd "$WORK"
set +e
bash build.sh
rc=$?
set -e

IMAGE="$WORK/out/arch/arm64/boot/Image"
ZIPS=$(ls -1 "$WORK"/*.zip 2>/dev/null || true)

if [ $rc -ne 0 ]; then
  if [ -f "$IMAGE" ] && [ -n "$ZIPS" ]; then
    say "build.sh exited $rc but produced an image and a zip"
    say "this is the known Telegram-upload failure at the very end; continuing"
  else
    die "build failed (exit $rc), see $WORK/build.log"
  fi
fi

[ -f "$IMAGE" ] || die "no image at $IMAGE - see $WORK/build.log"
say "image: $IMAGE"
if [ -n "$ZIPS" ]; then
  say "zip:   $ZIPS"
fi

# --- verify ----------------------------------------------------------------
IDENTITY="$IDENTITY" "$ROOT/scripts/20-verify.sh" "$IMAGE"
