#!/usr/bin/env python3
"""Where a video and its reports live on disk.

Layout:  <root>/<dd-mm-yyyy>/<slug>/
           video.mp4, video.*.vtt, video.info.json, .complete, .source
           report.md (report-2.md, ... on later runs)

<root> is ~/Documents/claude-video-reports (override: $WATCH_LIBRARY_DIR, or
the older $WATCH_CACHE_DIR). <dd-mm-yyyy> is the date the video was first
downloaded ($WATCH_DATE overrides "today"; watch-video.sh sets it). A video
already in the library under any date is reused from that folder rather than
downloaded again.

CLI:  library.py dir <source>      print the folder for <source> (creates it)
      library.py report <source>   print a fresh report path inside it
"""
from __future__ import annotations

import hashlib
import os
import re
import sys
from datetime import date
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SOURCE_MARKER = ".source"
_YT_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")


def root() -> Path:
    override = os.environ.get("WATCH_LIBRARY_DIR") or os.environ.get("WATCH_CACHE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Documents" / "claude-video-reports"


def today() -> str:
    return os.environ.get("WATCH_DATE") or date.today().strftime("%d-%m-%Y")


def _is_url(source: str) -> bool:
    parsed = urlparse(source)
    return parsed.scheme in ("http", "https") and bool(parsed.netloc)


def _youtube_id(url: str) -> str | None:
    p = urlparse(url)
    host = p.netloc.lower().removeprefix("www.").removeprefix("m.")
    if host == "youtu.be":
        cand = p.path.strip("/").split("/")[0]
    elif host.endswith("youtube.com"):
        parts = [s for s in p.path.split("/") if s]
        if parts and parts[0] in ("shorts", "live", "embed", "v") and len(parts) > 1:
            cand = parts[1]
        else:
            cand = (parse_qs(p.query).get("v") or [""])[0]
    else:
        return None
    return cand if _YT_ID.match(cand or "") else None


def _clean(text: str, limit: int = 60) -> str:
    text = re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-.")
    return text[:limit] or "video"


def source_key(source: str) -> str:
    """Stable identity for a source, so ?t=… / ?si=… variants share one folder."""
    if _is_url(source):
        yt = _youtube_id(source)
        return f"youtube:{yt}" if yt else source
    return str(Path(source).expanduser().resolve())


def slug(source: str) -> str:
    if _is_url(source):
        yt = _youtube_id(source)
        if yt:
            return yt
        p = urlparse(source)
        host = p.netloc.lower().removeprefix("www.").split(".")[0]
        tail = [s for s in p.path.split("/") if s]
        h = hashlib.sha256(source.encode("utf-8")).hexdigest()[:8]
        return _clean(f"{host}-{tail[-1]}" if tail else f"{host}-{h}")
    return _clean(Path(source).stem)


def find_existing(source: str) -> Path | None:
    base = root()
    if not base.is_dir():
        return None
    key = source_key(source)
    name = slug(source)
    for marker in sorted(base.glob(f"*/{name}*/{SOURCE_MARKER}")):
        try:
            if marker.read_text(encoding="utf-8").strip() == key:
                return marker.parent
        except OSError:
            continue
    return None


def video_dir(source: str, reuse: bool = True) -> Path:
    """Existing folder for this source, else a new one under today's date."""
    if reuse:
        hit = find_existing(source)
        if hit is not None:
            return hit
    key = source_key(source)
    day = root() / today()
    name = slug(source)
    d = day / name
    n = 2
    # A different source with the same slug already owns this name today.
    while (d / SOURCE_MARKER).exists() and (d / SOURCE_MARKER).read_text(encoding="utf-8").strip() != key:
        d = day / f"{name}-{n}"
        n += 1
    d.mkdir(parents=True, exist_ok=True)
    (d / SOURCE_MARKER).write_text(key, encoding="utf-8")
    return d


def report_path(source: str) -> Path:
    d = video_dir(source)
    p = d / "report.md"
    n = 2
    while p.exists():
        p = d / f"report-{n}.md"
        n += 1
    return p


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("dir", "report"):
        print("usage: library.py dir|report <url-or-path>", file=sys.stderr)
        raise SystemExit(2)
    fn = video_dir if sys.argv[1] == "dir" else report_path
    print(fn(sys.argv[2]))
