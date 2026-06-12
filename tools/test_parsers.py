"""Unit tests for the ROC scraper/parser internals — the format-fragile regex
bits that would otherwise only be exercised against live PDFs/HTML. All pure
(canned text in, value out), no network. Run: python3 -m unittest tools.test_parsers
(or `python3 tools/test_parsers.py`)."""

import os
import sys
import unittest
from datetime import date

sys.path.insert(0, os.path.dirname(__file__))

import refresh_roc as rr
import roc_sources as rs


class TestRocPct(unittest.TestCase):
    def test_dollar_over_total(self):
        t = ("Estimated Return of Capital $0.5062 97% "
             "Total (per common share) $0.5216 100%")
        self.assertEqual(rs._roc_pct(t), 97.0)

    def test_total_per_share_variant(self):
        t = "Return of Capital $0.027464 100% Total (per share) $0.027464"
        self.assertEqual(rs._roc_pct(t), 100.0)

    def test_prose(self):
        t = ("it is anticipated that 55% of such dividend will be a "
             "return of capital.")
        self.assertEqual(rs._roc_pct(t), 55.0)

    def test_prose_line_wrapped(self):
        # The phrase wraps mid-line in real notices — whitespace is collapsed.
        t = "anticipated that 98% of such dividend will be a return of\ncapital."
        self.assertEqual(rs._roc_pct(t), 98.0)

    def test_label_then_pct_no_dollar(self):
        # Westwood-style: the % follows the ROC label (no $); the NII row's % just
        # above must NOT be grabbed by the prose branch.
        t = ("Net Investment Income 0.00% Return of Capital or other Capital "
             "Source 100.00% Total Distribution (per share) 100.00%")
        self.assertEqual(rs._roc_pct(t), 100.0)

    def test_none(self):
        self.assertIsNone(rs._roc_pct("no return-of-capital figure here"))


class TestDates(unittest.TestCase):
    def test_payable_prose(self):
        t = "monthly dividend payable on April 24th, 2026 to shareholders"
        self.assertEqual(rs._payable_date(t), date(2026, 4, 24))

    def test_mdy(self):
        self.assertEqual(rs._date_mdy("11.28.25"), date(2025, 11, 28))

    def test_mdY(self):
        self.assertEqual(rs._date_mdY("11182024"), date(2024, 11, 18))

    def test_date_from_name_dotted(self):
        self.assertEqual(
            rr.date_from_name("YieldMax 19a-1 Notice 12.5.25 Payable.pdf"),
            date(2025, 12, 5))

    def test_date_from_name_iso(self):
        self.assertEqual(rr.date_from_name("Group_1_2026-06-04.pdf"),
                         date(2026, 6, 4))

    def test_recent_weekdays_thursday(self):
        # Fri 2026-06-12, want the 2 most recent Thursdays (weekday 3).
        self.assertEqual(
            rr.recent_weekdays(date(2026, 6, 12), 3, 2),
            [date(2026, 6, 11), date(2026, 6, 4)])


class TestInvescoPbp(unittest.TestCase):
    def test_pbp_row(self):
        # NII 0.01898 + Gain 0.27931 + RoP 0.09576 → 24.3%.
        line = "PBP 46137V399 Invesco S&P 500 BuyWrite ETF $ 0.01898 $ 0.27931 $ 0.09576 $ -"
        self.assertEqual(rs._pbp_roc_from_text(line), 24.3)

    def test_pbp_absent(self):
        self.assertIsNone(rs._pbp_roc_from_text("SPLV 12345 ... $0.10 $0 $0 $-"))


class TestFirstTrust(unittest.TestCase):
    def test_roc_row(self):
        text = ("FTHI 12345678A 10/31/2026 Monthly $0.8750 $0.0500 $0.0000 "
                "$0.0000 $0.1823 6% 0% 0% 94.0%")
        self.assertEqual(rs._ft_roc_from_text(text, "FTHI"), 94.0)

    def test_zero_roc_dash(self):
        # EIPI-style: ROC $ and % both render as '-' → 0%.
        text = ("EIPI 87654321B 10/31/2026 Monthly $0.1250 $0.0209 $0.1041 "
                "$0.0000 - 17% 83% 0% -")
        self.assertEqual(rs._ft_roc_from_text(text, "EIPI"), 0.0)

    def test_reads_current_not_cumulative(self):
        text = (
            "FTHI 12345678A 10/31/2026 Monthly $1.0 $0.1 $0.0 $0.0 $0.9 10% 0% 0% 90.0%\n"
            "Total Cumulative Fiscal YTD\n"
            "FTHI 12345678A 10/31/2026 Monthly $5.0 $4.0 $0.0 $0.0 $1.0 80% 0% 0% 20.0%")
        self.assertEqual(rs._ft_roc_from_text(text, "FTHI"), 90.0)


class TestForm8937(unittest.TestCase):
    def test_extract(self):
        text = ("YieldMax Magnificent 7 88636J642 YMAG 2/15/2025 2/13/2025 "
                "2/18/2025 $2.279200 $0.307900 13.5015%\n"
                "YieldMax Universe 88636J659 YMAX 2/15/2025 2/13/2025 "
                "2/18/2025 $1.5 $0.7 50.3868%")
        out = rs._extract_8937_rocs(text)
        self.assertEqual(out["YMAG"], 13.5)
        self.assertEqual(out["YMAX"], 50.4)


class TestAggregates(unittest.TestCase):
    def test_compute_annual(self):
        history = {
            "SPYI": {
                "2024-01-15": 90.0, "2024-04-15": 92.0,
                "2024-07-15": 94.0, "2024-10-15": 96.0,  # 4 → mean 93.0
                "2025-01-15": 80.0,  # current year, excluded
            },
            "THIN": {"2024-01-15": 50.0},  # <4 → no figure
        }
        annual = rr.compute_annual(history, {}, current_year=2025, min_count=4)
        self.assertEqual(annual["SPYI"], {2024: 93.0})
        self.assertNotIn("THIN", annual)

    def test_dollar_weighted(self):
        history = {"X": {f"2024-0{i}-15": v
                         for i, v in [(1, 0.0), (2, 0.0), (3, 0.0), (4, 100.0)]}}
        # The April payout (100% ROC) is 10x the others → pulled toward 100.
        divs = {"X": {"2024-01-15": 1.0, "2024-02-15": 1.0,
                      "2024-03-15": 1.0, "2024-04-15": 10.0}}
        annual = rr.compute_annual(history, divs, current_year=2025, min_count=4)
        self.assertEqual(annual["X"][2024], round(1000 / 13, 1))  # 76.9

    def test_trailing_from_history(self):
        h = {"A": {f"2024-{m:02d}-15": float(m) for m in range(1, 11)}}
        # mean of the last 8 (months 3..10) = 6.5
        self.assertEqual(rr.trailing_from_history(h, n=8), {"A": 6.5})

    def test_merge_history(self):
        merged = rr.merge_history(
            {"A": {"d1": 1.0}}, {"A": {"d2": 2.0}, "B": {"d3": 3.0}})
        self.assertEqual(merged, {"A": {"d1": 1.0, "d2": 2.0}, "B": {"d3": 3.0}})

    def test_merge_fresh_wins(self):
        merged = rr.merge_history({"A": {"d1": 1.0}}, {"A": {"d1": 9.0}})
        self.assertEqual(merged["A"]["d1"], 9.0)


if __name__ == "__main__":
    unittest.main()
