#!/usr/bin/env bash
# 用国内镜像站拉取镜像，并 retag 成本项目 compose 里使用的原始名字。
# 这样 docker-compose.yml 不需要任何修改。
#
#   ./scripts/pull-images.sh              # 依次尝试默认镜像站
#   MIRRORS="docker.m.daocloud.io" ./scripts/pull-images.sh
#
# 注意：官方镜像要带 library/，非官方要带命名空间。

set -euo pipefail

DEFAULT_MIRRORS=(
  "docker.m.daocloud.io"
  "docker.1panel.live"
  "docker.1ms.run"
)

# "目标镜像名|镜像站里的路径"
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

command -v docker >/dev/null 2>&1 || { echo "缺少 docker" >&2; exit 1; }

failures=()

for entry in "${IMAGES[@]}"; do
  target="${entry%%|*}"
  relpath="${entry##*|}"

  if docker image inspect "$target" >/dev/null 2>&1; then
    echo "✓ 已存在：$target（跳过）"
    continue
  fi

  pulled=false
  for mirror in "${MIRROR_LIST[@]}"; do
    src="${mirror}/${relpath}"
    echo "→ 尝试 $src"
    if docker pull "$src"; then
      docker tag "$src" "$target"
      echo "✓ 已就绪：$target（来源 $mirror）"
      pulled=true
      break
    fi
    echo "  失败，换下一个镜像站"
  done

  if [ "$pulled" = false ]; then
    failures+=("$target")
  fi
done

echo
if [ ${#failures[@]} -gt 0 ]; then
  echo "以下镜像全部镜像站都失败了：" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  echo "处理办法见 docs/docker-mirror.md 第 4 节" >&2
  exit 1
fi

echo "全部镜像就绪，可以执行：docker compose up -d"
