#!/usr/bin/env bash
# Helper: apply/monitor/reset the DDP training PyTorchJob.
#
# Usage:
#   AWS_PROFILE=... ./run-ddp-smoke-test.sh apply           # start training
#   AWS_PROFILE=... ./run-ddp-smoke-test.sh logs            # tail master log
#   AWS_PROFILE=... ./run-ddp-smoke-test.sh status          # show job + pods
#   AWS_PROFILE=... ./run-ddp-smoke-test.sh delete          # delete job (keep ckpts on FSx)
#   AWS_PROFILE=... ./run-ddp-smoke-test.sh reset           # delete job + wipe checkpoints
#
# The training script is loaded into a ConfigMap so we don't have to embed
# Python in YAML.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
JOB_YAML="$HERE/manifests/ddp-train-job.yaml"
PREP_YAML="$HERE/manifests/ddp-dataset-prep-job.yaml"
TRAIN_PY="$HERE/manifests/ddp_train.py"

: "${AWS_PROFILE:?AWS_PROFILE must be set}"
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-west-2}

for f in "$JOB_YAML" "$TRAIN_PY" "$PREP_YAML"; do
  [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

ensure_configmap() {
  # (Re-)create the ConfigMap that holds ddp_train.py.
  # Using create --dry-run + apply so this is idempotent.
  kubectl create configmap ddp-train-py \
    --from-file=ddp_train.py="$TRAIN_PY" \
    --dry-run=client -o yaml | kubectl apply -f -
}

ensure_dataset() {
  echo "=== Ensuring dataset is prepped ==="
  if kubectl get job ddp-dataset-prep >/dev/null 2>&1; then
    if kubectl get job ddp-dataset-prep -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -q 1; then
      echo "Dataset prep already ran successfully."
      return
    fi
    kubectl delete job ddp-dataset-prep --wait=true
  fi
  kubectl apply -f "$PREP_YAML"
  kubectl wait --for=condition=complete --timeout=15m job/ddp-dataset-prep
}

case "${1:-apply}" in
  apply)
    ensure_dataset
    echo ""
    echo "=== Creating/updating ddp-train-py ConfigMap ==="
    ensure_configmap
    echo ""
    echo "=== Deleting any prior training job ==="
    kubectl delete pytorchjob nccl-ddp-train --ignore-not-found --wait=true
    echo ""
    echo "=== Applying DDP training PyTorchJob ==="
    kubectl apply -f "$JOB_YAML"
    echo ""
    echo "Watch progress with:  $0 logs"
    ;;

  logs)
    kubectl logs -f nccl-ddp-train-master-0
    ;;

  status)
    echo "=== Job ==="
    kubectl get pytorchjob nccl-ddp-train 2>&1 || echo "(no job)"
    echo ""
    echo "=== Pods ==="
    kubectl get pods -l pytorch-job-name=nccl-ddp-train 2>&1 || echo "(no pods)"
    echo ""
    echo "=== Checkpoints on FSx ==="
    kubectl run fsx-peek --rm -i --restart=Never --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
      --overrides='{"spec":{"volumes":[{"name":"fsx","persistentVolumeClaim":{"claimName":"fsx-lustre-pvc"}}],"containers":[{"name":"peek","image":"public.ecr.aws/amazonlinux/amazonlinux:2023","command":["ls","-la","/fsx/ddp-smoke/ckpt/"],"volumeMounts":[{"name":"fsx","mountPath":"/fsx"}]}]}}' 2>&1 || echo "(fsx-peek pod failed)"
    ;;

  delete)
    kubectl delete pytorchjob nccl-ddp-train --ignore-not-found
    kubectl delete configmap ddp-train-py --ignore-not-found
    ;;

  reset)
    kubectl delete pytorchjob nccl-ddp-train --ignore-not-found
    kubectl delete configmap ddp-train-py --ignore-not-found
    echo "=== Wiping FSx checkpoint dir ==="
    kubectl run fsx-wipe --rm -i --restart=Never --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
      --overrides='{"spec":{"volumes":[{"name":"fsx","persistentVolumeClaim":{"claimName":"fsx-lustre-pvc"}}],"containers":[{"name":"w","image":"public.ecr.aws/amazonlinux/amazonlinux:2023","command":["/bin/bash","-c","rm -rf /fsx/ddp-smoke/ckpt/* && ls /fsx/ddp-smoke/"],"volumeMounts":[{"name":"fsx","mountPath":"/fsx"}]}]}}'
    ;;

  *)
    echo "Usage: $0 [apply|logs|status|delete|reset]"
    exit 1
    ;;
esac
