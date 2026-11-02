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

# 30-notify.sh names the compiled commit from `git log -1` in work/ksrc, and a
# local notify has no source tree, so it falls back to "kernel subject
# unavailable - see the zip hash". That fallback exists because a changelog once
# described the opposite of what the phone would run, so it must never be
# guessed - but it can be looked up. Ask the kernel repository for the subject of
# the commit pinned in configs/pins.env and hand it over as the one line the
# script reads. If the lookup fails, the honest fallback still applies.
try {
  $pins = Join-Path $root "configs/pins.env"
  $sha  = (Select-String -LiteralPath $pins -Pattern '^KERNEL_SHA="([0-9a-f]{40})"' |
             Select-Object -First 1).Matches[0].Groups[1].Value
  $krepo = (Select-String -LiteralPath $pins -Pattern '^KERNEL_REPO=".*/([^/"]+)\.git"' |
             Select-Object -First 1).Matches[0].Groups[1].Value

  $commit = & gh api "repos/Aqirul2411/$krepo/commits/$sha" | ConvertFrom-Json
  $subject = ($commit.commit.message -split "`n")[0]
  if ($subject) {
    # A throwaway repo carrying that one subject, so `git log -1 --format=%s`
    # returns exactly what the kernel build compiled. The message goes through a
    # file: PowerShell rewrites "->" inside a native argument into a
    # redirection, and a subject with an arrow silently became a git error.
    $ksrc    = Join-Path $work "ksrc"
    $gitExe  = "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"
    $msgFile = Join-Path $work "kernel-subject.txt"
    [IO.File]::WriteAllText($msgFile, $subject)
    New-Item -ItemType Directory -Force -Path $ksrc | Out-Null
    & $gitExe -C $ksrc init -q | Out-Null
    & $gitExe -C $ksrc -c user.email=notify@local -c user.name=notify commit -q --allow-empty -F $msgFile | Out-Null
    Write-Host "[notify] kernel subject: $subject"
  }
} catch {
  Write-Host "[notify] kernel subject lookup failed, the zip hash stands in: $_"
}

$bash = "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
$env:TELEGRAM_BOT_TOKEN = $token
$env:TELEGRAM_CHAT_ID   = $ChatId
$env:GITHUB_RUN_NUMBER  = $Run
if ($DryRun) { $env:TELEGRAM_DRY_RUN = "1" }

Push-Location $root
try { & $bash "./scripts/30-notify.sh" } finally { Pop-Location }

Remove-Item Env:\TELEGRAM_BOT_TOKEN -ErrorAction SilentlyContinue
