#!/usr/bin/env bash
# Pull images via domestic mirror registries and retag them to the original names used in this project's compose.
# This way docker-compose.yml needs no changes at all.
#
#   ./scripts/pull-images.sh              # try the default mirrors in order
#   MIRRORS="docker.m.daocloud.io" ./scripts/pull-images.sh
#
# Note: official images need library/, non-official ones need the namespace.

set -euo pipefail

DEFAULT_MIRRORS=(
  "docker.m.daocloud.io"
  "docker.1panel.live"
  "docker.1ms.run"
)

# "target image name|path in the mirror registry"
IMAGES=(
  "redis:7-alpine|library/redis:7-alpine"
  "hashicorp/http-echo:1.0|hashicorp/http-echo:1.0"
  "kong:3.6|library/kong:3.6"
)

if [ -n "${MIRRORS:-}" ]; then
  IFS=',' read -ra MIRROR_LIST <<< "$MIRRORS"
else
  MIRROR_LIST=("${DEFAULT_MIRRORS[@]}")
fi

command -v docker >/dev/null 2>&1 || { echo "docker is missing" >&2; exit 1; }

failures=()

for entry in "${IMAGES[@]}"; do
  target="${entry%%|*}"
  relpath="${entry##*|}"

  if docker image inspect "$target" >/dev/null 2>&1; then
    echo "✓ already exists: $target (skipped)"
    continue
  fi

  pulled=false
  for mirror in "${MIRROR_LIST[@]}"; do
    src="${mirror}/${relpath}"
    echo "→ trying $src"
    if docker pull "$src"; then
      docker tag "$src" "$target"
      echo "✓ ready: $target (source $mirror)"
      pulled=true
      break
    fi
    echo "  failed, trying the next mirror"
  done

  if [ "$pulled" = false ]; then
    failures+=("$target")
  fi
done

echo
if [ ${#failures[@]} -gt 0 ]; then
  echo "The following images failed on every mirror:" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  echo "See section 4 of docs/docker-mirror.md for remedies" >&2
  exit 1
fi

echo "All images ready, you can now run: docker compose up -d"
