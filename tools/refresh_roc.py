"""Regenerate lib/roc_data.dart — a trailing return-of-capital % per YieldMax
fund — from the funds' Section 19a-1 notices.

There is no JSON feed for YieldMax ROC; the only authoritative source is the
19a-1 notices, published as one PDF per weekly payable date per fund "Group".
Each notice gives, per fund, the distribution split (net investment income /
capital gains / return of capital) for that week only — a single week is noisy
(a fund can be 0% ROC one week and 95% the next), so we aggregate several weeks:

    trailing ROC% = Σ(ROC $) / Σ(total $)   over the sampled notices.

Each fund's table is preceded by its "Fund Name CUSIP Ticker" header, so we
assign each parsed table to the most-recently-seen ticker, and keep a row only
when the stated % matches ROC$ ÷ total$ (guards against a mis-parse).

Usage:
    python3 tools/refresh_roc.py                 # fetch recent notices, regenerate
    python3 tools/refresh_roc.py path/to/*.pdf   # parse local notice PDFs instead

Requires pypdf:  python3 -m venv .venv && .venv/bin/pip install pypdf
"""

import glob
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone

from pypdf import PdfReader

# Fund "Groups" we know the upload-folder path for, as
# label -> (upload-folder, payable weekday: Mon=0 … Sun=6). The filename embeds
# the same label. YieldMax reorganized in 2026: the single notice per group now
# covers many funds. "Group 1" holds the funds-of-funds (YMAG, YMAX) + ULTY etc.
# Notices are weekly but only filed on weeks with a non-income source, so many
# dates 404 — that's a no-ROC week, not a wrong URL.
GROUPS = {
    "Group 1": ("Group_1_Supplemental%20and%20Tax%20IRS%20Form%208937", 3),
}
BASE = "https://yieldmaxetfs.com/wp-content/uploads/TaxDocuments"

# Goldman GPIX/GPIQ have no headless-scriptable per-distribution source — the
# notice URLs are JS-gated GUIDs only discoverable via web search (see
# reference-roc-19a-sources). Carry a verified recent ROC% so they still auto-fill
# a fund-appropriate default. (First Trust, Invesco and Amplify now have real
# adapters in roc_sources.py.)
CARRY = {
    "GPIX": 70.0,
    "GPIQ": 72.0,
}

WEEKS_BACK = 26  # how many recent weekly notices to try per group


def recent_weekdays(today, weekday, n):
    """The n most recent dates on/before today falling on [weekday] (Mon=0)."""
    d = today - timedelta(days=(today.weekday() - weekday) % 7)
    return [d - timedelta(weeks=i) for i in range(n)]


def notice_url(folder, group_label, d):
    # Filenames use M.D.YY with no zero-padding, e.g. "12.5.25".
    stamp = f"{d.month}.{d.day}.{d.year % 100}"
    name = f"YieldMax 19a-1 Notice {stamp} Payable - {group_label}.pdf"
    return f"{BASE}/{folder}/{urllib.parse.quote(name)}"


def fetch(url, dest):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = r.read()
    except Exception:
        return False
    # A 404 returns a small HTML page, not a PDF.
    if not data.startswith(b"%PDF") or len(data) < 10000:
        return False
    with open(dest, "wb") as f:
        f.write(data)
    return True


def download_notices(workdir):
    os.makedirs(workdir, exist_ok=True)
    paths = []
    for label, (folder, weekday) in GROUPS.items():
        for d in recent_weekdays(date.today(), weekday, WEEKS_BACK):
            dest = os.path.join(workdir, f"{label.replace(' ', '_')}_{d}.pdf")
            if os.path.exists(dest) or fetch(notice_url(folder, label, d), dest):
                paths.append(dest)
    return paths


