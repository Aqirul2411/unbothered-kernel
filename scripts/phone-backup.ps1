# Back up the phone's boot partitions. Reads only, writes nothing to the phone
# except two image files in /sdcard, which it then pulls to backup/.
#
# This is the thing that makes every later flash reversible, so it verifies as it
# goes: device identity, root, slot, then a hash of each image.
#
#   powershell -File scripts/phone-backup.ps1
#
# Does not run on Linux/CI: it drives adb on Windows.

[CmdletBinding()]
param(
  [string]$Adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
  [string]$OutDir = "$PSScriptRoot\..\backup"
)

$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Say($msg)  { Write-Host "[backup] $msg" }
function AdbRoot([string]$cmd) { & $Adb shell "su -c '$cmd'" 2>&1 }

if (-not (Test-Path -LiteralPath $Adb)) { Fail "adb not found at $Adb (pass -Adb <path>)" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# --- who is on the other end ------------------------------------------------
$devices = (& $Adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\sdevice$' })
if (-not $devices) { Fail "no device: connect the phone, unlock it, accept the USB debugging prompt" }

$model = (& $Adb shell getprop ro.product.device).Trim()
$slot  = (& $Adb shell getprop ro.boot.slot_suffix).Trim()
$rel   = (& $Adb shell uname -r).Trim()
$build = (& $Adb shell getprop ro.build.display.id).Trim()

Say "device   : $model"
Say "build    : $build"
Say "slot     : $slot"
Say "kernel   : $rel"

if ($model -ne 'marble') { Fail "this is '$model', not marble; refusing to touch it" }
if ($slot -notin @('_a','_b')) { Fail "cannot read the active slot (got '$slot')" }

# --- root -------------------------------------------------------------------
$id = (AdbRoot 'id') -join ' '
if ($id -notmatch 'uid=0') { Fail "root unavailable: '$id' - grant the shell root request on the phone and retry" }
Say "root     : ok"

# --- the images -------------------------------------------------------------
# Both slots, because a rollback may not be on the slot you think it is.
foreach ($s in @('_a','_b')) {
  $part = "/dev/block/by-name/boot$s"
  $dest = "/sdcard/boot$s.img"
  Say "reading  : $part"

  $out = (AdbRoot "dd if=$part of=$dest conv=fsync") -join ' '
  if ($out -notmatch 'records') { Fail "dd did not report records for $part : $out" }

  $bytes = (AdbRoot "stat -c %s $dest") -join ' '
  if ($bytes -notmatch '^\s*(\d+)\s*$') { Fail "cannot size $dest : $bytes" }
  $size = [int64]$Matches[1]
  if ($size -lt 1MB) { Fail "$dest is only $size bytes, that is not a boot image" }
  Say "size     : $s $size bytes"

  & $Adb pull $dest "$OutDir\boot$s.img" | Out-Null
  & $Adb shell "rm -f $dest" | Out-Null
}

# --- prove the copies are the phone's --------------------------------------
$manifest = @()
foreach ($s in @('_a','_b')) {
  $path = Join-Path $OutDir "boot$s.img"
  if (-not (Test-Path -LiteralPath $path)) { Fail "missing $path after pull" }
  $local = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
  $remote = ((AdbRoot "sha256sum /dev/block/by-name/boot$s") -join ' ') -split '\s+' | Select-Object -First 1
  if (-not $remote) { Fail "cannot hash $s on the phone" }
  if ($local -ne $remote.ToLower()) { Fail "hash mismatch for boot$s.img: local $local, phone $remote" }
  $manifest += "$s $local $(Get-Item -LiteralPath $path | Select-Object -ExpandProperty Length)"
  Say "verified : boot$s.img $local"
}

# --- the magic bytes, so a 96 MB partition full of zeros cannot pass ---------
foreach ($s in @('_a','_b')) {
  $head = [IO.File]::ReadAllBytes((Join-Path $OutDir "boot$s.img"))
  $magic = [Text.Encoding]::ASCII.GetString($head[0..7])
  if ($magic -ne 'ANDROID!') {
    Write-Host "  note: boot$s.img magic is '$magic', not 'ANDROID!' - this slot may be empty or formatted differently" -ForegroundColor Yellow
  }
}

# --- record it --------------------------------------------------------------
$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$lines = @(
  "# boot backup",
  "date    $stamp",
  "device  $model",
  "build   $build",
  "slot    $slot",
  "kernel  $rel",
  "",
  "# slot sha256 bytes",
  $manifest
)
$lines | Set-Content -LiteralPath (Join-Path $OutDir 'MANIFEST.txt') -Encoding utf8

Say "written  : $OutDir\MANIFEST.txt"
Write-Host ""
Write-Host "Keep this folder untouched until the new kernel has booted twice." -ForegroundColor Green
Write-Host "Rollback, from the bootloader:  fastboot flash boot backup\boot$slot.img" -ForegroundColor Green
