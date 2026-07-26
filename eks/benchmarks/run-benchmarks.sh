#!/usr/bin/env bash
# Runner for the storage-backend benchmark suite.
# Iterates: 4 backends x 2 datasets x N tests.
#
# Usage:
#   AWS_PROFILE=... ./run-benchmarks.sh                # run all
#   AWS_PROFILE=... ./run-benchmarks.sh single-pod     # only T1a/T1c/T2a (fast, ~10 min each)
#   AWS_PROFILE=... ./run-benchmarks.sh t1b            # only T1b (distributed, ~5 min)
#   AWS_PROFILE=... ./run-benchmarks.sh collect        # download results/ from FSx to laptop
#
# Assumes:
#   - HyperPod cluster is InService with 2 p5e nodes as k8s Schedulable
#   - All 4 PVCs are Bound: fsx-lustre-pvc, fsx-lz-pvc, s3mp-pvc, s3mp-multinic-pvc
#   - kubectl is configured for hp-eks-lz-eks
#   - ConfigMap ddp-bench-py exists (auto-created below)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BENCH_PY="$HERE/bench.py"
MANIFEST_SINGLE="$HERE/manifests/bench-single-pod-job.yaml"
MANIFEST_T1B="$HERE/manifests/bench-t1b-pytorchjob.yaml"

: "${AWS_PROFILE:?AWS_PROFILE must be set}"
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-west-2}

RUNID=${RUNID:-$(date +%Y%m%d-%H%M%S)}

# Backends: label -> PVC name
# Note: multi-NIC S3 Mountpoint deferred (requires HyperPod lifecycle script
# to attach secondary ENAs on p5e's other network cards; see benchmark.md).
BACKENDS=(
  "fsx-parent:fsx-lustre-pvc"
  "fsx-lz:fsx-lz-pvc"
  "s3mp-single:s3mp-pvc"
)
DATASETS=(openalex openfold-pdb)

ensure_configmap() {
  echo "=== Creating/updating ConfigMap ddp-bench-py ==="
  kubectl create configmap ddp-bench-py \
    --from-file=bench.py="$BENCH_PY" \
    --dry-run=client -o yaml | kubectl apply -f -
}

run_single_pod() {
  local bench_slug=$1  # e.g. "t1a-t1c-t2a"
  local bench_list=$2  # e.g. "t1a,t1c,t2a"
  ensure_configmap
  for backend_pvc in "${BACKENDS[@]}"; do
    BACKEND="${backend_pvc%%:*}"
    DATA_PVC="${backend_pvc##*:}"
    for DATASET in "${DATASETS[@]}"; do
      echo ""
      echo "=== Running $bench_list on backend=$BACKEND dataset=$DATASET ==="
      export BACKEND DATA_PVC DATASET RUNID BENCH="$bench_list" BENCH_SLUG="$bench_slug"
      envsubst < "$MANIFEST_SINGLE" | kubectl apply -f -
      JOB_NAME="bench-${BACKEND}-${DATASET}-${bench_slug}"
      echo "Job: $JOB_NAME"
      kubectl wait --for=condition=complete --timeout=30m job/"$JOB_NAME" 2>&1 || {
        echo "Job $JOB_NAME did not complete cleanly; check logs:"
        kubectl logs -l job-name="$JOB_NAME" --tail=50
      }
    done
  done
}

run_t1b() {
  ensure_configmap
  for backend_pvc in "${BACKENDS[@]}"; do
    BACKEND="${backend_pvc%%:*}"
    DATA_PVC="${backend_pvc##*:}"
    for DATASET in "${DATASETS[@]}"; do
      echo ""
      echo "=== T1b on backend=$BACKEND dataset=$DATASET ==="
      export BACKEND DATA_PVC DATASET RUNID
      kubectl delete pytorchjob "bench-t1b-${BACKEND}-${DATASET}" --ignore-not-found --wait=true
      envsubst < "$MANIFEST_T1B" | kubectl apply -f -
      # Wait for both pods
      sleep 60
      for i in 1 2 3 4 5 6 7 8 9 10; do
        STATE=$(kubectl get pytorchjob "bench-t1b-${BACKEND}-${DATASET}" -o jsonpath='{.status.conditions[*].type}' 2>/dev/null)
        echo "[$i] state: $STATE"
        [[ "$STATE" == *Succeeded* || "$STATE" == *Failed* ]] && break
        sleep 30
      done
    done
  done
}

collect_results() {
  # Copy /results from LZ FSx (results-mount PVC) to laptop for analysis.
  # Uses a temporary pod to tar+base64 the results and cat to stdout.
  mkdir -p "$HERE/results"
  echo "=== Collecting results from cluster to $HERE/results/ ==="
  kubectl run bench-collector --rm -i --restart=Never \
    --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
    --overrides='{"spec":{"volumes":[{"name":"results","persistentVolumeClaim":{"claimName":"fsx-lz-pvc"}}],"containers":[{"name":"c","image":"public.ecr.aws/amazonlinux/amazonlinux:2023","command":["/bin/bash","-c","cd /results && ls -la *.json 2>/dev/null || echo NO_RESULTS_YET; cd /results && tar czf /tmp/r.tgz $(ls */*.json 2>/dev/null || echo -n) && base64 /tmp/r.tgz"],"volumeMounts":[{"name":"results","mountPath":"/results"}]}]}}' \
    2>&1 | base64 -d 2>/dev/null | tar xz -C "$HERE/results/" 2>&1 || echo "collect failed or no results"
  echo ""
  echo "Files in $HERE/results/:"
  find "$HERE/results" -name '*.json' | head
}

case "${1:-all}" in
  single-pod)
    run_single_pod "t1a-t1c-t2a" "t1a,t1c,t2a"
    ;;
  t1b)
    run_t1b
    ;;
  all)
    run_single_pod "t1a-t1c-t2a" "t1a,t1c,t2a"
    run_t1b
    ;;
  collect)
    collect_results
    ;;
  *)
    echo "Usage: $0 [single-pod | t1b | all | collect]"
    exit 1
    ;;
esac
