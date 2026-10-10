#!/usr/bin/env python3
"""Where a video and its reports live on disk.

Layout:  <root>/<yyyy-mm-dd>/<slug>/
           video.mp4, video.*.vtt, video.info.json, .complete, .source
           report.md (report-2.md, ... on later runs)

<root> is ~/Documents/claude-video-reports (override: $WATCH_LIBRARY_DIR, or
the older $WATCH_CACHE_DIR). <yyyy-mm-dd> is the date the video was first
downloaded ($WATCH_DATE overrides "today"; watch-video.sh sets it). A video
already in the library under any date is reused from that folder rather than
downloaded again.

<root>/INDEX.md lists every report (title, channel, summary, topics, path),
newest first, for quick triage before opening full reports.

CLI:  library.py dir <source>      print the folder for <source> (creates it)
      library.py report <source>   print a fresh report path inside it
      library.py index             rebuild <root>/INDEX.md
"""
from __future__ import annotations

import hashlib
import json
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
    return os.environ.get("WATCH_DATE") or date.today().isoformat()


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


def video_dir(source: str) -> Path:
    """Existing folder for this source, else a new one under today's date."""
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


VIDEO_EXTS = {".mp4", ".mkv", ".webm", ".mov", ".m4v", ".avi", ".flv", ".wmv"}


def metadata(source: str) -> dict:
    """Title, channel, duration, etc. from the library's video.info.json."""
    d = find_existing(source)
    raw: dict = {}
    if d is not None and (d / "video.info.json").is_file():
        try:
            raw = json.loads((d / "video.info.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raw = {}
    up = raw.get("upload_date") or ""
    return {
        "title": raw.get("title") or (Path(source).name if not _is_url(source) else None),
        "channel": raw.get("channel") or raw.get("uploader"),
        "url": raw.get("webpage_url") or source,
        "video_id": raw.get("id") or slug(source),
        "duration": raw.get("duration"),
        "uploaded": f"{up[:4]}-{up[4:6]}-{up[6:8]}" if len(up) == 8 else None,
        "tags": [str(x) for x in (raw.get("tags") or [])][:10],
    }


def frontmatter(fields: dict) -> str:
    """YAML frontmatter; values are JSON-encoded, which YAML reads as-is."""
    lines = ["---"]
    for k, v in fields.items():
        if v is None or v == []:
            continue
        lines.append(f"{k}: {json.dumps(v, ensure_ascii=False)}")
    lines.append("---")
    return "\n".join(lines) + "\n\n"


def read_frontmatter(path: Path) -> dict:
    """Parse the frontmatter written by frontmatter(); {} if there is none."""
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return {}
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---\n", 3)
    if end == -1:
        return {}
    out: dict = {}
    for line in text[4:end].splitlines():
        k, sep, v = line.partition(": ")
        if not sep:
            continue
        try:
            out[k.strip()] = json.loads(v)
        except ValueError:
            out[k.strip()] = v.strip()
    return out


def _first_heading(path: Path) -> str | None:
    try:
        with path.open(encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("# "):
                    return line[2:].strip()
    except (OSError, UnicodeDecodeError):
        pass
    return None


INDEX_NAME = "INDEX.md"


def rebuild_index() -> Path | None:
    """Regenerate <root>/INDEX.md from every report's frontmatter.

    Rebuilt from scratch each time (not appended), so re-runs, deleted
    reports and edited summaries never leave stale lines. Written via a temp
    file + rename so a concurrent reader never sees a half-written index.
    """
    base = root()
    if not base.is_dir():
        return None
    entries = []
    for rp in base.glob("*/*/report*.md"):
        fm = read_frontmatter(rp)
        rel = rp.relative_to(base).as_posix()
        topics = fm.get("topics") or fm.get("tags") or []
        if not isinstance(topics, list):
            topics = [topics]
        entries.append(
            {
                "watched": str(fm.get("watched") or rp.parent.parent.name),
                "title": fm.get("title") or _first_heading(rp) or rp.parent.name,
                "channel": fm.get("channel"),
                "duration": fm.get("duration"),
                "summary": fm.get("summary"),
                "topics": topics,
                "question": fm.get("question"),
                "path": rel,
                "complete": bool(fm),
            }
        )
    # Newest first; path as a stable tie-breaker.
    entries.sort(key=lambda e: (e["watched"], e["path"]), reverse=True)

    lines = [
        "# Video library index",
        "",
        f"<!-- generated by scripts/library.py — do not edit; {len(entries)} report(s) -->",
        "Paths are relative to this file. One entry per report, newest first.",
    ]
    day = None
    for e in entries:
        if e["watched"] != day:
            day = e["watched"]
            lines += ["", f"## {day}"]
        meta = ", ".join(str(x) for x in (e["channel"], e["duration"]) if x)
        head = f"- **{e['title']}**" + (f" ({meta})" if meta else "") + f" — `{e['path']}`"
        lines.append(head)
        detail = []
        if e["summary"]:
            detail.append(" ".join(str(e["summary"]).split()))
        if e["topics"]:
            detail.append("Topics: " + ", ".join(str(t) for t in e["topics"][:10]) + ".")
        if e["question"]:
            q = " ".join(str(e["question"]).split())
            detail.append(f"Asked: {q[:117] + '...' if len(q) > 120 else q}")
        if not e["complete"]:
            detail.append("(no metadata — report may be incomplete)")
        if detail:
            lines.append("  " + " ".join(detail))

    index = base / INDEX_NAME
    tmp = base / f".{INDEX_NAME}.{os.getpid()}.tmp"
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp, index)
    return index


def drop_video(source: str) -> Path | None:
    """Delete the downloaded video file, keeping subtitles, metadata and reports.

    Only for URL downloads; a local source file is never touched. A later run
    re-downloads into the same folder.
    """
    if not _is_url(source):
        return None
    d = find_existing(source)
    if d is None:
        return None
    removed = None
    for f in d.glob("video.*"):
        if f.suffix.lower() in VIDEO_EXTS:
            f.unlink()
            removed = f
    (d / ".complete").unlink(missing_ok=True)
    return removed


if __name__ == "__main__":
    if sys.argv[1:] == ["index"]:
        print(rebuild_index() or f"no library at {root()}")
        raise SystemExit(0)
    if len(sys.argv) != 3 or sys.argv[1] not in ("dir", "report"):
        print("usage: library.py dir|report <url-or-path>  |  library.py index", file=sys.stderr)
        raise SystemExit(2)
    fn = video_dir if sys.argv[1] == "dir" else report_path
    print(fn(sys.argv[2]))
