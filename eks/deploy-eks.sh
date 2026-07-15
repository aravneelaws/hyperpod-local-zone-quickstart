#!/usr/bin/env bash
# Deploy the HyperPod EKS in LZ stack.
#
# **EXPERIMENTAL / UNTESTED**: as of this commit, cluster creation is known to fail
# because HyperPod EKS requires helm chart dependencies (nvidia-device-plugin, EFA k8s
# plugin, HyperPod resiliency operator) to be installed on EKS BEFORE the HyperPod
# cluster resource. This template does not yet install them. See eks/README.md.
#
# Usage: ./deploy-eks.sh [deploy|outputs|delete]

set -euo pipefail

STACK_NAME=${STACK_NAME:-hyperpod-eks-lz}
REGION=${REGION:-us-west-2}
TEMPLATE_FILE=${TEMPLATE_FILE:-hyperpod-eks-lz-stack.yaml}
# Set TRAINING_PLAN_NAME to your FTP name. Leave empty for on-demand.
TRAINING_PLAN_NAME=${TRAINING_PLAN_NAME:-}
: "${AWS_PROFILE:?AWS_PROFILE must be set}"
export AWS_DEFAULT_REGION=$REGION

case "${1:-deploy}" in
  deploy)
    # Lookup training plan ARN
    TRAINING_PLAN_ARN=$(aws sagemaker describe-training-plan --training-plan-name "$TRAINING_PLAN_NAME" \
      --query 'TrainingPlanArn' --output text 2>/dev/null || echo "")
    if [ -z "$TRAINING_PLAN_ARN" ] || [ "$TRAINING_PLAN_ARN" = "None" ]; then
      echo "WARNING: Training plan $TRAINING_PLAN_NAME not found, deploying without one (on-demand)."
      TRAINING_PLAN_ARN=""
    fi
    echo "Training Plan ARN: ${TRAINING_PLAN_ARN:-<none>}"

    echo "=== Deploying stack $STACK_NAME ==="
    aws cloudformation deploy \
      --template-file "$TEMPLATE_FILE" \
      --stack-name "$STACK_NAME" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        TrainingPlanArn="$TRAINING_PLAN_ARN"

    echo ""
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
      --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table
    ;;

  outputs)
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
      --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table
    ;;

  delete)
    echo "WARNING: This deletes EKS + HyperPod + FSx. Type 'yes' to confirm."
    read -p "> " CONFIRM
    if [ "$CONFIRM" = "yes" ]; then
      BUCKET=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`LifecycleBucket`].OutputValue' \
        --output text 2>/dev/null || true)
      if [ -n "$BUCKET" ]; then
        aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
      fi
      aws cloudformation delete-stack --stack-name "$STACK_NAME"
      echo "Delete initiated. Wait 10-15 min for EKS+FSx to fully delete."
    fi
    ;;

  *)
    echo "Usage: $0 [deploy|outputs|delete]"
    exit 1
    ;;
esac
