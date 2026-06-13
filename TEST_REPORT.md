# TrueYield — Test Report

**Date:** 2026-06-12
**Branch:** `main`
**Toolchain:** Flutter (stable)

## Summary

| Check | Command | Result |
|---|---|---|
| Formatting | `dart format --output=none --set-exit-if-changed .` | ✅ Clean |
| Static analysis | `flutter analyze` | ✅ No issues found |
| Dart tests | `flutter test` | ✅ **102 / 102 passed** |
| Pipeline tests | `python3 -m unittest tools.test_parsers` | ✅ **22 / 22 passed** |
| Line coverage | `flutter test --coverage` | **91.5%** (1710 / 1869 lines) |

The Dart gates are enforced by `.github/workflows/ci.yml` and the
`.githooks/pre-commit` hook; CI also runs the Python parser tests.

## Test breakdown

| Suite | Tests | Scope |
|---|---:|---|
| `test/yield_math_test.dart` | 46 | The pure `YieldMath` engine on the broker-DRIP / return-of-capital model: flat-price baseline, the ROC income split, price-drop/rise total return, **lots** (single, multiple, closed/realized gains, the "single default lot ≡ no lots" invariant), **capital-gains tax** (short- vs long-term rate, loss netting within and across buckets, zero when nothing is sold), edge cases, and `rocPct` clamping — with real daily-bar fixtures cross-checked against `tools/yield_ref.py`. Also covers the Diagnostics scenarios (incl. the invariant card) and the published-field invariants. |
| `test/yahoo_parser_test.dart` | 13 | The pure `parseYahooChart` JSON parser: happy path, edge cases, every error branch, and the **per-distribution ROC precedence** — user override > completed-year actual > 19a-1 history (nearest payable date) > global default. |
| `test/charts_test.dart` | 3 | The pure `returnContributions` data prep for the return-breakdown bars: the signed components (income, gain/loss, taxes) sum to the net return, a sold lot adds Realized G/L + Capital-gains tax rows, and a price drop makes the gain contribution negative. |
| `test/widget_test.dart` | 29 | UI / end-to-end flow via an injected mock `http.Client`: the six tabs, the qualifying & "does not qualify" result cards, the portfolio grid for lots, the editable per-distribution ROC column, the saved-ticker pick list, the Info tab (coverage summary, tracked-fund list, CSV links), the Diagnostics scenarios, validation, the fetch-error messages (server / unknown symbol / network), and saved-input restoration. |
| `test/roc_data_test.dart` | 3 | `rocForTicker` lookup over the bundled `kRocByTicker` table (case/whitespace-insensitive, unknown → null, table populated and stamped). |
| `test/yahoo_base_test.dart` | 3 | `resolveYahooBase` routing: the CORS proxy is used **only on web**; native targets always call Yahoo directly. |
| `test/date_format_test.dart` | 5 | The pure date/staleness helpers: `isStale`, `fmtDateHuman`, `fmtStamp`. |
| **Dart total** | **102** | |
| `tools/test_parsers.py` | 22 | The format-fragile data-pipeline parsers (network-free, canned text): `_roc_pct` (labels / prose / line-wrap), the date parsers, the Invesco / First Trust / Form 8937 row extraction, and the `compute_annual` / `trailing` / `merge` aggregates. |

Shared test assets: `test/yahoo_fixture.dart` builds canned Yahoo Finance
chart payloads; `test/fixtures/` holds the captured daily responses.

## Coverage

The application source — now one library split across `part of 'main.dart'`
files (`models`, `yield_math`, `yahoo`, `roc`, `format`, `yield_screen`,
`result_card`, `tabs`) — is **91.5% covered** (1710 / 1869 lines). The uncovered
lines are essentially unreachable from a widget test: the `main()` / `runApp`
entry point, repeated `onTap: _selectAll(...)` field closures, the
`didChangeAppLifecycleState` resume branch (its decision logic is covered by the
`isStale` unit tests), the `CustomPainter` paint methods (the chart data prep is
unit-tested instead), and the external `launchUrl` / `showLicensePage` handlers
(they need a real platform/browser). The Python tools are covered by
`tools/test_parsers.py` rather than line coverage.

## Reproduce

```sh
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test --coverage
```
