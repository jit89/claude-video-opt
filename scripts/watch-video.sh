#!/usr/bin/env bash
#
# watch-video.sh — headless Codex process backed by DeepSeek as the
# video-understanding agent. Codex drives watch.py, views extracted frames
# (view_image), and writes the analysis report.
#
# Isolated CODEX_HOME — does not rewrite ~/.codex/config.toml, so
# interactive Codex/ChatGPT stays untouched. Same pattern as
# grok-coding-workflow/scripts/deepseek-code.sh.
#
# Claude Code is not used.
#
# Long videos are processed in windows (default 10 min): each window gets
# its own dense frame budget and the agent appends per-window findings to
# the report (durable working memory) before moving on.
#
# Usage:
#   ./scripts/watch-video.sh <url-or-path> ["question"] [--cleanup] [-- extra watch.py flags]
#
# Config (~/.config/watch/.env, the environment, or ~/grok-coding-workflow/.env):
#   DEEPSEEK_API_KEY            required
#   DEEPSEEK_BASE_URL           default https://api.deepseek.com/
#   DEEPSEEK_MODEL              default deepseek-v4-flash
#   DEEPSEEK_VISION_MODEL       alias for DEEPSEEK_MODEL if MODEL is unset
#   WATCH_WINDOW_SECONDS        default 600
#   WATCH_ANALYSIS_OUT          report path (default: next to the video, in
#                               ~/Documents/claude-video-reports/<dd-mm-yyyy>/<slug>/report.md)
#   WATCH_LIBRARY_DIR           library root (default ~/Documents/claude-video-reports)
#   WATCH_CODEX_HOME            isolated Codex state
#                               (default ~/.cache/watch-video/codex)
#   CODEX_BIN                   override Codex binary path
#   WATCH_VIDEO_MAX_RETRIES     default 2

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERE="$REPO_DIR/scripts"
ENV_FILE="$HOME/.config/watch/.env"
HOUSE_ENV="$HOME/grok-coding-workflow/.env"
OUT_FILE="${WATCH_ANALYSIS_OUT:-}"
WINDOW="${WATCH_WINDOW_SECONDS:-600}"
CODEX_HOME_DIR="${WATCH_CODEX_HOME:-$HOME/.cache/watch-video/codex}"
CACHE_DIR="${WATCH_LIBRARY_DIR:-${WATCH_CACHE_DIR:-$HOME/Documents/claude-video-reports}}"
export WATCH_LIBRARY_DIR="$CACHE_DIR"
# New downloads go into a folder named for today's date (dd-mm-yyyy).
# Pin it once here so a run that crosses midnight stays in one folder.
export WATCH_DATE="${WATCH_DATE:-$(date +%d-%m-%Y)}"
MODELS_JSON="$HERE/lib/codex-models.deepseek.json"
VENV_PY="$REPO_DIR/.venv/bin/python"

usage() {
  cat <<'EOF'
usage: watch-video.sh <url-or-path> ["question"] [--cleanup] [-- extra watch.py flags]

Watch a video with DeepSeek running inside a headless Codex process.

  --cleanup   remove extracted frames after the report is written
              (the downloaded video stays in the library)

Extra watch.py flags go after --  e.g. -- --resolution 1024 --start 1:00
EOF
  exit "${1:-2}"
}

# --- arg parsing: strip launcher-level --cleanup, keep the rest ---
CLEANUP=0
ARGS=()
for a in "$@"; do
  case "$a" in
    -h|--help) usage 0 ;;
    --cleanup) CLEANUP=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

