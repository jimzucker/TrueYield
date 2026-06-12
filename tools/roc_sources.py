"""Per-issuer Section 19a-1 ROC scrapers — extends the YieldMax-only
refresh_roc.py to the rest of the tracked option-income funds.

Each issuer publishes its return-of-capital split differently (per-fund PDF,
bundled multi-fund PDF, single cumulative file, DOCX, page-scraped hrefs), but
the *number* we want is the same: per payable date, what % of the distribution
was return of capital. Every adapter returns {ticker: {"YYYY-MM-DD": rocPct}}.

Coverage (verified fetchable from a plain Mozilla-UA GET, no JS):
  NEOS       SPYI QQQI BTCI IWMI IAUI   per-fund PDFs, hrefs off the fund page
  Global X   QYLD XYLD RYLD             per-fund PDF/DOCX, listing page (to 2015)
  ProShares  ISPY IQQQ                  per-fund PDF, listing page
  iShares    TLTW LQDW IVVW             ONE bundled "buywrites" PDF per date
  REX        FEPI AIPI                  ONE cumulative PDF holds all history
  VistaShares OMAH                      per-fund PDF, hrefs off the product page
  TappAlpha  TSPY                       per-fund PDF, hrefs off the product page
  Roundhill  QDTE XDTE                  always 100% ROC (seeded from div dates)
  constants  JEPI JEPQ BUYW = 0%        no 19a notice; ordinary income

Not yet covered (need a different mechanism — see notes): Amplify DIVO/QDVO
(listing 403), First Trust FTHI/FTQI/EIPI (GUID archive + per-doc column order),
Goldman GPIX/GPIQ (opaque GUID URLs, JS-rendered listing), Invesco PBP (curl 406).

Usage:
    python3 tools/roc_sources.py                 # bootstrap all → merge history
    python3 tools/roc_sources.py probe neos      # dry-run one issuer, print results
"""

import io
import os
import re
import sys
import urllib.request
import zipfile
from datetime import date, timedelta

from pypdf import PdfReader

import refresh_roc as rr  # load/merge/save history + dart writer + epoch

UA = {"User-Agent": "Mozilla/5.0"}
TIMEOUT = 60

MONTHS = {m: i for i, m in enumerate(
    ["january", "february", "march", "april", "may", "june", "july",
     "august", "september", "october", "november", "december"], 1)}


# ---------------------------------------------------------------- HTTP / files
def _get(url, binary=False):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        data = r.read()
    return data if binary else data.decode("utf-8", "ignore")


def _pdf_text(data):
    return "\n".join((p.extract_text() or "") for p in PdfReader(io.BytesIO(data)).pages)


def _docx_text(data):
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        xml = z.read("word/document.xml").decode("utf-8", "ignore")
    # Paragraph ends -> newline; drop every other tag with NO substitution so a
    # number split across runs (<w:t>1</w:t><w:t>7</w:t>) rejoins ("17", not
    # "1 7"). Real spaces live inside the text nodes, so they survive.
    xml = re.sub(r"</w:p>", "\n", xml)
    return re.sub(r"<[^>]+>", "", xml)


def _doc_text(url):
    data = _get(url, binary=True)
    return _docx_text(data) if url.lower().endswith(".docx") else _pdf_text(data)


# --------------------------------------------------------------- date parsing
def _date_prose(s):
    """'November 28th, 2025' / 'June 5, 2026' -> date, else None."""
    m = re.search(r"([A-Za-z]+)\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})", s)
    if m and m.group(1).lower() in MONTHS:
        return date(int(m.group(3)), MONTHS[m.group(1).lower()], int(m.group(2)))
    return None


def _date_mdy(s):
    """'11.28.25' or '11-28-25' or '112825' -> date (2-digit year), else None."""
    m = re.search(r"(\d{1,2})[.\-](\d{1,2})[.\-](\d{2})(?!\d)", s) \
        or re.search(r"(\d{2})(\d{2})(\d{2})(?!\d)", s)
    if not m:
        return None
    mo, da, yy = (int(x) for x in m.groups())
    return date(2000 + yy, mo, da) if 1 <= mo <= 12 and 1 <= da <= 31 else None


