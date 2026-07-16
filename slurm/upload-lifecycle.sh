#!/usr/bin/env bash
# Uploads HyperPod Slurm lifecycle scripts (AWS reference base-config) to the S3 bucket
# from the CFN stack. Run AFTER deploy.sh completes.
#
# Usage:
#   ./upload-lifecycle.sh

set -euo pipefail

STACK_NAME=${STACK_NAME:-hyperpod-phx-lz}
REGION=${REGION:-us-west-2}
: "${AWS_PROFILE:?AWS_PROFILE must be set}"
export AWS_DEFAULT_REGION=$REGION

BUCKET=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[?OutputKey==`LifecycleBucket`].OutputValue' \
  --output text)

FSX_DNS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[?OutputKey==`FsxDnsName`].OutputValue' \
  --output text)

FSX_MOUNT_NAME=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[?OutputKey==`FsxMountName`].OutputValue' \
  --output text)

echo "S3 bucket: $BUCKET"
echo "FSx DNS: $FSX_DNS"
echo "FSx mount name: $FSX_MOUNT_NAME"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
cd "$TMPDIR"

echo ""
echo "=== Cloning awsome-distributed-training reference lifecycle scripts ==="
git clone --depth 1 https://github.com/aws-samples/awsome-distributed-training.git
cd awsome-distributed-training/1.architectures/5.sagemaker-hyperpod/LifecycleScripts/base-config

echo ""
echo "=== Creating provisioning_parameters.json (matches AWS reference automate-cluster-creation.sh format) ==="
cat > provisioning_parameters.json <<PROV
{
  "version": "1.0.0",
  "workload_manager": "slurm",
  "controller_group": "controller-machine",
  "worker_groups": [
    {"instance_group_name": "worker-group-1", "partition_name": "ml.p5e.48xlarge"}
  ],
  "fsx_dns_name": "${FSX_DNS}",
  "fsx_mountname": "${FSX_MOUNT_NAME}"
}
PROV
echo "Wrote provisioning_parameters.json:"
cat provisioning_parameters.json

echo ""
echo "=== Uploading to s3://$BUCKET/src/ ==="
aws s3 sync . "s3://$BUCKET/src/" --exclude ".git/*"

echo ""
echo "=== Done. Contents: ==="
aws s3 ls "s3://$BUCKET/src/"
