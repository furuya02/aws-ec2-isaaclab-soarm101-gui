#!/bin/bash
# NGC login + Isaac Sim container pull + isaac_so_arm101 clone
# Run on g5.xlarge over SSH (after setup-docker.sh and setup-dcv.sh, reboot done).
# NGC API Key is read from stdin and never written to disk/history.
set -euo pipefail

ISAAC_VERSION="${ISAAC_VERSION:-5.1.0}"
NGC_IMAGE="nvcr.io/nvidia/isaac-sim:${ISAAC_VERSION}"

echo "Enter your NGC API Key (input is hidden):"
read -rs NGC_API_KEY
echo ""
if [[ -z "${NGC_API_KEY}" ]]; then
  echo "Error: NGC API Key is empty." >&2
  exit 1
fi

# --- docker login (Username is the literal string $oauthtoken) ---
echo "${NGC_API_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
unset NGC_API_KEY

# --- Pull Isaac Sim container (~30 GB, first pull takes time) ---
docker pull "${NGC_IMAGE}"

# --- Clone isaac_so_arm101 to borrow the URDF ---
mkdir -p ~/work && cd ~/work
if [[ ! -d isaac_so_arm101 ]]; then
  git clone https://github.com/MuammerBay/isaac_so_arm101.git
fi

# --- Permit container root to write USD next to URDF (URDF Importer 用) ---
# Note: Isaac Sim の URDF Importer は URDF と同じディレクトリに USD を書き出すため、
#   コンテナ内 root が ~/work 配下に書き込める必要がある。
sudo chmod -R a+rwX "${HOME}/work"

# --- Prepare cache directories for Isaac Sim ---
# Note: cache は GPU 固有のため、GPU タイプ切替時 (例: g5 ↔ g6e) はクリア推奨:
#   rm -rf ~/docker/isaac-sim/{kit-cache,ov-cache,gl-cache,compute-cache,logs}
mkdir -p ~/docker/isaac-sim/{kit-cache,ov-cache,gl-cache,compute-cache,logs}

URDF_HOST="${HOME}/work/isaac_so_arm101/src/isaac_so_arm101/robots/trs_so101/urdf/so_arm101.urdf"
URDF_CONTAINER="/work/isaac_so_arm101/src/isaac_so_arm101/robots/trs_so101/urdf/so_arm101.urdf"

cat <<EOF

============================================================
 Isaac Sim ${ISAAC_VERSION} setup complete.
============================================================
 URDF (host):      ${URDF_HOST}
 URDF (container): ${URDF_CONTAINER}

 To launch Isaac Sim Native GUI from the DCV desktop terminal:

   xhost +local:docker
   docker run --name isaac-sim --rm \\
     --runtime=nvidia --gpus all \\
     --ipc=host --network=host \\
     -e DISPLAY=\${DISPLAY} -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y \\
     -v /tmp/.X11-unix:/tmp/.X11-unix \\
     -v \${HOME}/work:/work \\
     -v \${HOME}/docker/isaac-sim/kit-cache:/isaac-sim/kit/cache:rw \\
     -v \${HOME}/docker/isaac-sim/ov-cache:/root/.cache/ov:rw \\
     -v \${HOME}/docker/isaac-sim/gl-cache:/root/.cache/nvidia/GLCache:rw \\
     -v \${HOME}/docker/isaac-sim/compute-cache:/root/.nv/ComputeCache:rw \\
     -v \${HOME}/docker/isaac-sim/logs:/root/.nvidia-omniverse/logs:rw \\
     --entrypoint /isaac-sim/kit/kit \\
     ${NGC_IMAGE} \\
     /isaac-sim/apps/isaacsim.exp.full.kit

 Notes:
   - 'isaac-sim.sh' is NOT used here — it defaults to Streaming experience.
     Native Desktop GUI requires invoking kit/kit + apps/isaacsim.exp.full.kit directly.
   - '--ipc=host' is required to avoid USD/tasking crashes from shared memory shortage.
   - cache volumes are GPU-specific. When switching GPU type (e.g. g5 <-> g6e),
     clear them: rm -rf ~/docker/isaac-sim/{kit-cache,ov-cache,gl-cache,compute-cache,logs}

 Then in Isaac Sim:
   File -> Import -> set File name to ${URDF_CONTAINER} (do NOT double-click; type/paste path)
   Check "Fix Base Link" before clicking Import
   Tools -> Physics -> Physics Inspector -> click "Re-Enable authoring"
   -> drag the blue sliders on each joint to articulate the arm
============================================================
EOF
