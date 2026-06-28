#!/usr/bin/env python3
# Copyright 2026 Jim Zucker
# SPDX-License-Identifier: Apache-2.0
"""Summarize Claude Code session transcripts for this repo.

Reports token usage, prompt/turn counts, and active vs. idle time by parsing
the JSONL transcript(s) Claude Code stores under
``~/.claude/projects/<encoded-repo-path>/``.

Portable: the project name is auto-detected from the repo folder, so this file
can be dropped into any repo's ``scripts/`` directory unchanged.

Scope: the repo's own dir plus each session's ``subagents/*.jsonl`` and any
pre-rename ALIAS_PROJECT_DIRS (e.g. iyield -> TrueYield), so the totals cover the
whole project history, not just the current path.

Usage:
    python3 scripts/session_stats.py            # all transcripts for this repo
    python3 scripts/session_stats.py FILE.jsonl # a specific transcript
    python3 scripts/session_stats.py --also DIR # fold in another project dir
    python3 scripts/session_stats.py --idle 10  # idle gap threshold in minutes
    python3 scripts/session_stats.py --md       # write the Markdown report
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import sys

# Gaps longer than this (minutes) count as idle, not active work.
DEFAULT_IDLE_MIN = 5

# Prior encoded project-dir names to fold in alongside this repo's own dir, so
# the stats span the whole project history rather than just the current path.
# Set this only when a repo was renamed mid-build (Claude Code keys transcripts
# by path, so pre-rename sessions live under the old encoded name); leave empty
# ([]) for a repo that kept its name. Override at runtime with --also NAME.
ALIAS_PROJECT_DIRS = [
    "-Users-jimzucker-code-GitHub-iyield",  # pre-rename: iyield -> TrueYield
]

# Claude Opus 4.8 standard API rates, USD per million tokens. Source:
# Anthropic's official pricing docs, platform.claude.com/docs/en/about-claude/
# pricing (verified 2026-06). Opus dropped 3x from the old 4.x $15/$75
# starting with 4.5. The total is dominated by the cache-read rate, so that
# one matters most. Override with --rate-* for other models (e.g. Sonnet 4.6
# is $3/$15, cache read $0.30; Haiku 4.5 is $1/$5, cache read $0.10).
RATES = {
    "output": 25.0,      # base output
    "input": 5.0,        # base (uncached) input
    "cache_write": 6.25, # 5-min cache write = 1.25x input (1h write is $10)
    "cache_read": 0.50,  # cache hit/refresh = 0.10x input
}

# Loaded cost of one engineer-day, USD — used only for the ROI comparison.
DAY_RATE = 800


def repo_root() -> str:
    """The repo this script lives in (its parent of scripts/)."""
    return os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def project_name() -> str:
    return os.path.basename(repo_root())


def transcript_dir_for(repo_path: str) -> str:
    """Claude Code encodes the repo path by replacing '/' with '-'."""
    encoded = repo_path.replace("/", "-")
    return os.path.expanduser(f"~/.claude/projects/{encoded}")


def transcripts_in(d: str) -> list[str]:
    """Every transcript under one project dir: the top-level session files plus
    the per-session ``subagents/*.jsonl`` (sub-agent runs count toward the
    build's tokens/time too)."""
    return (glob.glob(os.path.join(d, "*.jsonl"))
            + glob.glob(os.path.join(d, "*", "subagents", "*.jsonl")))


def find_transcripts(args_paths: list[str], also: list[str]) -> list[str]:
    if args_paths:
        return args_paths
    base = os.path.dirname(transcript_dir_for(repo_root()))  # ~/.claude/projects
    dirs = [transcript_dir_for(repo_root())]
    dirs += [os.path.join(base, name) for name in (*ALIAS_PROJECT_DIRS, *also)]
    files: list[str] = []
    for d in dirs:
        files.extend(transcripts_in(d))
    files = sorted(set(files))
    if not files:
        sys.exit(f"No transcripts found in {dirs[0]}")
    return files


def load(path: str) -> list[dict]:
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def parse_ts(r: dict):
    t = r.get("timestamp")
    if not t:
        return None
    try:
        return dt.datetime.fromisoformat(t.replace("Z", "+00:00"))
    except ValueError:
        return None


def is_human_prompt(r: dict) -> bool:
    """A message the user actually typed (not a tool result / slash-command)."""
    if r.get("type") != "user" or r.get("isMeta"):
        return False
    content = r.get("message", {}).get("content")
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_result":
                return False
        text = " ".join(b.get("text", "") for b in content if isinstance(b, dict))
    elif isinstance(content, str):
        text = content
    else:
        return False
    if not text.strip():
        return False
    markers = ("<local-command", "<command-name>", "command-message")
    if any(m in text for m in markers):
        return False
    if "Caveat:" in text and len(text) < 400:
        return False
    return True


def hms(td: dt.timedelta) -> str:
    s = int(td.total_seconds())
    return f"{s // 3600}h {s % 3600 // 60}m {s % 60}s"


def costs(outp, inp, cc, cr, rates):
    """Return per-category USD cost plus the no-cache counterfactual."""
    c = {
        "output": outp / 1e6 * rates["output"],
        "input": inp / 1e6 * rates["input"],
        "cache_write": cc / 1e6 * rates["cache_write"],
        "cache_read": cr / 1e6 * rates["cache_read"],
    }
    c["total"] = sum(c.values())
    # If cache reads had been billed as normal input tokens.
    c["nocache_reads"] = cr / 1e6 * rates["input"]
    c["cache_savings"] = c["nocache_reads"] - c["cache_read"]
    return c


def write_markdown(path, project, files, n_rows, outp, inp, cc, cr, total,
                   prompts, turns, events, active, claude, user, idle, idle_min,
                   n_user_records, rates) -> None:
    """Write the full narrative report — the story, not just the tables."""
    cr_m = cr / 1e6
    out_m = outp / 1e6
    total_m = total / 1e6
    c = costs(outp, inp, cc, cr, rates)
    lines = [
        "# Build session story",
        "",
        f"The real numbers behind building **{project}**, pulled from this "
        f"project's Claude Code session transcript ({n_rows:,} records spanning "
        "the whole build). Regenerate with `python3 scripts/session_stats.py --md`.",
        "",
        "## Tokens",
        "",
        "| Category | Tokens |",
        "| --- | ---: |",
        f"| Output (generated) | {outp:,} |",
        f"| Input (uncached) | {inp:,} |",
        f"| Cache write | {cc:,} |",
        f"| Cache read | {cr:,} |",
        f"| **Grand total** | **~{total_m:.1f} M** |",
        "",
        f"The total is dominated by **cache reads (~{cr_m:.0f} M)** — that's the "
        "growing conversation/codebase context being re-read on each of "
        f"{turns:,} assistant turns, billed at the cheap cached rate, not "
        f"{cr_m:.0f} M of fresh work. The number that reflects actual **produced "
        f"content is ~{out_m:.2f} M output tokens**.",
        "",
        "## Prompts",
        "",
        f"- **~{prompts} prompts you typed** (out of {n_user_records:,} raw "
        '"user" records — the rest are tool results, slash-command stdout, and '
        "system reminders).",
        f"- **{turns:,} assistant turns** in response (each prompt fans out into "
        "many tool-call/reasoning steps).",
    ]
    if events:
        start = events[0].astimezone()
        end = events[-1].astimezone()
        idle_h = idle.total_seconds() / 3600
        lines += [
            "",
            "## Time",
            "",
            f"Session ran **{start:%b %-d %-I:%M %p} → {end:%b %-d %-I:%M %p %Z}** "
            f"wall-clock, but that includes **~{idle_h:.0f} h of idle gaps** "
            f"(overnight, breaks). Counting only stretches with <{idle_min:g}-min "
            "gaps between events:",
            "",
            f"- **Active session: ~{hms(active)}**",
            f"  - **Claude working** (tool calls, builds, tests, writing): "
            f"~{hms(claude)}",
            f"  - **You prompting / reading**: ~{hms(user)}",
            "",
            "| Metric | Value |",
            "| --- | --- |",
            f"| Session start | {start:%Y-%m-%d %H:%M %Z} |",
            f"| Session end | {end:%Y-%m-%d %H:%M %Z} |",
            f"| Active (gaps <{idle_min:g}m) | {hms(active)} |",
            f"| &nbsp;&nbsp;Claude working | {hms(claude)} |",
            f"| &nbsp;&nbsp;User prompting | {hms(user)} |",
            f"| Idle (excluded) | {hms(idle)} |",
        ]
    lines += [
        "",
        "## Cost",
        "",
        "What this would cost on the **metered Claude API**, at Anthropic's "
        "official **Opus 4.8** rates (USD per million tokens — input $5, output "
        "$25, 5-min cache write $6.25, cache read $0.50; "
        "[source](https://platform.claude.com/docs/en/about-claude/pricing), "
        "verified 2026-06). The total scales linearly with the cache-read rate, "
        "which dominates; override with `--rate-*` for other models.",
        "",
        "| Token type | Rate / M | Tokens | Cost |",
        "| --- | ---: | ---: | ---: |",
        f"| Output | ${rates['output']:.2f} | {outp:,} | ${c['output']:,.2f} |",
        f"| Input (uncached) | ${rates['input']:.2f} | {inp:,} | "
        f"${c['input']:,.2f} |",
        f"| Cache write | ${rates['cache_write']:.2f} | {cc:,} | "
        f"${c['cache_write']:,.2f} |",
        f"| Cache read | ${rates['cache_read']:.2f} | {cr:,} | "
        f"${c['cache_read']:,.2f} |",
        f"| **Total** | | | **≈ ${c['total']:,.0f}** |",
        "",
        f"**Prompt caching saved ~${c['cache_savings']:,.0f}.** Those "
        f"{cr_m:.0f} M cache reads, if billed as normal input tokens "
        f"(${rates['input']:.0f}/M), would have been **~${c['nocache_reads']:,.0f}** "
        f"instead of **${c['cache_read']:,.0f}** — a "
        f"{rates['input'] / rates['cache_read']:.0f}× discount, and the single "
        "biggest cost lever.",
        "",
        "**At work this usually isn't metered API.** Most teams run Claude Code "
        "on a flat **subscription** (Max ~$100–200/mo), where this build is "
        f"effectively included; the ~${c['total']:,.0f} above is the equivalent "
        "à-la-carte value, useful for ROI math but not what most orgs pay.",
        "",
        "**ROI framing.** A project of this scope — built from scratch with "
        "tests and CI — is realistically **3–10 engineer-days**. At "
        f"~${DAY_RATE:,}/loaded-day that's **${3 * DAY_RATE:,}–${10 * DAY_RATE:,}** "
        f"of labor, so even the metered ~${c['total']:,.0f} (or a month of "
        f"subscription) is roughly **{3 * DAY_RATE / c['total']:.0f}–"
        f"{10 * DAY_RATE / c['total']:.0f}× cheaper** than the equivalent "
        "hands-on time.",
        "",
        "## Caveats",
        "",
        f"- All from **{len(files)} transcript "
        f"file{'s' if len(files) != 1 else ''}**, which cover the whole "
        "project — both the pre-compaction work and the continued sessions — not "
        "just any single feature.",
        '- **"User prompting" time is approximated** as the gap before each of '
        "your messages (composing + reading my output), so it bundles your "
        "think-time with reading time.",
        "- **Token counts come straight from the `usage` field** on each "
        "assistant message; **timing from event timestamps**.",
        "- **Costs use Anthropic's official Opus 4.8 rates** "
        "([pricing docs](https://platform.claude.com/docs/en/about-claude/pricing), "
        "verified 2026-06); the labor comparison is a rough industry figure, "
        "not a measured one.",
        "",
    ]
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as fh:
        fh.write("\n".join(lines))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("paths", nargs="*", help="transcript .jsonl file(s)")
    ap.add_argument("--idle", type=float, default=DEFAULT_IDLE_MIN,
                    help=f"idle gap threshold in minutes (default {DEFAULT_IDLE_MIN})")
    ap.add_argument("--md", nargs="?", const="docs/SESSION_STATS.md", default=None,
                    metavar="PATH",
                    help="write a Markdown report (default path docs/SESSION_STATS.md)")
    ap.add_argument("--also", action="append", default=[], metavar="DIR",
                    help="extra encoded project-dir name(s) to fold in, beyond "
                         "this repo's own and ALIAS_PROJECT_DIRS (repeatable)")
    ap.add_argument("--rate-output", type=float, default=RATES["output"])
    ap.add_argument("--rate-input", type=float, default=RATES["input"])
    ap.add_argument("--rate-cache-write", type=float, default=RATES["cache_write"])
    ap.add_argument("--rate-cache-read", type=float, default=RATES["cache_read"])
    args = ap.parse_args()
    rates = {
        "output": args.rate_output,
        "input": args.rate_input,
        "cache_write": args.rate_cache_write,
        "cache_read": args.rate_cache_read,
    }

    files = find_transcripts(args.paths, args.also)
    rows: list[dict] = []
    for p in files:
        rows.extend(load(p))

    inp = outp = cc = cr = 0
    assistant_turns = 0
    for r in rows:
        if r.get("type") != "assistant":
            continue
        assistant_turns += 1
        u = r.get("message", {}).get("usage") or {}
        inp += u.get("input_tokens", 0)
        outp += u.get("output_tokens", 0)
        cc += u.get("cache_creation_input_tokens", 0)
        cr += u.get("cache_read_input_tokens", 0)

    prompts = sum(1 for r in rows if is_human_prompt(r))

    events = sorted((t for t in (parse_ts(r) for r in rows) if t))
    idle_gap = dt.timedelta(minutes=args.idle)
    active = claude = user = idle = dt.timedelta()
    typed = [(parse_ts(r), r.get("type")) for r in rows if parse_ts(r)]
    typed.sort(key=lambda x: x[0])
    for (t0, _), (t1, ty1) in zip(typed, typed[1:]):
        gap = t1 - t0
        if gap > idle_gap:
            idle += gap
        else:
            active += gap
            if ty1 == "user":
                user += gap
            else:
                claude += gap

    total = inp + outp + cc + cr

    if args.md is not None:
        n_user_records = sum(1 for r in rows if r.get("type") == "user")
        write_markdown(args.md, project_name(), files, len(rows), outp, inp, cc,
                       cr, total, prompts, assistant_turns, events, active,
                       claude, user, idle, args.idle, n_user_records, rates)
        print(f"Wrote {args.md}")
        return

    # --- canonical summary (identical layout in every repo; relay verbatim) ---
    def k(n: int) -> str:
        """Compact magnitude, e.g. 6,372,888 -> '6.4M'."""
        for div, suf in ((1e9, "B"), (1e6, "M"), (1e3, "k")):
            if n >= div:
                return f"{n / div:.1f}{suf}"
        return str(n)

    note = ""
    extras = []
    if any(f"{os.sep}subagents{os.sep}" in f for f in files):
        extras.append("incl. subagents")
    if ALIAS_PROJECT_DIRS or args.also:
        extras.append("pre-rename history")
    if extras:
        note = " (" + " + ".join(extras) + ")"

    c = costs(outp, inp, cc, cr, rates)
    cr_pct = f"{cr / total * 100:.0f}%" if total else "0%"
    bar = "─" * 52
    out = [
        bar,
        f" {project_name()} · Claude Code build session",
        bar,
        f" {len(files)} transcripts{note} · {len(rows):,} records",
        "",
        " TOKENS",
        f"   Output (generated)  {outp:>15,}   {k(outp)}",
        f"   Cache read          {cr:>15,}   {k(cr)}  {cr_pct}",
        f"   Cache write         {cc:>15,}   {k(cc)}",
        f"   Input (uncached)    {inp:>15,}   {k(inp)}",
        f"   Total               {total:>15,}   {k(total)}",
        "",
        " ACTIVITY",
        f"   Human prompts       {prompts:>15,}",
        f"   Assistant turns     {assistant_turns:>15,}",
    ]
    if events:
        s, e = events[0].astimezone(), events[-1].astimezone()
        out += [
            "",
            f" TIME  (idle gaps >{args.idle:g}m excluded)",
            f"   Span                {s:%b %-d} → {e:%b %-d %Y}",
            f"   Active              {hms(active):>15}   "
            f"(Claude {hms(claude)} · you {hms(user)})",
        ]
    out += [
        "",
        " COST  (metered-API equivalent · Opus 4.8 rates)",
        f"   Output      @ ${rates['output']:>5.2f}/M   ${c['output']:>10,.2f}",
        f"   Cache write @ ${rates['cache_write']:>5.2f}/M   ${c['cache_write']:>10,.2f}",
        f"   Cache read  @ ${rates['cache_read']:>5.2f}/M   ${c['cache_read']:>10,.2f}",
        f"   Input       @ ${rates['input']:>5.2f}/M   ${c['input']:>10,.2f}",
        f"   {'-' * 34}",
        f"   Total                    ${c['total']:>10,.2f}",
        f"   Caching saved ~${c['cache_savings']:,.0f} vs. uncached",
        bar,
        " Metered-API equivalent — on a flat Claude Code subscription this",
        " build is effectively included, not a billed charge.",
    ]
    print("\n".join(out))


if __name__ == "__main__":
    main()
