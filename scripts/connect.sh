#!/bin/bash
# SSH connect helper: discover running instance by Name tag, then ssh in
# Run on local PC. Override defaults with env vars (REGION, KEYPAIR, PEM_PATH).
set -euo pipefail

REGION="${REGION:-ap-northeast-1}"
KEYPAIR="${KEYPAIR:-ec2-key}"
PEM_PATH="${PEM_PATH:-${HOME}/.ssh/${KEYPAIR}.pem}"
PROJECT="aws-ec2-isaaclab-soarm101-gui"

PUBLIC_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT}-instance" \
            "Name=instance-state-name,Values=running" \
  --region "${REGION}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

if [[ -z "${PUBLIC_IP}" || "${PUBLIC_IP}" == "None" ]]; then
  echo "Running instance not found (tag Name=${PROJECT}-instance)." >&2
  exit 1
fi

echo "Connecting to ${PUBLIC_IP} with ${PEM_PATH}..."
ssh -i "${PEM_PATH}" \
    -o StrictHostKeyChecking=accept-new \
    "ubuntu@${PUBLIC_IP}"