def _date_mdY(s):
    """'11182024' (MMDDYYYY) -> date, else None."""
    m = re.search(r"(\d{2})(\d{2})(\d{4})(?!\d)", s)
    if not m:
        return None
    mo, da, yy = int(m.group(1)), int(m.group(2)), int(m.group(3))
    return date(yy, mo, da) if 1 <= mo <= 12 and 1 <= da <= 31 else None


def _payable_date(text, fallback=None):
    """Prefer the 'payable on <date>' / 'Pay Date <date>' prose; else fallback."""
    m = re.search(r"payable on\s+([A-Za-z]+\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4})", text, re.I) \
        or re.search(r"Pay\s*Date[:\s]+([A-Za-z]+\s+\d{1,2},?\s+\d{4})", text, re.I)
    return (_date_prose(m.group(1)) if m else None) or fallback


# ----------------------------------------------------------------- ROC from text
_ROC_LABEL = r"(?:Estimated\s+)?Return of Capital"
_TOT_LABEL = r"Total \(per (?:common share|Capital Share|share)\)"


def _roc_pct(text):
    """Best per-distribution ROC% from one notice block, or None.

    Precedence: ROC$/total$ (most precise) > inline % on the ROC line >
    prose '...X% ... return of capital'.
    """
    text = re.sub(r"\s+", " ", text)  # notices line-wrap mid-phrase
    rm = re.search(_ROC_LABEL + r"\s*\$([0-9.]+)", text)
    tm = re.search(_TOT_LABEL + r"\s*\$([0-9.]+)", text)
    if rm and tm:
        roc, tot = float(rm.group(1)), float(tm.group(1))
        if tot > 0 and roc <= tot * 1.0001:
            return round(roc / tot * 100, 1)
    inline = re.search(_ROC_LABEL + r"\s*\$[0-9.]+\s+([0-9.]+)\s*%", text)
    if inline:
        return round(float(inline.group(1)), 1)
    prose = re.search(r"(\d+(?:\.\d+)?)\s*%[^.]*?return\s+of\s+capital", text, re.I)
    if prose:
        return round(float(prose.group(1)), 1)
    return None


def _hrefs(html, pat):
    return re.findall(pat, html)


# --------------------------------------------------------------------- adapters
def neos():
    base = "https://neosfunds.com/{}/"
    out = {}
    for t in ["SPYI", "QQQI", "BTCI", "IWMI", "IAUI"]:
        try:
            html = _get(base.format(t.lower()))
        except Exception as e:
            print(f"  NEOS {t}: page failed ({e})"); continue
        urls = sorted(set(_hrefs(
            html, r"https://neosfunds\.com/wp-content/uploads/[^\"']*?19a1[^\"']*?\.pdf")))
        d = {}
        for u in urls:
            try:
                txt = _pdf_text(_get(u, binary=True))
            except Exception:
                continue
            dt = _payable_date(txt, _date_mdy(os.path.basename(u)))
            pct = _roc_pct(txt)
            if dt and pct is not None:
                d[dt.isoformat()] = pct
        if d:
            out[t] = d
        print(f"  NEOS {t}: {len(d)} dates")
    return out


def globalx():
    out = {}
    for t in ["QYLD", "XYLD", "RYLD"]:
        try:
            html = _get(f"https://www.globalxetfs.com/filings-and-tax-supplements/{t}")
        except Exception as e:
            print(f"  GlobalX {t}: page failed ({e})"); continue
        urls = sorted(set(_hrefs(
            html, rf"https://assets\.globalxetfs\.com/funds/tax_supplements/{t}_Form-19a_[0-9]+\.(?:pdf|docx)")))
        d = {}
        for u in urls:
            try:
                txt = _doc_text(u)
            except Exception:
                continue
            dt = _payable_date(txt, _date_mdY(os.path.basename(u)))
            pct = _roc_pct(txt)
            if dt and pct is not None:
                d[dt.isoformat()] = pct
        if d:
            out[t] = d
        print(f"  GlobalX {t}: {len(d)} dates")
    return out


