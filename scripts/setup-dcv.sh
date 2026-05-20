#!/bin/bash
# NVIDIA CUDA Datacenter Driver 570 + Amazon DCV Server installer (Ubuntu 22.04, g5.xlarge / g6e.xlarge)
# Run on g5.xlarge (or g6e.xlarge) over SSH. Reboot after this script for the driver to load.
# Refs:
#   - https://docs.aws.amazon.com/dcv/latest/adminguide/setting-up-installing-linux-server.html
#   - https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/
# Note:
#   - GRID driver (s3://ec2-linux-nvidia-drivers/latest/) は Isaac Sim 5.1.0 と非互換
#     (librtx.scenedb で必ず crash する) ため使用しない。
#     CUDA Datacenter driver (nvidia-driver-570, GUI 用 libGL を含む) を使う。
set -euo pipefail

# --- 1. Ubuntu Desktop (minimal) ---
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-desktop-minimal

# --- 2. Disable Wayland (DCV requires Xorg) ---
if [[ -f /etc/gdm3/custom.conf ]]; then
  sudo sed -i 's/^#WaylandEnable=false/WaylandEnable=false/' /etc/gdm3/custom.conf
fi

# --- 3. Switch to graphical target ---
sudo systemctl set-default graphical.target

# --- 4. NVIDIA CUDA Datacenter Driver 570 (apt 経由、GUI 用 libGL 含む) ---
# Note:
#   kernel 6.8 のモジュールビルドには gcc-12 が必要。Ubuntu 22.04 default の gcc-11 は
#   '-ftrivial-auto-var-init=zero' を知らず、nvidia-dkms-570 のビルドが失敗する。
sudo apt-get install -y build-essential gcc-12 "linux-headers-$(uname -r)"
# Note: --install だけでは既存の gcc-11 が選ばれたままになるので --set で明示切替する
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100
sudo update-alternatives --set gcc /usr/bin/gcc-12
cd /tmp
wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
rm -f cuda-keyring_1.1-1_all.deb
sudo apt-get update
sudo apt-get install -y nvidia-driver-570
cd -

# --- 5. Xorg config (CUDA driver 用、手書き必須) ---
# Note:
#   - nvidia-xconfig は CUDA Datacenter driver パッケージに含まれないため手書き
#   - AllowEmptyInitialConfiguration "True" は headless サーバ (モニタ未接続) で必須
sudo tee /etc/X11/xorg.conf > /dev/null <<'EOF'
Section "ServerLayout"
    Identifier "Layout0"
    Screen 0 "Screen0"
EndSection
Section "Files"
EndSection
Section "Monitor"
    Identifier "Monitor0"
    Option "DPMS"
EndSection
Section "Device"
    Identifier "Device0"
    Driver "nvidia"
    Option "AllowEmptyInitialConfiguration" "True"
EndSection
Section "Screen"
    Identifier "Screen0"
    Device "Device0"
    Monitor "Monitor0"
    DefaultDepth 24
    Option "AllowEmptyInitialConfiguration" "True"
    SubSection "Display"
        Depth 24
    EndSubSection
EndSection
EOF

# --- 6. Amazon DCV Server (Ubuntu 22.04 x86_64) ---
cd /tmp
wget -q https://d1uj6qtbmh3dt5.cloudfront.net/NICE-GPG-KEY
gpg --import NICE-GPG-KEY
wget -q https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-ubuntu2204-x86_64.tgz
tar xzf nice-dcv-ubuntu2204-x86_64.tgz
cd nice-dcv-*-ubuntu2204-x86_64
sudo apt-get install -y ./nice-dcv-server_*_amd64.ubuntu2204.deb
sudo apt-get install -y ./nice-dcv-web-viewer_*_amd64.ubuntu2204.deb
sudo apt-get install -y ./nice-xdcv_*_amd64.ubuntu2204.deb
sudo apt-get install -y ./nice-dcv-gl_*_amd64.ubuntu2204.deb
sudo usermod -aG video dcv

# --- 7. DCV config: auto console session owned by ubuntu ---
sudo tee /etc/dcv/dcv.conf > /dev/null <<'EOF'
[session-management]
create-session = true
[session-management/automatic-console-session]
owner = "ubuntu"
[display]
target-fps = 30
EOF

# --- 8. Enable & start DCV server ---
sudo systemctl enable --now dcvserver

# --- 9. Set ubuntu user password (used to log in to DCV) ---
echo ""
echo "==> Set the ubuntu user password for DCV login:"
sudo passwd ubuntu

echo ""
echo "============================================================"
echo " DCV setup complete."
echo " Reboot is required to load NVIDIA driver 570:"
echo "   sudo reboot"
echo ""
echo " After reboot, open in your browser:"
echo "   https://<PublicIp>:8443"
echo "   Username: ubuntu"
echo "   Password: (the one you just set)"
echo "============================================================"