def parse_notice(path):
    """{ticker: (roc_dollars, total_dollars)} for one notice PDF."""
    txt = "\n".join((p.extract_text() or "") for p in PdfReader(path).pages)
    lines = [ln.strip() for ln in txt.splitlines()]
    pending = None
    roc_pct = roc_amt = None
    rows = {}
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("Fund Name") and "Ticker" in ln:
            j = i + 1
            while j < len(lines) and not lines[j]:
                j += 1
            m = re.search(r"([A-Z]{2,6})\s*$", lines[j]) if j < len(lines) else None
            pending = m.group(1) if m else None
            roc_pct = None
            i = j + 1
            continue
        m = re.match(r"Estimated Return of Capital\s+\$([0-9.]+)\s+([0-9.]+)%", ln)
        if m:
            roc_amt, roc_pct = float(m.group(1)), float(m.group(2))
        m = re.match(r"Total \(per common share\)\s+\$([0-9.]+)", ln)
        if m and pending and roc_pct is not None:
            tot = float(m.group(1))
            # Cross-check the stated % against the dollars; skip if they disagree.
            if tot > 0 and abs(roc_amt / tot * 100 - roc_pct) < 1.5:
                rows[pending] = (roc_amt, tot)
            pending = roc_pct = None
        i += 1
    return rows


def date_from_name(path):
    base = os.path.basename(path)
    # Original notice names embed the payable date as M.D.YY ("12.5.25");
    # auto-downloaded files are saved as ...{YYYY-MM-DD}.pdf.
    m = re.search(r"(\d{1,2})\.(\d{1,2})\.(\d{2})(?!\d)", base)
    if m:
        mo, da, yy = (int(x) for x in m.groups())
        return date(2000 + yy, mo, da)
    m = re.search(r"(\d{4})-(\d{2})-(\d{2})", base)
    if m:
        y, mo, da = (int(x) for x in m.groups())
        return date(y, mo, da)
    return None


