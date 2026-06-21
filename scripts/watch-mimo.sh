#!/usr/bin/env bash
#
# watch-mimo.sh — run a headless Claude Code process backed by MiMo-V2.5 as the
# video-understanding agent. MiMo drives watch.py (this repo), reads the
# extracted frames with the Read tool, and reasons over them using its thinking.
#
# Why a separate process? ANTHROPIC_BASE_URL / ANTHROPIC_API_KEY / ANTHROPIC_MODEL
# are PROCESS-GLOBAL in Claude Code, so this is a sibling `claude` process with
# its own env — the same pattern as agentic-coding-workflow/scripts/kimi-code.sh.
#
# Long videos are processed in windows (default 10 min) so nothing is missed:
# each window gets its own dense frame budget and the agent appends per-window
# findings to the report (durable working memory) before moving on.
#
# Usage:
#   ./scripts/watch-mimo.sh <url-or-path> ["question"] [--cleanup] [-- <extra watch.py flags>]
#
# Flags:
#   --cleanup     Remove the extracted-frames working dir after the report is
#                 written (the downloaded video stays in the cache).
#
# Config (read from ~/.config/watch/.env or the environment):
#   MIMO_API_KEY            tp-... (Token Plan) or sk-... (pay-as-you-go) [required]
#   MIMO_BASE_URL           OpenAI-format base; Anthropic base is derived (/v1 -> /anthropic)
#   MIMO_MODEL              default: mimo-v2.5
#   WATCH_WINDOW_SECONDS    window size for long videos (default: 600 = 10 min)
#   WATCH_ANALYSIS_OUT      report path (default: $PWD/watch-analysis.md)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$HOME/.config/watch/.env"
OUT_FILE="${WATCH_ANALYSIS_OUT:-$PWD/watch-analysis.md}"
WINDOW="${WATCH_WINDOW_SECONDS:-600}"

# --- arg parsing: strip the launcher-level --cleanup flag, keep the rest ---
CLEANUP=0
ARGS=()
for a in "$@"; do
  if [[ "$a" == "--cleanup" ]]; then CLEANUP=1; else ARGS+=("$a"); fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

SOURCE="${1:?usage: watch-mimo.sh <url-or-path> [question] [--cleanup] [-- extra watch.py flags]}"
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

# --- config / key loading ---
load_var() {
  local name="$1" val="${!1:-}"
  if [[ -z "$val" && -f "$ENV_FILE" ]]; then
    val="$(grep -E "^${name}=" "$ENV_FILE" | tail -1 | cut -d= -f2- \
          | sed -e 's/^["'"'"' ]*//' -e 's/["'"'"' ]*$//')"
  fi
  printf '%s' "$val"
}

MIMO_API_KEY="$(load_var MIMO_API_KEY)"
MIMO_BASE_URL="$(load_var MIMO_BASE_URL)"
MIMO_MODEL="$(load_var MIMO_MODEL)"
: "${MIMO_API_KEY:?set MIMO_API_KEY (in the environment or ${ENV_FILE})}"
MIMO_BASE_URL="${MIMO_BASE_URL:-https://api.xiaomimimo.com/v1}"
MIMO_MODEL="${MIMO_MODEL:-mimo-v2.5}"

ANTHROPIC_BASE="${MIMO_BASE_URL%/v1}"
ANTHROPIC_BASE="${ANTHROPIC_BASE%/}/anthropic"

export ANTHROPIC_BASE_URL="$ANTHROPIC_BASE"
export ANTHROPIC_API_KEY="$MIMO_API_KEY"
export ANTHROPIC_MODEL="$MIMO_MODEL"
export ANTHROPIC_SMALL_FAST_MODEL="$MIMO_MODEL"
unset ANTHROPIC_AUTH_TOKEN || true

# --- working dir for extracted frames (so --cleanup has a known target) ---
WORK_BASE="$(mktemp -d -t watch-mimo-work-XXXXXX)"
cleanup() {
  if [[ "${CLEANUP:-0}" -eq 1 && -n "${WORK_BASE:-}" && -d "${WORK_BASE:-}" ]]; then
    rm -rf "$WORK_BASE"
    echo "[watch-mimo] cleaned up frames: ${WORK_BASE}" >&2
  fi
}
trap cleanup EXIT

# --- decide single-pass vs windowed (skip windowing for explicit ranges) ---
FOCUSED=0
case " ${EXTRA[*]:-} " in *" --start "*|*" --end "*) FOCUSED=1 ;; esac

DUR=""
if PROBE_JSON="$(python3 "${REPO_DIR}/scripts/watch.py" "${SOURCE}" --probe \
                  --out-dir "${WORK_BASE}/probe" 2>/dev/null)"; then
  DUR="$(printf '%s' "$PROBE_JSON" \
        | python3 -c 'import json,sys; print(int(float(json.load(sys.stdin)["duration_seconds"])))' \
        2>/dev/null || true)"
fi

