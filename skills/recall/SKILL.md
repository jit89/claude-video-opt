---
name: recall
description: >
  Answer questions from the library of videos already watched with
  /watch-video — "which video showed…", "what did they say about…", "have we
  watched anything on…", "compare what those videos said about…". Triages the
  library index with a cheap model, then reads only the matching reports.
  Use when the user asks about a video they watched before, or runs
  /watch:recall.
argument-hint: "<question about videos already watched>"
allowed-tools: Bash, Read, Grep, Agent
user-invocable: true
---

# /watch:recall — search the videos we've watched

Every `/watch-video` run leaves a report in
`~/Documents/claude-video-reports/<yyyy-mm-dd>/<video-id>/report*.md`
(root overridable with `$WATCH_LIBRARY_DIR`), and the library keeps an index
at `~/Documents/claude-video-reports/INDEX.md`: one entry per report with
title, channel, duration, a 1–2 sentence summary, topics, the question that
was asked, and the report path (relative to the index).

Answer from the reports. Never re-watch a video or read frame images here; if
the library doesn't cover the question, say so and offer `/watch-video`.

## 1. Refresh the index

```bash
"${CLAUDE_PLUGIN_ROOT}/.venv/bin/python" "${CLAUDE_PLUGIN_ROOT}/scripts/library.py" index
```

It prints the index path (or `no library at …` → tell the user nothing has
been watched yet and stop). Rebuilding is cheap and picks up reports from
runs that were interrupted before they could update the index.

## 2. Triage and exact search — in parallel

Send both in the same turn:

**a. Triage with Haiku.** Use the Agent tool with `model: "haiku"`
(`subagent_type: "general-purpose"`, description "Triage video library") and
this prompt, filled in:

> Read `<index path>`. The user asks: "<question>". Pick the reports most
> likely to answer it — at most 5, best first. Judge by title, summary,
> topics and the question each report answered. Reply with only lines of the
> form `<path relative to the index> — <one-line reason>`, or the single word
> `NONE`. Do not open the reports themselves.

**b. Exact text search** — when the question names something literal (a
command, flag, product, person, number, quote), grep the reports for it:

```bash
grep -rniF --include='report*.md' -- "<literal term>" "<library dir>" | head -40
```

`<library dir>` is the folder holding the index from step 1. Skip (b) for
purely thematic questions.

## 3. Read and answer

1. Merge the candidates: Haiku's picks (paths are relative to the library
   dir) plus any report the grep hit, at most ~6. If both came back empty,
   read `INDEX.md` yourself once before concluding nothing matches.
   Reports vary a lot in size: a short clip is a few KB, a long video is
   split into 10-minute `## [MM:SS–MM:SS]` window sections and can pass
   100 KB. So check size first (`wc -c <report>`):
   - **Under ~40 KB** → read the whole report.
   - **Larger** → list its sections with
     `grep -n '^## ' <report>`, read the frontmatter and the final
     `## Summary`, then only the windows the question or a grep hit points
     to (Read with `offset`/`limit`).
2. Answer the question directly. For each claim, cite the video title, the
   `[MM:SS]` timestamp from the report when there is one, and the report path.
   Quote code or commands verbatim in fenced blocks.
3. When several videos are relevant, say how they agree or differ.
4. If the reports don't settle it, say what is missing and offer a focused
   `/watch-video <url> "<question>" -- --start … --end …` re-run of the most
   relevant video (its URL is `source:` in the report's frontmatter).

The reports were written by DeepSeek from frames and transcripts; attribute
visual claims to them rather than stating them as your own observations.