def proshares():
    try:
        html = _get("https://www.proshares.com/resources/tax-and-filing-documents/19a-1")
    except Exception as e:
        print(f"  ProShares: listing failed ({e})"); return {}
    out = {}
    for t in ["ISPY", "IQQQ"]:
        urls = sorted(set(
            "https://www.proshares.com" + h for h in _hrefs(
                html, rf"/globalassets/proshares/documents/19a1/{t.lower()}_19a-[0-9]+\.pdf")))
        d = {}
        for u in urls:
            try:
                txt = _pdf_text(_get(u, binary=True))
            except Exception:
                continue
            dt = _payable_date(txt, _date_mdy(os.path.basename(u)))
            pct = _roc_pct(txt)
            if dt and pct is not None:
                d[dt.isoformat()] = pct
        if d:
            out[t] = d
        print(f"  ProShares {t}: {len(d)} dates")
    return out


def ishares():
    """TLTW/LQDW/IVVW share one bundled 'buywrites' PDF per date; each fund is a
    row giving '$<total> ... $<roc> (x%)'. Parse the row per ticker."""
    try:
        html = _get("https://www.ishares.com/us/library/section-19-notices")
    except Exception as e:
        print(f"  iShares: listing failed ({e})"); return {}
    urls = sorted(set(
        "https://www.ishares.com" + h for h in _hrefs(
            html, r"/us/literature/distribution-information/etf-section19-buywrites-[0-9-]+\.pdf")))
    out = {"TLTW": {}, "LQDW": {}, "IVVW": {}}
    for u in urls:
        try:
            txt = _pdf_text(_get(u, binary=True))
        except Exception:
            continue
        dt = _payable_date(txt, _date_mdy(os.path.basename(u)))
        if not dt:
            continue
        for t in out:
            # Row: "... TICKER CUSIP $total $income (x%) [$stcg (x%)] $roc (x%)".
            # OCR leaves spaces inside the dollar figures, so read the inline
            # percentages: the LAST one on the row is the ROC %. First match =
            # the Current-distribution table (Cumulative FYTD comes second).
            line = re.search(rf"\b{t}\s+[0-9A-Z]{{6,}}\s+(.+)", txt)
            if line:
                pcts = re.findall(r"\(\s*(\d+)\s*%\s*\)", line.group(1))
                if pcts:
                    out[t][dt.isoformat()] = float(pcts[-1])
    for t, d in out.items():
        print(f"  iShares {t}: {len(d)} dates")
    return {t: d for t, d in out.items() if d}


def rex():
    """Each REX fund has ONE cumulative PDF (overwritten) holding every notice
    newest-first. Split into per-notice blocks and parse each."""
    files = {
        "FEPI": "https://www.rexshares.com/wp-content/uploads/2024/04/19a-1-Notice-to-Shareholders-FEPI.pdf",
        "AIPI": "https://www.rexshares.com/wp-content/uploads/2024/07/19a-1-notice-to-shareholders-aipi.pdf",
    }
    out = {}
    for t, u in files.items():
        try:
            txt = _pdf_text(_get(u, binary=True))
        except Exception as e:
            print(f"  REX {t}: failed ({e})"); continue
        # Block boundary = each notice's 'Return of Capital' line; pair with the
        # nearest 'Pay Date'/'payable on' date that precedes it.
        d = {}
        marks = [(m.start(), m.group()) for m in re.finditer(
            r"(?:Pay Date|payable on|Return of Capital)", txt)]
        last_date = None
        for pos, kind in marks:
            window = txt[pos:pos + 80]
            if kind in ("Pay Date", "payable on"):
                dt = _payable_date(txt[pos:pos + 80])
                if dt:
                    last_date = dt
            else:  # Return of Capital
                pct = _roc_pct(txt[pos - 10:pos + 80])
                if last_date and pct is not None:
                    d[last_date.isoformat()] = pct
        if d:
            out[t] = d
        print(f"  REX {t}: {len(d)} dates")
    return out


