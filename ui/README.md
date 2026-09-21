# UI override

`ui/simple/base.html` is a copy of the `simple` theme's `base.html` from the
pinned SearXNG image, with a local `<style>` restyle and a small preferences
script appended. It is mounted read-only over the container's copy:

```yaml
./ui/simple/base.html:/usr/local/searxng/searx/templates/simple/base.html:ro
```

Mounting it read-only matters: Jinja templates render inside the app process,
so a writable mount would turn any file-write bug into code execution.

## Upgrading the pinned image

The image digest in `docker-compose.yml` is pinned deliberately. On a blind
`:latest` pull the backend can drift (renamed asset, new template context
variable) and the copied `base.html` can break the page. To upgrade:

1. Pull the new image: `docker pull searxng/searxng:latest`
2. Extract its stock template:

   ```sh
   # from the image
   docker run --rm --entrypoint cat searxng/searxng:latest \
     /usr/local/searxng/searx/templates/simple/base.html > /tmp/base.html
   ```

3. Re-apply the local `<style>` block and the preferences script from the
   current `ui/simple/base.html` on top of the fresh upstream file, keeping
   every upstream Jinja tag intact.
4. Bump the digest in `docker-compose.yml` (`docker image inspect
   searxng/searxng:latest --format '{{index .RepoDigests 0}}'`) and re-test.
5. Keep this file in sync if the upgrade changes the template structure.

## No webfonts

The restyle deliberately ships no fonts, images or scripts from third parties:
a third-party request would leak the searcher's IP and referring page and
defeat the point of self-hosting. The font stack falls back to `Inter` if it
is installed locally, otherwise the platform UI font. If you want to bundle a
webfont, drop it into the image's static dir (or serve it from this repo) and
add the `@font-face` to the `<style>` block -- still no external hosts.