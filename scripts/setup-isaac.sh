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

URDF_HOST="${HOME}/work/isaac_so_arm101/src/isaac_so_arm101/robots/trs_so101/urdf/so_arm101.urdf"
URDF_CONTAINER="/work/isaac_so_arm101/src/isaac_so_arm101/robots/trs_so101/urdf/so_arm101.urdf"

cat <<EOF

============================================================
 Isaac Sim ${ISAAC_VERSION} setup complete.
============================================================
 URDF (host):      ${URDF_HOST}
 URDF (container): ${URDF_CONTAINER}

 To launch Isaac Sim GUI from the DCV desktop terminal:

   xhost +local:docker
   docker run --name isaac-sim --rm --gpus all \\
     -e DISPLAY=\${DISPLAY} -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y \\
     -v /tmp/.X11-unix:/tmp/.X11-unix \\
     -v \${HOME}/work:/work \\
     --network=host ${NGC_IMAGE} ./isaac-sim.sh

 Then in Isaac Sim:
   File -> Import -> select ${URDF_CONTAINER}
   Check "Static Base" before clicking Import
   Tools -> Physics -> Physics Inspector -> Joint Drive Target Position
============================================================
EOF