def _page_scrape(ticker, page_url, href_pat):
    try:
        html = _get(page_url)
    except Exception as e:
        print(f"  {ticker}: page failed ({e})"); return {}
    urls = sorted(set(_hrefs(html, href_pat)))
    d = {}
    for u in urls:
        try:
            txt = _pdf_text(_get(u.replace("%20", " ").replace(" ", "%20"), binary=True))
        except Exception:
            continue
        dt = _payable_date(txt, _date_mdy(urllib_unquote(os.path.basename(u))))
        pct = _roc_pct(txt)
        if dt and pct is not None:
            d[dt.isoformat()] = pct
    print(f"  {ticker}: {len(d)} dates")
    return {ticker: d} if d else {}


def urllib_unquote(s):
    return urllib.request.unquote(s)


def vistashares():
    return _page_scrape(
        "OMAH", "https://www.vistashares.com/etf/omah/",
        r"https://www\.vistashares\.com/wp-content/uploads/[^\"']*?OMAH[^\"']*?19a[^\"']*?\.pdf")


def tappalpha():
    return _page_scrape(
        "TSPY", "https://www.tappalphafunds.com/etfs/tspy",
        r"https://cdn\.prod\.website-files\.com/[^\"']*?TSPY[^\"']*?19a[^\"']*?\.pdf")


_MONTHS_NAME = [
    "january", "february", "march", "april", "may", "june", "july",
    "august", "september", "october", "november", "december",
]


