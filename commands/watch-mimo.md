---
description: Watch a video with MiMo-V2.5 as the agent. Delegates to a headless Claude Code process backed by MiMo that runs the /watch pipeline, reads the frames, and writes a detailed analysis report.
argument-hint: <video-url-or-path> [question]
allowed-tools: [Bash, Read, AskUserQuestion]
---

Delegate a video watch to **MiMo-V2.5** (not Claude) using the arguments: $ARGUMENTS

`scripts/watch-mimo.sh` launches a headless Claude Code process backed by MiMo-V2.5 (via `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` pointed at MiMo's Anthropic-compatible endpoint). That MiMo agent runs `watch.py`, reads the extracted frames with the Read tool, reasons over them with its own thinking, and writes a report.

Steps:

1. **Parse args.** Treat the first token of $ARGUMENTS as the video source (URL or local path) and the rest as the question. If no source was given, ask for one with `AskUserQuestion` before continuing. If no question was given, default to: _"Create a detailed report: overview, key moments with [MM:SS] timestamps, any code/commands shown (verbatim, in fenced blocks), and takeaways."_

2. **Preflight the MiMo key.** Run:
   ```bash
   grep -Eq '^MIMO_API_KEY=.+' ~/.config/watch/.env && echo OK || echo MISSING
   ```
   If `MISSING`, tell the user to add their MiMo credentials to `~/.config/watch/.env` — `MIMO_API_KEY` (`tp-…` for a Token Plan, `sk-…` for pay-as-you-go) and, for a Token Plan, the dedicated `MIMO_BASE_URL` from their console — then stop.

3. **Run the harness.** This is a longer-running delegation (it downloads, extracts scene-change frames, and runs the MiMo agent loop). Pass `--resolution 1024` so on-screen code/text is legible to MiMo, and forward any extra `watch.py` flags (e.g. `--start`/`--end`) after the `--`:
   ```bash
   "${CLAUDE_SKILL_DIR}/scripts/watch-mimo.sh" "<source>" "<question>" -- --resolution 1024
   ```

4. **Surface the report.** The script prints the path of the report it wrote (default `watch-analysis.md` in the current directory). `Read` that file and present its contents to the user.
