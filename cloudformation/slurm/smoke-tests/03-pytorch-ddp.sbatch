#!/bin/bash
#SBATCH --job-name=ddp-smoke
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:8
#SBATCH --exclusive
#SBATCH -p ml.p5e.48xlarge
#SBATCH --output=logs/ddp-%j.out
#SBATCH --error=logs/ddp-%j.err
#SBATCH --time=00:20:00

# Multi-node PyTorch DDP smoke test.
# Trains a ~440M-parameter MLP on synthetic data across 16 GPUs (2 nodes x 8).
#
# Prereqs:
#  - venv-ddp with torch + torchvision already installed on /opt/dlami/nvme/ on both worker nodes.
#    See 04-install-venv-on-nvme.sbatch (a companion helper) or install manually with:
#      srun -N2 --gres=gpu:1 bash -c '
#        VENV=/opt/dlami/nvme/venv-ddp
#        [ -d "$VENV/lib/python3.10/site-packages/torch" ] || {
#          python3 -m venv "$VENV" &&
#          "$VENV/bin/pip" install torch torchvision --index-url https://download.pytorch.org/whl/cu124
#        }
#      '
#  - This sbatch file is submitted from the controller with the training script co-located at
#    /fsx/ubuntu/ddp-test/ddp_mini.py (see below). FSx is used because it is shared across nodes;
#    /tmp is not shared, so srun'd python processes on the second node cannot see files
#    created on the first.
#
# Tested result on H200 p5e in PHX LZ: 100 steps in ~3.2s, ~16,239 samples/sec across 16 GPUs.

set -ex
mkdir -p logs

VENV=${VENV:-/opt/dlami/nvme/venv-ddp}
TRAIN_SCRIPT=${TRAIN_SCRIPT:-/fsx/ubuntu/ddp-test/ddp_mini.py}

if [ ! -x "$VENV/bin/torchrun" ]; then
  echo "ERROR: venv not found at $VENV/bin/torchrun. See prereqs above."
  exit 1
fi

if [ ! -f "$TRAIN_SCRIPT" ]; then
  # Write the training script to FSx so both nodes can access it
  mkdir -p "$(dirname "$TRAIN_SCRIPT")"
  cat > "$TRAIN_SCRIPT" <<'PY'
import os
import time
import socket
import torch
import torch.nn as nn
import torch.distributed as dist
from torch.nn.parallel import DistributedDataParallel as DDP


def main():
    dist.init_process_group(backend="nccl")
    local_rank = int(os.environ["LOCAL_RANK"])
    torch.cuda.set_device(local_rank)
    device = torch.device(f"cuda:{local_rank}")
    rank, world = dist.get_rank(), dist.get_world_size()

    if rank == 0:
        print(
            f"[rank {rank}] host={socket.gethostname()} world_size={world} "
            f"torch={torch.__version__} cuda={torch.version.cuda} "
            f"gpu={torch.cuda.get_device_name(local_rank)}",
            flush=True,
        )
    dist.barrier()

    # ~440M-parameter MLP: 26 Linear(4096, 4096) layers
    model = nn.Sequential(
        nn.Linear(4096, 4096), nn.ReLU(),
        *[nn.Sequential(nn.Linear(4096, 4096), nn.ReLU()) for _ in range(24)],
        nn.Linear(4096, 4096),
    ).to(device)
    model = DDP(model, device_ids=[local_rank])
    opt = torch.optim.AdamW(model.parameters(), lr=1e-4)
    loss_fn = nn.MSELoss()

    batch_size = 32
    steps = 100
    t0 = time.time()
    for step in range(steps):
        x = torch.randn(batch_size, 4096, device=device)
        y = torch.randn(batch_size, 4096, device=device)
        loss = loss_fn(model(x), y)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        opt.step()
        if rank == 0 and step % 10 == 0:
            print(
                f"[rank 0] step {step}/{steps} loss={loss.item():.4f} "
                f"elapsed={time.time() - t0:.1f}s",
                flush=True,
            )

    if rank == 0:
        total = time.time() - t0
        thr = steps * batch_size * world / total
        print(
            f"[rank 0] SUCCESS: {steps} steps in {total:.1f}s "
            f"({thr:.1f} samples/sec across {world} GPUs)",
            flush=True,
        )
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
PY
  echo "Wrote training script to $TRAIN_SCRIPT"
fi

# Head node coordinates
export MASTER_ADDR=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n1)
export MASTER_PORT=29500

# DDP + NCCL settings
export NCCL_DEBUG=WARN
export FI_PROVIDER=efa
export FI_EFA_USE_HUGE_PAGE=0

srun bash -c "$VENV/bin/torchrun \
  --nnodes=2 \
  --nproc-per-node=8 \
  --rdzv-id=\$SLURM_JOB_ID \
  --rdzv-backend=c10d \
  --rdzv-endpoint=\$MASTER_ADDR:\$MASTER_PORT \
  $TRAIN_SCRIPT"

echo "=== Done ==="
