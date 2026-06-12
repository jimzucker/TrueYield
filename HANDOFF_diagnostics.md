# Handoff — Diagnostics tab + number readability

Branch: `claude/diag-tab-and-number-readability` (off `main` @ `a696421`).
All work below is committed here. `flutter analyze` clean, `flutter test` = 78/78 green,
`dart format` clean.

## What changed in this branch

1. **Renamed the `Diagnostics` tab to `Diag` and moved it to the end (after `Info`).**
   - `lib/main.dart` — tab list + `TabBarView` children reordered so the two stay in sync.
   - Page heading inside the tab is still the full word **"Diagnostics"** (the tab chip is
     the only space-constrained spot). Say the word if you want the heading shortened too.
   - `test/widget_test.dart` updated to tap/assert `'Diag'`.

2. **Numbers are easier to read — thousands separators app-wide.**
   - Added a tiny `_grouped()` helper (no `intl` dependency) and routed `_money()` /
     `_signedMoney()` through it, so `$1250.00` now renders as `$1,250.00`. This improves
     the result card and Prices tab too, not just Diagnostics.
   - Share counts in the Diagnostics rows also go through `_grouped()` for consistency.
   - NOTE: the Distributions footer total still uses the separate 4-decimal `_fmt()`
     (`$3.0000`), which a widget test asserts on — left untouched on purpose.

3. **Fixed the first diagnostic's misleading label** (the "numbers don't make sense" one).
   See the analysis below — the label was wrong; I corrected it. The deeper design
   question is left for you (it needs a product call).

## The "first one's numbers don't make sense" — root cause (NEEDS YOUR DECISION)

The first card is **"No lots"**. It was labeled *"1 share, ~1y default (TTM view)"*, but
that description does not match what the math actually computes:

- `buildDiagnostics()` calls `run(null)` → `YieldMath.compute(lots: null)`.
- With `lots == null`, `compute()` (`lib/main.dart` ~`395-403`) synthesizes **one default
  lot of 1 share with buy date at epoch 0** — i.e. it is held for the *entire* ~3-year
  synthetic window and reinvests **all 36** monthly distributions.
- So the card legitimately shows ~`1.00 → ~2.2` shares and a large multi-year return.
  The numbers are *correct for a 3-year hold* — the **label** was the lie. I changed the
  detail to: `1 share held the full ~3y window · all distributions reinvested`.

### The deeper mismatch (why this is worth your time)

Commit `a696421` ("Lots: default to 100 shares on the last trading day, cost = that day's
close") changed the **app's** no-lots default. But the **math's** `lots == null` default is
still "1 share @ epoch 0". So:

- In the real app, a user with no lots now gets **100 shares bought today** (≈$0 gain).
- The Diagnostics "No lots" card exercises the **old** 1-share/epoch-0 path, which the UI
  no longer hits the same way.

They have drifted apart. Options to reconcile (pick one on desktop):

- **(A) Relabel only** *(done)* — cheapest; keeps full-history coverage but the card no
  longer mirrors the app's real default.
- **(B) Make the diagnostic match the UI default** — change the "No lots" scenario to seed
  100 shares on the last bar. Honest, but the card becomes boring (~$0 unrealized) and you
  lose the "held since inception" coverage, so probably add it back as a separate card.
- **(C) Unify the defaults** — make `compute(lots: null)` build the same 100-share/last-day
  lot the UI uses, and update `yield_math_test.dart` expectations. Biggest change, but
  removes the two-defaults footgun for good. **My recommendation** if you want one source
  of truth — just budget time for the test updates (several `closeTo` values will move).

## Other "easier to understand" ideas I did NOT do (your call)

- Round share counts to whole numbers when they're integers (e.g. `100` not `100.00`).
- Abbreviate very large dollars (`$1.2M`) — probably unnecessary here.
- Add a one-line plain-English summary per diagnostic card ("+186% over 3 yrs, mostly
  reinvested distributions").

## Still open from earlier in the session (separate issue)

Android **portrait** still doesn't fill the screen; **landscape** does. Strong evidence it's
Chrome's **"Desktop site"** mode (the toolbar in the screenshot has a home + "+" button =
desktop/tablet UI), which makes Chrome ignore the `<meta viewport>` we added. First step is
to confirm by toggling Chrome ⋮ → "Desktop site" off. If it's already off, it's the Flutter
desktop-mode-portrait bug (flutter/flutter#154162) and needs a code workaround. Not touched
in this branch.

## How to run / verify locally

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d chrome     # eyeball the Diag tab + comma formatting
```
