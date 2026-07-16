#!/usr/bin/env bash
# Creates the HyperPod Slurm cluster referencing outputs from the CFN stack.
# Run AFTER deploy.sh and upload-lifecycle.sh.
#
# Usage:
#   ./create-cluster.sh

set -euo pipefail

STACK_NAME=${STACK_NAME:-hyperpod-phx-lz}
CLUSTER_NAME=${CLUSTER_NAME:-hyperpod-phx-lz-cluster}
# Set TRAINING_PLAN_NAME to the name of your Flexible Training Plan (FTP).
# Leave empty to attempt on-demand capacity (will fail if no capacity available in the LZ).
TRAINING_PLAN_NAME=${TRAINING_PLAN_NAME:-}
REGION=${REGION:-us-west-2}
: "${AWS_PROFILE:?AWS_PROFILE must be set}"
export AWS_DEFAULT_REGION=$REGION

# Grab stack outputs
get_output() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

VPC_ID=$(get_output VpcId)
PARENT_SUBNET=$(get_output ParentAzSubnetId)
LZ_SUBNET=$(get_output LzSubnetId)
SG_ID=$(get_output SecurityGroupId)
BUCKET_URI=$(get_output LifecycleBucketS3Uri)
EXEC_ROLE=$(get_output ClusterExecutionRoleArn)

# Look up training plan ARN
TRAINING_PLAN_ARN=""
if [ -n "$TRAINING_PLAN_NAME" ]; then
  TRAINING_PLAN_ARN=$(aws sagemaker describe-training-plan --training-plan-name "$TRAINING_PLAN_NAME" \
    --query 'TrainingPlanArn' --output text 2>/dev/null || echo "")
  if [ -z "$TRAINING_PLAN_ARN" ] || [ "$TRAINING_PLAN_ARN" = "None" ]; then
    echo "WARNING: Training plan '$TRAINING_PLAN_NAME' not found. Cluster will use on-demand capacity."
    TRAINING_PLAN_ARN=""
  fi
else
  echo "TRAINING_PLAN_NAME not set. Attempting on-demand capacity (usually not available for p5e in LZs)."
fi

echo "=== Cluster inputs ==="
echo "VPC: $VPC_ID"
echo "Parent AZ subnet (head): $PARENT_SUBNET"
echo "LZ subnet (worker):      $LZ_SUBNET"
echo "Security group:          $SG_ID"
echo "Lifecycle S3 URI:        $BUCKET_URI"
echo "Execution role:          $EXEC_ROLE"
echo "Training plan ARN:       ${TRAINING_PLAN_ARN:-<none, on-demand>}"
echo ""

# Build the worker group. If a training plan ARN was found, include it.
if [ -n "$TRAINING_PLAN_ARN" ]; then
  WORKER_TRAINING_PLAN=", \"TrainingPlanArn\": \"${TRAINING_PLAN_ARN}\""
else
  WORKER_TRAINING_PLAN=""
fi

# Build the instance-groups payload
INSTANCE_GROUPS=$(cat <<JSON
[
  {
    "InstanceGroupName": "controller-machine",
    "InstanceType": "ml.m6i.4xlarge",
    "InstanceCount": 1,
    "LifeCycleConfig": {
      "SourceS3Uri": "${BUCKET_URI}/src",
      "OnCreate": "on_create.sh"
    },
    "ExecutionRole": "${EXEC_ROLE}",
    "ThreadsPerCore": 2,
    "InstanceStorageConfigs": [
      {"EbsVolumeConfig": {"VolumeSizeInGB": 500}}
    ],
    "OverrideVpcConfig": {
      "SecurityGroupIds": ["${SG_ID}"],
      "Subnets": ["${LZ_SUBNET}"]
    }
  },
  {
    "InstanceGroupName": "worker-group-1",
    "InstanceType": "ml.p5e.48xlarge",
    "InstanceCount": 2,
    "LifeCycleConfig": {
      "SourceS3Uri": "${BUCKET_URI}/src",
      "OnCreate": "on_create.sh"
    },
    "ExecutionRole": "${EXEC_ROLE}",
    "ThreadsPerCore": 1,
    "InstanceStorageConfigs": [
      {"EbsVolumeConfig": {"VolumeSizeInGB": 500}}
    ],
    "OverrideVpcConfig": {
      "SecurityGroupIds": ["${SG_ID}"],
      "Subnets": ["${LZ_SUBNET}"]
    }${WORKER_TRAINING_PLAN}
  }
]
JSON
)

VPC_CONFIG=$(cat <<JSON
{
  "SecurityGroupIds": ["${SG_ID}"],
  "Subnets": ["${PARENT_SUBNET}"]
}
JSON
)

echo "=== Creating cluster $CLUSTER_NAME ==="
aws sagemaker create-cluster \
  --cluster-name "$CLUSTER_NAME" \
  --instance-groups "$INSTANCE_GROUPS" \
  --vpc-config "$VPC_CONFIG" \
  --node-recovery Automatic

echo ""
echo "=== Cluster creation submitted. Watch progress: ==="
echo "aws sagemaker describe-cluster --cluster-name $CLUSTER_NAME --query 'ClusterStatus'"
echo ""
echo "Or use console:"
echo "https://console.aws.amazon.com/sagemaker/home?region=${REGION}#/cluster-management/${CLUSTER_NAME}"
