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
Each video gets one folder: `~/Documents/claude-video-reports/<yyyy-mm-dd>/<video-id>/`, dated by the day it was first downloaded (override the root with `$WATCH_LIBRARY_DIR`). The video, subtitles, metadata and every report about it live together there. A video already in the library is **reused on later runs** (YouTube `?t=`, `?si=`, `/shorts/` and `youtu.be` links share one folder). A `.complete` sentinel prevents serving partial downloads, and library hits don't need `yt-dlp`. Force a fresh download with `--no-cache`; delete the video after the report with `--drop-video`.

### 4. Watch with **DeepSeek Vision** — `/watch-video` (`scripts/watch-video.sh`)
`watch_vision.py` runs `watch.py`, sends the JPEGs plus the time-aligned transcript to DeepSeek's vision model as native image content, and writes `report.md` next to the video. Long videos are split into 10-minute windows with a final cross-window summary. Each report starts with YAML frontmatter (title, source, channel, duration, uploaded, watched, model, question, a 1–2 sentence summary, topics, tags).

### 5. Recall across everything watched — `/watch:recall`
After each run the library index `~/Documents/claude-video-reports/INDEX.md` is rebuilt from every report's frontmatter (one short entry per report, newest first; `scripts/library.py index` rebuilds it by hand). `/watch:recall <question>` has Haiku triage the index, greps the reports for literal terms (commands, names, quotes), then reads only the matching reports and answers with titles, timestamps and paths. No embeddings or local models.

---

## Using it

### Base flow — Claude watches (`/watch`)
Unchanged from upstream:
```
/watch https://youtu.be/dQw4w9WgXcQ what happens at the 30 second mark?
/watch ~/Movies/screen-recording.mp4 when does the UI break?
```
New knobs on `scripts/watch.py`: `--no-scene-change`, `--no-cache` (the others — `--start`/`--end`, `--resolution`, `--max-frames`, `--fps`, `--whisper`, `--no-whisper` — are documented upstream).

### New flow — DeepSeek watches (`/watch-video`)
```
/watch-video https://youtu.be/abc "Detailed report; extract any on-screen code verbatim"
```
Or run the launcher directly:
```bash
./scripts/watch-video.sh "<url-or-path>" "your question"
./scripts/watch-video.sh "<url-or-path>" "your question" --cleanup --drop-video -- --resolution 1024 --start 1:00 --end 2:00
```
- The launcher checks today's date first, so new downloads land in today's folder.
- `--cleanup` removes the extracted frames; `--drop-video` deletes the downloaded video. Set `WATCH_DROP_VIDEO=1` in `~/.config/watch/.env` to make that the default on a machine, and `--keep-video` to keep one anyway. Subtitles, metadata and reports stay.
- `video.info.json` is trimmed to the fields that matter (title, channel, dates, tags, description, chapters, …) — yt-dlp's full dump is ~10 MB of format and caption URLs on long videos.
- Everything after `--` goes to `watch.py`. Pass `--resolution 1024` to read on-screen code accurately.
- Transient errors (rate-limit / overload) are retried per request (`$WATCH_VISION_MAX_RETRIES`, default 2).

### DeepSeek configuration (`~/.config/watch/.env`)
| Var | Value |
|-----|-------|
| `DEEPSEEK_API_KEY` | **Required.** [platform.deepseek.com](https://platform.deepseek.com/api_keys) |
| `DEEPSEEK_BASE_URL` | Default `https://api.deepseek.com` |
| `DEEPSEEK_VISION_MODEL` | Default `deepseek-v4-flash-vision-exp` |

`scripts/setup.py` scaffolds these placeholders into the `.env` alongside the Whisper keys.

---

## Install as a Claude Code plugin

Python dependencies live in a project venv built by uv on a uv-managed Python; the system Python is never touched.

```bash
brew install ffmpeg uv
./scripts/ensure-venv.sh                      # creates .venv (yt-dlp + curl_cffi)
claude plugin marketplace add "$PWD"          # this folder is the marketplace
claude plugin install watch@claude-video
```
A plugin added from a local folder is loaded in place, so edits to this repo apply in the next session. Inside Claude Code: `/watch:watch-video <url> [question]`, or just paste a video URL.

## What's unchanged (see upstream for details)

Install on other surfaces, first-run setup, the frame-budget table, Whisper/Groq/OpenAI key setup, supported sites, the 25 MB Whisper limit, and the `build-skill.sh` bundle all behave as in the **[original repo](https://github.com/bradautomates/claude-video#readme)**.

## Structure (additions in **bold**)

```
.
├── SKILL.md                     # upstream /watch skill (claude.ai / standalone)
├── skills/watch-video/SKILL.md  # /watch-video (plugin skill, NEW)
├── skills/recall/SKILL.md       # /watch:recall over the library index (NEW)
├── commands/watch.md            # /watch
├── scripts/
│   ├── watch.py                 # + scene-change, timeline, library wiring
│   ├── download.py              # + dated library download
│   ├── library.py               # dated folders, metadata, frontmatter, INDEX.md (NEW)
│   ├── frames.py                # + extract_scene_change()
│   ├── transcribe.py
│   ├── whisper.py
│   ├── setup.py                 # + DEEPSEEK_* env scaffolding
│   ├── watch_vision.py          # DeepSeek vision harness (NEW)
│   ├── watch-video.sh           # launcher: pins the date, runs the harness (NEW)
│   └── ensure-venv.sh           # uv venv bootstrap (NEW)
├── hooks/  ·  .claude-plugin/  ·  .codex-plugin/  ·  .github/workflows/
```

See [CHANGELOG.md](CHANGELOG.md) for the full version history.

## License

MIT — same as upstream. Built on `yt-dlp`, `ffmpeg`, Claude's multimodal `Read` tool, Whisper ([Groq](https://groq.com) / [OpenAI](https://openai.com)), and [DeepSeek Vision](https://api-docs.deepseek.com/guides/vision).

Original project: [github.com/bradautomates/claude-video](https://github.com/bradautomates/claude-video) · [LICENSE](LICENSE)