def aggregate(paths):
    acc = {}
    for p in paths:
        for t, (roc, tot) in parse_notice(p).items():
            a = acc.setdefault(t, [0.0, 0.0, 0])
            a[0] += roc
            a[1] += tot
            a[2] += 1
    # Keep funds seen in at least half the notices (drops one-off mis-parses).
    threshold = max(2, len(paths) // 2)
    out = {
        t: round(roc / tot * 100, 1)
        for t, (roc, tot, n) in acc.items()
        if n >= threshold and tot > 0
    }
    return out


def trailing_from_history(history, n=8):
    """Per-fund trailing ROC% (mean of each fund's most recent [n] payable
    dates) — the kRocByTicker auto-fill default, covering every fund we have any
    history for."""
    out = {}
    for t, dates in history.items():
        pts = [dates[d] for d in sorted(dates)[-n:]]
        if pts:
            out[t] = round(sum(pts) / len(pts), 1)
    return out


def write_dart(roc_by_ticker, as_of, dest):
    merged = dict(CARRY)
    merged.update(roc_by_ticker)  # parsed values win over carried defaults
    lines = [
        "// GENERATED by tools/refresh_roc.py — do not edit by hand.",
        "//",
        "// Trailing return-of-capital % per YieldMax fund, aggregated from their",
        "// Section 19a-1 notices (ROC $ / total $ over the sampled weeks). These",
        "// are estimates; rerun the script to refresh. See the project-roc-autofetch",
        "// memory for the source/approach.",
        "//",
        f"// As of: {as_of}",
        "",
        f"const String kRocDataAsOf = '{as_of}';",
        "",
        "/// Ticker -> trailing return-of-capital %, used to auto-fill the ROC field",
        "/// when a known YieldMax fund is entered.",
        "const Map<String, double> kRocByTicker = {",
    ]
    for t in sorted(merged):
        lines.append(f"  '{t}': {merged[t]},")
    lines.append("};")
    with open(dest, "w") as f:
        f.write("\n".join(lines) + "\n")
    return merged


def build_history(paths):
    """{ticker: {"YYYY-MM-DD": rocPct}} — each notice's per-fund ROC% keyed by
    its payable date (the per-distribution ROC)."""
    hist = {}
    for p in paths:
        d = date_from_name(p)
        if d is None:
            continue
        iso = d.isoformat()
        for t, (roc, tot) in parse_notice(p).items():
            if tot > 0:
                hist.setdefault(t, {})[iso] = round(roc / tot * 100, 1)
    return hist


def load_history(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}


def merge_history(existing, fresh):
    """Union of the two; freshly-parsed values win on a date collision."""
    out = {t: dict(dates) for t, dates in existing.items()}
    for t, dates in fresh.items():
        out.setdefault(t, {}).update(dates)
    return out


def save_history(history, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # Sort tickers, and dates within each, for stable diffs.
    ordered = {
        t: {d: history[t][d] for d in sorted(history[t])} for t in sorted(history)
    }
    with open(path, "w") as f:
        json.dump(ordered, f, indent=2, sort_keys=False)
        f.write("\n")


def write_history_csv(history, path):
    """Tidy long-format ROC CSV (ticker,payable_date,roc_pct) — an Info-tab
    download link."""
    with open(path, "w") as f:
        f.write("ticker,payable_date,roc_pct\n")
        for t in sorted(history):
            for d in sorted(history[t]):
                f.write(f"{t},{d},{history[t][d]}\n")


def _epoch(iso):
    y, m, d = (int(x) for x in iso.split("-"))
    return int(datetime(y, m, d, tzinfo=timezone.utc).timestamp())


def write_history_dart(history, as_of, dest):
    """lib/roc_history.dart — per-payable-date ROC by ticker, epoch-keyed, used to
    auto-fill the Distributions-tab per-distribution ROC."""
    lines = [
        "// GENERATED by tools/refresh_roc.py — do not edit by hand.",
        "//",
        "// Per-payable-date return-of-capital % per YieldMax fund, parsed from the",
        "// Section 19a-1 notices. Inner key = the payable date as a Unix epoch",
        "// (seconds, UTC midnight). Used to pre-fill the Distributions-tab",
        "// per-distribution ROC. See the project-roc-autofetch memory.",
        "//",
        f"// As of: {as_of}",
        "",
        f"const String kRocHistoryAsOf = '{as_of}';",
        "",
        "/// Ticker -> {payable-date epoch (s) -> return-of-capital %}.",
        "const Map<String, Map<int, double>> kRocByTickerByEpoch = {",
    ]
    for t in sorted(history):
        entries = ", ".join(
            f"{_epoch(d)}: {history[t][d]}" for d in sorted(history[t])
        )
        lines.append(f"  '{t}': {{{entries}}},")
    lines.append("};")
    with open(dest, "w") as f:
        f.write("\n".join(lines) + "\n")


def main():
    args = [a for a in sys.argv[1:] if a.endswith(".pdf") or "*" in a]
    if args:
        paths = []
        for a in args:
            paths.extend(glob.glob(a))
    else:
        paths = download_notices("/tmp/yieldmax_19a1")
    if not paths:
        sys.exit("No notice PDFs found/fetched.")

    # The refresh stamp is the generation date — multiple data sources, many
    # lagging the notice dates, so "today" is the honest "as of".
    as_of = date.today().isoformat()

    root = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))

    # Per-payable-date history: merge this run's notices into the committed JSON.
    hist_path = os.path.join(root, "data", "roc_history.json")
    history = merge_history(load_history(hist_path), build_history(paths))
    save_history(history, hist_path)
    write_history_csv(history, os.path.join(root, "data", "roc_history.csv"))
    write_history_dart(
        history, as_of, os.path.join(root, "lib", "roc_history.dart")
    )

    # Trailing per-fund default (kRocByTicker), derived from the FULL merged
    # history so every fund — not just this run's notices — keeps a value.
    roc = trailing_from_history(history)
    dest = os.path.join(root, "lib", "roc_data.dart")
    merged = write_dart(roc, as_of, dest)

    n_dates = sum(len(v) for v in history.values())
    print(f"{len(paths)} notices · {len(roc)} funds · "
          f"{len(merged)} in roc_data (incl. {len(CARRY)} carried) · as of {as_of}")
    print(f"history: {len(history)} funds · {n_dates} dated ROC points")
    for t in sorted(merged):
        carried = " (carried)" if t in CARRY and t not in roc else ""
        print(f"  {t:6} {merged[t]:5.1f}%{carried}")
    print(f"\nWrote {dest}, lib/roc_history.dart, {hist_path}")


if __name__ == "__main__":
    main()