if [[ -n "$DUR" && "$FOCUSED" -eq 0 && "$DUR" -gt "$WINDOW" ]]; then
  # ---- windowed prompt (long video) ----
  WINDOWS_TEXT=""
  k=0; s=0
  while [[ "$s" -lt "$DUR" ]]; do
    e=$(( s + WINDOW )); [[ "$e" -gt "$DUR" ]] && e="$DUR"
    WINDOWS_TEXT="${WINDOWS_TEXT}  - window ${k}: --start ${s} --end ${e} --out-dir ${WORK_BASE}/win_${k}"$'\n'
    s="$e"; k=$(( k + 1 ))
  done
  echo "[watch-mimo] long video (${DUR}s) → ${k} window(s) of ${WINDOW}s" >&2

  read -r -d '' PROMPT <<EOF || true
You are a video-understanding agent (model: ${MIMO_MODEL}) analysing a LONG video
(${DUR}s total) in ${WINDOW}-second windows so nothing is missed. Repo: ${REPO_DIR}.

Process the windows strictly IN ORDER. For each window, run the watcher for just
that slice, read its frames, and APPEND your findings to the report file BEFORE
starting the next window — that file is durable working memory, so an interruption
only loses the current window.

Report file: ${OUT_FILE}

Windows (start/end/out-dir already computed — use them verbatim):
${WINDOWS_TEXT}
For each window above (start S, end E, out-dir D):
  1. Run:
       python3 ${REPO_DIR}/scripts/watch.py "${SOURCE}" --start S --end E --out-dir D --scene-change ${EXTRA[*]:-}
     It prints a "## Frames" path list and a time-aligned "## Timeline".
  2. Read EVERY frame path it lists (Read tool); use the timeline transcript too.
  3. APPEND a section to ${OUT_FILE} headed "## [<S as mm:ss>–<E as mm:ss>]" with:
     key moments (timestamped), any on-screen or spoken code/commands (verbatim, in
     fenced blocks), and notable visuals. Write it before the next window.

After ALL windows are done, APPEND a final "## Summary" section that answers:
  ${QUESTION}
synthesising across the whole video and citing timestamps. Then print ${OUT_FILE}
as your last line.
EOF
else
  # ---- single-pass prompt (short video or explicit range) ----
  read -r -d '' PROMPT <<EOF || true
You are a video-understanding agent (model: ${MIMO_MODEL}) using the /watch
pipeline in ${REPO_DIR}.

1. Run the watcher to download the video, extract one frame per shot, and pull
   the transcript:
     python3 ${REPO_DIR}/scripts/watch.py "${SOURCE}" --out-dir ${WORK_BASE}/full ${EXTRA[*]:-}
   It prints a "## Frames" path list and a time-aligned "## Timeline".
2. Read EVERY frame path it lists using the Read tool. The timeline tells you what
   is said as each frame appears — use both together.
3. Reason over the frames AND the transcript (use your thinking). Then answer:
     ${QUESTION}
   Cite timestamps. Write the final analysis to ${OUT_FILE} and print its path
   as your last line.
EOF
fi

# Resolve the REAL claude binary (bypass any interactive `claude` shell wrapper).
CLAUDE_BIN="${CLAUDE_REAL_BIN:-}"
[[ -z "$CLAUDE_BIN" && -x "$HOME/.local/bin/claude" ]] && CLAUDE_BIN="$HOME/.local/bin/claude"
[[ -z "$CLAUDE_BIN" ]] && CLAUDE_BIN="$(command -v claude || true)"
: "${CLAUDE_BIN:?could not find the claude binary (set CLAUDE_REAL_BIN)}"

echo "[watch-mimo] model=${MIMO_MODEL} base=${ANTHROPIC_BASE_URL}" >&2
[[ "$CLEANUP" -eq 0 ]] && echo "[watch-mimo] frames kept in ${WORK_BASE} (pass --cleanup to remove)" >&2

# Short transient-retry on rate limits / overload, then a clean exit code so the
# caller (e.g. the /watch-mimo command) can fall back to the standard /watch flow.
MAX_RETRIES="${WATCH_MIMO_MAX_RETRIES:-2}"
LOG="$(mktemp -t watch-mimo-XXXXXX.log)"
attempt=1
while :; do
  set +e
  "$CLAUDE_BIN" -p "$PROMPT" \
    --permission-mode acceptEdits \
    --allowedTools "Read,Edit,Write,Bash,Glob,Grep,Skill" 2>&1 | tee "$LOG"
  rc=${PIPESTATUS[0]}
  set -e

  [[ $rc -eq 0 ]] && exit 0

  if grep -qiE '429|rate.?limit|overloaded|quota|too many requests' "$LOG" \
     && (( attempt < MAX_RETRIES )); then
    backoff=$(( 10 * attempt ))
    echo "[watch-mimo] transient error — retry ${attempt}/${MAX_RETRIES} in ${backoff}s" >&2
    sleep "$backoff"
    attempt=$(( attempt + 1 ))
    continue
  fi

  echo "[watch-mimo] FAILED (exit ${rc}); MiMo harness did not complete. Log: ${LOG}" >&2
  echo "[watch-mimo] Fallback: re-run with the standard /watch flow (Claude as the agent)." >&2
  exit "$rc"
done
