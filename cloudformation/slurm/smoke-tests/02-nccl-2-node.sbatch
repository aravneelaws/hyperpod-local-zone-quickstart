#!/bin/bash
#SBATCH --job-name=nccl-2node
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --exclusive
#SBATCH -p ml.p5e.48xlarge
#SBATCH --output=logs/nccl-2node-%j.out
#SBATCH --error=logs/nccl-2node-%j.err
#SBATCH --time=00:20:00

# 2-node NCCL all-reduce over EFA. THE key test for Local Zones.
# Validates that the LZ has functional multi-rail EFA fabric.
#
# Tested result on H200 p5e in PHX LZ (us-west-2-phx-2a):
#   4 GB:  ~465 GB/s busBw
#   8 GB:  ~479 GB/s busBw
#  16 GB:  ~484 GB/s busBw
# These numbers are consistent with all 32 EFA rails being active.

set -ex
mkdir -p logs

CUDA_DIR=$(ls -d /usr/local/cuda-*/efa/test-cuda-*/ 2>/dev/null | head -1)
[ -z "$CUDA_DIR" ] && { echo "ERROR: NCCL binaries not found"; exit 1; }
echo "Using NCCL binaries from: $CUDA_DIR"

# NCCL / EFA settings
export NCCL_DEBUG=INFO
export FI_PROVIDER=efa
export FI_EFA_USE_HUGE_PAGE=0

# 8 ranks per node x 2 nodes = 16 GPUs total
srun --mpi=pmix "${CUDA_DIR}/all_reduce_perf" -b 8 -e 16G -f 2 -g 1

echo "=== Done ==="
