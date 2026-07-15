#!/usr/bin/env bash
# Verifies cluster is InService and prints instance IDs / SSH command.
#
# Usage: ./verify-cluster.sh

set -euo pipefail

CLUSTER_NAME=${CLUSTER_NAME:-hyperpod-phx-lz-cluster}
REGION=${REGION:-us-west-2}
: "${AWS_PROFILE:?AWS_PROFILE must be set}"
export AWS_DEFAULT_REGION=$REGION

echo "=== Cluster status ==="
aws sagemaker describe-cluster --cluster-name "$CLUSTER_NAME" \
  --query '{Status:ClusterStatus,Groups:InstanceGroups[].[InstanceGroupName,InstanceType,CurrentCount,TargetCount,Status]}' --output table

echo ""
echo "=== Cluster nodes ==="
aws sagemaker list-cluster-nodes --cluster-name "$CLUSTER_NAME" \
  --query 'ClusterNodeSummaries[].[InstanceGroupName,InstanceId,PrivateDnsHostname,InstanceStatus.Status]' --output table

CLUSTER_ID=$(aws sagemaker describe-cluster --cluster-name "$CLUSTER_NAME" \
  --query 'ClusterArn' --output text | rev | cut -d/ -f1 | rev)

CTRL_ID=$(aws sagemaker list-cluster-nodes --cluster-name "$CLUSTER_NAME" \
  --query 'ClusterNodeSummaries[?InstanceGroupName==`controller-machine`].InstanceId' --output text)

if [ -n "$CTRL_ID" ] && [ "$CTRL_ID" != "None" ]; then
  echo ""
  echo "=== SSH to controller ==="
  echo "aws ssm start-session --target sagemaker-cluster:${CLUSTER_ID}_controller-machine-${CTRL_ID}"
fi
