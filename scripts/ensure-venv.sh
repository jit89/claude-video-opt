#!/usr/bin/env bash
# Create <repo>/.venv with uv and install yt-dlp + curl_cffi into it.
# The venv runs on a uv-managed Python (kept under ~/.local/share/uv/python,
# not on PATH). Never touches /usr/bin/python3, Homebrew Python, or which
# `python3` your shell resolves to.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/.venv"
REQ="$ROOT/requirements.txt"
PY_VERSION="${WATCH_VENV_PYTHON:-3.12}"

UV="$(command -v uv || true)"
[[ -z "$UV" && -x /opt/homebrew/bin/uv ]] && UV=/opt/homebrew/bin/uv
if [[ -z "$UV" ]]; then
  echo "need uv to create the venv (refusing to use system Python)." >&2
  echo "Install with: brew install uv" >&2
  exit 1
fi

echo "[venv] uv=${UV} python=${PY_VERSION} (uv-managed)" >&2
echo "[venv] target=${VENV}" >&2

if [[ ! -x "$VENV/bin/python" ]]; then
  "$UV" venv --managed-python --python "$PY_VERSION" "$VENV"
fi

"$UV" pip install --python "$VENV/bin/python" -r "$REQ"

echo "[venv] python=$("$VENV/bin/python" -c 'import sys; print(sys.executable, sys.version.split()[0])')" >&2
"$VENV/bin/python" -c "import curl_cffi; print('[venv] curl_cffi', getattr(curl_cffi, '__version__', 'ok'))"
"$VENV/bin/yt-dlp" --list-impersonate-targets >/dev/null
echo "[venv] ready: $VENV/bin/yt-dlp" >&2
