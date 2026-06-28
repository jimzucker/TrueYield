# Build session story

The real numbers behind building **TrueYield**, pulled from this project's Claude Code session transcript (14,404 records spanning the whole build). Regenerate with `python3 scripts/session_stats.py --md`.

## Tokens

| Category | Tokens |
| --- | ---: |
| Output (generated) | 6,303,905 |
| Input (uncached) | 919,504 |
| Cache write | 20,663,910 |
| Cache read | 1,977,615,943 |
| **Grand total** | **~2005.5 M** |

The total is dominated by **cache reads (~1978 M)** — that's the growing conversation/codebase context being re-read on each of 6,172 assistant turns, billed at the cheap cached rate, not 1978 M of fresh work. The number that reflects actual **produced content is ~6.30 M output tokens**.

## Prompts

- **~275 prompts you typed** (out of 3,311 raw "user" records — the rest are tool results, slash-command stdout, and system reminders).
- **6,172 assistant turns** in response (each prompt fans out into many tool-call/reasoning steps).

## Time

Session ran **May 28 12:03 PM → Jun 28 10:06 AM EDT** wall-clock, but that includes **~722 h of idle gaps** (overnight, breaks). Counting only stretches with <5-min gaps between events:

- **Active session: ~20h 26m 23s**
  - **Claude working** (tool calls, builds, tests, writing): ~13h 39m 25s
  - **You prompting / reading**: ~6h 46m 58s

| Metric | Value |
| --- | --- |
| Session start | 2026-05-28 12:03 EDT |
| Session end | 2026-06-28 10:06 EDT |
| Active (gaps <5m) | 20h 26m 23s |
| &nbsp;&nbsp;Claude working | 13h 39m 25s |
| &nbsp;&nbsp;User prompting | 6h 46m 58s |
| Idle (excluded) | 721h 36m 37s |

## Cost

What this would cost on the **metered Claude API**, at Anthropic's official **Opus 4.8** rates (USD per million tokens — input $5, output $25, 5-min cache write $6.25, cache read $0.50; [source](https://platform.claude.com/docs/en/about-claude/pricing), verified 2026-06). The total scales linearly with the cache-read rate, which dominates; override with `--rate-*` for other models.

| Token type | Rate / M | Tokens | Cost |
| --- | ---: | ---: | ---: |
| Output | $25.00 | 6,303,905 | $157.60 |
| Input (uncached) | $5.00 | 919,504 | $4.60 |
| Cache write | $6.25 | 20,663,910 | $129.15 |
| Cache read | $0.50 | 1,977,615,943 | $988.81 |
| **Total** | | | **≈ $1,280** |

**Prompt caching saved ~$8,899.** Those 1978 M cache reads, if billed as normal input tokens ($5/M), would have been **~$9,888** instead of **$989** — a 10× discount, and the single biggest cost lever.

**At work this usually isn't metered API.** Most teams run Claude Code on a flat **subscription** (Max ~$100–200/mo), where this build is effectively included; the ~$1,280 above is the equivalent à-la-carte value, useful for ROI math but not what most orgs pay.

**ROI framing.** A project of this scope — built from scratch with tests and CI — is realistically **3–10 engineer-days**. At ~$800/loaded-day that's **$2,400–$8,000** of labor, so even the metered ~$1,280 (or a month of subscription) is roughly **2–6× cheaper** than the equivalent hands-on time.

## Caveats

- All from **30 transcript files**, which cover the whole project — both the pre-compaction work and the continued sessions — not just any single feature.
- **"User prompting" time is approximated** as the gap before each of your messages (composing + reading my output), so it bundles your think-time with reading time.
- **Token counts come straight from the `usage` field** on each assistant message; **timing from event timestamps**.
- **Costs use Anthropic's official Opus 4.8 rates** ([pricing docs](https://platform.claude.com/docs/en/about-claude/pricing), verified 2026-06); the labor comparison is a rough industry figure, not a measured one.
