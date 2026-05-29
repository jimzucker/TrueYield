# TrueYield CORS proxy

The web build (GitHub Pages) calls Yahoo Finance from the browser, but Yahoo's
chart endpoint sends no `Access-Control-Allow-Origin` header, so the browser
blocks the response. This folder is a tiny [Cloudflare Worker](https://workers.cloudflare.com/)
that forwards the request and adds the CORS headers. Native (iOS/Android/desktop)
builds are unaffected — they call Yahoo directly and never use the proxy.

It proxies only `GET /v8/finance/chart/*`; everything else is rejected.

You need a free Cloudflare account either way (the proxy runs on Cloudflare).
Pick one deploy path.

### Option A — from GitHub Actions (no local tooling)

1. In Cloudflare: create an API token (My Profile → API Tokens → **Edit
   Cloudflare Workers** template) and note your **Account ID** (Workers dashboard).
2. In this GitHub repo: **Settings → Secrets and variables → Actions → Secrets**,
   add:
   - `CLOUDFLARE_API_TOKEN` — the token from step 1
   - `CLOUDFLARE_ACCOUNT_ID` — your account id
3. Run the **Deploy CORS proxy** workflow (Actions tab → Run workflow, or push a
   change under `proxy/`). It runs `wrangler deploy` for you and logs the
   `https://trueyield-proxy.<subdomain>.workers.dev` URL.
4. Continue with **"Point the web build at it"** below.

### Option B — from your machine

1. `npm install -g wrangler && wrangler login`
2. `cd proxy && wrangler deploy` (prints the `*.workers.dev` URL).
3. Continue below.

### Point the web build at it

1. **Settings → Secrets and variables → Actions → Variables → New repository
   variable**
   - **Name:** `YAHOO_PROXY`
   - **Value:** the worker URL above, **no trailing slash**
2. Re-run the **Deploy to GitHub Pages** workflow (or push to `main`). The build
   passes `--dart-define=YAHOO_PROXY=...`, and the live demo fetches through the
   worker.

> You don't need a separate repository — the workflow deploys the worker from
> this `proxy/` folder. (A dedicated repo also works if you prefer; just copy
> `worker.js` + `wrangler.toml` and the `deploy-proxy.yml` workflow into it.)

## How it's wired

- `lib/main.dart` reads `YAHOO_PROXY` via `String.fromEnvironment` and, **only on
  web**, prefixes the Yahoo path with it (`yahooBase`). With the variable unset,
  the web build still loads but live lookups stay CORS-blocked.
- `.github/workflows/pages.yml` forwards the repo variable into the build with
  `--dart-define=YAHOO_PROXY=${{ vars.YAHOO_PROXY }}`.

## Notes

- The worker is stateless and adds a 60s cache; Cloudflare's free tier covers
  far more than a demo needs.
- To lock it down, replace `Access-Control-Allow-Origin: *` in `worker.js` with
  your Pages origin (`https://<user>.github.io`).
