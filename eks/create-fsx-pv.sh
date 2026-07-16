#!/usr/bin/env bash
# Stage 2.5: Create a static Kubernetes PersistentVolume + PersistentVolumeClaim
# referencing the FSx Lustre file system provisioned by the CFN stack.
#
# Prereqs:
#   - deploy-eks.sh has completed (CFN created FSx)
#   - install-helm.sh has completed (aws-fsx-csi-driver installed)
#
# Usage: AWS_PROFILE=... ./create-fsx-pv.sh
#
# Produces a Kubernetes PV named fsx-lustre-pv and a PVC named fsx-lustre-pvc
# in namespace default. Pods reference the PVC via:
#   volumes:
#     - name: fsx
#       persistentVolumeClaim:
#         claimName: fsx-lustre-pvc

set -euo pipefail

STACK_NAME=${STACK_NAME:-hyperpod-eks-lz}
REGION=${REGION:-us-west-2}
NAMESPACE=${NAMESPACE:-default}
PV_NAME=${PV_NAME:-fsx-lustre-pv}
PVC_NAME=${PVC_NAME:-fsx-lustre-pvc}
: "${AWS_PROFILE:?AWS_PROFILE must be set}"
export AWS_DEFAULT_REGION=$REGION

get_output() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null || echo ""
}

FSX_ID=$(get_output FsxFileSystemId)
FSX_DNS=$(get_output FsxDnsName)
FSX_MOUNT=$(get_output FsxMountName)

for pair in "FSX_ID=$FSX_ID" "FSX_DNS=$FSX_DNS" "FSX_MOUNT=$FSX_MOUNT"; do
  val="${pair#*=}"
  if [ -z "$val" ] || [ "$val" = "None" ]; then
    echo "ERROR: missing FSx output ${pair%%=*} from stack $STACK_NAME."
    echo "Either the stack was deployed with CreateFsx=false, or the stack does not exist."
    exit 1
  fi
done

echo "=== FSx Lustre info ==="
echo "  ID:        $FSX_ID"
echo "  DNS:       $FSX_DNS"
echo "  MountName: $FSX_MOUNT"
echo ""

FSX_CAPACITY_GIB=$(aws fsx describe-file-systems --file-system-ids "$FSX_ID" \
  --query 'FileSystems[0].StorageCapacity' --output text 2>/dev/null || echo 1200)

echo "=== Applying PV + PVC to k8s ==="
kubectl apply -f - <<YAML
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PV_NAME}
  labels:
    type: fsx-lustre
spec:
  capacity:
    storage: ${FSX_CAPACITY_GIB}Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  mountOptions:
    - flock
  persistentVolumeReclaimPolicy: Retain
  csi:
    driver: fsx.csi.aws.com
    # Static volume handle format: <fs-id>::<mount-name>::<dns-name>
    volumeHandle: ${FSX_ID}::${FSX_MOUNT}::${FSX_DNS}
    volumeAttributes:
      dnsname: ${FSX_DNS}
      mountname: ${FSX_MOUNT}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  # storageClassName: "" + selector binds this PVC to our specific PV.
  storageClassName: ""
  resources:
    requests:
      storage: ${FSX_CAPACITY_GIB}Gi
  selector:
    matchLabels:
      type: fsx-lustre
YAML

sleep 5
kubectl get pv "$PV_NAME" 2>&1
kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" 2>&1
