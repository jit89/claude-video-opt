#!/usr/bin/env python3
"""Watch a video with DeepSeek V4 Flash Vision Exp.

Runs watch.py (download / frames / transcript), then sends the JPEGs plus
timeline to https://api.deepseek.com as native image content. Long videos
are split into WATCH_WINDOW_SECONDS windows.

Usage:
  watch_vision.py <url-or-path> ["question"] [--cleanup] [--drop-video] [-- extra watch.py flags]

  --cleanup     remove extracted frames once the report is written
  --drop-video  delete the downloaded video afterwards (keeps subtitles,
                metadata and reports; also on via WATCH_DROP_VIDEO=1)
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
from pathlib import Path
from urllib.request import Request, urlopen


SCRIPT_DIR = Path(__file__).parent.resolve()
WATCH_PY = SCRIPT_DIR / "watch.py"
sys.path.insert(0, str(SCRIPT_DIR))
import library  # noqa: E402
CONFIG_FILE = Path.home() / ".config" / "watch" / ".env"
HOUSE_ENV = Path.home() / "grok-coding-workflow" / ".env"

DEFAULT_BASE = "https://api.deepseek.com"
DEFAULT_MODEL = "deepseek-v4-flash-vision-exp"
DEFAULT_QUESTION = (
    "Give a structured analysis: what happens, the key visual moments with "
    "timestamps, and the overall topic."
)
DEFAULT_WINDOW = 600
# Raw JPEG budget so base64 + JSON stay under DeepSeek's 48 MiB body limit.
MAX_RAW_BYTES = 18 * 1024 * 1024
MAX_IMAGES = 80
HTTP_TIMEOUT = 600
FRAME_RE = re.compile(r"^- `(.+?)` \(t=([^)]+)\)\s*$")


def _from_dotenv(path: Path, name: str) -> str | None:
    if not path.is_file():
        return None
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, raw = line.partition("=")
            if key.strip() != name:
                continue
            raw = raw.strip()
            if len(raw) >= 2 and raw[0] in ('"', "'") and raw[-1] == raw[0]:
                raw = raw[1:-1]
            return raw or None
    except OSError:
        return None
    return None


def load_var(name: str, default: str = "") -> str:
    val = os.environ.get(name)
    if val and val.strip():
        return val.strip()
    for path in (CONFIG_FILE, HOUSE_ENV):
        got = _from_dotenv(path, name)
        if got:
            return got
    return default


def load_api_key() -> str:
    key = load_var("DEEPSEEK_API_KEY")
    if not key:
        raise SystemExit(
            "set DEEPSEEK_API_KEY in the environment, "
            f"{CONFIG_FILE}, or {HOUSE_ENV}"
        )
    return key


def fmt_mmss(seconds: int) -> str:
    seconds = max(0, int(seconds))
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h:d}:{m:02d}:{s:02d}"
    return f"{m:02d}:{s:02d}"


def parse_watch_report(text: str) -> tuple[list[tuple[str, str]], str]:
    """Return ([(path, timestamp_label), ...], timeline_markdown)."""
    frames: list[tuple[str, str]] = []
    in_frames = False
    timeline_start = None
    for i, line in enumerate(text.splitlines()):
        if line.strip() == "## Frames":
            in_frames = True
            continue
        if line.startswith("## ") and in_frames and line.strip() != "## Frames":
            in_frames = False
        if in_frames:
            m = FRAME_RE.match(line)
            if m:
                frames.append((m.group(1), m.group(2)))
        if line.startswith("## Timeline"):
            timeline_start = i
            break
    timeline = ""
    if timeline_start is not None:
        timeline = "\n".join(text.splitlines()[timeline_start:])
    return frames, timeline


def run_watch(source: str, extra: list[str], out_dir: Path) -> str:
    cmd = [
        sys.executable,
        str(WATCH_PY),
        source,
        "--out-dir",
        str(out_dir),
        *extra,
    ]
    print(f"[watch-vision] {' '.join(cmd)}", file=sys.stderr)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.stderr:
        sys.stderr.write(proc.stderr)
        if not proc.stderr.endswith("\n"):
            sys.stderr.write("\n")
    if proc.returncode != 0:
        raise SystemExit(f"watch.py failed (exit {proc.returncode})")
    return proc.stdout


def probe_duration(source: str, extra: list[str], work: Path) -> int | None:
    cmd = [
        sys.executable,
        str(WATCH_PY),
        source,
        "--probe",
        "--out-dir",
        str(work / "probe"),
    ]
    if "--no-cache" in extra:
        cmd.append("--no-cache")
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    try:
        data = json.loads(proc.stdout.strip().splitlines()[-1])
        return int(float(data["duration_seconds"]))
    except (json.JSONDecodeError, KeyError, ValueError, IndexError):
        return None


def jpeg_data_url(path: str) -> str:
    raw = Path(path).read_bytes()
    b64 = base64.b64encode(raw).decode("ascii")
    return f"data:image/jpeg;base64,{b64}"


def pack_batches(
    frames: list[tuple[str, str]],
) -> list[list[tuple[str, str]]]:
    if not frames:
        return [[]]
    batches: list[list[tuple[str, str]]] = []
    cur: list[tuple[str, str]] = []
    size = 0
    for path, ts in frames:
        try:
            n = Path(path).stat().st_size
        except OSError:
            continue
        if cur and (len(cur) >= MAX_IMAGES or size + n > MAX_RAW_BYTES):
            batches.append(cur)
            cur, size = [], 0
        cur.append((path, ts))
        size += n
    if cur:
        batches.append(cur)
    return batches or [[]]


def chat(
    *,
    key: str,
    base: str,
    model: str,
    messages: list[dict],
    max_retries: int,
) -> str:
    url = base.rstrip("/") + "/chat/completions"
    body = json.dumps(
        {
            "model": model,
            "messages": messages,
            "thinking": {"type": "enabled"},
            "reasoning_effort": "high",
        }
    ).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {key}",
        "Accept": "application/json",
    }
    ctx = ssl.create_default_context()
    last_err = ""
    for attempt in range(1, max_retries + 1):
        req = Request(url, data=body, headers=headers, method="POST")
        try:
            with urlopen(req, timeout=HTTP_TIMEOUT, context=ctx) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            err_body = exc.read().decode("utf-8", errors="replace")[:800]
            last_err = f"HTTP {exc.code}: {err_body}"
            retryable = exc.code in (408, 409, 429, 500, 502, 503, 504)
            if retryable and attempt < max_retries:
                backoff = 10 * attempt
                print(
                    f"[watch-vision] {last_err[:120]} — retry {attempt}/{max_retries} in {backoff}s",
                    file=sys.stderr,
                )
                time.sleep(backoff)
                continue
            raise SystemExit(f"DeepSeek vision failed: {last_err}") from exc
        except urllib.error.URLError as exc:
            last_err = str(exc.reason or exc)
            if attempt < max_retries:
                backoff = 10 * attempt
                print(
                    f"[watch-vision] {last_err} — retry {attempt}/{max_retries} in {backoff}s",
                    file=sys.stderr,
                )
                time.sleep(backoff)
                continue
            raise SystemExit(f"DeepSeek vision failed: {last_err}") from exc

        try:
            msg = payload["choices"][0]["message"]
        except (KeyError, IndexError, TypeError) as exc:
            raise SystemExit(f"DeepSeek vision: unexpected response: {payload!r}") from exc
        content = msg.get("content") or ""
        if isinstance(content, list):
            content = "".join(
                (p.get("text") or "") if isinstance(p, dict) else str(p) for p in content
            )
        if not str(content).strip():
            raise SystemExit("DeepSeek vision returned empty content")
        return str(content).strip()
    raise SystemExit(f"DeepSeek vision failed: {last_err}")


def analyze_batch(
    *,
    key: str,
    base: str,
    model: str,
    question: str,
    heading: str,
    timeline: str,
    batch: list[tuple[str, str]],
    max_retries: int,
    part: str = "",
) -> str:
    text_parts = [
        "You are analyzing frames from a video plus its time-aligned transcript.",
        f"Section: {heading}{part}.",
        "Each image is labeled with its absolute timestamp t=MM:SS.",
        "Cite timestamps. Quote on-screen or spoken code/commands verbatim in fenced blocks.",
        "",
        f"User question: {question}",
        "",
    ]
    if timeline.strip():
        text_parts.append(timeline.strip())
        text_parts.append("")
    if batch:
        text_parts.append("Frames in this request, in order:")
        for i, (_path, ts) in enumerate(batch, 1):
            text_parts.append(f"  {i}. t={ts}")
    else:
        text_parts.append("No frames were extracted for this slice; use the transcript.")

    content: list[dict] = [{"type": "text", "text": "\n".join(text_parts)}]
    for path, ts in batch:
        content.append({"type": "text", "text": f"Frame t={ts}"})
        content.append(
            {
                "type": "image_url",
                "image_url": {"url": jpeg_data_url(path), "detail": "high"},
            }
        )
    print(
        f"[watch-vision] {heading}{part}: {len(batch)} image(s) → {model}",
        file=sys.stderr,
    )
    return chat(
        key=key,
        base=base,
        model=model,
        messages=[{"role": "user", "content": content}],
        max_retries=max_retries,
    )


def analyze_slice(
    *,
    key: str,
    base: str,
    model: str,
    question: str,
    heading: str,
    report_text: str,
    max_retries: int,
) -> str:
    frames, timeline = parse_watch_report(report_text)
    batches = pack_batches(frames)
    chunks: list[str] = []
    n = len(batches)
    for i, batch in enumerate(batches, 1):
        part = f" (part {i}/{n})" if n > 1 else ""
        chunks.append(
            analyze_batch(
                key=key,
                base=base,
                model=model,
                question=question,
                heading=heading,
                timeline=timeline if i == 1 else "",
                batch=batch,
                max_retries=max_retries,
                part=part,
            )
        )
    if len(chunks) == 1:
        return chunks[0]
    return "\n\n".join(f"### Part {i}/{n}\n\n{c}" for i, c in enumerate(chunks, 1))


def append_report(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    existing = path.read_text(encoding="utf-8") if path.is_file() else ""
    if existing and not existing.endswith("\n"):
        existing += "\n"
    path.write_text(existing + text + ("\n" if not text.endswith("\n") else ""), encoding="utf-8")


def extra_has_range(extra: list[str]) -> bool:
    return "--start" in extra or "--end" in extra


def parse_args(argv: list[str]) -> argparse.Namespace:
    cleanup = False
    drop_video = os.environ.get("WATCH_DROP_VIDEO", "") in ("1", "true", "yes")
    kept: list[str] = []
    for i, a in enumerate(argv):
        if a == "--":
            kept.extend(argv[i:])
            break
        if a == "--cleanup":
            cleanup = True
        elif a == "--drop-video":
            drop_video = True
        else:
            kept.append(a)

    extra: list[str] = []
    if "--" in kept:
        i = kept.index("--")
        extra = kept[i + 1 :]
        kept = kept[:i]

    p = argparse.ArgumentParser(
        prog="watch_vision.py",
        description="Watch a video with DeepSeek V4 Flash Vision Exp.",
        epilog="Extra watch.py flags go after --  e.g. -- --resolution 1024",
    )
    p.add_argument("source", help="Video URL or local path")
    p.add_argument(
        "question",
        nargs="?",
        default=DEFAULT_QUESTION,
        help="What to look for (default: structured analysis)",
    )
    args = p.parse_args(kept)
    args.cleanup = cleanup
    args.drop_video = drop_video
    args.extra = extra
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    key = load_api_key()
    base = load_var("DEEPSEEK_BASE_URL", DEFAULT_BASE)
    model = load_var("DEEPSEEK_VISION_MODEL", DEFAULT_MODEL) or DEFAULT_MODEL
    # Default: next to the downloaded video, in
    # ~/Documents/claude-video-reports/<yyyy-mm-dd>/<slug>/report.md
    # Pin the date once so watch.py subprocesses use the same dated folder.
    os.environ.setdefault("WATCH_DATE", library.today())
    out_override = os.environ.get("WATCH_ANALYSIS_OUT")
    out_file = (
        Path(out_override).expanduser() if out_override else library.report_path(args.source)
    )
    window = int(os.environ.get("WATCH_WINDOW_SECONDS") or DEFAULT_WINDOW)
    max_retries = int(os.environ.get("WATCH_VISION_MAX_RETRIES") or "2")
    extra = list(args.extra)

    work = Path(tempfile.mkdtemp(prefix="watch-vision-work-"))
    print(f"[watch-vision] model={model} base={base}", file=sys.stderr)
    if not args.cleanup:
        print(f"[watch-vision] frames kept in {work} (pass --cleanup to remove)", file=sys.stderr)

    try:
        focused = extra_has_range(extra)
        dur = None if focused else probe_duration(args.source, extra, work)
        if dur is not None:
            # The probe already did any forced re-download; don't repeat it
            # for every window.
            extra = [a for a in extra if a != "--no-cache"]
        windows: list[tuple[int | None, int | None, Path, str]]
        if dur is not None and dur > window:
            n = 0
            s = 0
            windows = []
            while s < dur:
                e = min(s + window, dur)
                heading = f"{fmt_mmss(s)}–{fmt_mmss(e)}"
                windows.append((s, e, work / f"win_{n}", heading))
                s = e
                n += 1
            print(
                f"[watch-vision] long video ({dur}s) → {n} window(s) of {window}s",
                file=sys.stderr,
            )
        else:
            windows = [(None, None, work / "full", "full")]

        header = [
            "# Watch report",
            "",
            f"- **Source:** {args.source}",
            f"- **Model:** `{model}`",
            f"- **Question:** {args.question}",
            "",
        ]
        out_file.write_text("\n".join(header), encoding="utf-8")

        window_notes: list[str] = []
        for start, end, out_dir, heading in windows:
            flags = list(extra)
            if start is not None and end is not None:
                flags.extend(
                    [
                        "--start",
                        str(start),
                        "--end",
                        str(end),
                        "--scene-change",
                    ]
                )
            report = run_watch(args.source, flags, out_dir)
            body = analyze_slice(
                key=key,
                base=base,
                model=model,
                question=args.question,
                heading=heading,
                report_text=report,
                max_retries=max_retries,
            )
            section = f"## [{heading}]\n\n{body}\n"
            append_report(out_file, section)
            window_notes.append(f"## [{heading}]\n\n{body}")

        if len(windows) > 1:
            synth_prompt = (
                "Synthesise the per-window notes below into a final ## Summary that answers:\n"
                f"{args.question}\n\n"
                "Cite timestamps. Do not invent visuals that are not in the notes.\n\n"
                + "\n\n".join(window_notes)
            )
            print("[watch-vision] writing summary across windows", file=sys.stderr)
            summary = chat(
                key=key,
                base=base,
                model=model,
                messages=[{"role": "user", "content": synth_prompt}],
                max_retries=max_retries,
            )
            append_report(out_file, f"## Summary\n\n{summary}\n")

        # Prepend YAML frontmatter now that the download (and its metadata)
        # exists, so reports can be indexed into a knowledge base later.
        meta = library.metadata(args.source)
        fields = {
            "title": meta["title"],
            "source": meta["url"],
            "video_id": meta["video_id"],
            "channel": meta["channel"],
            "duration": fmt_mmss(int(meta["duration"])) if meta["duration"] else None,
            "uploaded": meta["uploaded"],
            "watched": os.environ["WATCH_DATE"],
            "model": model,
            "question": args.question,
            "tags": meta["tags"],
        }
        body = out_file.read_text(encoding="utf-8")
        if meta["title"]:
            body = body.replace("# Watch report", f"# {meta['title']}", 1)
        out_file.write_text(library.frontmatter(fields) + body, encoding="utf-8")

        if args.drop_video:
            removed = library.drop_video(args.source)
            if removed:
                print(f"[watch-vision] deleted video: {removed}", file=sys.stderr)

        print(str(out_file))
        return 0
    finally:
        if args.cleanup:
            try:
                import shutil

                shutil.rmtree(work, ignore_errors=True)
                print(f"[watch-vision] cleaned up frames: {work}", file=sys.stderr)
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
