# Send a finished CI build to Telegram from this machine.
#
# Why this exists: the CI step that would do it automatically needs a token with
# the `workflow` scope to change .github/workflows/build.yml, and ours has only
# `repo`. Until that is granted, the same message is sent from here - same
# script, same wording, same gate on the verifier's output.
#
#   .\scripts\notify-local.ps1 -Run 41192578628
#
# The bot token is read from a file outside the tree (%LOCALAPPDATA%\Temp\opencode\
# tg.token by default). It is never written into this repository, and this script
# does not print it.

param(
  [Parameter(Mandatory = $true)][string]$Run,
  [string]$TokenFile = "C:\Users\adzemia\AppData\Local\Temp\opencode\tg.token",
  [string]$ChatId = "80113038",
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp  = Join-Path $env:TEMP "opencode\notify-$Run"

if (-not (Test-Path $TokenFile)) { throw "no token at $TokenFile" }
$token = (Get-Content $TokenFile -Raw).Trim()

# Fresh download every time: a cached artifact from the previous run is exactly
# the mistake this is meant to avoid.
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& gh -R Aqirul2411/unbothered-kernel run download $Run -D $tmp 2>&1 | Out-String
$art = Get-ChildItem $tmp -Directory | Select-Object -First 1
if (-not $art) { throw "run $Run produced no artifact" }

# 30-notify.sh reads work/, so hand it the downloaded tree as if it had just
# been built here. verify/ is what tells it whether to announce or explain.
$work = Join-Path $root "work"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work | Out-Null
Copy-Item "$($art.FullName)\*" $work -Recurse -Force

$bash = "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
$env:TELEGRAM_BOT_TOKEN = $token
$env:TELEGRAM_CHAT_ID   = $ChatId
$env:GITHUB_RUN_NUMBER  = $Run
if ($DryRun) { $env:TELEGRAM_DRY_RUN = "1" }

Push-Location $root
try { & $bash "./scripts/30-notify.sh" } finally { Pop-Location }

Remove-Item Env:\TELEGRAM_BOT_TOKEN -ErrorAction SilentlyContinue
