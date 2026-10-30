#!/usr/bin/env bash
# Verify a built Image against the kernels that are known to boot on the phone.
#
# This runs BEFORE anything is flashed. It answers one question:
#   "is this the same kernel, apart from the things we intentionally changed?"
#
# Checks:
#   1. the embedded .config (IKCONFIG) diffs clean against
#      configs/marble-working.config, except for lines listed in
#      configs/verify-allow.txt (only honoured for IDENTITY=own)
#   2. vermagic matches the expectation for this identity
#   3. the root/susfs/LTO/CFI options we asked for are actually on
#   4. the CONFIG_KSU block matches a reference that is known to boot
#
# Exit 0 = comparable, go ahead. Exit 1 = do not flash.
#
# Two references, both extracted from Images that boot on marble:
#   marble-working.config   Arkael  5.10.272  ReSukiSU     + SUSFS  thin LTO
#   templar-working.config  Templar 5.10.271  KernelSU-Next + SUSFS  full LTO

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/configs/pins.env"
# shellcheck source=/dev/null
source "$ROOT/configs/identity.env"

IMAGE="${1:-$ROOT/work/out/arch/arm64/boot/Image}"
REF="$ROOT/configs/$REF_CONFIG"
ALLOW="$ROOT/configs/verify-allow.txt"
OUT="${OUT:-$ROOT/work/verify}"

die() { echo "FAIL: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
say() { echo "[verify] $*"; }

[ -f "$IMAGE" ] || die "no image at $IMAGE"
[ -f "$REF" ]   || die "no reference config at $REF"
mkdir -p "$OUT"

say "identity $IDENTITY   ksu $KSU   reference $(basename "$REF")"
say "image  $IMAGE"
say "$(stat -c '%s bytes' "$IMAGE" 2>/dev/null || stat -f '%z bytes' "$IMAGE")"
say "sha256 $( (sha256sum "$IMAGE" 2>/dev/null || shasum -a 256 "$IMAGE") | cut -d' ' -f1)"

# --- 1. embedded config ----------------------------------------------------
say "extracting embedded config"
python3 - "$IMAGE" "$OUT/built.config" <<'PY'
import gzip, io, sys

img, dst = sys.argv[1], sys.argv[2]
blob = open(img, "rb").read()
start = blob.find(b"IKCFG_ST")
end = blob.find(b"IKCFG_ED")
if start < 0 or end < 0 or end < start:
    sys.exit("no IKCONFIG in this image (CONFIG_IKCONFIG off?)")
data = gzip.GzipFile(fileobj=io.BytesIO(blob[start + 8:end])).read()
open(dst, "wb").write(data)
print("  %d bytes, %d lines -> %s" % (len(data), data.count(b"\n"), dst))
PY

diff -u "$REF" "$OUT/built.config" > "$OUT/config.diff" || true

# Only config statements matter; the diff also carries context and hunk headers.
grep -E '^[-+](CONFIG_|# CONFIG_)' "$OUT/config.diff" > "$OUT/config.changed" || true

# The allowlist is a deliberate exception for `own`, and never for `repro`.
ALLOW_RE='^$'
ALLOWED_COUNT=0
if [ "$IDENTITY" = "own" ] && [ -f "$ALLOW" ]; then
  ALLOW_RE="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOW" | paste -sd'|' - || true)"
  [ -n "$ALLOW_RE" ] || ALLOW_RE='^$'
fi

awk -v re="$ALLOW_RE" '
  { body = substr($0, 2) }
  body ~ re { print > allowed;  next }
            { print > significant }
' allowed="$OUT/config.allowed.diff" significant="$OUT/config.significant.diff" \
  "$OUT/config.changed"

: >> "$OUT/config.allowed.diff"
: >> "$OUT/config.significant.diff"
ALLOWED_COUNT=$(grep -cE '^[-+](# )?CONFIG_' "$OUT/config.allowed.diff" || true)

if [ "$ALLOWED_COUNT" -gt 0 ]; then
  say "accepted differences ($ALLOWED_COUNT lines, see $OUT/config.allowed.diff):"
  sed -n '1,40p' "$OUT/config.allowed.diff" | sed 's/^/    /'
fi

