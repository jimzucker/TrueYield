# TrueYield × Claude Code — by the numbers

## Bottom line

**~11,700 lines of shipped, test-backed code** across four build targets
(iOS · Android · macOS · web), delivered with **~15 hours of hands-on steering**
and **~$100 of subscription**. The same workload on the pay-as-you-go API would
have cost **≈ $1,330** — **~13× more** than the flat-rate plan — because long,
context-heavy coding (a 1M-token window re-read ~6,700 times) is exactly where AI
assistance and a flat-rate plan compound: **99.97% of the token volume was cache
reads**, billed at a tenth of input price.

---

Two scopes, kept honest:

- **Code volume** = the full git history of the app (scaffold → today, one Flutter
  codebase).
- **Time & cost** = the ~3 weeks captured in local transcripts (May 26 → Jun 14
  2026, iYield rename → TrueYield v1.8). The pre-rename scaffolding days predate
  these logs, so the effort figures are a **floor**.

## Code shipped (Claude-assisted)

- **~11,700 lines of authored code** in one Flutter/Dart codebase that targets
  **iOS · Android · macOS · web**
  - App source ~4,900 · Dart tests ~5,000 · Python data-pipeline ~1,800
- App ↔ test split is **~1:1** (4,889 / 4,992) — the same invariant-testing
  discipline, cross-checked against an independent Python reference port
- Plus **~2,500 lines of generated** ROC/price data tables (and larger JSON
  datasets) bootstrapped for 40+ funds — counted separately because they're
  machine-written, not hand-authored
- **96 commits** over the window

## Effort actually spent (last ~3 weeks)

- **~15 hours genuine hands-on** (range 14–17h), adjusted down ~50% because this
  window was split across multiple apps — across **10 active days**
- **7.2 million output tokens** across **~6,700 assistant turns** (Opus 4.8),
  including 28 sub-agent runs

## Cost

- Subscriptions are flat-rate, not metered. The same workload on the
  pay-as-you-go API would be **≈ $1,330** — **~$1,015 of it cache reads** (the
  full 1M-token context re-read every turn: **2.03 billion** cache-read tokens).
- Breakdown: cache reads $1,015 (76%) · output $180 · cache writes $129 · fresh
  input $4.
- Actual spend: **~$100** ($20 Pro → $100 Max) → **~13× more compute than the
  cash cost.**
- The **$20 → $100 Max upgrade was the right call**: the June 12 push alone was
  62 commits in one day — the bulk of that 2-billion-token cache-read load — and
  would have rate-limited on the $20 tier.

---

### Method & sources

- **Code volume** — `git ls-files` line counts by language on the current tree;
  generated `lib/{roc_*,price_coverage}.dart` separated from hand-authored source.
- **Tokens, turns, hours** — parsed from the local Claude Code transcripts under
  `~/.claude/projects/` for both the `TrueYield` and pre-rename `iyield` project
  dirs, including the 28 sub-agent transcripts. Output/cache/input token totals
  are summed from each assistant turn's `usage`. Hands-on hours are the sum of
  inter-event gaps capped at 10 min (a gap over the cap counts as a break), then
  reduced 50% for multi-app context-switching during the window.
- **Cost** — API-equivalent priced at Opus 4.8 rates: input $5.00, output
  $25.00, cache-write-5m $6.25 (1.25×), cache-read $0.50 (0.1×) per MTok.
