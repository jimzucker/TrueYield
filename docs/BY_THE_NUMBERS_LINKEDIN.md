# TrueYield — LinkedIn post (paste-ready)

> LinkedIn does not render Markdown — no headers, bold, or tables. The text below
> is plain text with line breaks and unicode bullets so it pastes in clean. The
> detailed, sourced version lives in [BY_THE_NUMBERS.md](BY_THE_NUMBERS.md).

---

I built a 4-platform investing app with Claude Code in ~16 hours. Here's what it actually cost.

TrueYield is an after-tax yield + total-return calculator for covered-call ETFs. One Flutter codebase, shipping to iOS, Android, macOS, and web.

The numbers, kept honest:

📦 What got built
• ~11,700 lines of authored code
• App and tests run ~1:1 — every calculation is invariant-tested, cross-checked against an independent Python port
• A data pipeline that auto-fetches return-of-capital + price history for 40+ funds
• 100 commits over ~3 weeks

⏱️ What it took me
• ~16 hours of genuine hands-on steering (the rest is split across other apps I was building in the same window)

💸 What it cost
• Subscription: ~$100 (started on the $20 Pro plan, upgraded to $100 Max)
• That same workload on the pay-as-you-go API would've been ≈ $1,340
• ~13× more compute than I paid in cash

Here's the part I didn't expect:

99.97% of the token volume was cache reads — the full context re-read on every single turn, ~6,800 times. 2 billion cached tokens. On the API that's ~$1,000 of the bill. On a flat-rate plan, it's free headroom.

The takeaway: long, context-heavy coding is exactly where AI assistance + a flat-rate plan compound. You're not paying per token — you're paying for a seat while the model re-reads a 1M-token context thousands of times for you.

The $20 → $100 upgrade paid for itself on day one. One 62-commit afternoon alone would've rate-limited the cheaper tier.

#ClaudeCode #AItools #Flutter #BuildInPublic #SoftwareDevelopment