[[ $# -ge 1 ]] || usage
SOURCE="$1"
shift || true

QUESTION="Give a structured analysis: what happens, the key visual moments with timestamps, and the overall topic."
if [[ "${1:-}" != "" && "${1:-}" != "--" ]]; then
  QUESTION="$1"
  shift || true
fi

EXTRA=()
if [[ "${1:-}" == "--" ]]; then
  shift
  EXTRA=("$@")
fi

# --- config / key loading (env, watch .env, house .env) ---
env_file_get() {
  local file="$1" key="$2" line val
  [[ -f "$file" ]] || return 1
  line="$(grep -E "^${key}=" "$file" | tail -n1)" || return 1
  [[ -n "$line" ]] || return 1
  val="${line#*=}"
  val="${val%$'\r'}"
  if [[ ${#val} -ge 2 && "$val" == \"*\" ]]; then
    val="${val:1:${#val}-2}"
  elif [[ ${#val} -ge 2 && "$val" == \'*\' ]]; then
    val="${val:1:${#val}-2}"
  fi
  [[ -n "$val" ]] || return 1
  printf '%s' "$val"
}

load_var() {
  local name="$1"
  local val="${!name:-}"
  if [[ -n "$val" ]]; then
    printf '%s' "$val"
    return 0
  fi
  local f got
  for f in "$ENV_FILE" "$HOUSE_ENV"; do
    got="$(env_file_get "$f" "$name" || true)"
    if [[ -n "$got" ]]; then
      printf '%s' "$got"
      return 0
    fi
  done
  return 1
}

DEEPSEEK_API_KEY="$(load_var DEEPSEEK_API_KEY || true)"
DEEPSEEK_BASE_URL="$(load_var DEEPSEEK_BASE_URL || true)"
DEEPSEEK_MODEL="$(load_var DEEPSEEK_MODEL || true)"
if [[ -z "$DEEPSEEK_MODEL" ]]; then
  DEEPSEEK_MODEL="$(load_var DEEPSEEK_VISION_MODEL || true)"
fi
: "${DEEPSEEK_API_KEY:?set DEEPSEEK_API_KEY (in the environment, ${ENV_FILE}, or ${HOUSE_ENV})}"
export DEEPSEEK_API_KEY
DEEPSEEK_BASE_URL="${DEEPSEEK_BASE_URL:-https://api.deepseek.com/}"
[[ "$DEEPSEEK_BASE_URL" == */ ]] || DEEPSEEK_BASE_URL="${DEEPSEEK_BASE_URL}/"
DEEPSEEK_MODEL="${DEEPSEEK_MODEL:-deepseek-v4-flash}"
export DEEPSEEK_BASE_URL DEEPSEEK_MODEL

find_codex() {
  if [[ -n "${CODEX_BIN:-}" && -x "$CODEX_BIN" ]]; then
    printf '%s' "$CODEX_BIN"
    return 0
  fi
  local c
  c="$(command -v codex 2>/dev/null || true)"
  if [[ -n "$c" ]]; then
    printf '%s' "$c"
    return 0
  fi
  local nvm_latest
  nvm_latest="$(ls -1d "$HOME"/.nvm/versions/node/*/bin/codex 2>/dev/null | tail -n1 || true)"
  if [[ -n "$nvm_latest" && -x "$nvm_latest" ]]; then
    printf '%s' "$nvm_latest"
    return 0
  fi
  for c in "$HOME/.local/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex; do
    if [[ -x "$c" ]]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

CODEX_BIN="$(find_codex)" || {
  echo "could not find the codex binary (install Codex CLI ≥ 0.144, or set CODEX_BIN)" >&2
  echo "Claude Code is not used by this harness." >&2
  exit 1
}
export PATH="$(dirname "$CODEX_BIN"):$PATH"

toml_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

if [[ ! -x "$VENV_PY" ]]; then
  echo "[watch-video] missing project venv: $VENV_PY" >&2
  echo "[watch-video] run: $HERE/ensure-venv.sh" >&2
  echo "[watch-video] (installs yt-dlp + curl_cffi in .venv; does not touch system Python)" >&2
  exit 1
fi

# --- working dir for extracted frames (so --cleanup has a known target) ---
WORK_BASE="$(mktemp -d -t watch-video-work-XXXXXX)"
if [[ -z "$OUT_FILE" ]]; then
  OUT_FILE="$("$VENV_PY" "$HERE/library.py" report "$SOURCE")"
fi
OUT_FILE="$("$VENV_PY" -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$OUT_FILE")"
OUT_DIR="$(dirname "$OUT_FILE")"
mkdir -p "$OUT_DIR" "$CACHE_DIR" "$CODEX_HOME_DIR"

cleanup() {
  if [[ "${CLEANUP:-0}" -eq 1 && -n "${WORK_BASE:-}" && -d "${WORK_BASE:-}" ]]; then
    rm -rf "$WORK_BASE"
    echo "[watch-video] cleaned up frames: ${WORK_BASE}" >&2
  fi
}
trap cleanup EXIT

GIT_WRITABLE_ROOTS="[$(toml_quote "$WORK_BASE"),$(toml_quote "$OUT_DIR"),$(toml_quote "$CACHE_DIR")]"

write_codex_config() {
  cat >"$CODEX_HOME_DIR/config.toml" <<EOF
model = "${DEEPSEEK_MODEL}"
model_provider = "deepseek"
preferred_auth_method = "apikey"
forced_login_method = "api"
model_reasoning_effort = "high"
model_catalog_json = "${CODEX_HOME_DIR}/models.json"
sandbox_mode = "workspace-write"
approval_policy = "never"

[sandbox_workspace_write]
network_access = true
writable_roots = ${GIT_WRITABLE_ROOTS}

[model_providers.deepseek]
name = "deepseek"
base_url = "${DEEPSEEK_BASE_URL}"
wire_api = "responses"
env_key = "DEEPSEEK_API_KEY"

[tools]
view_image = true
EOF
}

export CODEX_HOME="$CODEX_HOME_DIR"
cp "$MODELS_JSON" "$CODEX_HOME_DIR/models.json"
write_codex_config

# --- decide single-pass vs windowed (skip windowing for explicit ranges) ---
FOCUSED=0
case " ${EXTRA[*]:-} " in *" --start "*|*" --end "*) FOCUSED=1 ;; esac

DUR=""
PROBE_FLAGS=()
case " ${EXTRA[*]:-} " in *" --no-cache "*) PROBE_FLAGS+=(--no-cache) ;; esac
if PROBE_JSON="$("$VENV_PY" "${REPO_DIR}/scripts/watch.py" "${SOURCE}" --probe \
                  --out-dir "${WORK_BASE}/probe" "${PROBE_FLAGS[@]+"${PROBE_FLAGS[@]}"}" 2>/dev/null)"; then
  DUR="$(printf '%s' "$PROBE_JSON" \
        | "$VENV_PY" -c 'import json,sys; print(int(float(json.load(sys.stdin)["duration_seconds"])))' \
        2>/dev/null || true)"
fi

EXTRA_TEXT="${EXTRA[*]:-}"

if [[ -n "$DUR" && "$FOCUSED" -eq 0 && "$DUR" -gt "$WINDOW" ]]; then
  WINDOWS_TEXT=""
  k=0; s=0
  while [[ "$s" -lt "$DUR" ]]; do
    e=$(( s + WINDOW )); [[ "$e" -gt "$DUR" ]] && e="$DUR"
    WINDOWS_TEXT="${WINDOWS_TEXT}  - window ${k}: --start ${s} --end ${e} --out-dir ${WORK_BASE}/win_${k}"$'\n'
    s="$e"; k=$(( k + 1 ))
  done
  echo "[watch-video] long video (${DUR}s) → ${k} window(s) of ${WINDOW}s" >&2

  read -r -d '' PROMPT <<EOF || true
You are a video-understanding agent (model: ${DEEPSEEK_MODEL}, Codex harness) analysing a LONG video
(${DUR}s total) in ${WINDOW}-second windows so nothing is missed. Repo: ${REPO_DIR}.

You are headless. Do not ask questions. Do not use web search. Do not look for Claude Code.

Process the windows strictly IN ORDER. For each window, run the watcher for just
that slice, view its frames, and APPEND your findings to the report file BEFORE
starting the next window — that file is durable working memory, so an interruption
only loses the current window.

Report file: ${OUT_FILE}

Windows (start/end/out-dir already computed — use them verbatim):
${WINDOWS_TEXT}
For each window above (start S, end E, out-dir D):
  1. Run:
       ${VENV_PY} ${REPO_DIR}/scripts/watch.py "${SOURCE}" --start S --end E --out-dir D --scene-change ${EXTRA_TEXT}
     It prints a "## Frames" path list and a time-aligned "## Timeline".
  2. View EVERY frame JPEG it lists (view_image / image tool). Use the timeline transcript too.
  3. APPEND a section to ${OUT_FILE} headed "## [<S as mm:ss>–<E as mm:ss>]" with:
     key moments (timestamped), any on-screen or spoken code/commands (verbatim, in
     fenced blocks), and notable visuals. Write it before the next window.

After ALL windows are done, APPEND a final "## Summary" section that answers:
  ${QUESTION}
synthesising across the whole video and citing timestamps. Then print ${OUT_FILE}
as your last line.
EOF
else
  read -r -d '' PROMPT <<EOF || true
You are a video-understanding agent (model: ${DEEPSEEK_MODEL}, Codex harness) using the /watch
pipeline in ${REPO_DIR}.

You are headless. Do not ask questions. Do not use web search. Do not look for Claude Code.

1. Run the watcher to download the video, extract one frame per shot, and pull
   the transcript:
     ${VENV_PY} ${REPO_DIR}/scripts/watch.py "${SOURCE}" --out-dir ${WORK_BASE}/full ${EXTRA_TEXT}
   It prints a "## Frames" path list and a time-aligned "## Timeline".
2. View EVERY frame JPEG it lists (view_image / image tool). The timeline tells you what
   is said as each frame appears — use both together.
3. Reason over the frames AND the transcript. Then answer:
     ${QUESTION}
   Cite timestamps. Write the final analysis to ${OUT_FILE} and print its path
   as your last line.
EOF
fi

echo "[watch-video] model=${DEEPSEEK_MODEL} harness=codex base=${DEEPSEEK_BASE_URL}" >&2
echo "[watch-video] report=${OUT_FILE}" >&2
[[ "$CLEANUP" -eq 0 ]] && echo "[watch-video] frames kept in ${WORK_BASE} (pass --cleanup to remove)" >&2

MAX_RETRIES="${WATCH_VIDEO_MAX_RETRIES:-2}"
LOG="$(mktemp -t watch-video-XXXXXX.log)"
LAST_MSG="$(mktemp -t watch-video-last-XXXXXX.txt)"
attempt=1
while :; do
  set +e
  "$CODEX_BIN" exec \
    --approve-for-me \
    --skip-git-repo-check \
    --color never \
    -C "$REPO_DIR" \
    --add-dir "$WORK_BASE" \
    --add-dir "$OUT_DIR" \
    --add-dir "$CACHE_DIR" \
    -c "sandbox_workspace_write.writable_roots=${GIT_WRITABLE_ROOTS}" \
    -c "sandbox_workspace_write.network_access=true" \
    -m "$DEEPSEEK_MODEL" \
    -o "$LAST_MSG" \
    - <<<"$PROMPT" 2>&1 | tee "$LOG"
  rc=${PIPESTATUS[0]}
  set -e

  if [[ $rc -eq 0 ]]; then
    if [[ -s "$LAST_MSG" ]]; then
      echo "[watch-video] last message:" >&2
      cat "$LAST_MSG" >&2
    fi
    echo "$OUT_FILE"
    exit 0
  fi

  if grep -qiE '429|rate.?limit|overloaded|quota|too many requests' "$LOG" \
     && (( attempt < MAX_RETRIES )); then
    backoff=$(( 10 * attempt ))
    echo "[watch-video] transient error — retry ${attempt}/${MAX_RETRIES} in ${backoff}s" >&2
    sleep "$backoff"
    attempt=$(( attempt + 1 ))
    continue
  fi

  echo "[watch-video] FAILED (exit ${rc}); Codex/DeepSeek harness did not complete. Log: ${LOG}" >&2
  echo "[watch-video] Fallback: re-run with the standard /watch flow (host agent reads frames)." >&2
  exit "$rc"
done
