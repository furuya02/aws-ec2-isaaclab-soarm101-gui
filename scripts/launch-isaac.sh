#!/bin/bash
# Isaac Sim 5.1.0 Native GUI launcher
#
# Run inside the DCV desktop terminal (NOT plain SSH; needs DISPLAY).
# Usage:
#   ./scripts/launch-isaac.sh              # normal launch
#   ./scripts/launch-isaac.sh --clear-cache  # clear GPU-specific shader cache first
#                                            # (do this after switching GPU type, e.g. g5 <-> g6e)
#
# Env overrides:
#   NGC_IMAGE   default: nvcr.io/nvidia/isaac-sim:5.1.0
#   EXPERIENCE  default: /isaac-sim/apps/isaacsim.exp.full.kit  (Native Desktop)
set -euo pipefail

NGC_IMAGE="${NGC_IMAGE:-nvcr.io/nvidia/isaac-sim:5.1.0}"
EXPERIENCE="${EXPERIENCE:-/isaac-sim/apps/isaacsim.exp.full.kit}"

# DISPLAY が無い (SSH ターミナル等) なら早期失敗
if [[ -z "${DISPLAY:-}" ]]; then
  echo "Error: DISPLAY is not set." >&2
  echo "       Run this script inside the DCV desktop terminal," >&2
  echo "       or 'export DISPLAY=:0' first if already logged in via browser DCV." >&2
  exit 1
fi

# --clear-cache: GPU タイプ切替直後など、shader cache の不整合を解消したい時
if [[ "${1:-}" == "--clear-cache" ]]; then
  echo "==> Clearing Isaac Sim cache (GPU-specific shader / Vulkan pipeline)..."
  rm -rf ~/docker/isaac-sim/{kit-cache,ov-cache,gl-cache,compute-cache,logs}
fi

# Cache directories（GPU 切替時はクリア推奨）
mkdir -p ~/docker/isaac-sim/{kit-cache,ov-cache,gl-cache,compute-cache,logs}

# Permit Docker to access the local X server
xhost +local:docker > /dev/null

# Remove leftover container if any (--rm 起動なので普通は残らないが念のため)
docker rm -f isaac-sim 2>/dev/null || true

# Launch Native GUI by invoking kit + experience directly
# (do NOT use ./isaac-sim.sh — it defaults to the Streaming experience and won't show a window)
exec docker run --name isaac-sim --rm \
  --runtime=nvidia --gpus all \
  --ipc=host --network=host \
  -e DISPLAY="${DISPLAY}" -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "${HOME}/work:/work" \
  -v "${HOME}/docker/isaac-sim/kit-cache:/isaac-sim/kit/cache:rw" \
  -v "${HOME}/docker/isaac-sim/ov-cache:/root/.cache/ov:rw" \
  -v "${HOME}/docker/isaac-sim/gl-cache:/root/.cache/nvidia/GLCache:rw" \
  -v "${HOME}/docker/isaac-sim/compute-cache:/root/.nv/ComputeCache:rw" \
  -v "${HOME}/docker/isaac-sim/logs:/root/.nvidia-omniverse/logs:rw" \
  --entrypoint /isaac-sim/kit/kit \
  "${NGC_IMAGE}" \
  "${EXPERIENCE}"
