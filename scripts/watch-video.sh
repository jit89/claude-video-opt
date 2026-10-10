#!/usr/bin/env bash
#
# watch-video.sh — launcher for watch_vision.py (DeepSeek vision).
#
# Checks today's date first and pins it, so the download and the report land
# together in ~/Documents/claude-video-reports/<yyyy-mm-dd>/<video-id>/
# (a video already in the library is reused from its existing folder).
#
# Usage:
#   ./scripts/watch-video.sh <url-or-path> ["question"] [--cleanup] [--drop-video] [-- extra watch.py flags]
#
# Config (~/.config/watch/.env or the environment):
#   DEEPSEEK_API_KEY            required
#   DEEPSEEK_BASE_URL           default https://api.deepseek.com
#   DEEPSEEK_VISION_MODEL       default deepseek-v4-flash-vision-exp
#   WATCH_LIBRARY_DIR           library root (default ~/Documents/claude-video-reports)
#   WATCH_ANALYSIS_OUT          report path (default: report.md next to the video)
#   WATCH_WINDOW_SECONDS        window size for long videos (default 600)
#   WATCH_VISION_MAX_RETRIES    per-request retries (default 2)
#   WATCH_DROP_VIDEO=1          always delete the video after the report

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$HERE/../.venv/bin/python"

if [[ ! -x "$VENV_PY" ]]; then
  echo "[watch-video] missing project venv; run: $HERE/ensure-venv.sh" >&2
  exit 1
fi

# New downloads go into a folder named for today's date. Pin it once here so
# a run that crosses midnight stays in one folder.
export WATCH_DATE="${WATCH_DATE:-$(date +%Y-%m-%d)}"
# ffmpeg/ffprobe from Homebrew, even when launched from a minimal PATH.
[[ -d /opt/homebrew/bin ]] && export PATH="/opt/homebrew/bin:$PATH"

exec "$VENV_PY" "$HERE/watch_vision.py" "$@"
