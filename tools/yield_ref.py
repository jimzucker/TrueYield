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


def _roc_frac(pct):
    return min(max(pct / 100.0, 0.0), 1.0)


def _compute_lot(lot, asc, sorted_bars, current_price, combined, default_roc):
    """One lot's economics (Model A — income scales by the *initial* share count).

    lot: dict {buyTs, shares, price?, sellTs?} — shares is qty and price is the
    per-share basis (null → buy-date close); principal = shares × price.
    Distributions while held (buyTs <= ts <= sellTs)
    count; each may carry its own roc (asc holds (ts, amt, roc-or-None)). A closed
    lot (sellTs set) is valued at the sell-date price (realized gain); an open lot
    at current_price."""
    market_buy_price = price_at(lot["buyTs"], sorted_bars) or current_price
    s = lot.get("shares") or 0
    buy_price = lot.get("price")
    if buy_price is None:
        buy_price = market_buy_price
    cost = s * buy_price

    sell_ts = lot.get("sellTs")
    sell_price = None if sell_ts is None else (price_at(sell_ts, sorted_bars) or current_price)

    factor = 1.0
    dist_per_share = 0.0
    income_per_share = 0.0
    for ts, amt, roc in asc:
        if ts < lot["buyTs"]:
            continue
        if sell_ts is not None and ts > sell_ts:
            continue
        p = price_at(ts, sorted_bars) or current_price
        factor *= 1 + amt / p
        dist_per_share += amt
        income_per_share += amt * (1 - _roc_frac(roc if roc is not None else default_roc))

    final_shares = s * factor
    income = s * income_per_share
    nav = final_shares * (sell_price if sell_price is not None else current_price)
    # Long-term if held more than a year (matches Dart's inDays > 365).
    is_long_term = sell_ts is not None and ((sell_ts - lot["buyTs"]) // 86400) > 365
    return {
        "buyTs": lot["buyTs"],
        "sellTs": sell_ts,
        "isClosed": sell_ts is not None,
        "isLongTerm": is_long_term,
        "initialShares": s,
        "buyPrice": buy_price,
        "sellPrice": sell_price,
        "finalShares": final_shares,
        "cost": cost,
        "distributions": s * dist_per_share,
        "incomeAmount": income,
        "taxThisYear": income * combined,
        "nav": nav,
        "costBasis": cost + income,
        "gl": nav - (cost + income),
    }


def compute(ticker, current_price, fed_pct, state_pct, local_pct, dists, bars,
            roc_pct=0.0, lt_gains_pct=15.0, lots=None):
    """dists: list[(ts, amount)] or [(ts, amount, roc-or-None)]; bars: list[(ts,
    close-or-None)] — both unsorted ok. lots: list of {buyTs, shares, price?,
    sellTs?} or None for the single default lot.

    Mirrors lib/main.dart YieldMath.compute: real broker-DRIP share growth, a
    return-of-capital-aware tax basis (see roc-cost-basis-and-gl memory), and
    per-lot aggregation (Model A)."""
    sorted_bars = sorted(bars, key=lambda b: b[0])
    if not dists:
        return {"qualifies": False, "reason": "no distributions in last 12 months"}

    combined = (fed_pct + state_pct + local_pct) / 100.0
    lt_rate = min(max((lt_gains_pct + state_pct + local_pct) / 100.0, 0.0), 1.0)
    # Normalize distributions to (ts, amt, roc-or-None).
    norm = [(d[0], d[1], d[2] if len(d) > 2 else None) for d in dists]
    asc = sorted(norm, key=lambda d: d[0])

    total = 0.0
    per_share_income = 0.0
    for ts, amt, roc in asc:
        total += amt
        per_share_income += amt * (1 - _roc_frac(roc if roc is not None else roc_pct))

    gross = total / current_price

    # First valid close ≈ price one year ago.
    start_price = current_price
    for _ts, c in sorted_bars:
        if c is not None and c > 0:
            start_price = c
            break

    # No explicit lots → one default lot (epoch 0, 1 share) → original per-share math.
    is_default_lot = not lots
    eff_lots = lots if lots else [{"buyTs": 0, "shares": 1}]
    lot_results = [
        _compute_lot(l, asc, sorted_bars, current_price, combined, roc_pct)
        for l in eff_lots
    ]

    total_cost = sum(l["cost"] for l in lot_results)
    total_initial = sum(l["initialShares"] for l in lot_results)
    total_final = sum(l["finalShares"] for l in lot_results)
    distributions_received = sum(l["distributions"] for l in lot_results)
    income_amount = sum(l["incomeAmount"] for l in lot_results)
    tax_this_year = sum(l["taxThisYear"] for l in lot_results)
    nav = sum(l["nav"] for l in lot_results)
    cost_basis = sum(l["costBasis"] for l in lot_results)
    realized_gl = sum(l["gl"] for l in lot_results if l["isClosed"])
    unrealized_gl = sum(l["gl"] for l in lot_results if not l["isClosed"])
    realized_st = sum(l["gl"] for l in lot_results if l["isClosed"] and not l["isLongTerm"])
    realized_lt = sum(l["gl"] for l in lot_results if l["isClosed"] and l["isLongTerm"])
    # Net each bucket; a losing bucket offsets the other; tax positive remainders.
    net_st, net_lt = realized_st, realized_lt
    if net_st < 0:
        net_lt += net_st
        net_st = 0.0
    elif net_lt < 0:
        net_st += net_lt
        net_lt = 0.0
    cap_gains_tax = (net_st * combined if net_st > 0 else 0.0) + (
        net_lt * lt_rate if net_lt > 0 else 0.0)
    drip_shares = total_final
    cf_gross = (total_final / total_initial if total_initial > 0 else 1.0) - 1
    per_share_tax = per_share_income * combined
    after_tax_yield_roc = (total - per_share_tax) / current_price
    total_return_before_tax = (nav - total_cost) / total_cost if total_cost > 0 else 0.0
    total_return_after_tax = (
        (nav - tax_this_year - cap_gains_tax - total_cost) / total_cost
        if total_cost > 0 else 0.0
    )

    return {
        "qualifies": True,
        "ticker": ticker,
        "currentPrice": current_price,
        "numBars": len(sorted_bars),
        "numDists": len(dists),
        "rocPct": roc_pct,
        "startPrice": start_price,
        "sumDistributions": total,
        "grossYield": gross,
        "compoundedGrossYield": cf_gross,
        "dripShares": drip_shares,
        "incomeAmount": income_amount,
        "taxThisYear": tax_this_year,
        "capGainsTax": cap_gains_tax,
        "nav": nav,
        "costBasis": cost_basis,
        "unrealizedGL": unrealized_gl,
        "realizedGL": realized_gl,
        "afterTaxYieldRoc": after_tax_yield_roc,
        "totalReturnBeforeTax": total_return_before_tax,
        "totalReturnAfterTax": total_return_after_tax,
        "totalCost": total_cost,
        "perShareIncome": per_share_income,
        "distributionsReceived": distributions_received,
        "isDefaultLot": is_default_lot,
        "lots": lot_results,
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
    # ROC share of distributions per ticker: YMAG distributions are ~71% return
    # of capital; TQQQ pays ordinary income (no ROC).
    roc_by_ticker = {"YMAG": 71.0, "TQQQ": 0.0}
    rows = []
    for t in ("YMAG", "TQQQ"):
        fx = load_fixture(f"/tmp/trueyield_fixtures/{t}.json")
        out = compute(
            ticker=fx["ticker"],
            current_price=fx["currentPrice"],
            fed_pct=32,
            state_pct=5,
            local_pct=0,
            dists=fx["dists"],
            bars=fx["bars"],
            roc_pct=roc_by_ticker.get(fx["ticker"], 0.0),
        )
        rows.append(out)

    def pct(x):
        return f"{x * 100:8.4f}%"

    def money(x):
        return f"{x:8.4f}"

    keys = [
        ("rocPct", "Return of capital (%)", lambda v: f"{v:8.1f}"),
        ("startPrice", "Start price ($)", money),
        ("sumDistributions", "Sum distributions ($)", money),
        ("grossYield", "Advertised yield", pct),
        ("afterTaxYieldRoc", "After-tax yield (ROC)", pct),
        ("compoundedGrossYield", "DRIP gross", pct),
        ("dripShares", "DRIP shares", money),
        ("incomeAmount", "Income (taxable) ($)", money),
        ("taxThisYear", "Tax this year ($)", money),
        ("nav", "NAV ($)", money),
        ("costBasis", "Cost basis ($)", money),
        ("unrealizedGL", "Unrealized G/L ($)", money),
        ("totalReturnBeforeTax", "Total return (before tax)", pct),
        ("totalReturnAfterTax", "Total return (after tax)", pct),
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

    portfolio_demo()


def portfolio_demo():
    """Multi-lot 'Portfolio (validated)' table for the YMAG fixture — the
    reference for the Dart `print Portfolio (validated)` test (same row order as
    the app's _PortfolioGrid: buy month, shares bought→now, cost, value, G/L)."""
    try:
        fx = load_fixture("/tmp/trueyield_fixtures/YMAG.json")
    except (FileNotFoundError, KeyError):
        print("\n(skip portfolio demo — YMAG fixture not on disk)")
        return

    # Three lots at different buy dates, sized in shares and dollars.
    def ts(y, m, d):
        return int(datetime(y, m, d, tzinfo=timezone.utc).timestamp())

    lots = [
        {"buyTs": ts(2025, 6, 1), "shares": 100},
        {"buyTs": ts(2025, 12, 1), "shares": 300, "price": 16},
        {"buyTs": ts(2026, 3, 1), "shares": 50},
    ]
    out = compute(
        ticker=fx["ticker"], current_price=fx["currentPrice"],
        fed_pct=32, state_pct=5, local_pct=0,
        dists=fx["dists"], bars=fx["bars"], roc_pct=71.0, lots=lots,
    )

    def m(d):
        return datetime.fromtimestamp(d, tz=timezone.utc).strftime("%b '%y")

    print("\nPortfolio (validated) — YMAG  [roc 71%, tax 37%]")
    print("-" * 60)
    print(f"{'Lot':<10}{'Shares':>16}{'Cost':>11}{'Value':>11}{'G/L':>11}")
    for l in out["lots"]:
        sh = f"{l['initialShares']:.2f}->{l['finalShares']:.2f}"
        lbl = m(l["buyTs"]) + (f"->{m(l['sellTs'])}" if l["isClosed"] else "")
        print(f"{lbl:<10}{sh:>16}{l['cost']:>11.2f}"
              f"{l['nav']:>11.2f}{l['gl']:>+11.2f}")
    ti = sum(l["initialShares"] for l in out["lots"])
    tf = sum(l["finalShares"] for l in out["lots"])
    print(f"{'Total':<10}{f'{ti:.2f}->{tf:.2f}':>16}{out['totalCost']:>11.2f}"
          f"{out['nav']:>11.2f}{out['unrealizedGL']:>+11.2f}")
    print(f"\nTotal return after tax: {out['totalReturnAfterTax'] * 100:+.2f}%")


if __name__ == "__main__":
    main()
