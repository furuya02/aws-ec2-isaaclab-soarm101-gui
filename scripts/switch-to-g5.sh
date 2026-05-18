#!/bin/bash
# Switch the EC2 instance to g5.xlarge (stop -> modify -> start)
# Run on local PC. Auto-discovers the instance by Name tag.
set -euo pipefail

REGION="${REGION:-ap-northeast-1}"
PROJECT="aws-ec2-isaaclab-soarm101-gui"
TARGET_TYPE="g5.xlarge"

INSTANCE_ID="${INSTANCE_ID:-$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT}-instance" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --region "${REGION}" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)}"

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "Instance not found (tag Name=${PROJECT}-instance). Did you 'cdk deploy'?" >&2
  exit 1
fi

echo "==> Target: ${INSTANCE_ID} -> ${TARGET_TYPE}"

CURRENT_STATE=$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" --region "${REGION}" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)

if [[ "${CURRENT_STATE}" != "stopped" ]]; then
  echo "==> Stopping ${INSTANCE_ID}..."
  aws ec2 stop-instances --instance-ids "${INSTANCE_ID}" --region "${REGION}" > /dev/null
  aws ec2 wait instance-stopped --instance-ids "${INSTANCE_ID}" --region "${REGION}"
fi

echo "==> Switching to ${TARGET_TYPE}..."
aws ec2 modify-instance-attribute --instance-id "${INSTANCE_ID}" \
  --instance-type "${TARGET_TYPE}" --region "${REGION}"

echo "==> Starting ${INSTANCE_ID}..."
aws ec2 start-instances --instance-ids "${INSTANCE_ID}" --region "${REGION}" > /dev/null
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${REGION}"

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" --region "${REGION}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo ""
echo "==> Done. Running as ${TARGET_TYPE}."
echo "  InstanceId: ${INSTANCE_ID}"
echo "  PublicIp:   ${PUBLIC_IP}"
echo ""
echo "  Billing now ~\$1.30/h (~195 JPY/h). Switch back with switch-to-t3.sh when finished."