if [ -s "$OUT/config.significant.diff" ]; then
  echo
  echo "Config differs from $(basename "$REF") in a way we did not ask for:"
  echo "  (full diff:   $OUT/config.diff)"
  echo "  (accepted:    $OUT/config.allowed.diff)"
  echo
  sed -n '1,60p' "$OUT/config.significant.diff"
  echo
  if grep -qE '^[-+](# )?CONFIG_(KSU|KPM)' "$OUT/config.significant.diff"; then
    warn "the differences above are in the root stack."
    warn "that block is produced by the pins in configs/pins.env: BAKASU_SETUP_SHA,"
    warn "BAKASU_DRIVER_SHA, SUSFS_SHA. A wrong pin looks exactly like this."
  fi
  die "$(grep -cE '^[-+](# )?CONFIG_' "$OUT/config.significant.diff") unexpected config differences"
fi
say "config: clean"

# --- 2. vermagic -----------------------------------------------------------
BUILT_VERMAGIC=$(strings -n 10 "$IMAGE" | grep -m1 ' SMP preempt mod_unload .* aarch64$' || true)
[ -n "$BUILT_VERMAGIC" ] || die "cannot find a vermagic string in the image"
say "vermagic: $BUILT_VERMAGIC"

case "$IDENTITY" in
  repro)
    [ "$BUILT_VERMAGIC" = "$EXPECTED_VERMAGIC" ] \
      || die "vermagic mismatch, this is NOT a reproduction of the working kernel"
    say "vermagic matches the phone's kernel exactly"
    ;;
  own)
    case "$BUILT_VERMAGIC" in
      "$EXPECTED_LINUX_VERSION-$KERNEL_NAME/"*" SMP preempt mod_unload"*)
        say "vermagic carries our own name, as intended" ;;
      *)
        die "vermagic is not '$EXPECTED_LINUX_VERSION-$KERNEL_NAME/<hash> ...'" ;;
    esac
    ;;
esac

# --- 3. the options we actually asked for ---------------------------------
for opt in CONFIG_LTO_CLANG_THIN=y CONFIG_CFI_CLANG=y; do
  grep -qx "$opt" "$OUT/built.config" || die "expected $opt in the built config"
done
if [ "$KSU" = "no" ]; then
  grep -qx '# CONFIG_KSU is not set' "$OUT/built.config" \
    || die "KSU=no, but CONFIG_KSU is enabled in the built config"
  say "lto/cfi: present, root: none (as asked)"
else
  for opt in CONFIG_KSU=y CONFIG_KSU_SUSFS=y; do
    grep -qx "$opt" "$OUT/built.config" || die "expected $opt in the built config"
  done
  say "root/susfs/lto/cfi: present"
fi

# --- 4. is our root block one we know boots? ------------------------------
# Arkael ships ReSukiSU, Templar ships KernelSU-Next. Both boot on this phone,
# so a KSU symbol set that matches neither is a symbol set nobody has booted.
same_ksu_block() {
  local a="$1" b="$2"
  diff -q <(grep -E '^CONFIG_(KSU|KPM)' "$a" | sort) \
          <(grep -E '^CONFIG_(KSU|KPM)' "$b" | sort) >/dev/null
}

case "$IDENTITY:$KSU" in
  repro:*)
    same_ksu_block "$OUT/built.config" "$REF" \
      || die "CONFIG_KSU block differs from $(basename "$REF"); repro must match Arkael exactly"
    say "root block matches Arkael (ReSukiSU) exactly"
    ;;
  own:yes)
    KREF="$ROOT/configs/$KSU_REF_CONFIG"
    if [ -f "$KREF" ]; then
      diff -u <(grep -E '^CONFIG_(KSU|KPM)' "$KREF" | sort) \
              <(grep -E '^CONFIG_(KSU|KPM)' "$OUT/built.config" | sort) \
        > "$OUT/ksu.diff" || true
      if [ -s "$OUT/ksu.diff" ]; then
        warn "root block is not identical to $(basename "$KREF") (KernelSU-Next, boots):"
        sed -n '1,40p' "$OUT/ksu.diff" | sed 's/^/    /'
        warn "not fatal: KernelSU-Next moves too, and our tree is Arkael's."
        warn "read $OUT/ksu.diff before flashing; a missing CONFIG_KSU_SUSFS is a red flag."
      else
        say "root block matches Templar (KernelSU-Next), the other kernel that boots here"
      fi
    fi
    ;;
esac

# --- summary ---------------------------------------------------------------
echo
echo "PASS - comparable to configs/$(basename "$REF")"
echo "  config diff : $OUT/config.diff"
echo "  accepted    : $OUT/config.allowed.diff"
echo "  vermagic    : $BUILT_VERMAGIC"
echo "  identity    : $IDENTITY   ksu: $KSU"
