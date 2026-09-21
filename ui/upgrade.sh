#!/usr/bin/env bash
#
# Upgrade the pinned SearXNG image and re-apply the local theme override.
#
# The stock simple/base.html is extracted from the currently pinned digest
# (the merge base) and from the new image; the local edits -- the <style>
# block, the appearance controls and their script -- are carried over with a
# three-way merge instead of a hand-splice.
#
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$ROOT/docker-compose.yml"
LOCAL="$ROOT/ui/simple/base.html"
CONFLICT_FILE="$ROOT/ui/simple/base.html.merged"
BACKUP="$ROOT/ui/simple/base.html.bak"
TEMPLATE_PATH="/usr/local/searxng/searx/templates/simple/base.html"
INSTANCE_URL="${SEARXNG_URL:-http://localhost:9000/}"

NEW_IMAGE="searxng/searxng:latest"
MODE="dry-run"
ADOPT=""

usage() {
  cat <<'EOF'
usage: ui/upgrade.sh [--apply] [--check] [--adopt FILE] [--image REF]

  (default)     dry run: merge against the pinned image's template, show a diff
  --apply       install the merged template, bump the digest in
                docker-compose.yml, restart the stack and verify the instance
  --check       quiet mode for CI: exit 0 when there is no upstream template
                drift, 2 when the template changed, 3 on a merge conflict
  --adopt FILE  install an already-resolved merge (after a conflict) and apply
  --image REF   new image reference (default: searxng/searxng:latest)
EOF
  exit "${1:-0}"
}

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE="apply" ;;
    --check) MODE="check" ;;
    --adopt) MODE="adopt"; ADOPT="${2:?--adopt needs a file}"; shift ;;
    --image) NEW_IMAGE="${2:?--image needs a ref}"; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

image_present() { docker image inspect "$1" >/dev/null 2>&1; }

extract_stock_template() {
  docker run --rm --entrypoint cat "$1" "$TEMPLATE_PATH" >"$2"
}

registry_digest_ref() {
  docker image inspect "$1" --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    | grep -m1 '@sha256:' || true
}

PINNED_REF="$(grep -m1 -oE 'searxng/searxng(:[^@[:space:]]+)?@sha256:[0-9a-f]{64}' "$COMPOSE" || true)"
[ -n "$PINNED_REF" ] || die "no digest-pinned searxng image found in $COMPOSE"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ "$MODE" = "adopt" ]; then
  [ -f "$ADOPT" ] || die "no such file: $ADOPT"
  if grep -qE '^(<<<<<<<|=======|>>>>>>>)' "$ADOPT"; then
    die "$ADOPT still contains conflict markers"
  fi
  MERGED="$ADOPT"
  UPSTREAM_CHANGED=1
else
  echo "==> extracting stock template from pinned image $PINNED_REF"
  extract_stock_template "$PINNED_REF" "$TMP/old.html"

  if ! image_present "$NEW_IMAGE"; then
    echo "==> pulling $NEW_IMAGE"
    docker pull "$NEW_IMAGE" >/dev/null
  fi
  echo "==> extracting stock template from $NEW_IMAGE"
  extract_stock_template "$NEW_IMAGE" "$TMP/new.html"

  MERGED="$TMP/merged.html"
  set +e
  git merge-file -p --diff3 "$LOCAL" "$TMP/old.html" "$TMP/new.html" >"$MERGED"
  merge_rc=$?
  set -e

  if [ "$merge_rc" -gt 0 ]; then
    cp "$MERGED" "$CONFLICT_FILE"
    echo "!! merge conflict in $merge_rc hunk(s): upstream changed the same lines as the local theme" >&2
    grep -nE '^<<<<<<<' "$CONFLICT_FILE" >&2 || true
    echo "   resolve the markers in $CONFLICT_FILE, then run:" >&2
    echo "     ui/upgrade.sh --adopt $CONFLICT_FILE" >&2
    exit 3
  fi

  if cmp -s "$LOCAL" "$MERGED"; then UPSTREAM_CHANGED=0; else UPSTREAM_CHANGED=1; fi
fi

NEW_DIGEST_REF="$(registry_digest_ref "$NEW_IMAGE")"
NEW_REF="${NEW_DIGEST_REF:-$NEW_IMAGE}"
if [ "$NEW_REF" = "$NEW_IMAGE" ] && [ "$NEW_REF" != "$PINNED_REF" ] && [[ "$NEW_REF" != *"@sha256:"* ]]; then
  die "$NEW_IMAGE has no registry digest; refusing to pin it in $COMPOSE"
fi
if [ "$NEW_REF" = "$PINNED_REF" ]; then DIGEST_CHANGED=0; else DIGEST_CHANGED=1; fi

if [ "$MODE" = "check" ]; then
  if [ "$UPSTREAM_CHANGED" = "1" ]; then
    echo "template drift against $NEW_IMAGE; run ui/upgrade.sh to inspect" >&2
    exit 2
  fi
  exit 0
fi

if [ "$MODE" = "dry-run" ]; then
  if [ "$UPSTREAM_CHANGED" = "0" ]; then
    echo "==> local override is in sync with $NEW_IMAGE; nothing to merge"
  else
    echo "==> upstream changes the merge would adopt:"
    diff -u "$LOCAL" "$MERGED" || true
  fi
  if [ "$DIGEST_CHANGED" = "1" ]; then
    echo "==> digest would move $PINNED_REF -> $NEW_REF"
  else
    echo "==> digest unchanged: $PINNED_REF"
  fi
  echo "==> dry run; re-run with --apply to install"
  exit 0
fi

if [ "$UPSTREAM_CHANGED" = "0" ] && [ "$DIGEST_CHANGED" = "0" ]; then
  echo "==> already up to date: $PINNED_REF"
  exit 0
fi

command -v curl >/dev/null || die "curl is required to verify the instance"

if [ "$UPSTREAM_CHANGED" = "1" ]; then
  cp -p "$LOCAL" "$BACKUP"
  install -m 0644 "$MERGED" "$LOCAL"
  echo "==> installed merged template"
fi

if [ "$DIGEST_CHANGED" = "1" ]; then
  count="$(grep -cF "$PINNED_REF" "$COMPOSE")"
  [ "$count" = "1" ] || die "expected one occurrence of $PINNED_REF in $COMPOSE, found $count"
  sed -i "s|$PINNED_REF|$NEW_REF|" "$COMPOSE"
  grep -qF "$NEW_REF" "$COMPOSE" || die "failed to update the image digest in $COMPOSE"
  echo "==> pinned $NEW_REF in docker-compose.yml"
fi

echo "==> restarting stack"
docker compose -f "$COMPOSE" up -d >/dev/null

verify_instance() {
  local code="" i
  for i in $(seq 1 30); do
    code="$(curl -s -o "$TMP/page.html" -w '%{http_code}' "$INSTANCE_URL" || true)"
    [ "$code" = "200" ] && break
    sleep 1
  done
  [ "$code" = "200" ] && grep -q 'oklch' "$TMP/page.html"
}

if verify_instance; then
  echo "==> ok: $INSTANCE_URL serves the restyled template"
  rm -f "$BACKUP" "$CONFLICT_FILE"
else
  echo "!! verification failed, rolling back" >&2
  [ -f "$BACKUP" ] && mv "$BACKUP" "$LOCAL"
  if [ "$DIGEST_CHANGED" = "1" ]; then
    sed -i "s|$NEW_REF|$PINNED_REF|" "$COMPOSE"
  fi
  docker compose -f "$COMPOSE" up -d >/dev/null || true
  die "instance did not answer at $INSTANCE_URL with the custom theme; rolled back"
fi
