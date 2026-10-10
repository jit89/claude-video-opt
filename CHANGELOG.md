# Changelog

All notable changes to `/watch` are documented here.

## [Unreleased]

### Changed
- Downloads and reports now live together in a dated library: `~/Documents/claude-video-reports/<yyyy-mm-dd>/<video-id>/` (`scripts/library.py`) instead of hash-named dirs under `~/.cache/watch/downloads`. The date is today's when a video is first downloaded (`watch-video.sh` pins it via `$WATCH_DATE`); a video already in the library is reused from its folder, and `--no-cache` re-downloads in place. YouTube URL variants (`?t=`, `?si=`, `/shorts/`, `youtu.be`) share one folder. Root override: `$WATCH_LIBRARY_DIR` (`$WATCH_CACHE_DIR` still honoured).
- `scripts/ensure-venv.sh` builds `.venv` with uv on a uv-managed Python 3.14 (rebuilds when the version differs); it no longer needs Homebrew Python.
- `/watch-video` runs `scripts/watch_vision.py`, which sends frames + timeline straight to DeepSeek Vision (`DEEPSEEK_VISION_MODEL`, default `deepseek-v4-flash-vision-exp`). `scripts/watch-video.sh` is now a thin launcher that pins the date and runs it in the venv. The earlier Codex-driven harness was removed (it remains in git history, commit e039340).
- YouTube downloads use a **project venv** (`~/claude-video-opt/.venv`) with `yt-dlp` + `curl_cffi`. `download.py` calls that `yt-dlp` with `--impersonate chrome` and yt-dlp's default player clients (not android/ios, which are SABR-only 360p). System Python is not used. Bootstrap: `scripts/ensure-venv.sh`.

### Fixed
- SessionStart hook checks the venv's yt-dlp and the DeepSeek key, and stays silent when ready (it used to look for yt-dlp on PATH and nag about optional Whisper keys).

### Added
- Library index `~/Documents/claude-video-reports/INDEX.md`, rebuilt from report frontmatter after every `/watch-video` run (`scripts/library.py index` by hand). Reports gain `summary` and `topics` fields from one extra short text call; a failed call never fails the run.
- `/watch:recall <question>` skill: Haiku triages the index, grep finds literal terms, then only the matching reports are read.
- Scene-change frame extraction in `scripts/frames.py` — `extract_scene_change()` uses ffmpeg's `select=gt(scene,0.3)` filter to emit one frame per detected shot instead of uniform every-N-seconds sampling, keeping token cost flat on long videos. Always emits frame 0 (the scene filter only fires on *changes*). Falls back to uniform sampling when fewer than 10 scenes are detected (static/screen-recorded sources). Adapted from [taoufik123-collab/claude-watch](https://github.com/taoufik123-collab/claude-watch) v0.2.0.
- `--no-scene-change` flag on `scripts/watch.py` to force uniform sampling.

- Time-aligned `## Timeline` section in the report — frames and transcript lines are merged in chronological order so the model can see what's on screen as each line is spoken. Replaces the standalone transcript block; the `## Frames` path list (for the Read tool) is unchanged.
- Windowed processing for long videos in `scripts/watch_vision.py` — past 10 min (configurable via `$WATCH_WINDOW_SECONDS`), the harness probes duration (new `watch.py --probe`) and processes the video in 10-minute windows, each with its own dense per-shot budget, appending per-window findings to the report and ending with a cross-window `## Summary`. Avoids squeezing an hour-long video into a single 100-frame "sparse scan." Explicit `--start`/`--end` ranges skip windowing.
- `--cleanup` flag on `watch-video.sh` / `watch_vision.py` — removes the extracted-frames working dir after the report is written. `--drop-video` (or `WATCH_DROP_VIDEO=1`) also deletes the downloaded video, keeping subtitles, metadata and reports.
- YAML frontmatter on every `/watch-video` report (title, source, video_id, channel, duration, uploaded, watched, model, question, tags) so reports can be indexed.
- Plugin skill `skills/watch-video/SKILL.md` (paths via `${CLAUDE_PLUGIN_ROOT}`); plugin version 0.2.0.
- `--scene-change` flag on `scripts/watch.py` — forces scene-change sampling even inside a focused range (used by windowed passes); its uniform fallback now uses the denser focused budget when a range is set.
- `--probe` flag on `scripts/watch.py` — prints `{duration_seconds, title}` as JSON and exits without extracting frames (used to plan windows).

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
