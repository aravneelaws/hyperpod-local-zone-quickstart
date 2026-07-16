#!/bin/bash
#SBATCH --job-name=nccl-1node
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --exclusive
#SBATCH -p ml.p5e.48xlarge
#SBATCH --output=logs/nccl-1node-%j.out
#SBATCH --error=logs/nccl-1node-%j.err
#SBATCH --time=00:15:00

# Single-node NCCL all_reduce test. Only intra-node NVSwitch used (no EFA).
# Expected on H200 p5e (8x): ~475 GB/s busBw at 4 GB.

set -ex
mkdir -p logs

# Auto-detect CUDA path (DLAMI ships CUDA 13.0 as of Jul 2026)
CUDA_DIR=$(ls -d /usr/local/cuda-*/efa/test-cuda-*/ 2>/dev/null | head -1)
[ -z "$CUDA_DIR" ] && { echo "ERROR: NCCL binaries not found"; exit 1; }
echo "Using NCCL binaries from: $CUDA_DIR"

srun --mpi=pmix "${CUDA_DIR}/all_reduce_perf" -b 8 -e 4G -f 2 -g 1

echo "=== Done ==="
