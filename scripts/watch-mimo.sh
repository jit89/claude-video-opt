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
# Usage:
#   ./scripts/watch-mimo.sh <url-or-path> ["question"] [-- <extra watch.py flags>]
#
# Config (read from ~/.config/watch/.env or the environment):
#   MIMO_API_KEY   tp-... (Token Plan) or sk-... (pay-as-you-go)        [required]
#   MIMO_BASE_URL  OpenAI-format base, e.g.
#                  https://token-plan-sgp.xiaomimimo.com/v1   (Anthropic base is
#                  derived from it: trailing /v1 -> /anthropic)
#   MIMO_MODEL     default: mimo-v2.5

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$HOME/.config/watch/.env"

SOURCE="${1:?usage: watch-mimo.sh <url-or-path> [question] [-- extra watch.py flags]}"
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

# Pull a var from the environment, falling back to the watch .env file.
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

# Derive the Anthropic-compatible base URL: strip a trailing /v1, append /anthropic.
ANTHROPIC_BASE="${MIMO_BASE_URL%/v1}"
ANTHROPIC_BASE="${ANTHROPIC_BASE%/}/anthropic"

# Point this process at MiMo. MiMo's Anthropic endpoint authenticates via the
# x-api-key header, so use ANTHROPIC_API_KEY — NOT ANTHROPIC_AUTH_TOKEN (Bearer).
# Verified against the live token-plan endpoint: x-api-key returns 200.
export ANTHROPIC_BASE_URL="$ANTHROPIC_BASE"
export ANTHROPIC_API_KEY="$MIMO_API_KEY"
export ANTHROPIC_MODEL="$MIMO_MODEL"
export ANTHROPIC_SMALL_FAST_MODEL="$MIMO_MODEL"
unset ANTHROPIC_AUTH_TOKEN || true

read -r -d '' PROMPT <<EOF || true
You are a video-understanding agent (model: ${MIMO_MODEL}) using the /watch
pipeline in ${REPO_DIR}.

1. Run the watcher to download the video, extract one frame per shot, and pull
   the transcript:
     python3 ${REPO_DIR}/scripts/watch.py "${SOURCE}" ${EXTRA[*]}
   It prints a markdown report: a "## Frames" list of frame file paths
   (chronological, each tagged with its absolute timestamp) and a
   "## Timeline" that interleaves those frames with the transcript in time order.
2. Read EVERY frame path it lists using the Read tool to view the images. The
   timeline tells you what is said as each frame appears — use both together.
3. Reason over the frames AND the transcript (use your thinking). Then answer:
     ${QUESTION}
   Cite timestamps for your claims. Write the final analysis to
   ${REPO_DIR}/watch-analysis.md and print its path as your last line.
EOF

# Resolve the REAL claude binary. The interactive shell may define a `claude`
# wrapper function (provider switcher); bypass it and call the binary directly.
CLAUDE_BIN="${CLAUDE_REAL_BIN:-}"
[[ -z "$CLAUDE_BIN" && -x "$HOME/.local/bin/claude" ]] && CLAUDE_BIN="$HOME/.local/bin/claude"
[[ -z "$CLAUDE_BIN" ]] && CLAUDE_BIN="$(command -v claude || true)"
: "${CLAUDE_BIN:?could not find the claude binary (set CLAUDE_REAL_BIN)}"

echo "[watch-mimo] model=${MIMO_MODEL} base=${ANTHROPIC_BASE_URL}" >&2
exec "$CLAUDE_BIN" -p "$PROMPT" \
  --permission-mode acceptEdits \
  --allowedTools "Read,Edit,Write,Bash,Glob,Grep,Skill"
