# Custom SearXNG UI

A SearXNG deployment with a cleaner, customized simple theme. The theme uses
OKLCH color logic to keep hues and colors consistent, adds a few appearance
customization options on the preferences page, and ships no external fonts,
scripts or images.

## Quick start

```sh
cp .env.example .env      # then edit SEARXNG_SECRET
docker compose up -d      # requires the .env secret
```

Open http://localhost:9000. Stop with `docker compose down`.

## Layout

- `searxng/settings.yml` — instance settings, merged on top of the upstream
  defaults (`use_default_settings: true`). Engines here enable/disable the
  curated list; anything not listed inherits the upstream default.
- `ui/simple/base.html` — overridden `simple` theme template, mounted read-only
  into the container. See `ui/README.md` for the upgrade procedure.
- `docker-compose.yml` — the pinned SearXNG image plus a Valkey cache.

## Configuration

- Signing key: `SEARXNG_SECRET` in `.env` (never commit a real one).
- Instance URL: `SEARXNG_BASE_URL` in `docker-compose.yml`.
- Engines, timeouts and suspended times: `searxng/settings.yml`.
- Theme hue/background swatches: preferences page (stored per-browser).