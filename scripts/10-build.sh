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
#   1. kernel name / builder / host        -> identity
#   2. kernel clone                        -> check out KERNEL_SHA, not a branch tip
#   3. localversion suffix                 -> KERNEL_SHORT_SHA, not git's choice
#   4. inject_ksu scripts                  -> pinned to BUILD_SHA, not branch 6.x
#   5. ReSukiSU setup + driver             -> pinned shas, not branch main
#   6. KernelSU-Next setup + driver        -> pinned sha, not branch dev-susfs
#   7. susfs4ksu clone                     -> pinned sha
#   8. KPM Image patch                     -> pinned sha
#   9. AnyKernel3 clone                    -> pinned sha
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
if [ "$IDENTITY" = "repro" ] && [ "$KSU" != "sukisu" ]; then
  die "IDENTITY=repro must use KSU=sukisu (Arkael's ReSukiSU), got KSU=$KSU.
  A different root flavour changes the CONFIG_KSU_* block, so the repro config
  diff against configs/marble-working.config would stop proving anything.
  Use IDENTITY=own for KernelSU-Next."
fi
if [ "$IDENTITY" = "own" ] && [ "$KSU" = "sukisu" ]; then
  die "IDENTITY=own is KernelSU-Next (KSU=yes). ReSukiSU only exists to reproduce
  the phone's current kernel: use IDENTITY=repro for it."
fi

say "identity: $IDENTITY  (kernel name: $NAME, built by $KUSER@$KHOST)"

# --- edit the pinned build script ------------------------------------------
# Done in python, not sed: every replacement is a plain exact string with a
# count assertion, so a moved line is a one-line error message instead of an
# edit that silently did nothing.
export NAME KUSER KHOST
export KERNEL_REPO KERNEL_BRANCH KERNEL_SHA KERNEL_CLONE_DEPTH KERNEL_SHORT_SHA
export BUILD_SHA BAKASU_SETUP_SHA BAKASU_DRIVER_SHA KSUN_SHA
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

# 1. identity
edit("kernel name",
     'KERNEL_NAME="Arkael"',
     'KERNEL_NAME="%s"' % e("NAME"))
edit("builder user",
     'USER="arqzey"',
     'USER="%s"' % e("KUSER"))
edit("builder host",
     'HOST="Arch-linux"',
     'HOST="%s"' % e("KHOST"))

# 2. kernel at the pinned commit, not at the branch tip
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

# 3. the localversion suffix. build.sh asks git for a short hash and lets git
#    choose how short: it derives the length from the repository's object count,
#    so the same commit prints as 7 or 9 hex digits depending on how it was
#    cloned -- and that lands in CONFIG_LOCALVERSION and therefore in vermagic.
#    Both identities want the same 9 digits the working kernel carries, so the
#    value is pinned instead of derived.
edit("localversion suffix",
     "LATEST_COMMIT_HASH=$(git rev-parse --short HEAD)",
     "LATEST_COMMIT_HASH=%s" % want("KERNEL_SHORT_SHA"))

# 4. the defconfig injection script, fetched from a moving branch by default.
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

# 5. ReSukiSU: pin the setup script and the driver commit it checks out.
#    setup.sh takes a commit as $1, so "bash -s -- <sha>" is all it needs.
edit("bakasu setup",
     'curl -LSs "https://raw.githubusercontent.com/Arkael-Dev/BakaSU/refs/heads/main/kernel/setup.sh" | bash',
     'curl -LSs "https://raw.githubusercontent.com/Arkael-Dev/BakaSU/%s/kernel/setup.sh" | bash -s -- %s'
     % (want("BAKASU_SETUP_SHA"), want("BAKASU_DRIVER_SHA")))

# 6. KernelSU-Next: the KSU=yes path, i.e. IDENTITY=own only. install_ksu curls
#    kernel/setup.sh from a branch and then checks that branch out; this does the
#    same fetch at a fixed commit, so the root driver cannot change under us.
edit("ksun setup (own only)",
     "install_ksu 'pershoot/KernelSU-Next' 'dev-susfs'",
     'curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/%s/kernel/setup.sh" | bash -s -- %s'
     % (want("KSUN_SHA"), want("KSUN_SHA")))

# 7. SUSFS: both clone spellings in the script (quoted for susfs_included,
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

# 8. the binary KPM patch applied to the finished Image
edit("kpm patch",
     "SukiSU_patch/raw/refs/heads/main/kpm/patch_linux",
     "SukiSU_patch/raw/%s/kpm/patch_linux" % want("SUKISU_PATCH_SHA"))

# 9. AnyKernel3 packaging
edit("anykernel clone",
     "git clone -q --depth=1 $ANYKERNEL_REPO -b $ANYKERNEL_BRANCH anykernel",
     "\n".join([
         "git clone -q --depth=1 $ANYKERNEL_REPO -b $ANYKERNEL_BRANCH anykernel",
         "git -C anykernel fetch -q --depth=64 origin $ANYKERNEL_BRANCH",
         "git -C anykernel checkout -q %s" % want("ANYKERNEL_SHA"),
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
