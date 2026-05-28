"""Independent Python port of YieldMath.compute for cross-checking the Dart
implementation. Reads the cached Yahoo JSON and produces expected outputs."""

import json
import sys
from datetime import datetime, timezone


def bar_index_at(div_ts, bars):
    """Latest bar whose ts is <= div_ts. Returns -1 if no such bar."""
    idx = -1
    for i, (ts, _close) in enumerate(bars):
        if ts <= div_ts:
            idx = i
        else:
            break
    return idx


def price_at(div_ts, bars):
    if not bars:
        return None
    idx = bar_index_at(div_ts, bars)
    start = idx if idx >= 0 else 0
    for j in range(start, -1, -1):
        c = bars[j][1]
        if c is not None:
            return c
    for j in range(start + 1, len(bars)):
        c = bars[j][1]
        if c is not None:
            return c
    return None


def compute(ticker, current_price, fed_pct, state_pct, local_pct, dists, bars):
    """dists: list[(ts, amount)], bars: list[(ts, close-or-None)] — both unsorted ok."""
    sorted_bars = sorted(bars, key=lambda b: b[0])
    if not dists:
        return {"qualifies": False, "reason": "no distributions in last 12 months"}

    combined = (fed_pct + state_pct + local_pct) / 100.0
    asc = sorted(dists, key=lambda d: d[0])
    div_by_bar = [0.0] * len(sorted_bars)

    total = 0.0
    cf_gross = 1.0
    cf_net = 1.0
    for ts, amt in asc:
        total += amt
        bi = bar_index_at(ts, sorted_bars)
        if 0 <= bi < len(div_by_bar):
            div_by_bar[bi] += amt
        p = price_at(ts, sorted_bars) or current_price
        cf_gross *= 1 + amt / p
        cf_net *= 1 + (amt * (1 - combined)) / p

    gross = total / current_price
    after = gross * (1 - combined)

    valids = [c for _, c in sorted_bars if c is not None and c > 0]
    avg_price = (sum(valids) / len(valids)) if valids else current_price
    avg_gross = total / avg_price
    avg_net = avg_gross * (1 - combined)

    twr_g = 1.0
    twr_n = 1.0
    for i in range(len(sorted_bars) - 1):
        p0 = sorted_bars[i][1]
        p1 = sorted_bars[i + 1][1]
        if p0 is None or p1 is None or p0 <= 0:
            continue
        d = div_by_bar[i] if i < len(div_by_bar) else 0.0
        twr_g *= (p1 + d) / p0
        twr_n *= (p1 + d * (1 - combined)) / p0

    return {
        "qualifies": True,
        "ticker": ticker,
        "currentPrice": current_price,
        "numBars": len(sorted_bars),
        "numDists": len(dists),
        "sumDistributions": total,
        "grossYield": gross,
        "afterTaxYield": after,
        "compoundedGrossYield": cf_gross - 1,
        "compoundedAfterTaxYield": cf_net - 1,
        "avgPriceGrossYield": avg_gross,
        "avgPriceAfterTaxYield": avg_net,
        "twrGross": twr_g - 1,
        "twrAfterTax": twr_n - 1,
    }


def load_fixture(path):
    d = json.load(open(path))
    r = d["chart"]["result"][0]
    meta = r["meta"]
    ts = r.get("timestamp", [])
    closes = r["indicators"]["quote"][0]["close"]
    bars = list(zip(ts, closes))
    divs_map = r.get("events", {}).get("dividends", {}) or {}
    dists = []
    for v in divs_map.values():
        dists.append((int(v["date"]), float(v["amount"])))
    return {
        "ticker": meta["symbol"],
        "currentPrice": float(meta["regularMarketPrice"]),
        "bars": bars,
        "dists": dists,
    }


def main():
    rows = []
    for t in ("YMAG", "TQQQ"):
        fx = load_fixture(f"/tmp/iyield_fixtures/{t}.json")
        out = compute(
            ticker=fx["ticker"],
            current_price=fx["currentPrice"],
            fed_pct=32,
            state_pct=5,
            local_pct=0,
            dists=fx["dists"],
            bars=fx["bars"],
        )
        rows.append(out)

    def pct(x):
        return f"{x * 100:8.4f}%"

    keys = [
        ("sumDistributions", "Sum distributions ($)", lambda v: f"{v:8.4f}"),
        ("grossYield", "Gross yield (simple TTM)", pct),
        ("afterTaxYield", "After-tax yield (simple)", pct),
        ("compoundedGrossYield", "DRIP gross", pct),
        ("compoundedAfterTaxYield", "DRIP after-tax", pct),
        ("avgPriceGrossYield", "Avg-price gross", pct),
        ("avgPriceAfterTaxYield", "Avg-price after-tax", pct),
        ("twrGross", "TWR gross (incl. price)", pct),
        ("twrAfterTax", "TWR after-tax", pct),
    ]

    name_w = max(len(label) for _, label, _ in keys) + 1
    headers = [r["ticker"] for r in rows]
    col_w = 12

    print(f"\nTax: fed=32%, state=5%, local=0% (combined 37%)")
    print(f"Fetched: {datetime.now(timezone.utc).isoformat()}\n")
    head = f"{'Metric':<{name_w}} " + " ".join(f"{h:>{col_w}}" for h in headers)
    print(head)
    print("-" * len(head))
    print(f"{'Current price ($)':<{name_w}} " +
          " ".join(f"{r['currentPrice']:>{col_w}.4f}" for r in rows))
    print(f"{'# bars':<{name_w}} " +
          " ".join(f"{r['numBars']:>{col_w}d}" for r in rows))
    print(f"{'# distributions':<{name_w}} " +
          " ".join(f"{r['numDists']:>{col_w}d}" for r in rows))
    print("-" * len(head))
    for k, label, fmt in keys:
        line = f"{label:<{name_w}} " + " ".join(
            f"{fmt(r[k]):>{col_w}}" for r in rows
        )
        print(line)

    print("\n# Dart literals for tests (precision 1e-5):")
    for r in rows:
        print(f"\n  // {r['ticker']}")
        for k, _, _ in keys:
            v = r[k]
            print(f"  expect(result.{k}, closeTo({v:.6f}, 1e-5));")


if __name__ == "__main__":
    main()
