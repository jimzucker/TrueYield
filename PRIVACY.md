# TrueYield privacy policy

Last updated: 2026-06-12.

## Short version

TrueYield runs entirely on your device. It does not have a backend, does not collect telemetry, does not have user accounts, and does not transmit any personal data to anyone. The only automatic network request it makes is to Yahoo Finance, to fetch the prices and dividend history needed to answer your query. (Tapping a CSV-download or project link opens a file hosted on GitHub — only when you choose to.)

## What stays on your device

The app stores the following locally, using the operating system's standard `shared_preferences` facility:

- The last ticker you entered.
- The marginal federal, state, and local tax rates you entered.

This data never leaves your device. You can clear it by uninstalling the app or by clearing app data through your OS settings.

## What gets sent off your device

When you tap **Calculate**, TrueYield issues a single HTTPS request to:

```
https://query2.finance.yahoo.com/v8/finance/chart/{TICKER}?interval=1d&range={RANGE}&events=div
```

`{RANGE}` is the smallest span that covers your oldest lot (or one year by default). That request goes directly to Yahoo Finance. Yahoo's own privacy and terms apply to that request. TrueYield does not proxy, log, or aggregate these requests anywhere — there is no TrueYield server.

The request contains:

- The ticker symbol you typed.
- A User-Agent header identifying the request as coming from a generic desktop browser (Yahoo's endpoint rejects empty user agents).

It does not contain your tax rates, your name, your device identifier, or anything else that identifies you.

The return-of-capital and price history shown for the tracked funds is compiled into the app, so it requires no network request. The optional "Download (CSV)" and project links open files hosted on GitHub (github.com / raw.githubusercontent.com) in your browser — only if you tap them, and carrying no information about you beyond the standard request your browser makes.

## What we do *not* do

- No analytics SDK, no crash reporting service, no advertising SDK.
- No third-party tracking.
- No account creation, no sign-in, no email collection.
- No facial recognition, no camera, no microphone, no location.
- No background activity. The app only makes a network request when you tap Calculate.

## Children's privacy

TrueYield is not directed at children under 13 and does not knowingly collect any data from anyone, including children.

## Contact

Questions about this policy can be sent to the project maintainer through the project's source repository.

## Changes

If this policy changes, the updated version will appear in this file in the project repository with a new "Last updated" date.
