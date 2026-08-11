# Marketplace (moved)

The **official RoamSocket marketplace** lives in a **separate public repo**.
The host path below is the current external GitHub location (not the product name):

| | |
|--|--|
| **Repository (external host)** | [roamsocket-ai/roamsocket-marketplace](https://github.com/roamsocket-ai/roamsocket-marketplace) |
| **Catalog URL** | `https://raw.githubusercontent.com/roamsocket-ai/roamsocket-marketplace/main/catalog.json` |
| **Authoring docs** | In that repo’s [README](https://github.com/roamsocket-ai/roamsocket-marketplace#how-to-make-your-own-marketplace) |

## Why separate?

- Update connectors, skills, plugins, and Metal recommendations **without** shipping an app release.
- Clear ownership: product code vs catalog content.
- Users can fork or add their own marketplace repos in **Settings → Marketplace**.

## Client defaults

Desktop and iOS ship with the raw catalog URL above as the default marketplace source
(`DEFAULT_MARKETPLACE_URL` / `defaultMarketplaceURL`). Bundled offline fallbacks remain
in the app binaries if the fetch fails.

## Editing the official catalog

```bash
git clone https://github.com/roamsocket-ai/roamsocket-marketplace.git
# edit catalog.json
git commit -am "chore: update marketplace catalog"
git push
```

Clients pick up changes on **Refresh** or next launch.
