#!/usr/bin/env python3
"""Download a video via yt-dlp, or resolve a local file path.

Also fetches subtitles (manual first, then auto-generated) in VTT format so
transcribe.py can parse them without needing Whisper.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import library  # noqa: E402


VIDEO_EXTS = {".mp4", ".mkv", ".webm", ".mov", ".m4v", ".avi", ".flv", ".wmv"}

# Sentinel written into a cache dir once a download finishes cleanly. We only
# treat a cache entry as a hit when this exists, so an interrupted/partial
# download is never served from cache.
CACHE_COMPLETE_MARKER = ".complete"


def is_url(source: str) -> bool:
    if source.startswith("-"):
        return False
    parsed = urlparse(source)
    return parsed.scheme in ("http", "https") and bool(parsed.netloc)


def resolve_local(path: str) -> dict:
    p = Path(path).expanduser().resolve()
    if not p.exists():
        raise SystemExit(f"File not found: {p}")
    if p.suffix.lower() not in VIDEO_EXTS:
        print(
            f"[watch] warning: {p.suffix} is not a known video extension, proceeding anyway",
            file=sys.stderr,
        )
    return {
        "video_path": str(p),
        "subtitle_path": None,
        "info": {"title": p.name, "url": str(p)},
        "downloaded": False,
    }


def _pick_subtitle(out_dir: Path) -> Path | None:
    candidates = sorted(out_dir.glob("video*.vtt"))
    if not candidates:
        return None
    preferred = [c for c in candidates if ".en" in c.name]
    return preferred[0] if preferred else candidates[0]


def _pick_video(out_dir: Path) -> Path | None:
    for ext in (".mp4", ".mkv", ".webm", ".mov"):
        for candidate in out_dir.glob(f"video*{ext}"):
            return candidate
    for candidate in out_dir.glob("video.*"):
        if candidate.suffix.lower() in VIDEO_EXTS:
            return candidate
    return None


def _result_from_dir(out_dir: Path, url: str) -> dict:
    """Build the download result dict from files already on disk in out_dir."""
    video = _pick_video(out_dir)
    subtitle = _pick_subtitle(out_dir)
    info_path = out_dir / "video.info.json"
    info: dict = {}
    if info_path.exists():
        try:
            raw = json.loads(info_path.read_text(encoding="utf-8"))
            info = {
                "title": raw.get("title"),
                "uploader": raw.get("uploader") or raw.get("channel"),
                "duration": raw.get("duration"),
                "url": raw.get("webpage_url") or url,
            }
        except Exception as exc:
            print(f"[watch] info.json parse failed: {exc}", file=sys.stderr)
            info = {"url": url}

    return {
        "video_path": str(video) if video else None,
        "subtitle_path": str(subtitle) if subtitle else None,
        "info": info or {"url": url},
        "downloaded": True,
    }


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def _venv_yt_dlp() -> Path:
    """yt-dlp from the project venv (curl_cffi lives there). Never system/brew PATH."""
    return _repo_root() / ".venv" / "bin" / "yt-dlp"


def yt_dlp_bin() -> str:
    venv = _venv_yt_dlp()
    if venv.is_file() and os.access(venv, os.X_OK):
        return str(venv)
    raise SystemExit(
        f"yt-dlp not found at {venv}. "
        f"Create the project venv (does not touch system Python): "
        f"{_repo_root() / 'scripts' / 'ensure-venv.sh'}"
    )


def download_url(url: str, out_dir: Path, use_cache: bool = True) -> dict:
    # Every URL download lands in the dated library folder
    # (~/Documents/claude-video-reports/<dd-mm-yyyy>/<slug>/). Check for an
    # existing copy first — a hit must not require yt-dlp to be installed.
    cache_dir = library.video_dir(url, reuse=use_cache)
    if use_cache and (cache_dir / CACHE_COMPLETE_MARKER).exists() and _pick_video(cache_dir):
        print(f"[watch] library hit — reusing {cache_dir}", file=sys.stderr)
        return _result_from_dir(cache_dir, url)
    (cache_dir / CACHE_COMPLETE_MARKER).unlink(missing_ok=True)
    out_dir = cache_dir
    print(f"[watch] downloading into {out_dir}", file=sys.stderr)

    ytdlp = yt_dlp_bin()

    out_dir.mkdir(parents=True, exist_ok=True)
    output_template = str(out_dir / "video.%(ext)s")

    impersonate = os.environ.get("WATCH_YTDLP_IMPERSONATE", "chrome").strip() or "chrome"
    print(f"[watch] yt-dlp={ytdlp} impersonate={impersonate}", file=sys.stderr)

    cmd = [
        ytdlp,
        "-N", "8",
        "-f", "bv*[height<=720]+ba/b[height<=720]/bv+ba/b",
        "--merge-output-format", "mp4",
        # curl_cffi Chrome impersonation so the web client can see DASH 720p
        # instead of SABR-only android/ios progressive 360p.
        "--impersonate", impersonate,
        # Do not pin android/ios/web: those clients are SABR-only (360p
        # progressive). Default clients + Chrome impersonation expose DASH ≤720p.
        "--write-info-json",
        "--write-subs",
        "--write-auto-subs",
        "--sub-langs", "en,en-US,en-GB,en-orig",
        "--sub-format", "vtt",
        "--convert-subs", "vtt",
        "--no-playlist",
        "--ignore-errors",
        "-o", output_template,
        "--",
        url,
    ]

    # yt-dlp may exit non-zero if a subtitle variant fails (e.g. 429) even when
    # the video itself downloaded fine. Treat "video file present" as success.
    result = subprocess.run(cmd, stdout=sys.stderr, stderr=sys.stderr)
    video = _pick_video(out_dir)
    if video is None:
        raise SystemExit(
            f"yt-dlp did not produce a video file in {out_dir} (exit {result.returncode})"
        )

    # Mark the cache entry complete only after a video file is confirmed present,
    # so a partial download is never served on a later run.
    (cache_dir / CACHE_COMPLETE_MARKER).write_text("ok", encoding="utf-8")

    return _result_from_dir(out_dir, url)


def download(source: str, out_dir: Path, use_cache: bool = True) -> dict:
    if is_url(source):
        return download_url(source, out_dir, use_cache=use_cache)
    return resolve_local(source)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: download.py <url-or-path> <out-dir>", file=sys.stderr)
        raise SystemExit(2)
    result = download(sys.argv[1], Path(sys.argv[2]))
    print(json.dumps(result, indent=2))