def _get_plain(url):
    """Invesco's Akamai WAF 406s a *browser* UA but serves a plain one fine."""
    req = urllib.request.Request(url, headers={"User-Agent": "Python-urllib/3.12"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.read()


def _invesco_pbp_roc(pdf_bytes):
    """PBP row: NII · GainFromSale · ReturnOfPrincipal · NetUnrealizedDepr (per
    share $; '$ -' = 0). ROC% = RoP / (NII + Gain + RoP)."""
    import io
    import pdfplumber
    f = lambda s: 0.0 if s.replace(" ", "") == "-" else float(s.replace(" ", ""))
    with pdfplumber.open(io.BytesIO(pdf_bytes)) as pdf:
        for p in pdf.pages:
            for line in (p.extract_text() or "").splitlines():
                if re.match(r"^PBP\s", line):
                    nums = re.findall(r"\$\s*([\d][\d.\s]*\d|\d|-)", line)
                    if len(nums) >= 3:
                        nii, gain, rop = f(nums[0]), f(nums[1]), f(nums[2])
                        tot = nii + gain + rop
                        return round(rop / tot * 100, 1) if tot > 0 else None
    return None


def invesco(div_dates):
    """PBP — one combined monthly Invesco notice per pay month; fetch the notice
    for each Yahoo distribution's month and key the ROC by that ex-date so it
    matches in-app."""
    base = ("https://www.invesco.com/content/dam/invesco/us/en/documents/"
            "section-19a/Invesco-19a-section-notice-{}-{}.pdf")
    d, cache = {}, {}
    for ex in div_dates.get("PBP", [])[-18:]:
        y, m, _ = (int(x) for x in ex.split("-"))
        if (y, m) not in cache:
            try:
                data = _get_plain(base.format(_MONTHS_NAME[m - 1], y))
                cache[(y, m)] = data if data.startswith(b"%PDF") else None
            except Exception:
                cache[(y, m)] = None
        data = cache[(y, m)]
        if data:
            roc = _invesco_pbp_roc(data)
            if roc is not None:
                d[ex] = roc
    print(f"  Invesco PBP: {len(d)} dates")
    return {"PBP": d} if d else {}


_FT_NUM = r"(\$[\d,]+\.\d+|-)"
_FT_PCT = r"([\d.]+%|-)"


def _ft_row_roc(pdf_bytes, ticker):
    """First Trust notices are row-per-fund and pdfplumber linearizes them. Read
    the CURRENT table (before the cumulative one); ROC of 0 prints as '-'."""
    import io
    import pdfplumber
    with pdfplumber.open(io.BytesIO(pdf_bytes)) as pdf:
        text = "\n".join(p.extract_text() or "" for p in pdf.pages)
    current = re.split(r"Total Cumulative|Cumulative\s+Fiscal", text)[0]
    row = re.compile(
        rf"^{ticker}(?:\s*\(\d+\))?\s+[0-9A-Z]{{9}}\s+\S+\s+\w+\s+"
        + r"\s+".join([_FT_NUM] * 5)   # Total, NII, STCG, LTCG, ROC ($)
        + r"\s+" + r"\s+".join([_FT_PCT] * 4)  # NII, STCG, LTCG, ROC (%)
    )
    money = lambda s: None if s == "-" else float(s.replace("$", "").replace(",", ""))
    pct = lambda s: None if s == "-" else float(s.rstrip("%"))
    for line in current.splitlines():
        m = row.match(line.strip())
        if m:
            g = m.groups()  # 0..8: Total,NII,STCG,LTCG,ROC$, NII%,STCG%,LTCG%,ROC%
            roc_pct = pct(g[8])
            if roc_pct is None:
                total, roc_d = money(g[0]), money(g[4])
                roc_pct = round(roc_d / total * 100, 1) if roc_d and total else 0.0
            return round(roc_pct, 1)
    return None


def firsttrust():
    """FTHI/FTQI/EIPI — scrape the per-ticker 19a-1 archive for GUID PDFs (paired
    with their notice date), then parse each fund's ROC row."""
    arch = ("https://www.ftportfolios.com/Retail/Etf/Etffundnewsarchive.aspx"
            "?Ticker={}&SubCategoryCode=19A1_NOTICES")
    loader = "https://www.ftportfolios.com/Common/ContentFileLoader.aspx?ContentGUID={}"
    out = {}
    for t in ["FTHI", "FTQI", "EIPI"]:
        try:
            html = _get(arch.format(t))
        except Exception as e:
            print(f"  FirstTrust {t}: archive failed ({e})"); continue
        pairs = re.findall(
            r"ContentGUID=([0-9a-f-]{36}).{0,400}?19a-1 Notice\s*[–\-]\s*"
            r"(\d{1,2}/\d{1,2}/\d{4})", html, re.S)
        d, seen = {}, set()
        for guid, datestr in pairs:
            if guid in seen:
                continue
            seen.add(guid)
            mo, da, yr = (int(x) for x in datestr.split("/"))
            try:
                roc = _ft_row_roc(_get(loader.format(guid), binary=True), t)
            except Exception:
                continue
            if roc is not None:
                d[date(yr, mo, da).isoformat()] = roc
        if d:
            out[t] = d
        print(f"  FirstTrust {t}: {len(d)} dates")
    return out


def amplify(div_dates):
    """DIVO/QDVO — the tax-center listing is 403, but the per-notice PDF URL is
    constructable from the pay date (= Yahoo ex-date + 1, verified). Try a small
    offset window per distribution."""
    import time
    base = "https://amplifyetfs.com/wp-content/uploads/files/19a-1_Notice_{}_{}.pdf"
    out = {}
    for t in ["DIVO", "QDVO"]:
        d = {}
        # Recent ~3y only — older notices predate Amplify's filing and bulk
        # requests trip the site's bot protection (which throttles randomly), so
        # retry the still-unresolved dates a few passes. Pay date = ex-date + 1
        # (try that first), then a small window either side.
        exs = div_dates.get(t, [])[-36:]
        resolved = set()
        for _ in range(3):
            pending = [e for e in exs if e not in resolved]
            if not pending:
                break
            for ex in pending:
                y, m, da = (int(x) for x in ex.split("-"))
                for off in (1, 0, 2, 3):
                    dt = date(y, m, da) + timedelta(days=off)
                    stamp = f"{dt.month:02d}-{dt.day:02d}-{dt.year % 100:02d}"
                    try:
                        data = _get(base.format(stamp, t), binary=True)
                    except Exception:
                        continue
                    if not data.startswith(b"%PDF"):
                        continue
                    pct = _roc_pct(_pdf_text(data))
                    if pct is not None:
                        d[(_payable_date(_pdf_text(data)) or dt).isoformat()] = pct
                        resolved.add(ex)
                    break
                time.sleep(0.3)
        if d:
            out[t] = d
        print(f"  Amplify {t}: {len(d)} dates")
    return out


def roundhill(div_dates):
    """QDTE/XDTE are 100% ROC on every notice observed; seed each fund's
    distribution dates (from Yahoo) at 100%."""
    out = {}
    for t in ["QDTE", "XDTE"]:
        d = {ds: 100.0 for ds in div_dates.get(t, [])}
        if d:
            out[t] = d
        print(f"  Roundhill {t}: {len(d)} dates (100% ROC)")
    return out


def constants(div_dates):
    """Funds with no 19a notice / no ROC: ordinary-income distributions."""
    out = {}
    for t in ["JEPI", "JEPQ", "BUYW"]:
        d = {ds: 0.0 for ds in div_dates.get(t, [])}
        if d:
            out[t] = d
        print(f"  const {t}: {len(d)} dates (0% ROC)")
    return out


ADAPTERS = {
    "neos": neos, "globalx": globalx, "proshares": proshares,
    "ishares": ishares, "rex": rex, "vistashares": vistashares,
    "tappalpha": tappalpha, "firsttrust": firsttrust,
}


def _div_dates():
    """{ticker: [iso ex-div dates]} from the committed price history."""
    import json
    root = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
    path = os.path.join(root, "data", "prices_history.json")
    try:
        with open(path) as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return {}
    return {t: sorted(v.get("dividends", {})) for t, v in doc.get("tickers", {}).items()}


def collect():
    history = {}
    for name, fn in ADAPTERS.items():
        history.update(fn())
    dd = _div_dates()
    history.update(amplify(dd))
    history.update(invesco(dd))
    history.update(roundhill(dd))
    history.update(constants(dd))
    return history


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "probe":
        name = sys.argv[2]
        fn = ADAPTERS.get(name)
        if name == "roundhill":
            res = roundhill(_div_dates())
        elif name == "amplify":
            res = amplify(_div_dates())
        elif name == "invesco":
            res = invesco(_div_dates())
        elif name == "constants":
            res = constants(_div_dates())
        elif fn:
            res = fn()
        else:
            sys.exit(f"unknown issuer '{name}'")
        for t, d in res.items():
            pts = sorted(d.items())
            print(f"{t}: {len(d)} dates  "
                  f"[{pts[0][0]}..{pts[-1][0]}]  recent={pts[-1][1]}%")
        return

    root = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
    hist_path = os.path.join(root, "data", "roc_history.json")
    fresh = collect()
    merged = rr.merge_history(rr.load_history(hist_path), fresh)
    rr.save_history(merged, hist_path)
    rr.write_history_csv(merged, os.path.join(root, "data", "roc_history.csv"))
    as_of = date.today().isoformat()
    rr.write_history_dart(merged, as_of, os.path.join(root, "lib", "roc_history.dart"))
    n = sum(len(v) for v in merged.values())
    print(f"\nmerged: {len(merged)} funds · {n} dated ROC points · as of {as_of}")
    print(f"Wrote {hist_path}, lib/roc_history.dart")


if __name__ == "__main__":
    main()
