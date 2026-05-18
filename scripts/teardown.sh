#!/bin/bash
# Full teardown: cdk destroy + leftover-resource check
# Run on local PC inside aws-ec2-isaaclab-soarm101-gui/scripts/.
set -euo pipefail

REGION="${REGION:-ap-northeast-1}"
PROJECT="aws-ec2-isaaclab-soarm101-gui"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CDK_DIR="${SCRIPT_DIR}/../cdk"

echo "==> Running cdk destroy..."
cd "${CDK_DIR}"
pnpm exec cdk destroy --force

echo ""
echo "==> Verifying no leftover resources..."

echo "  EC2 instances (any state):"
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT}-instance" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --region "${REGION}" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' \
  --output table

echo "  Elastic IPs:"
aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=${PROJECT}-eip" \
  --region "${REGION}" \
  --query 'Addresses[].[AllocationId,PublicIp]' \
  --output table

echo "  Volumes:"
aws ec2 describe-volumes \
  --filters "Name=tag:Name,Values=${PROJECT}-instance" \
  --region "${REGION}" \
  --query 'Volumes[].[VolumeId,State]' \
  --output table

echo ""
echo "==> Teardown complete. Check Cost Explorer tomorrow to confirm \$0 billing."
