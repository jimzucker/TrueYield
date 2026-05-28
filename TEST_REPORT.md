# TrueYield — Test Report

**Date:** 2026-05-28
**Branch:** `claude/todays-charges-DMByB`
**Toolchain:** Flutter 3.44.0 (stable) · Dart 3.12.0

## Summary

| Check | Command | Result |
|---|---|---|
| Formatting | `dart format --output=none --set-exit-if-changed .` | ✅ Clean |
| Static analysis | `flutter analyze` | ✅ No issues found |
| Tests | `flutter test` | ✅ **41 / 41 passed** |
| Line coverage | `flutter test --coverage` | **98.6%** (506 / 513 lines) |

These are the same three gates enforced by `.github/workflows/ci.yml` and the
`.githooks/pre-commit` hook.

## Test breakdown

| Suite | Tests | Scope |
|---|---:|---|
| `test/yield_math_test.dart` | 20 | The pure `YieldMath` engine on the broker-DRIP / return-of-capital model: flat-price baseline, the ROC income split (0% and 100%), price-drop and price-rise total return, distribution ordering, the no-distribution and all-null-close edge cases, `priceAt` back- and forward-walk, a distribution dated before the first bar, combined tax rates at/above 100%, and `rocPct` clamping. Includes real daily-bar **YMAG** and **TQQQ** fixtures whose expected values are cross-checked against the Python reference in `tools/yield_ref.py`, plus invariant checks tying the published fields (`dripShares`, `nav`, `incomeAmount`, `taxThisYear`, `costBasis`, `unrealizedGL`, `afterTaxYieldRoc`, `totalReturnBeforeTax/AfterTax`) back to their primitives. |
| `test/yahoo_parser_test.dart` | 7 | The pure `parseYahooChart` JSON parser: happy path, null close → null `PriceBar`, skipped malformed dividend entries, and every error branch (API error envelope, empty result, null result, missing price). |
| `test/widget_test.dart` | 14 | UI and end-to-end flow: app boot, form rendering (incl. the return-of-capital field), three tabs, empty-state placeholders, input validation (empty ticker, non-numeric rate, out-of-range ROC), and tap-to-select-all. Via an injected mock `http.Client`, the full Calculate → parse → render path: the qualifying result card (total return after tax, income, tax, advertised & after-tax yields), the populated Distributions and Prices tabs (incl. the em-dash for a null close), the "Does not qualify" card, and the HTTP-error message — plus ticker upper-casing and `interval=1d` endpoint params in the outgoing request. |
| **Total** | **36** | |

Shared test assets: `test/yahoo_fixture.dart` builds canned Yahoo Finance
chart payloads; `test/fixtures/` holds the captured YMAG/TQQQ daily responses.

## Coverage

`lib/main.dart` — the only application source file — is **98.6% covered**
(506 / 513 lines). The 7 uncovered lines are:

- the `main()` / `runApp` entry point (run only on a real device launch),
- four identical `onTap: () => _selectAll(...)` field closures (the same
  wiring as the ticker field, which *is* covered), and
- one `_StatusChip` color branch that the current UI never reaches (the
  qualifying card builds no chip).

## Reproduce

```sh
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test --coverage
```
