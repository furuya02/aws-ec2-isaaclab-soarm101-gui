#!/bin/bash
# Port-forward localhost:8443 -> EC2:8443 (Amazon DCV) via SSM Session Manager.
# Run on local PC. Requires AWS CLI v2 + Session Manager Plugin.
# Once running, open https://localhost:8443 in a browser.
# Ctrl+C to stop the tunnel.
set -euo pipefail

REGION="${REGION:-ap-northeast-1}"
LOCAL_PORT="${LOCAL_PORT:-8443}"
PROJECT="aws-ec2-isaaclab-soarm101-gui"

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT}-instance" \
            "Name=instance-state-name,Values=running" \
  --region "${REGION}" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "Running instance not found (tag Name=${PROJECT}-instance)." >&2
  exit 1
fi

echo "==> Forwarding localhost:${LOCAL_PORT} -> ${INSTANCE_ID}:8443"
echo "    Open in a browser:  https://localhost:${LOCAL_PORT}"
echo "    (Ctrl+C to stop)"

exec aws ssm start-session \
  --target "${INSTANCE_ID}" \
  --region "${REGION}" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"8443\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
