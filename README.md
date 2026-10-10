# /watch — enhanced fork

**Give Claude (or DeepSeek Vision) the ability to watch any video.**

> This is an **enhanced fork** of [`bradautomates/claude-video`](https://github.com/bradautomates/claude-video) — the original `/watch` skill by Bradley Bonanno (MIT). It downloads a video with `yt-dlp`, extracts frames with `ffmpeg`, pulls a timestamped transcript (free captions, Whisper fallback), and hands frames + transcript to an agent so it can answer questions about what's actually on screen.
>
> **This README documents only what's different in this fork.** For the full base story — how the pipeline works end to end, install on every surface (Claude Code / claude.ai / Codex), the frame-budget math, Whisper setup, and limits — see the **[original README](https://github.com/bradautomates/claude-video#readme)**. Everything there still applies here.

---

## What's new in this fork

Four additive enhancements on top of upstream v0.1.3. The base pipeline (yt-dlp → ffmpeg → captions/Whisper) is unchanged; nothing below breaks existing `/watch` usage.

### 1. Scene-change frame extraction (`scripts/frames.py`)
Instead of sampling one frame every *N* seconds, the default full-video pass now emits **one frame per detected shot** using ffmpeg's `select='gt(scene,0.3)'` filter. This keeps token cost flat on long videos and never misses a hard cut.
- Always emits frame 0 (the scene filter only fires on *changes*).
- **Falls back to uniform sampling** automatically when a source is static (screen recordings, long talking heads) and yields too few scenes.
- **Fixes a truncation bug:** the frame budget is now spread *evenly across the whole timeline* (keeping first and last), so long, cut-heavy videos are no longer truncated to just their opening.
- Disable with `--no-scene-change`. Focused mode (`--start`/`--end`) and an explicit `--fps` still use uniform sampling.

### 2. Time-aligned `## Timeline` (`scripts/watch.py`)
The report now interleaves **frames and transcript lines in chronological order**, so the agent sees what's on screen *as each line is spoken* (frame markers `F` and transcript lines `»`, merged by timestamp). The plain `## Frames` path list is still there for the Read tool.

### 3. Dated video library (`scripts/library.py`, `scripts/download.py`)
URL downloads land in `~/Documents/claude-video-reports/<dd-mm-yyyy>/<video-id>/` (dated by the day of first download; override the root with `$WATCH_LIBRARY_DIR`), and the harness writes `report.md` into the same folder. A video already in the library is **reused on later runs** — video, subtitles, and metadata. A `.complete` sentinel prevents serving partial downloads, and cache hits don't even require `yt-dlp` installed. Force a fresh download with `--no-cache`.

### 4. Watch with **DeepSeek inside Codex** — `/watch-video` (`scripts/watch-video.sh`)
The headline feature. A **headless Codex** process (`codex exec`), pointed at DeepSeek, drives `watch.py`, views the extracted JPEGs, and writes the report. Isolated `CODEX_HOME` at `~/.cache/watch-video/codex` — interactive Codex/ChatGPT is untouched. Long videos are still split into 10-minute windows. Claude Code is not used.

---

## Using it

### Base flow — Claude watches (`/watch`)
Unchanged from upstream:
```
/watch https://youtu.be/dQw4w9WgXcQ what happens at the 30 second mark?
/watch ~/Movies/screen-recording.mp4 when does the UI break?
```
New knobs on `scripts/watch.py`: `--no-scene-change`, `--no-cache` (the others — `--start`/`--end`, `--resolution`, `--max-frames`, `--fps`, `--whisper`, `--no-whisper` — are documented upstream).

### New flow — DeepSeek watches via Codex (`/watch-video`)
```
/watch-video https://youtu.be/abc "Detailed report; extract any on-screen code verbatim"
```
Or run the launcher directly. Just a source and a question works (no flags needed):
```bash
# Minimal — source + question, no trailing flags:
./scripts/watch-video.sh "<url-or-path>" "your question"

# Clean up frames afterward, and forward extra watch.py flags after `--`:
./scripts/watch-video.sh "<url-or-path>" "your question" --cleanup -- --resolution 1024 --start 1:00 --end 2:00
```
- Both forms work; the `--` is only needed when you pass extra `watch.py` flags.
- `--cleanup` removes the extracted-frames working dir after the report is written (the downloaded video stays cached).
- Pass `--resolution 1024` when you want on-screen code/text read accurately.
- The report is written to the **current directory** as `watch-analysis.md` (override with `$WATCH_ANALYSIS_OUT`).
- Requires Codex CLI ≥ 0.144 on `PATH` (or `$CODEX_BIN`).

**Long videos are windowed automatically.** Past 10 minutes (configurable via `$WATCH_WINDOW_SECONDS`), the harness splits the video into 10-minute windows — Codex/DeepSeek appends per-window findings to the report as durable working memory. Explicit `--start`/`--end` ranges skip windowing.

### DeepSeek configuration (`~/.config/watch/.env`)
| Var | Value |
|-----|-------|
| `DEEPSEEK_API_KEY` | **Required** unless already set in the environment or `~/grok-coding-workflow/.env`. [platform.deepseek.com](https://platform.deepseek.com/api_keys). |
| `DEEPSEEK_BASE_URL` | Default `https://api.deepseek.com/`. |
| `DEEPSEEK_MODEL` | Default `deepseek-v4-flash`. `DEEPSEEK_VISION_MODEL` is accepted as an alias. |

`scripts/setup.py` scaffolds these placeholders into the `.env` alongside the Whisper keys. Isolated Codex state lives at `~/.cache/watch-video/codex` and does **not** rewrite `~/.codex/config.toml`.

---

## Does `/watch-video` have a fallback?

Yes — two layers:

1. **Transient retry in the launcher.** `watch-video.sh` retries on rate-limit / overload with a short backoff (configurable via `$WATCH_VIDEO_MAX_RETRIES`), then exits with a clean non-zero code if it still can't complete.
2. **Fall back to the host agent.** If the harness ultimately fails, `/watch-video` falls back to the **standard `/watch` flow** — it runs `watch.py` directly and lets the host (Grok) read the frames and answer. Because the download is already cached and `watch.py` is provider-independent, this fallback is fast and always available. Do not fall back to Claude Code.

---

## What's unchanged (see upstream for details)

Install, first-run setup, the frame-budget table, Whisper/Groq/OpenAI key setup, supported sites, the 25 MB Whisper limit, claude.ai/Codex packaging, and the `build-skill.sh` bundle — all behave exactly as in the **[original repo](https://github.com/bradautomates/claude-video#readme)**. Install the enhanced version as a plugin with:

```
/plugin marketplace add jit89/claude-video-opt
/plugin install watch@claude-video
```

## Structure (additions in **bold**)

```
.
├── SKILL.md
├── commands/
│   ├── watch.md                 # /watch
│   └── watch-video.md           # /watch-video  (NEW)
├── scripts/
│   ├── watch.py                 # + scene-change, timeline, cache wiring
│   ├── download.py              # + on-disk URL cache
│   ├── frames.py                # + extract_scene_change()
│   ├── transcribe.py
│   ├── whisper.py
│   ├── setup.py                 # + DEEPSEEK_* env scaffolding
│   ├── lib/codex-models.deepseek.json
│   └── watch-video.sh           # headless Codex + DeepSeek launcher
├── hooks/  ·  .claude-plugin/  ·  .codex-plugin/  ·  .github/workflows/
```

See [CHANGELOG.md](CHANGELOG.md) for the full version history.

## License

MIT — same as upstream. Built on `yt-dlp`, `ffmpeg`, Claude's multimodal `Read` tool, Whisper ([Groq](https://groq.com) / [OpenAI](https://openai.com)), and [DeepSeek Vision](https://api-docs.deepseek.com/guides/vision).

Original project: [github.com/bradautomates/claude-video](https://github.com/bradautomates/claude-video) · [LICENSE](LICENSE)
