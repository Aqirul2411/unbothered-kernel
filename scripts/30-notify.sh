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
# unbothered.zip is the predictable name CI makes; the versioned one is what the
# build itself calls it. Prefer the predictable name when both are present.
ZIP=""
for cand in "$WORK/unbothered.zip" "$(ls -1t "$WORK"/*.zip 2>/dev/null | head -n1 || true)"; do
  if [ -n "$cand" ] && [ -f "$cand" ]; then ZIP="$cand"; break; fi
done
RELEASE_FILE="$WORK/ksrc/include/config/kernel.release"
RELEASE="$(cat "$RELEASE_FILE" 2>/dev/null || echo "$EXPECTED_LINUX_VERSION-$KERNEL_NAME/${KERNEL_SHA:0:9}")"

zip_line="not produced"
zip_sha=""
if [ -n "$ZIP" ] && [ -f "$ZIP" ]; then
  zip_sha="$(sha256sum "$ZIP" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$ZIP" | cut -d' ' -f1)"
  zip_line="$(basename "$ZIP")  $(stat -c '%s' "$ZIP" 2>/dev/null || stat -f '%z' "$ZIP") bytes"
fi

# The recipe's most recent changes: what we did, as opposed to what the kernel
# does. Filtered to the paths that actually reach the build - a commit that only
# edits docs or this script is not a changelog entry for a kernel.
commits="$(git -C "$ROOT" log -3 --format='%s' -- \
  configs/tuning.fragment configs/pins.env configs/identity.env \
  patches assets scripts/10-build.sh 2>/dev/null || true)"

patches="$(grep -oE 'Applying source patch [^ ]+' "$WORK/build.log" 2>/dev/null \
  | sed 's/Applying source patch //' || true)"

config_changed="$(sed -n '1,28p' "$WORK/verify/config.changed" 2>/dev/null || true)"

# --- send ------------------------------------------------------------------
# Plain text on purpose: Markdown eats the underscores in symbol names, and a
# changelog whose CONFIG_HZ_250 becomes italic is a changelog nobody trusts.
#
# ASCII on purpose as well. A middle dot and an ellipsis in these strings made
# Telegram answer "Bad Request: strings must be encoded in UTF-8" - the
# multi-byte characters do not survive the trip from Git Bash through curl on
# Windows. So the payload is transliterated or stripped, and anything found is
# reported rather than silently dropped: a message that quietly loses its
# characters is worse than one that refuses to send.
ascii_safe() {
  local in="$1" out
  out="$(printf '%s' "$in" | sed 's/\xe2\x80\xa6/.../g; s/\xc2\xb7/|/g; s/\xe2\x80\x94/-/g; s/\xe2\x80\x93/-/g')"
  out="$(printf '%s' "$out" | LC_ALL=C tr -d '\200-\377')"
  if [ "$out" != "$in" ]; then
    say "note: non-ASCII characters were converted or removed for Telegram"
  fi
  printf '%s' "$out"
}

tg_text() {
  if [ -n "$DRY_RUN" ]; then
    printf '\n----- would send -----\n%s\n----------------------\n' "$1" >&2
    echo 200; return 0
  fi
  curl -s --max-time 60 -o /dev/null -w '%{http_code}' \
    -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "disable_web_page_preview=true" \
    --data-urlencode "text=$(ascii_safe "$1")" 2>/dev/null
}

tg_doc() {
  if [ -n "$DRY_RUN" ]; then
    printf '\n----- would attach -----\n%s   (caption follows)\n%s\n------------------------\n' "$1" "$2" >&2
    echo 200; return 0
  fi
  curl -s --max-time 300 -o /dev/null -w '%{http_code}' \
    -F "document=@$1" \
    -F "chat_id=${CHAT}" \
    -F "caption=$(ascii_safe "$2")" \
    "https://api.telegram.org/bot${TOKEN}/sendDocument" 2>/dev/null
}

if [ -n "$ZIP" ] && [ -f "$ZIP" ] && [ -s "$WORK/verify/config.changed" ]; then
  sig="$(stat -c '%s' "$WORK/verify/config.significant.diff" 2>/dev/null || echo '?')"
  n="$(grep -cE '^[-+](CONFIG_|# CONFIG_)' "$WORK/verify/config.changed" 2>/dev/null || echo '?')"
  BODY="Unbothered $GITHUB_RUN_NUMBER | $RELEASE

what changed
$(printf '%s\n' "$commits" | sed 's/^/  | /')

config vs the phone: $n lines, significant diff ${sig} bytes
file   $(basename "$ZIP")  $(( $(stat -c '%s' "$ZIP") / 1000000 )) MB
sha256 $zip_sha

flash, reboot twice, watch wake latency and idle drain.
rollback: Desktop\\Unbothered\\unbothered-hz-only.zip"

  say "sending changelog"
  code="$(tg_text "$BODY")"
  [ "$code" = "200" ] || say "changelog rejected by Telegram (HTTP $code)"

  say "sending $ZIP"
  code="$(tg_doc "$ZIP" "$RELEASE | sha256 ${zip_sha:0:16}... | config diff ${sig} bytes
flash from recovery, keep the previous zip until it boots twice")"
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
