# iYield session log

Tracks elapsed time per build session. Append a row per session; close it out when the user signals the session is done.

| Session | Date (local) | Elapsed | Scope |
|---|---|---|---|
| v1 | 2026-05-25 | < 21 min | scaffold, single-screen UI, Yahoo Finance lookup, gross + after-tax yield, qualifying/non-qualifying paths, iOS simulator verification (YMAG, BRK-B), shared_preferences for rate persistence |
| v2 | 2026-05-25 | ~60 min (same day) | added three additional yield views (compounded DRIP, average-price denominator, total return / TWR); restructured UI into three tabs (Calculate, Distributions, Prices) with date-range summaries; persist last ticker between launches; Apache 2.0 LICENSE + NOTICE; PRIVACY.md; rewritten README; license headers on Dart sources |
| v2.1 | 2026-05-25 | ~30 min (same day) | extracted YieldMath pure-function class; 20-test suite covering all four computations + UI behavior (flat-price baseline, after-tax linearity, price drop/rise, avg-price, ordering, YMAG fixture, non-qualifying, null closes, single distribution, tab presence, persistence restoration); fixed pre-window distribution price fallback (use first available bar, not currentPrice); pre-commit hook (.githooks/pre-commit) enforcing analyze + test; README screenshots from the live simulator |
