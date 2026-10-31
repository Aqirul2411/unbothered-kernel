#!/usr/bin/env bash
# Tell the person, on Telegram, what was built - and hand them the file.
#
# This runs after the build and after verification, because "here is your
# kernel" is only useful if the kernel passed the gates. When the build failed
# it says why instead: a CI that goes quiet is what this step exists to stop.
#
# Credentials: TELEGRAM_BOT_TOKEN (required), TELEGRAM_CHAT_ID (optional).
# They are GitHub Actions secrets, passed in as environment variables. Neither
# belongs in this repository, and nothing here prints the token - not in a log
# line, not in an error message.
#
# If TELEGRAM_CHAT_ID is unset, the chat is taken from the most recent message
# the bot has received, so setting up means: create the bot, send it "hi",
# add the token. The chat it picked is logged, so a surprise is visible.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/configs/pins.env"
# shellcheck source=/dev/null
source "$ROOT/configs/identity.env"

WORK="$ROOT/work"
TOKEN="${TELEGRAM_BOT_TOKEN:-}"
DRY_RUN="${TELEGRAM_DRY_RUN:-}"

say() { echo "[notify] $*"; }

if [ -n "$DRY_RUN" ]; then
  # Prints exactly what would be sent, sends nothing. Used to check the wording
  # without spending a message on it.
  TOKEN="dry-run"
fi

if [ -z "$TOKEN" ]; then
  say "TELEGRAM_BOT_TOKEN is not set, nothing to send"
  exit 0
fi

# --- who to send to --------------------------------------------------------
CHAT="${TELEGRAM_CHAT_ID:-}"
if [ -z "$CHAT" ] && [ -n "$DRY_RUN" ]; then
  CHAT="dry-run-chat"
fi
if [ -z "$CHAT" ]; then
  say "TELEGRAM_CHAT_ID is not set, asking Telegram who last messaged the bot"
  CHAT="$(curl -s --max-time 20 \
      "https://api.telegram.org/bot${TOKEN}/getUpdates?limit=50&allowed_updates=%5B%22message%22%5D" \
    | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not d.get("ok"):
    raise SystemExit(0)
for u in reversed(d.get("result") or []):
    m = u.get("message") or u.get("edited_message") or {}
    c = (m.get("chat") or {}).get("id")
    if c is not None:
        print(c)
        break
')"
fi

if [ -z "$CHAT" ]; then
  say "no chat to send to: send the bot a message once, then set TELEGRAM_CHAT_ID"
  exit 0
fi
say "chat $CHAT"

# --- what actually got built ----------------------------------------------
ZIP="$(ls -1t "$WORK"/*.zip 2>/dev/null | head -n1 || true)"
RELEASE_FILE="$WORK/ksrc/include/config/kernel.release"
RELEASE="$(cat "$RELEASE_FILE" 2>/dev/null || echo "$EXPECTED_LINUX_VERSION-$KERNEL_NAME/${KERNEL_SHA:0:9}")"

zip_line="not produced"
zip_sha=""
if [ -n "$ZIP" ] && [ -f "$ZIP" ]; then
  zip_sha="$(sha256sum "$ZIP" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$ZIP" | cut -d' ' -f1)"
  zip_line="$(basename "$ZIP")  $(stat -c '%s' "$ZIP" 2>/dev/null || stat -f '%z' "$ZIP") bytes"
fi

# The recipe's most recent changes: what we did, as opposed to what the kernel
# does. Three commits is the window a person cares about.
commits="$(git -C "$ROOT" log -3 --format='%h %s' 2>/dev/null || true)"

patches="$(grep -oE 'Applying source patch [^ ]+' "$WORK/build.log" 2>/dev/null \
  | sed 's/Applying source patch //' || true)"

config_changed="$(sed -n '1,28p' "$WORK/verify/config.changed" 2>/dev/null || true)"

# --- send ------------------------------------------------------------------
# Plain text on purpose: Markdown eats the underscores in symbol names, and a
# changelog whose CONFIG_HZ_250 becomes italic is a changelog nobody trusts.
tg_text() {
  if [ -n "$DRY_RUN" ]; then
    printf '\n----- would send -----\n%s\n----------------------\n' "$1" >&2
    echo 200; return 0
  fi
  curl -s --max-time 60 -o /dev/null -w '%{http_code}' \
    -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "disable_web_page_preview=true" \
    --data-urlencode "text=$1" 2>/dev/null
}

tg_doc() {
  if [ -n "$DRY_RUN" ]; then
    printf '\n----- would attach -----\n%s   (caption follows)\n%s\n------------------------\n' "$1" "$2" >&2
    echo 200; return 0
  fi
  curl -s --max-time 300 -o /dev/null -w '%{http_code}' \
    -F "document=@$1" \
    -F "chat_id=${CHAT}" \
    -F "caption=$2" \
    "https://api.telegram.org/bot${TOKEN}/sendDocument" 2>/dev/null
}

if [ -n "$ZIP" ] && [ -f "$ZIP" ] && [ -s "$WORK/verify/config.changed" ]; then
  BODY="Unbothered - build $GITHUB_RUN_NUMBER

kernel   $RELEASE
file     $zip_line
sha256   $zip_sha

recipe (last 3 commits)
$(printf '%s\n' "$commits" | sed 's/^/  /')

source patches
$(if [ -n "$patches" ]; then printf '%s\n' "$patches" | sed 's/^/  /'; else echo "  none"; fi)

config, compared with the kernel on the phone
$(if [ -n "$config_changed" ]; then printf '%s\n' "$config_changed" | sed 's/^/  /'; else echo "  nothing significant"; fi)

verifier: config.significant.diff $(stat -c '%s' "$WORK/verify/config.significant.diff" 2>/dev/null || echo '?') bytes, ksu block $(stat -c '%s' "$WORK/verify/ksu-marble-working.config.diff" 2>/dev/null || echo '?') bytes

Flash it, reboot twice, and watch wake latency and idle drain.
Rollback: Desktop\\Unbothered\\unbothered-hz-only.zip"

  say "sending changelog"
  code="$(tg_text "$BODY")"
  [ "$code" = "200" ] || say "changelog rejected by Telegram (HTTP $code)"

  say "sending $ZIP"
  code="$(tg_doc "$ZIP" "$RELEASE
sha256 ${zip_sha:0:16}...
config.significant.diff"
)"
  [ "$code" = "200" ] || say "document rejected by Telegram (HTTP $code)"
else
  # A failed build still needs to say something, or the next question is
  # "did it even run?".
  why="$(grep -E 'error:|fatal error|^\s*ERROR|Failed at line|FAIL:' "$WORK/build.log" 2>/dev/null \
    | tail -n 8 || true)"
  BODY="Unbothered - build $GITHUB_RUN_NUMBER FAILED

$(if [ -n "$why" ]; then printf '%s\n' "$why"; else echo "no error line found in build.log"; fi)

nothing was sent to the phone; the previous kernel is untouched."
  say "build did not produce a verified zip, sending the failure instead"
  code="$(tg_text "$BODY")"
  [ "$code" = "200" ] || say "failure message rejected by Telegram (HTTP $code)"
fi

# A notification is a courtesy, never a gate: the build already passed or it
# already failed, and a chat outage must not change that answer.
exit 0
