# Handoff — Diagnostics tab + number readability

Branch: `claude/diag-tab-and-number-readability` (off `main`).
`flutter analyze` clean · `dart format` clean · `flutter test` = **80/80 green**
(verified with a real Flutter 3.44.2 / Dart 3.12.2 toolchain).

## What changed on this branch

1. **Tab renamed `Diagnostics` → `Diag`, moved after `Info`.** (`lib/main.dart`, plus
   `test/widget_test.dart`.) The page heading inside the tab is still "Diagnostics".

2. **Diagnostics now use round, hand-checkable synthetic data** (`buildDiagnostics`):
   - Prices step **$10 → $15 → $20** across three one-year bands; a mirror **$20 → $15 →
     $10** path drives the new falling case. Prices are keyed to whole months-ago, so the
     results are independent of the calendar date the tab is opened.
   - Flat **$0.10 monthly** distribution, **30%** tax (all federal), **50%** ROC.
   - This replaced the old fractional `$10→$13 / $0.25 / 37%` data that produced the
     confusing "1.00 → 2.2 shares, +186%" first card.

3. **New scenario: "Falling price"** — bought 18 mo ago at $15, now $10 (a clear capital
   loss that distributions only partly offset; exactly the covered-call-ETF failure mode).

4. **Each scenario carries baked-in EXPECTED results and self-checks** (`DiagCheck`):
   - Every card checks Cost / Value / Shares / After-tax return % against expected values
     derived from the round inputs, and shows a **PASS/FAIL** pill + an "Expected vs actual"
     block. The tab header shows an overall `N / 7 pass` summary.
   - The test suite asserts every scenario passes (`yield_math_test.dart` →
     "every scenario passes its baked-in expected checks") and that the falling case is a
     loss. So the diagnostics are now part of the test class going forward.
   - The expected numbers were computed from the math, sanity-checked against the round
     inputs (e.g. Cost `1 lot · 30 months` = 100 × $10 = $1,000; Value = DRIP shares ×
     current price), then pinned. Tolerance is relative `1e-3` + `$0.01`.

5. **Thousands separators in money** (`_grouped`) from the earlier pass are still here
   (`$1,250.00`). Harmless; with the small round diag numbers it rarely shows. Say if you
   want it reverted.

## Recommendation C — STOP, my earlier note was based on a misread

My previous note proposed "make `compute(lots: null)` build the same 100-share/last-day lot
the UI uses." **On a closer read that premise is wrong, so I did NOT implement it:**

- Commit `a696421` changed the **"Add lot" button seed** (100 sh, last trading day,
  cost = that day's close) — `lib/main.dart` ~`1455`. It did **not** change the no-lots
  default.
- The no-lots default is still: `_activeLots()` returns `null` when empty
  (`main.dart:987`) → `compute` synthesizes a 1-share lot, and the no-lots fetch range is
  ~365 days (`main.dart:1171`). So "1 share over the whole ~1y window = the per-share **TTM**
  view." **UI and math already agree** — there is no default mismatch to unify.
- Implementing literal C would **delete the TTM view**, which is a real, tested feature
  ("no lots → the default (TTM) view"; "a single lot uses the portfolio view, not the TTM
  one"). That's why I paused and asked instead.

The only genuine (minor) inconsistency left: the **Add-lot seed** says "100 shares today"
while the empty-state hint says *"Default: 1 share bought ~1 year ago."* They describe two
different things, but the wording can confuse. Options put to you in chat:
  - (1) Leave defaults as-is (recommended — TTM is correct & consistent).
  - (2) Unify the *messaging* (make the Add-lot seed 1 share, or reword the hint).
  - (3) Literal C — replace the no-lots default with 100 sh/today (removes TTM; not advised).

## How to run / verify

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d chrome   # eyeball the Diag tab: PASS pills + Expected vs actual
```
