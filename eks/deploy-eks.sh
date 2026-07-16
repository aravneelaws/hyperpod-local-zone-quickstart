#!/usr/bin/env bash
# Stage 1: Deploy the infrastructure-only CFN stack for HyperPod EKS in a Local Zone.
# Creates: VPC, subnets (parent AZ + LZ), EKS cluster with add-ons, IAM roles, S3 bucket.
# Does NOT install helm charts or create the HyperPod cluster.
#
# Usage:
#   AWS_PROFILE=... ./deploy-eks.sh                # deploy (or update)
#   AWS_PROFILE=... ./deploy-eks.sh outputs        # show stack outputs
#   AWS_PROFILE=... ./deploy-eks.sh delete         # tear down
#
# After deploy, run:
#   ./install-helm.sh              (installs HyperPod helm dependencies into EKS)
#   ./create-hyperpod-cluster.sh   (creates the AWS::SageMaker::Cluster)

set -euo pipefail

STACK_NAME=${STACK_NAME:-hyperpod-eks-lz}
REGION=${REGION:-us-west-2}
TEMPLATE_FILE=${TEMPLATE_FILE:-hyperpod-eks-lz-stack.yaml}
LOCAL_ZONE_ID=${LOCAL_ZONE_ID:-usw2-phx2-az1}
K8S_VERSION=${K8S_VERSION:-1.33}
: "${AWS_PROFILE:?AWS_PROFILE must be set}"
export AWS_DEFAULT_REGION=$REGION

case "${1:-deploy}" in
  deploy)
    echo "=== Deploying stack $STACK_NAME ==="
    echo "  Region:      $REGION"
    echo "  Local Zone:  $LOCAL_ZONE_ID"
    echo "  K8s version: $K8S_VERSION"
    echo ""

    aws cloudformation deploy \
      --template-file "$TEMPLATE_FILE" \
      --stack-name "$STACK_NAME" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        LocalZoneId="$LOCAL_ZONE_ID" \
        KubernetesVersion="$K8S_VERSION"

    echo ""
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
      --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table

    echo ""
    echo "Next steps:"
    echo "  1. Configure kubectl:  aws eks update-kubeconfig --name \$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query 'Stacks[0].Outputs[?OutputKey==\`EksClusterName\`].OutputValue' --output text) --region $REGION"
    echo "  2. Install helm chart: ./install-helm.sh"
    echo "  3. Create HyperPod:    ./create-hyperpod-cluster.sh"
    ;;

  outputs)
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
      --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table
    ;;

  delete)
    echo "This deletes the EKS cluster and VPC. If a HyperPod cluster still exists, delete it first."
    read -p "Continue? (yes/no) " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then exit 0; fi

    BUCKET=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
      --query 'Stacks[0].Outputs[?OutputKey==`LifecycleBucket`].OutputValue' \
      --output text 2>/dev/null || true)
    if [ -n "$BUCKET" ]; then
      aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
    fi
    aws cloudformation delete-stack --stack-name "$STACK_NAME"
    echo "Delete initiated."
    ;;

  *)
    echo "Usage: $0 [deploy|outputs|delete]"
    exit 1
    ;;
esac
