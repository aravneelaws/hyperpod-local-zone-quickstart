#!/usr/bin/env bash
# Stage 2: Install the HyperPod dependency helm chart into the EKS cluster.
# Follows the AWS reference workshop's manual install path.
#
# Prereqs:
#   - helm >= 3.x installed locally (verify: helm version)
#   - kubectl configured for the EKS cluster (verify: kubectl get nodes)
#   - git installed locally
#
# Charts installed (as one umbrella release "hyperpod-dependencies"):
#   - health-monitoring-agent (namespace aws-hyperpod)
#   - nvidia-device-plugin
#   - aws-efa-k8s-device-plugin
#   - neuron-device-plugin (for Trainium; harmless on GPU-only)
#   - training-operators (kubeflow, namespace kubeflow)
#   - mpi-operator
#   - kubernetes PriorityClass
#
# Usage: AWS_PROFILE=... ./install-helm.sh

set -euo pipefail

STACK_NAME=${STACK_NAME:-hyperpod-eks-lz}
REGION=${REGION:-us-west-2}
HELM_REPO=${HELM_REPO:-https://github.com/aws/sagemaker-hyperpod-cli.git}
CHART_PATH_IN_REPO=${CHART_PATH_IN_REPO:-helm_chart/HyperPodHelmChart}
RELEASE_NAME=${RELEASE_NAME:-hyperpod-dependencies}
NAMESPACE=${NAMESPACE:-kube-system}
: "${AWS_PROFILE:?AWS_PROFILE must be set}"
export AWS_DEFAULT_REGION=$REGION

# Sanity: local tools
for cmd in helm kubectl git aws; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found in PATH"; exit 1; }
done

# Get EKS cluster name from the stack outputs
EKS_CLUSTER_NAME=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[?OutputKey==`EksClusterName`].OutputValue' --output text)
if [ -z "$EKS_CLUSTER_NAME" ] || [ "$EKS_CLUSTER_NAME" = "None" ]; then
  echo "ERROR: could not resolve EksClusterName from stack $STACK_NAME"
  exit 1
fi

echo "=== Configuring kubectl for cluster $EKS_CLUSTER_NAME ==="
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$REGION"

echo ""
echo "=== EKS cluster info ==="
kubectl cluster-info 2>&1 | head -3
echo ""
kubectl get nodes 2>&1 | head
kubectl get pods -A 2>&1 | head -20

# Clone the helm chart repo into a tempdir
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
echo ""
echo "=== Cloning helm chart from $HELM_REPO ==="
git clone --depth 1 "$HELM_REPO" "$TMPDIR/sagemaker-hyperpod-cli" >/dev/null 2>&1
CHART_DIR="$TMPDIR/sagemaker-hyperpod-cli/$CHART_PATH_IN_REPO"
if [ ! -d "$CHART_DIR" ]; then
  echo "ERROR: chart path $CHART_PATH_IN_REPO not found in $HELM_REPO"
  exit 1
fi

echo ""
echo "=== helm dependency update ==="
cd "$CHART_DIR/.."
helm dependency update "$(basename $CHART_DIR)"

echo ""
echo "=== helm install $RELEASE_NAME ==="
helm upgrade --install "$RELEASE_NAME" "$(basename $CHART_DIR)" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout 15m

echo ""
echo "=== Verify install ==="
helm list --all-namespaces
echo ""
echo "--- aws-hyperpod namespace ---"
kubectl get ds -n aws-hyperpod 2>&1 || echo "(no ds in aws-hyperpod yet, ok)"
kubectl get pods -n aws-hyperpod 2>&1 || echo "(no pods yet)"
echo ""
echo "--- kube-system HyperPod pieces ---"
kubectl get ds -n kube-system 2>&1 | head -15

echo ""
echo "=== Done. Next: ./create-hyperpod-cluster.sh ==="
