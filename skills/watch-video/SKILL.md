---
name: watch-video
description: >
  Watch a video (YouTube, Vimeo, TikTok, X, Twitch, a local file, or any
  yt-dlp URL) by delegating every frame to the DeepSeek vision model.
  watch_vision.py downloads with yt-dlp, extracts time-stamped frames with
  ffmpeg, pulls a transcript, sends the JPEGs to DeepSeek, and writes a
  markdown report that you read and summarize.
  Use when the user pastes a video URL, points at a local video file, asks to
  watch / analyze / summarize a video or extract on-screen code from a
  recording, or runs /watch-video.
argument-hint: "<video-url-or-path> [question]"
allowed-tools: Bash, Read, AskUserQuestion
user-invocable: true
---

# /watch-video — DeepSeek watches, you report

**DeepSeek is the only model that looks at frames.** `watch_vision.py`
downloads the video, extracts JPEGs, base64s them straight to
`https://api.deepseek.com/chat/completions` as native image content, and writes
a markdown analysis. Your job is to run it and read the report.

## Hard rule: never Read a frame JPEG

Do **not** `Read` any file under a `frames/` directory, and do not open the
work dir to "check" what DeepSeek saw. If the report is thin, wrong, or the run
fails, fix it by re-running with different flags (a focused range,
`--resolution 1024`, a sharper question) — never by looking at the frames
yourself. The only file you read is the report.

This holds even when the user asks a follow-up you think you could answer
faster by glancing at a frame. Re-run the tool against the range in question.

## Paths

