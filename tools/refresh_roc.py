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
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import date, timedelta

from pypdf import PdfReader

# Fund "Groups" we know the upload-folder path for. Other groups (incl. the
# YMAG/YMAX funds-of-funds) use different folders; add them here as discovered.
GROUPS = {
    "Group 2": "Group_2_Supplemental%20and%20Tax%20IRS%20Form%208937",
}
BASE = "https://yieldmaxetfs.com/wp-content/uploads/TaxDocuments"

# Funds we can't yet locate a notice folder for — carry the app's historical
# default so they still auto-fill. Refresh once their group path is added above.
CARRY = {"YMAG": 71.0, "YMAX": 71.0}

WEEKS_BACK = 12  # how many recent weekly notices to try per group


def recent_fridays(today, n):
    """The n most recent Fridays on/before today, as date objects."""
    d = today - timedelta(days=(today.weekday() - 4) % 7)  # back up to Friday
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
    for label, folder in GROUPS.items():
        for d in recent_fridays(date.today(), WEEKS_BACK):
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
    m = re.search(r"(\d{1,2})\.(\d{1,2})\.(\d{2})(?!\d)", os.path.basename(path))
    if not m:
        return None
    mo, da, yy = (int(x) for x in m.groups())
    return date(2000 + yy, mo, da)


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

    dates = [d for d in (date_from_name(p) for p in paths) if d]
    as_of = max(dates).isoformat() if dates else date.today().isoformat()

    roc = aggregate(paths)
    dest = os.path.join(os.path.dirname(__file__), "..", "lib", "roc_data.dart")
    dest = os.path.normpath(dest)
    merged = write_dart(roc, as_of, dest)

    print(f"{len(paths)} notices · {len(roc)} funds parsed · "
          f"{len(merged)} total (incl. {len(CARRY)} carried) · as of {as_of}")
    for t in sorted(merged):
        carried = " (carried)" if t in CARRY and t not in roc else ""
        print(f"  {t:6} {merged[t]:5.1f}%{carried}")
    print(f"\nWrote {dest}")


if __name__ == "__main__":
    main()
