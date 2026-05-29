# TrueYield — Test Report

**Date:** 2026-05-29
**Branch:** `main`
**Toolchain:** Flutter 3.41.7 (stable)

## Summary

| Check | Command | Result |
|---|---|---|
| Formatting | `dart format --output=none --set-exit-if-changed .` | ✅ Clean |
| Static analysis | `flutter analyze` | ✅ No issues found |
| Tests | `flutter test` | ✅ **46 / 46 passed** |
| Line coverage | `flutter test --coverage` | **98.1%** (574 / 585 lines) |

These are the same three gates enforced by `.github/workflows/ci.yml` and the
`.githooks/pre-commit` hook.

## Test breakdown

| Suite | Tests | Scope |
|---|---:|---|
| `test/yield_math_test.dart` | 20 | The pure `YieldMath` engine on the broker-DRIP / return-of-capital model: flat-price baseline, the ROC income split (0% and 100%), price-drop and price-rise total return, distribution ordering, the no-distribution and all-null-close edge cases, `priceAt` back- and forward-walk, a distribution dated before the first bar, combined tax rates at/above 100%, and `rocPct` clamping. Includes real daily-bar **YMAG** and **TQQQ** fixtures whose expected values are cross-checked against the Python reference in `tools/yield_ref.py`, plus invariant checks tying the published fields (`dripShares`, `nav`, `incomeAmount`, `taxThisYear`, `costBasis`, `unrealizedGL`, `afterTaxYieldRoc`, `totalReturnBeforeTax/AfterTax`) back to their primitives. |
| `test/yahoo_parser_test.dart` | 7 | The pure `parseYahooChart` JSON parser: happy path, null close → null `PriceBar`, skipped malformed dividend entries, and every error branch (API error envelope, empty result, null result, missing price). |
| `test/yahoo_base_test.dart` | 3 | `resolveYahooBase` routing: the CORS proxy is used **only on web** and only when one is configured; native targets (iOS/Android/desktop) always call Yahoo directly — even if a proxy value is present. Guards against the routing silently regressing. |
| `test/widget_test.dart` | 16 | UI and end-to-end flow: app boot, form rendering (incl. the return-of-capital field), the four tabs, the Info tab’s user-guide content, empty-state placeholders, input validation (empty ticker, non-numeric rate, out-of-range ROC), tap-to-select-all, and clearing a stale result when an input changes. Via an injected mock `http.Client`, the full Calculate → parse → render path: the qualifying result card (total return after tax, income, tax, advertised & after-tax yields), the populated Distributions and Prices tabs (incl. the em-dash for a null close), the "Does not qualify" card, and the HTTP-error message — plus ticker upper-casing and `interval=1d` endpoint params in the outgoing request. |
| **Total** | **46** | |

Shared test assets: `test/yahoo_fixture.dart` builds canned Yahoo Finance
chart payloads; `test/fixtures/` holds the captured YMAG/TQQQ daily responses.

## Coverage

`lib/main.dart` — the only application source file — is **98.1% covered**
(574 / 585 lines). The 11 uncovered lines are all unreachable from a widget
test:

- the `main()` / `runApp` entry point (run only on a real device launch),
- four identical `onTap: () => _selectAll(...)` field closures (the same
  wiring as the ticker field, which *is* covered),
- one `_StatusChip` color branch the qualifying card never reaches, and
- the external-link `launchUrl` call and the `showLicensePage` handler in the
  Info tab (they require a real platform/browser, not exercised in tests).

## Reproduce

```sh
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test --coverage
```
