#!/usr/bin/env bash
# Put the pinned inputs on disk. Builds nothing.
#
# Result:
#   src/build-arkael  the build system at BUILD_SHA, which also carries
#                     functions.sh, kernel-patches/ and inject_ksu/
#
# The kernel itself is not fetched here: scripts/10-build.sh makes the build
# check out KERNEL_SHA, and a shallow clone plus a checkout is cheaper than
# keeping a local mirror of a 3.5 GB tree around.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/configs/pins.env"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "[fetch] $*"; }

command -v git >/dev/null || die "git not found"
mkdir -p "$ROOT/src"

# --- build system ----------------------------------------------------------
# Arkael-Dev/build-arkael was deleted on 2026-10-31. The pinned commit is
# vendored in vendor/ as a git bundle, so the build no longer depends on a
# third-party repository staying online. The network clone stays as a fallback
# for the case where the bundle is missing.
#
# The bundle is found by asking git, not by guessing a filename from the sha:
# an earlier version of this script derived 7 characters from the pin while the
# file was named with 8, and the build fell through to the dead URL.
BUNDLE=""
for b in "$ROOT"/vendor/build-arkael-*.bundle; do
  [ -f "$b" ] || continue
  if git bundle list-heads "$b" 2>/dev/null | grep -q "^$BUILD_SHA"; then
    BUNDLE="$b"
    break
  fi
done

if [ ! -d "$ROOT/src/build-arkael/.git" ]; then
  if [ -n "$BUNDLE" ]; then
    say "using the vendored build system ($(basename "$BUNDLE"))"
    git clone -q "$BUNDLE" "$ROOT/src/build-arkael"
  else
    say "no vendored bundle contains $BUILD_SHA, trying $BUILD_REPO"
    git clone -q "$BUILD_REPO" "$ROOT/src/build-arkael" \
      || die "cannot obtain the build system: upstream is gone and no bundle has the pin"
  fi
fi
# A full clone on purpose: it is under 2 MB, and it means the pin can be any
# commit on any branch, not just a branch tip. A bundle clone has nothing to
# fetch from, hence the || true.
git -C "$ROOT/src/build-arkael" fetch -q --all --tags || true
git -C "$ROOT/src/build-arkael" -c advice.detachedHead=false checkout -q "$BUILD_SHA"

BHEAD="$(git -C "$ROOT/src/build-arkael" rev-parse HEAD)"
[ "$BHEAD" = "$BUILD_SHA" ] || die "build pin drift: have $BHEAD want $BUILD_SHA"

say "build-arkael  $(git -C "$ROOT/src/build-arkael" log -1 --format='%h %s')"

# --- kernel pin ------------------------------------------------------------
# We cannot prove an arbitrary sha is on a branch without fetching the branch,
# and the build does that anyway. What we can do is print the tip, so the log
# says how far the branch has moved past the pin.
TIP="$(git ls-remote --heads "$KERNEL_REPO" "refs/heads/$KERNEL_BRANCH" | cut -f1)"
[ -n "$TIP" ] || die "cannot reach $KERNEL_REPO (refs/heads/$KERNEL_BRANCH)"
say "kernel        $KERNEL_BRANCH tip is ${TIP:0:9}, pinning ${KERNEL_SHA:0:9}"

if [ "$TIP" = "$KERNEL_SHA" ]; then
  say "kernel        pin is the branch tip"
else
  say "kernel        pin is behind the tip: the build clones ${KERNEL_CLONE_DEPTH} commits and checks out the pin"
fi

say "ok"
