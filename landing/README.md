# Landing (moved)

The **RoamSocket marketing site** lives in a **separate public repo**:

| | |
|--|--|
| **Repository** | [roamsocket/roamsocket-site](https://github.com/roamsocket/roamsocket-site) |
| **Deploy** | Cloudflare Workers static assets (`wrangler deploy`) |
| **Authoring docs** | That repo’s [README](https://github.com/roamsocket/roamsocket-site#readme) |

## Why separate?

- Ship site copy, design, and deploys **without** touching the app monorepo.
- Clear ownership: product code vs marketing site.
- Workers Builds can point at the site repo root (no monorepo root-directory config).

## Editing the site

```bash
git clone https://github.com/roamsocket/roamsocket-site.git
cd roamsocket-site
npm install
npm run dev          # local preview
npm run deploy       # publish (requires wrangler login)
```

This monorepo’s `landing/` folder is a **pointer only** — do not put the live site here.
