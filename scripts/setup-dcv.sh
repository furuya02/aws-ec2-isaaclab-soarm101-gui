#!/bin/bash
# NVIDIA GRID Driver + Amazon DCV Server installer (Ubuntu 22.04, g5.xlarge)
# Run on g5.xlarge over SSH. Reboot after this script for the driver to load.
# Refs:
#   - https://docs.aws.amazon.com/dcv/latest/adminguide/setting-up-installing-linux-server.html
#   - s3://ec2-linux-nvidia-drivers/latest/ (NVIDIA GRID driver for AWS)
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

# --- 4. NVIDIA GRID Driver (RTX Virtual Workstation) from S3 ---
sudo apt-get install -y unzip awscli build-essential "linux-headers-$(uname -r)"
mkdir -p ~/grid && cd ~/grid
aws s3 cp --recursive s3://ec2-linux-nvidia-drivers/latest/ . --region ap-northeast-1
chmod +x NVIDIA-Linux-x86_64*.run
sudo ./NVIDIA-Linux-x86_64*.run --silent
cd -

# --- 5. Xorg auto-configure for GRID ---
sudo nvidia-xconfig --preserve-busid --enable-all-gpus

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
echo " Reboot is recommended to fully load the GRID driver:"
echo "   sudo reboot"
echo ""
echo " After reboot, open in your browser:"
echo "   https://<PublicIp>:8443"
echo "   Username: ubuntu"
echo "   Password: (the one you just set)"
echo "============================================================"
