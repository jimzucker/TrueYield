"""Bootstrap/refresh data/prices_history.json — daily closing prices and cash
distributions per fund, straight from Yahoo Finance, going back to inception.

Yahoo's chart endpoint returns the full daily history for an explicit epoch
range (range=max silently coarsens to weekly for long spans, so we pass
period1=0). One JSON per ticker gives raw daily closes plus the dividend events.

    closes     {YYYY-MM-DD: close}   raw (unadjusted) closing price
    dividends  {YYYY-MM-DD: amount}  per-share cash distribution on its ex-date

Usage:
    python3 tools/refresh_prices.py                 # all funds in UNIVERSE
    python3 tools/refresh_prices.py MSTY QYLD ...    # just these tickers

This is a committed dataset (audit trail + CSV-export source + offline seed);
the app still fetches live quotes at run time.
"""

import json
import os
import sys
import time
import urllib.request
from datetime import date, datetime, timezone

# The funds we track. Keep in sync with the ROC universe in refresh_roc.py.
UNIVERSE = [
    "JEPI", "JEPQ", "QQQI", "SPYI", "QYLD", "DIVO", "XYLD", "GPIX", "GPIQ",
    "FTHI", "TLTW", "FEPI", "NVDY", "RYLD", "ISPY", "BUYW", "BTCI", "EIPI",
    "MSTY", "ULTY", "IWMI", "QDTE", "FTQI", "TSLY", "OMAH", "QDVO", "TSPY",
    "IAUI", "YMAX", "AIPI", "IQQQ", "AMDY", "PBP", "XDTE", "YMAG", "GOOY",
    "IVVW", "LQDW", "GDXY", "AMZY",
]

CHART = "https://query2.finance.yahoo.com/v8/finance/chart/{}?period1=0&period2=9999999999&interval=1d&events=div"


def _iso(epoch):
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%d")


def fetch_ticker(ticker):
    """{"inception", "closes", "dividends"} for one ticker, or None on failure."""
    req = urllib.request.Request(
        CHART.format(ticker), headers={"User-Agent": "Mozilla/5.0"}
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            doc = json.load(r)
    except Exception as e:
        print(f"  {ticker}: fetch failed ({e})")
        return None

    res = (doc.get("chart") or {}).get("result")
    if not res:
        print(f"  {ticker}: no chart result")
        return None
    res = res[0]
    ts = res.get("timestamp") or []
    quote = (res.get("indicators") or {}).get("quote") or [{}]
    closes_raw = quote[0].get("close") or []

    closes = {}
    for t, c in zip(ts, closes_raw):
        if c is not None:
            closes[_iso(t)] = round(c, 4)

    divs = {}
    for ev in ((res.get("events") or {}).get("dividends") or {}).values():
        amt = ev.get("amount")
        if amt is not None and "date" in ev:
            divs[_iso(ev["date"])] = round(amt, 6)

    if not closes:
        print(f"  {ticker}: no closes")
        return None
    inception = min(closes)
    print(f"  {ticker:6} {len(closes):>5} closes  {len(divs):>3} divs  "
          f"since {inception}")
    return {
        "inception": inception,
        "closes": dict(sorted(closes.items())),
        "dividends": dict(sorted(divs.items())),
    }


def main():
    tickers = [t.upper() for t in sys.argv[1:]] or UNIVERSE
    root = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
    dest = os.path.join(root, "data", "prices_history.json")

    # Merge into any existing file so a partial run doesn't drop other tickers.
    existing = {"tickers": {}}
    if os.path.exists(dest):
        try:
            with open(dest) as f:
                existing = json.load(f)
        except (json.JSONDecodeError, OSError):
            pass

    out = dict(existing.get("tickers") or {})
    ok = 0
    for t in tickers:
        rec = fetch_ticker(t)
        if rec:
            out[t] = rec
            ok += 1
        time.sleep(0.3)  # be polite to Yahoo

    as_of = date.today().isoformat()
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w") as f:
        json.dump(
            {"as_of": as_of, "tickers": dict(sorted(out.items()))},
            f, indent=0, separators=(",", ":"),
        )
        f.write("\n")

    n_close = sum(len(v["closes"]) for v in out.values())
    size = os.path.getsize(dest)
    print(f"\n{ok}/{len(tickers)} tickers fetched · {len(out)} total · "
          f"{n_close} close points · {size // 1024} KB · as of {as_of}")
    print(f"Wrote {dest}")


if __name__ == "__main__":
    main()
