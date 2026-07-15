#!/usr/bin/env bash
# Deploys the CFN stack, then walks through post-CFN steps.
# Prereqs: AWS_PROFILE set, region us-west-2, PHX LZ opted in (already done).
#
# Usage:
#   ./deploy.sh           # Deploy the stack
#   ./deploy.sh outputs   # Show stack outputs
#   ./deploy.sh delete    # Delete the stack

set -euo pipefail

STACK_NAME=${STACK_NAME:-hyperpod-phx-lz}
REGION=${REGION:-us-west-2}
TEMPLATE_FILE=${TEMPLATE_FILE:-hyperpod-lz-stack.yaml}

: "${AWS_PROFILE:?AWS_PROFILE must be set}"
export AWS_DEFAULT_REGION=$REGION

case "${1:-deploy}" in
  deploy)
    echo "=== Verifying PHX LZ is opted in ==="
    aws ec2 describe-availability-zones --all-availability-zones \
      --filters "Name=zone-name,Values=us-west-2-phx-2a" \
      --query 'AvailabilityZones[].[ZoneName,OptInStatus]' --output table

    echo ""
    echo "=== Deploying stack $STACK_NAME ==="
    aws cloudformation deploy \
      --template-file "$TEMPLATE_FILE" \
      --stack-name "$STACK_NAME" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        CreateFsx=true \
        FsxStorageCapacityGiB=1200 \
        FsxPerUnitStorageThroughput=250

    echo ""
    echo "=== Stack outputs ==="
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
      --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table
    ;;

  outputs)
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
      --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table
    ;;

  delete)
    echo "=== Deleting stack $STACK_NAME ==="
    echo "WARNING: This will delete the FSx file system and lose all data on it."

    # Refuse to run if HyperPod cluster still exists (stack delete will hang otherwise)
    CLUSTER_NAME=${CLUSTER_NAME:-hyperpod-phx-lz-cluster}
    if aws sagemaker describe-cluster --cluster-name "$CLUSTER_NAME" --query 'ClusterStatus' --output text 2>/dev/null | grep -qv "^$"; then
      echo ""
      echo "ERROR: HyperPod cluster '$CLUSTER_NAME' still exists. Delete it first:"
      echo "  aws sagemaker delete-cluster --cluster-name $CLUSTER_NAME"
      echo "  aws sagemaker wait cluster-deleted --cluster-name $CLUSTER_NAME"
      echo "Then rerun './deploy.sh delete'."
      exit 1
    fi

    read -p "Continue with stack delete? (yes/no) " CONFIRM
    if [ "$CONFIRM" = "yes" ]; then
      # Empty the lifecycle bucket first (CFN can't delete non-empty buckets)
      BUCKET=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`LifecycleBucket`].OutputValue' \
        --output text 2>/dev/null || true)
      if [ -n "$BUCKET" ]; then
        echo "Emptying $BUCKET..."
        aws s3 rm "s3://$BUCKET" --recursive || true
      fi
      aws cloudformation delete-stack --stack-name "$STACK_NAME"
      echo "Delete initiated. Monitor with: aws cloudformation describe-stacks --stack-name $STACK_NAME"
    fi
    ;;

  *)
    echo "Usage: $0 [deploy|outputs|delete]"
    exit 1
    ;;
esac
