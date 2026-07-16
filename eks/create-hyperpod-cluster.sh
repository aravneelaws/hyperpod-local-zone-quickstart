#!/usr/bin/env bash
# Stage 3: Create the SageMaker HyperPod cluster attached to the EKS cluster from Stage 1.
# The accelerated instance group is placed in the LZ subnet via VpcConfig.Subnets.
#
# Prereqs:
#   - deploy-eks.sh has completed successfully
#   - install-helm.sh has completed successfully
#
# Usage:
#   AWS_PROFILE=... TRAINING_PLAN_NAME=my-ftp ./create-hyperpod-cluster.sh
#
# Env vars:
#   STACK_NAME                 (default: hyperpod-eks-lz)
#   REGION                     (default: us-west-2)
#   CLUSTER_NAME               (default: hp-eks-lz-cluster)
#   ACCELERATED_INSTANCE_TYPE  (default: ml.p5e.48xlarge)
#   ACCELERATED_INSTANCE_COUNT (default: 2)
#   TRAINING_PLAN_NAME         (default: empty; required to get FTP-reserved capacity in most LZs)

set -euo pipefail

STACK_NAME=${STACK_NAME:-hyperpod-eks-lz}
REGION=${REGION:-us-west-2}
CLUSTER_NAME=${CLUSTER_NAME:-hp-eks-lz-cluster}
ACCELERATED_INSTANCE_TYPE=${ACCELERATED_INSTANCE_TYPE:-ml.p5e.48xlarge}
ACCELERATED_INSTANCE_COUNT=${ACCELERATED_INSTANCE_COUNT:-2}
TRAINING_PLAN_NAME=${TRAINING_PLAN_NAME:-}
: "${AWS_PROFILE:?AWS_PROFILE must be set}"
export AWS_DEFAULT_REGION=$REGION

# Resolve infra from CFN stack
get_output() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
EKS_CLUSTER_ARN=$(get_output EksClusterArn)
WORKER_SUBNET=$(get_output WorkerSubnetId)
SG_ID=$(get_output SecurityGroupId)
EXEC_ROLE=$(get_output HyperPodExecRoleArn)
BUCKET=$(get_output LifecycleBucket)

for pair in "EKS_CLUSTER_ARN=$EKS_CLUSTER_ARN" "WORKER_SUBNET=$WORKER_SUBNET" "SG_ID=$SG_ID" "EXEC_ROLE=$EXEC_ROLE" "BUCKET=$BUCKET"; do
  val="${pair#*=}"
  if [ -z "$val" ] || [ "$val" = "None" ]; then
    echo "ERROR: missing output ${pair%%=*} from stack $STACK_NAME"
    exit 1
  fi
done

# Resolve training plan ARN (optional)
TRAINING_PLAN_ARN=""
if [ -n "$TRAINING_PLAN_NAME" ]; then
  TRAINING_PLAN_ARN=$(aws sagemaker describe-training-plan --training-plan-name "$TRAINING_PLAN_NAME" \
    --query 'TrainingPlanArn' --output text 2>/dev/null || echo "")
  if [ -z "$TRAINING_PLAN_ARN" ] || [ "$TRAINING_PLAN_ARN" = "None" ]; then
    echo "WARNING: Training plan '$TRAINING_PLAN_NAME' not found. Trying on-demand."
    TRAINING_PLAN_ARN=""
  fi
fi

# Upload a minimal on_create.sh to the lifecycle bucket if not already present.
# HyperPod EKS worker LCS is much simpler than Slurm - it typically just sets up
# the container runtime handoff. Reference base-config has a working minimum.
LCS_KEY="on_create.sh"
if ! aws s3api head-object --bucket "$BUCKET" --key "$LCS_KEY" 2>/dev/null; then
  echo "=== Uploading a minimal on_create.sh to s3://$BUCKET/$LCS_KEY ==="
  TMPFILE=$(mktemp)
  cat > "$TMPFILE" <<'LCS'
#!/bin/bash
# Minimal on_create.sh for HyperPod EKS worker.
# The DLAMI + kubelet + HyperPod agent handle most work; this script is a placeholder
# for any node-local customization (dataset prep, package installs, etc.).
set -ex
echo "$(date) [$(hostname)] on_create.sh starting"
# No-op body - customize as needed.
echo "$(date) [$(hostname)] on_create.sh complete"
LCS
  aws s3 cp "$TMPFILE" "s3://$BUCKET/$LCS_KEY" --quiet
  rm -f "$TMPFILE"
fi

# Build cluster-config.json using Python (avoids bash quoting hell for optional fields)
CFG=$(mktemp)
mv "$CFG" "${CFG}.json"
CFG="${CFG}.json"
trap "rm -f $CFG" EXIT

python3 - <<PY > "$CFG"
import json

group = {
    "InstanceGroupName": "accelerated",
    "InstanceType": "$ACCELERATED_INSTANCE_TYPE",
    "InstanceCount": $ACCELERATED_INSTANCE_COUNT,
    "InstanceStorageConfigs": [{"EbsVolumeConfig": {"VolumeSizeInGB": 500}}],
    "LifeCycleConfig": {"SourceS3Uri": "s3://$BUCKET", "OnCreate": "on_create.sh"},
    "ExecutionRole": "$EXEC_ROLE",
    "ThreadsPerCore": 1,
}
tp_arn = "$TRAINING_PLAN_ARN"
if tp_arn:
    group["TrainingPlanArn"] = tp_arn

cfg = {
    "ClusterName": "$CLUSTER_NAME",
    "Orchestrator": {"Eks": {"ClusterArn": "$EKS_CLUSTER_ARN"}},
    "InstanceGroups": [group],
    "VpcConfig": {"SecurityGroupIds": ["$SG_ID"], "Subnets": ["$WORKER_SUBNET"]},
    "NodeRecovery": "Automatic",
}
print(json.dumps(cfg, indent=2))
PY

python3 -m json.tool "$CFG" > /dev/null || {
  echo "ERROR: generated cluster-config.json is not valid:"
  cat "$CFG"
  exit 1
}

echo "=== cluster-config.json ==="
cat "$CFG"
echo ""

# Submit
aws sagemaker create-cluster --cli-input-json "file://$CFG" \
  --query 'ClusterArn' --output text

echo ""
echo "=== Watch progress ==="
echo "aws sagemaker describe-cluster --cluster-name $CLUSTER_NAME --query 'ClusterStatus'"
echo ""
echo "Or:"
echo "aws sagemaker list-cluster-nodes --cluster-name $CLUSTER_NAME"
