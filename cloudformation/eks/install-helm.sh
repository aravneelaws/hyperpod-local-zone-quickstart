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
echo "=== Done with hyperpod-dependencies. Next: FSx CSI driver ==="
echo ""

# ---------- Install aws-fsx-csi-driver ----------
# The HyperPod helm chart does NOT include FSx CSI. Install it separately
# so pods can mount the FSx Lustre file system provisioned by the CFN stack.
echo "=== Adding aws-fsx-csi-driver helm repo ==="
helm repo add aws-fsx-csi-driver https://kubernetes-sigs.github.io/aws-fsx-csi-driver >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

echo ""
echo "=== helm upgrade --install aws-fsx-csi-driver ==="
helm upgrade --install aws-fsx-csi-driver aws-fsx-csi-driver/aws-fsx-csi-driver \
  --namespace kube-system \
  --wait \
  --timeout 5m

echo ""
echo "=== Verify FSx CSI driver ==="
kubectl get csidrivers 2>&1 | grep -E "NAME|fsx"
kubectl get pods -n kube-system 2>&1 | grep fsx

echo ""
echo "=== Done with FSx CSI driver. Next: S3 Mountpoint CSI driver ==="
echo ""

# ---------- Install aws-mountpoint-s3-csi-driver ----------
# Only needed if using S3 Mountpoint as a storage backend (in addition to,
# or instead of, FSx Lustre). Skip by setting SKIP_S3_MOUNTPOINT_CSI=1.
if [ "${SKIP_S3_MOUNTPOINT_CSI:-0}" = "1" ]; then
  echo "=== SKIP_S3_MOUNTPOINT_CSI=1, skipping S3 Mountpoint CSI install ==="
else
  echo "=== Adding aws-mountpoint-s3-csi-driver helm repo ==="
  helm repo add aws-mountpoint-s3-csi-driver https://awslabs.github.io/mountpoint-s3-csi-driver >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1

  echo ""
  echo "=== helm upgrade --install aws-mountpoint-s3-csi-driver ==="
  # --wait can time out if there are no worker nodes yet (DaemonSet has nothing to schedule onto).
  # Retry without --wait to still complete the release install.
  if ! helm upgrade --install aws-mountpoint-s3-csi-driver aws-mountpoint-s3-csi-driver/aws-mountpoint-s3-csi-driver \
        --namespace kube-system --wait --timeout 5m 2>/dev/null; then
    echo "First install attempt (--wait) timed out; retrying without --wait..."
    helm upgrade --install aws-mountpoint-s3-csi-driver aws-mountpoint-s3-csi-driver/aws-mountpoint-s3-csi-driver \
      --namespace kube-system
  fi

  echo ""
  echo "=== Verify S3 Mountpoint CSI driver ==="
  kubectl get csidrivers 2>&1 | grep -E "NAME|s3"
  kubectl get sa -n kube-system s3-csi-driver-sa 2>&1

  echo ""
  echo "NOTE: The S3 Mountpoint CSI driver's ServiceAccount (s3-csi-driver-sa)"
  echo "      needs Pod Identity association with an IAM role that has S3"
  echo "      permissions on the target bucket. If you deployed the CFN stack"
  echo "      with CreateS3MountpointBucket=true, the association is already"
  echo "      wired up by CFN (see stack output S3MountpointRoleArn)."
fi

echo ""
echo "=== Done. Next steps: ==="
echo "  1. Apply the static FSx PV/PVC: ./create-fsx-pv.sh (auto-generated from stack outputs)"
echo "  2. Create the HyperPod cluster: ./create-hyperpod-cluster.sh"
