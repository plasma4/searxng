# UI override

`ui/simple/base.html` is a copy of the `simple` theme's `base.html` from the pinned SearXNG image, with a local `<style>` restyle and a small preferences script appended. It is mounted read-only over the container's copy:

```yaml
./ui/simple/base.html:/usr/local/searxng/searx/templates/simple/base.html:ro
```

Mounting it read-only matters: Jinja templates render inside the app process, so a writable mount would turn any file-write bug into code execution.

## Upgrading the pinned image

The image digest in `docker-compose.yml` is pinned deliberately: on a blind
`:latest` pull the backend can drift (renamed asset, new template context
variable) and the copied `base.html` can break the page. `ui/upgrade.sh`
automates the upgrade. It extracts the stock template from the pinned digest
(used as the merge base) and from the new image, then carries the local
`<style>` block, appearance controls and script over with a three-way merge
via `git merge-file`:

```sh
ui/upgrade.sh          # dry run: show what upstream changed and the digest move
ui/upgrade.sh --apply  # install, bump the digest, restart, verify, roll back on failure
ui/upgrade.sh --check  # CI: exit 2 when the upstream template drifted
```

If upstream touched the same lines as the local theme, the merge stops with
conflicts, writes `ui/simple/base.html.merged` with markers and exits 3.
Resolve them, then install the resolved file:

```sh
ui/upgrade.sh --adopt ui/simple/base.html.merged
```

On success the `.merged` and `.bak` scratch files are removed; both are
gitignored. To do it by hand instead: pull the image, extract its stock
template with

```sh
docker run --rm --entrypoint cat searxng/searxng:latest \
  /usr/local/searxng/searx/templates/simple/base.html > /tmp/base.html
```

re-apply the local edits keeping every upstream Jinja tag intact, then bump the
digest with `docker image inspect searxng/searxng:latest --format '{{index .RepoDigests 0}}'`.
Keep this file in sync if an upstream change alters the template structure.