| What | Path |
|------|------|
| Launcher (pins today's date, runs the harness in the venv) | `${CLAUDE_PLUGIN_ROOT}/scripts/watch-video.sh` |
| Vision harness | `${CLAUDE_PLUGIN_ROOT}/scripts/watch_vision.py` |
| Python | `${CLAUDE_PLUGIN_ROOT}/.venv/bin/python` — uv-managed; never use system `python3` or pip-install anything |
| Keys | `~/.config/watch/.env` (mode 0600) |
| Library (videos + reports) | `~/Documents/claude-video-reports/<yyyy-mm-dd>/<video-id>/` |

`yt-dlp` comes from the project venv (it needs `curl_cffi`). If the venv is
missing, run `${CLAUDE_PLUGIN_ROOT}/scripts/ensure-venv.sh` (uses uv; never
touches system Python).

## Configuration

| Var | Default | Notes |
|-----|---------|-------|
| `DEEPSEEK_API_KEY` | — | **required**; lives in `~/.config/watch/.env` |
| `DEEPSEEK_BASE_URL` | `https://api.deepseek.com` | |
| `DEEPSEEK_VISION_MODEL` | `deepseek-v4-flash-vision-exp` | |
| `WATCH_LIBRARY_DIR` | `~/Documents/claude-video-reports` | library root |
| `WATCH_ANALYSIS_OUT` | `report.md` next to the video | leave unset |
| `WATCH_WINDOW_SECONDS` | `600` | window size for long videos |
| `WATCH_VISION_MAX_RETRIES` | `2` | per-request retries |
| `WATCH_DROP_VIDEO` | unset | `1` = always delete the video after the report |

Frames are batched to stay under DeepSeek's body limit: max 80 images or
~18 MB of raw JPEG per request, whichever comes first.

## Procedure

### 1. Parse input

Split the source (URL or path) from the optional question. Multiple URLs →
one run per URL. If the user gave no question, let the script use its default
(structured analysis with timestamps) or pass a sharper one yourself.

### 2. Preflight (silent on success, once per session)

```bash
test -x "${CLAUDE_PLUGIN_ROOT}/.venv/bin/python" && echo VENV:OK || echo VENV:MISSING
(command -v ffmpeg || ls /opt/homebrew/bin/ffmpeg) >/dev/null 2>&1 && echo FFMPEG:OK || echo FFMPEG:MISSING
(grep -qE '^DEEPSEEK_API_KEY=.+' ~/.config/watch/.env 2>/dev/null \
  || [ -n "${DEEPSEEK_API_KEY:-}" ]) && echo KEY:OK || echo KEY:MISSING
```

- `VENV:MISSING` → run `${CLAUDE_PLUGIN_ROOT}/scripts/ensure-venv.sh`.
- `FFMPEG:MISSING` → `brew install ffmpeg`.
- `KEY:MISSING` → **stop**. Tell the user to set `DEEPSEEK_API_KEY` in
  `~/.config/watch/.env`. Do not invent a key, and do not fall back to reading
  frames yourself — that defeats the point of this skill.
- Whisper keys (`GROQ_API_KEY` / `OPENAI_API_KEY`) may be blank; transcripts
  then come from native captions only. Do not block on it. If a video has no
  captions, DeepSeek works frames-only and the report will say so; mention it
  and offer to set up a Groq key (console.groq.com/keys).

### 3. Run the harness in the background

It downloads, extracts, and makes several vision calls — minutes, not seconds.
Use `run_in_background: true`.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/watch-video.sh" \
  "<source>" "<question>" --cleanup -- --resolution 1024
```

- The launcher checks today's date first. A new video downloads into
  `~/Documents/claude-video-reports/<yyyy-mm-dd>/<video-id>/` and the report
  is written next to it as `report.md` (`report-2.md`, … on re-runs). A video
  already in the library under an earlier date is reused from that folder.
- Each report starts with YAML frontmatter (title, source, channel, duration,
  uploaded, watched, model, question, tags) for indexing.
- `--cleanup` removes the extracted frames once the report is written. Prefer
  it — you are never going to read those JPEGs.
- `--drop-video` also deletes the downloaded video afterwards (subtitles,
  metadata and reports stay). Use it when the user wants to save disk space.
- **Everything after `--` is passed through to `watch.py`**: `--resolution
  1024` (keep this; on-screen code is unreadable at the 512px default),
  `--start 1:00 --end 2:00`, `--max-frames 40`, `--no-cache`, `--no-whisper`.
- Long videos are windowed automatically into `WATCH_WINDOW_SECONDS` passes,
  each with its own dense frame budget, appended to the report as they finish;
  a final `## Summary` section synthesizes across windows.
- A `--start`/`--end` range skips windowing and densifies frames for that
  slice.
- Tell the user the job started and where the report will land, then get on
  with other work.

### 4. Multiple URLs

One background job per URL (each gets its own library folder). Cap at
~4 concurrent; queue the rest. Summarize each as it finishes rather than
waiting for the whole batch, unless the user asked for a combined write-up.

### 5. When the job finishes

The script prints the report path on stdout. Then:

1. `Read` the report (the report only).
2. Lead with a direct answer if the user asked something specific, citing the
   `[MM:SS]` timestamps DeepSeek recorded.
3. Otherwise summarize: overview, key moments, notable visuals, and any
   code/commands — verbatim, in fenced blocks.
4. Give the user the report path for the full detail; do not paste it whole.

Attribute visual claims to the report. If DeepSeek's notes are vague about
something the user cares about, say so and offer a focused re-run rather than
filling the gap with your own guess.

## Follow-ups

If the report for this video is already in context, answer from it. Re-run only
for a different time range, a higher resolution, a fresh download
(`--no-cache`), or a genuinely different question.

## Failure modes

| Symptom | Action |
|---------|--------|
| `set DEEPSEEK_API_KEY in the environment…` | stop; ask the user to fill `~/.config/watch/.env` |
| HTTP 401 / 404 model not found | report it verbatim; the model slug may not be served on this account — do not silently swap models |
| HTTP 413 / body too large | lower `--max-frames`, or drop `--resolution` to 512 |
| Rate limit after internal retries | wait and re-run; raise `WATCH_VISION_MAX_RETRIES` if it is chronic |
| `missing project venv` / `yt-dlp not found` | run `${CLAUDE_PLUGIN_ROOT}/scripts/ensure-venv.sh` |
| Login / region / age gate | surface the yt-dlp error verbatim; do not retry in a loop |
| Report written but empty/garbled sections | re-run that window with `--start`/`--end` and a sharper question |
| On-screen code illegible in the report | re-run the range at `--resolution 1024` (or 1280) |

If the harness fails outright, say so and stop. Reading the frames yourself is
not the fallback — the user asked for DeepSeek to be the only pair of eyes.

## Security notes

- JPEG frames and transcript text go to `api.deepseek.com`. The video file
  itself is never uploaded there.
- Only extracted audio goes to a Whisper API, and only when captions are
  missing and `--no-whisper` was not passed.
- No platform login, cookies, or posting.
- Keys live in `~/.config/watch/.env` (mode 0600). Never echo them to the
  user, into reports, or into shell output.
