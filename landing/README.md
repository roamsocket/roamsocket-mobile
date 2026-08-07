# Landing (Cloudflare Workers)

Static marketing site for **CodeSocket**. No build step — HTML, CSS, and JS under `public/` are served as [Workers static assets](https://developers.cloudflare.com/workers/static-assets/).

```
landing/
├── public/           # site files (what gets published)
│   ├── index.html
│   ├── styles.css
│   ├── main.js
│   └── _headers
├── wrangler.jsonc    # Cloudflare config
├── package.json
└── README.md
```

## Local preview

```bash
cd landing
npm install
npm run dev          # http://localhost:8787
```

Or open `public/index.html` directly in a browser (no Wrangler required).

## Deploy

```bash
cd landing
npm install
npx wrangler login   # once per machine
npm run deploy       # → https://codesocket.<account>.workers.dev
```

Dry-run (validate upload, no publish):

```bash
npm run deploy:dry
```

## Config

| File | Role |
|------|------|
| `wrangler.jsonc` | Worker name, `assets.directory` → `./public` |
| `public/_headers` | Security + cache headers |
| `.assetsignore` | Extra excludes if the assets root ever changes |

### Custom domain

In the [Cloudflare dashboard](https://dash.cloudflare.com/) → **Workers & Pages** → **codesocket** → **Settings** → **Domains & Routes**, attach a custom domain. DNS must be on the same Cloudflare account.

### Git-connected deploys (optional)

Connect this repo in **Workers Builds** with:

- **Root directory:** `landing`
- **Build command:** *(empty — static files)*
- **Deploy command:** `npx wrangler deploy`
