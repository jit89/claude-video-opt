#!/usr/bin/env bash
# SessionStart hook for /watch — one-line status so users know what's wired up.
# Silent on ready state to avoid spam. Points at the installer when something
# is missing.
set -euo pipefail

CONFIG_FILE="$HOME/.config/watch/.env"

# Warn if the secrets file has loose permissions.
if [[ -f "$CONFIG_FILE" ]]; then
  perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || echo "")
  if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
    echo "/watch: WARNING — $CONFIG_FILE has permissions $perms (should be 600)."
    echo "  Fix: chmod 600 $CONFIG_FILE"
  fi
fi

# Load API keys from the config file without exporting them.
read_key() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    echo "${!name}"
    return
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    awk -F= -v k="$name" '
      /^[[:space:]]*#/ { next }
      $1 == k {
        sub(/^[[:space:]]*/, "", $2); sub(/[[:space:]]*$/, "", $2);
        gsub(/^["'\'']|["'\'']$/, "", $2);
        print $2; exit
      }
    ' "$CONFIG_FILE"
  fi
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

HAS_FFMPEG=""
HAS_YTDLP=""
{ command -v ffmpeg || ls /opt/homebrew/bin/ffmpeg; } >/dev/null 2>&1 && HAS_FFMPEG="yes"
# yt-dlp lives in the project venv (with curl_cffi), never on the system PATH.
[[ -x "$ROOT/.venv/bin/yt-dlp" ]] && HAS_YTDLP="yes"

HAS_DEEPSEEK="$(read_key DEEPSEEK_API_KEY)"

# Ready → silent. Whisper keys are optional (captions cover most videos), so
# their absence is not worth a message every session.
if [[ -n "$HAS_FFMPEG" && -n "$HAS_YTDLP" && -n "$HAS_DEEPSEEK" ]]; then
  exit 0
fi

if [[ -z "$HAS_FFMPEG" ]]; then
  echo "/watch: needs ffmpeg. Install with: brew install ffmpeg"
fi
if [[ -z "$HAS_YTDLP" ]]; then
  echo "/watch: needs the project venv (yt-dlp). Run: \"$ROOT/scripts/ensure-venv.sh\" (uses uv; never touches system Python)"
fi
if [[ -z "$HAS_DEEPSEEK" ]]; then
  echo "/watch: /watch-video needs DEEPSEEK_API_KEY in $CONFIG_FILE (https://platform.deepseek.com/api_keys)."
fi
