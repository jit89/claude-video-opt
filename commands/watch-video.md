---
description: Watch a video with DeepSeek running inside a headless Codex process. Delegates to watch.py for frames/transcript; Codex/DeepSeek views the JPEGs and writes a detailed analysis report.
argument-hint: <video-url-or-path> [question]
allowed-tools: [Bash, Read, AskUserQuestion]
---

Delegate a video watch to **DeepSeek via Codex** using the arguments: $ARGUMENTS

`scripts/watch-video.sh` launches an isolated `codex exec` pointed at DeepSeek. Codex runs `watch.py`, views the extracted frames, and writes the report. Long videos are windowed automatically. Claude Code is not used.

Steps:

1. **Parse args.** Treat the first token of $ARGUMENTS as the video source (URL or local path) and the rest as the question. If no source was given, ask for one with `AskUserQuestion` before continuing. If no question was given, default to: _"Create a detailed report: overview, key moments with [MM:SS] timestamps, any code/commands shown (verbatim, in fenced blocks), and takeaways."_

2. **Preflight Codex and the DeepSeek key.** Run:
   ```bash
   command -v codex >/dev/null && echo CODEX:OK || echo CODEX:MISSING
   (grep -Eq '^DEEPSEEK_API_KEY=.+' ~/.config/watch/.env 2>/dev/null \
     || grep -Eq '^DEEPSEEK_API_KEY=.+' ~/grok-coding-workflow/.env 2>/dev/null \
     || [ -n "${DEEPSEEK_API_KEY:-}" ]) && echo KEY:OK || echo KEY:MISSING
   ```
   If `CODEX:MISSING`, tell the user to install Codex CLI (≥ 0.144). Do not try Claude Code. If `KEY:MISSING`, tell the user to add `DEEPSEEK_API_KEY` to `~/.config/watch/.env` (https://platform.deepseek.com/api_keys) or `~/grok-coding-workflow/.env`, then stop.

3. **Run the harness.** Pass `--resolution 1024` so on-screen code/text is legible, and forward any extra `watch.py` flags (e.g. `--start`/`--end`) after the `--`. Add `--cleanup` (before the `--`) if the user wants the extracted frames removed afterward:
   ```bash
   "${CLAUDE_SKILL_DIR}/scripts/watch-video.sh" "<source>" "<question>" [--cleanup] -- --resolution 1024
   ```
   Long videos (> 10 min) are automatically processed in 10-minute **windows** — each window gets its own dense frame budget and findings are appended to the report.

4. **Surface the report.** The script prints the path of the report it wrote (default `~/Documents/claude-video-reports/<dd-mm-yyyy>/<video-id>/report.md`, next to the downloaded video). `Read` that file and present its contents to the user.

5. **Fallback if the harness fails.** If `watch-video.sh` exits non-zero (rate-limited, errored — it already retried transient errors internally), do **not** stop. Fall back to the standard `/watch` flow: run `"${CLAUDE_SKILL_DIR}/.venv/bin/python" "${CLAUDE_SKILL_DIR}/scripts/watch.py" "<source>" --resolution 1024 [range flags]` yourself, `Read` each frame it lists, and answer from the frames + transcript. Tell the user Codex/DeepSeek was unavailable and you analyzed it directly.
