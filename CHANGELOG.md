# Changelog

All notable changes to `/watch` are documented here.

## [Unreleased]

### Added
- Scene-change frame extraction in `scripts/frames.py` — `extract_scene_change()` uses ffmpeg's `select=gt(scene,0.3)` filter to emit one frame per detected shot instead of uniform every-N-seconds sampling, keeping token cost flat on long videos. Always emits frame 0 (the scene filter only fires on *changes*). Falls back to uniform sampling when fewer than 10 scenes are detected (static/screen-recorded sources). Adapted from [taoufik123-collab/claude-watch](https://github.com/taoufik123-collab/claude-watch) v0.2.0.
- `--no-scene-change` flag on `scripts/watch.py` to force uniform sampling.

- On-disk download cache in `scripts/download.py` — URL downloads are keyed by a SHA-256 hash of the URL and reused on later runs (video + subtitles + info.json). Cache root is `~/.cache/watch/downloads` or `$WATCH_CACHE_DIR`. A `.complete` sentinel guards against serving partial downloads, and cache hits no longer require yt-dlp to be installed. `--no-cache` forces a re-download.
- Time-aligned `## Timeline` section in the report — frames and transcript lines are merged in chronological order so the model can see what's on screen as each line is spoken. Replaces the standalone transcript block; the `## Frames` path list (for the Read tool) is unchanged.
- `/watch-mimo <url-or-path> [question]` slash command (`commands/watch-mimo.md`) — invokes the MiMo harness and surfaces the generated report. The harness writes `watch-analysis.md` to the caller's working directory (override with `$WATCH_ANALYSIS_OUT`) rather than the plugin dir.
- MiMo-V2.5 harness in `scripts/watch-mimo.sh` — runs the pipeline under a headless Claude Code process backed by MiMo-V2.5 (via `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` pointed at MiMo's Anthropic-compatible endpoint), so MiMo itself drives `watch.py`, reads the frames with the Read tool, and reasons over them. Verified against MiMo's token-plan endpoint: `x-api-key` auth, image content blocks, tool use, extended thinking, and streaming all work. Config via `MIMO_API_KEY` / `MIMO_BASE_URL` / `MIMO_MODEL` in `~/.config/watch/.env` (pay-as-you-go `sk-` or Token Plan `tp-`); `setup.py` scaffolds them.

### Changed
- Full-video passes now default to scene-change sampling. Focused mode (`--start`/`--end`) and an explicit `--fps` still use uniform sampling.

### Fixed
- Scene-change extraction no longer truncates long, cut-heavy videos to just their opening. ffmpeg emits detected scenes chronologically; the frame budget is now spread *evenly across the whole timeline* (always keeping the first and last) instead of head-capping at `max_frames`. Extraction is bounded by a generous internal hard cap (`SCENE_DETECT_HARD_CAP`).

## [0.1.3] — 2026-05-09

### Fixed
- Windows: `video.info.json` is read as UTF-8 (#4). Previously `Path.read_text()` defaulted to cp1252 on Windows and crashed on yt-dlp's UTF-8 output, silently dropping Title/Uploader from the report. Same fix applied to `.env` reads/writes in `whisper.py` and `setup.py`.
- `download.py` now logs info.json parse failures to stderr instead of swallowing them.

### Security
- Hardened subprocess argv against option injection (#2): inserted `--` before the URL in the yt-dlp argv, and tightened `is_url` to reject `-`-prefixed sources and require a non-empty netloc. Resolved video/audio paths to absolute via `Path.resolve()` before passing to `ffmpeg`/`ffprobe`, so a relative path starting with `-` can't be misinterpreted as a flag.

## [0.1.2] — 2026-04-24

### Fixed
- Windows console crash: removed the emoji from the long-video warning in `watch.py`; cp1252 consoles couldn't encode it.
- `setup.py` now prints `winget` / `pip` install commands on Windows instead of "unsupported platform" — matches what the README already promised.

### Changed
- `SKILL.md` notes that on Windows the scripts must be invoked with `python`, not `python3` (the latter is the Microsoft Store stub on Windows).

## [0.1.1] — 2026-04-24

### Fixed
- Added `commands/watch.md` shim so `/watch` is callable when installed as a Claude Code plugin. Without it, the plugin loaded but the skill wasn't exposed as a slash command.
- `scripts/build-skill.sh` now strips `commands/` from the claude.ai `.skill` bundle alongside `hooks/` and `.claude-plugin/`.

## [0.1.0] — 2026-04-24

Initial marketplace release.

### Added
- `/watch <url-or-path> [question]` slash command.
- yt-dlp download with native caption extraction (manual + auto-subs).
- ffmpeg frame extraction with auto-scaled fps (≤2 fps, ≤100 frames, duration-aware budget).
- `--start` / `--end` focused mode with denser frame budget and transcript range filtering.
- Whisper fallback (Groq preferred, OpenAI secondary) for videos without captions.
- `setup.py` preflight: silent `--check`, structured `--json`, and installer that auto-runs `brew install` on macOS.
- Session-start hook that prints a one-line status on first run / partial config.
- `.skill` bundle packaging for claude.ai upload via `scripts/build-skill.sh`.
