#!/bin/bash
# Run FROM the controller node after SSHing in.
# Verifies: Slurm, GPUs, EFA, FSx mount, NCCL binaries.

set +e  # keep going on failures - we want to see all diagnostics

echo "=========================================="
echo "1. Slurm partition state"
echo "=========================================="
sinfo -l
echo ""

echo "=========================================="
echo "2. GPU inventory on each worker (via srun)"
echo "=========================================="
srun -N2 --ntasks-per-node=1 --gres=gpu:8 bash -c 'echo "=== $(hostname) ==="; nvidia-smi -L; echo ""; nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader'
echo ""

echo "=========================================="
echo "3. EFA adapters on each worker"
echo "=========================================="
srun -N2 --ntasks-per-node=1 bash -c 'echo "=== $(hostname) ==="; fi_info -p efa 2>&1 | grep -E "provider|fabric|domain" | head -40; echo ""; echo "EFA device count: $(ls /sys/class/infiniband/ 2>/dev/null | grep -c rdmap || echo 0)"'
echo ""

echo "=========================================="
echo "4. FSx mount"
echo "=========================================="
df -h /fsx 2>/dev/null || echo "FSx not mounted at /fsx"
srun -N2 --ntasks-per-node=1 bash -c 'echo "=== $(hostname) ==="; df -h /fsx 2>&1 || echo "no FSx mount"'
echo ""

echo "=========================================="
echo "5. NCCL test binaries"
echo "=========================================="
ls /usr/local/cuda-*/efa/test-cuda-*/all_reduce_perf 2>/dev/null || echo "NCCL binaries not found in standard location - searching..."
find / -name "all_reduce_perf" -type f 2>/dev/null | head -3
echo ""

echo "=========================================="
echo "6. Slurm accounting / job state"
echo "=========================================="
squeue
echo ""

echo "=========================================="
echo "Done."
echo "=========================================="
