#!/usr/bin/env bash
# Rewrite the finished zip with a writer that is known to flash.
#
# Why this exists: the recovery on this phone rejected two Info-ZIP archives
# with "Zip file is corrupt!" while accepting a repack of the very same Image
# written by Python's zipfile. Every archive check available here (EOCD, central
# directory, all local headers, CRC, entry order, control-file hashes) said the
# two archives were equivalent - so this is not a repair, it is removing a
# variable.
#
# The evidence is ambiguous and worth stating: the rejected files may simply have
# arrived truncated over the transfer, and the repack may have arrived intact.
# What is not ambiguous is that the repacked archive flashed and the Info-ZIP
# ones did not, so the artifact we ship is now always written by the writer that
# demonstrably works here.
#
# Side benefit: fixed timestamps make the archive deterministic, so the same
# Image produces the same zip hash on every build. Timestamps in a zip are
# metadata nobody reads; a reproducible hash is something that can be compared.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/work"
say() { echo "[repack] $*"; }

shopt -s nullglob
zips=("$WORK"/*.zip)
[ ${#zips[@]} -gt 0 ] || { say "no zip to repack"; exit 0; }

# Ubuntu runners have python3; a Windows checkout may only have the store alias
# or a differently named binary. Say so plainly instead of failing later.
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { say "no python3 on PATH, cannot repack"; exit 1; }

for z in "${zips[@]}"; do
  say "repacking $(basename "$z")"
  "$PY" - "$z" <<'PY'
import os
import sys
import zipfile

src = sys.argv[1]
tmp = src + ".repack"

with zipfile.ZipFile(src) as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
    for info in zin.infolist():
        data = zin.read(info.filename)
        new = zipfile.ZipInfo(info.filename, date_time=(2026, 1, 1, 0, 0, 0))
        new.compress_type = info.compress_type
        new.external_attr = info.external_attr   # keeps the Unix mode bits
        new.create_system = 3                    # Unix, as the original
        new.internal_attr = info.internal_attr
        zout.writestr(new, data)

with zipfile.ZipFile(tmp) as check:
    bad = check.testzip()
    if bad is not None:
        sys.exit("repack produced a bad entry: %s" % bad)
    if len(check.infolist()) != len(zipfile.ZipFile(src).infolist()):
        sys.exit("repack changed the entry count")

os.replace(tmp, src)
print("  %s -> %d bytes" % (os.path.basename(src), os.path.getsize(src)))
PY
done

say "done"
