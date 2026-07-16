"""Multi-node DDP smoke test for HyperPod EKS + FSx Lustre.

Uses FSx (/fsx) for:
- reading a synthetic dataset (seeded once by a companion prep job)
- writing per-epoch checkpoints from rank 0

Runs on 2 nodes x 8 GPUs = 16 ranks via torchrun c10d rendezvous, using EFA
for gradient sync via NCCL.

If a checkpoint exists in /fsx/ddp-smoke/ckpt/, resumes from it. This makes
the second run of the same PyTorchJob demonstrate durable state.
"""
import os
import socket
import time
from pathlib import Path

import torch
import torch.distributed as dist
import torch.nn as nn
from torch.nn.parallel import DistributedDataParallel as DDP
from torch.utils.data import DataLoader, Dataset, DistributedSampler


FSX_ROOT = Path(os.environ.get("FSX_ROOT", "/fsx/ddp-smoke"))
DATASET_PATH = FSX_ROOT / "dataset" / "synthetic.pt"
CKPT_DIR = FSX_ROOT / "ckpt"


class SyntheticDataset(Dataset):
    """Loads pre-serialized tensors from FSx.

    This exercises the FSx read path from every rank concurrently. Total dataset
    size is intentionally modest (~4 GiB) so cross-zone read latency doesn't
    dominate; the point is to prove the plumbing works, not to benchmark FSx.
    """

    def __init__(self, path: Path):
        blob = torch.load(path, map_location="cpu", weights_only=False)
        self.x = blob["x"]
        self.y = blob["y"]

    def __len__(self):
        return self.x.shape[0]

    def __getitem__(self, i):
        return self.x[i], self.y[i]


def build_model():
    # ~440M-parameter MLP. Same size as the Slurm smoke test for comparability.
    return nn.Sequential(
        nn.Linear(4096, 4096),
        nn.ReLU(),
        *[nn.Sequential(nn.Linear(4096, 4096), nn.ReLU()) for _ in range(24)],
        nn.Linear(4096, 4096),
    )


def maybe_load_checkpoint(model, optimizer, device):
    """Find newest epoch-N.pt in ckpt dir; return (start_epoch, resumed_flag)."""
    if not CKPT_DIR.exists():
        return 0, False
    ckpts = sorted(CKPT_DIR.glob("epoch-*.pt"),
                   key=lambda p: int(p.stem.split("-")[1]))
    if not ckpts:
        return 0, False
    latest = ckpts[-1]
    epoch = int(latest.stem.split("-")[1])
    state = torch.load(latest, map_location=device, weights_only=False)
    model.load_state_dict(state["model"])
    optimizer.load_state_dict(state["optimizer"])
    return epoch, True


def save_checkpoint(model, optimizer, epoch):
    CKPT_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CKPT_DIR / f"epoch-{epoch}.pt.tmp"
    final = CKPT_DIR / f"epoch-{epoch}.pt"
    torch.save({
        "epoch": epoch,
        "model": model.module.state_dict(),
        "optimizer": optimizer.state_dict(),
    }, tmp)
    os.replace(tmp, final)


def main():
    dist.init_process_group(backend="nccl")
    rank = dist.get_rank()
    world = dist.get_world_size()
    local_rank = int(os.environ["LOCAL_RANK"])
    torch.cuda.set_device(local_rank)
    device = torch.device(f"cuda:{local_rank}")

    if rank == 0:
        print(f"[rank 0] host={socket.gethostname()} world_size={world} "
              f"torch={torch.__version__} cuda={torch.version.cuda} "
              f"nccl={torch.cuda.nccl.version()} "
              f"gpu={torch.cuda.get_device_name(local_rank)}",
              flush=True)
    dist.barrier()

    # Dataset streamed from FSx across all ranks
    if rank == 0:
        print(f"[rank 0] loading dataset from {DATASET_PATH} ...", flush=True)
    t0 = time.time()
    ds = SyntheticDataset(DATASET_PATH)
    if rank == 0:
        print(f"[rank 0] dataset loaded: {len(ds)} samples "
              f"in {time.time() - t0:.1f}s",
              flush=True)
    dist.barrier()

    sampler = DistributedSampler(ds, num_replicas=world, rank=rank,
                                 shuffle=True, drop_last=True)
    loader = DataLoader(ds, batch_size=32, sampler=sampler,
                        num_workers=2, pin_memory=True)

    model = build_model().to(device)
    model = DDP(model, device_ids=[local_rank])
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-4)
    loss_fn = nn.MSELoss()

    # Resume support: if a checkpoint exists, pick up where we left off.
    start_epoch, resumed = maybe_load_checkpoint(model.module, optimizer, device)
    if rank == 0:
        if resumed:
            print(f"[rank 0] RESUMED from epoch {start_epoch} "
                  f"(checkpoint dir: {CKPT_DIR})",
                  flush=True)
        else:
            print(f"[rank 0] starting fresh (no checkpoint in {CKPT_DIR})",
                  flush=True)
    dist.barrier()

    total_epochs = int(os.environ.get("EPOCHS", "5"))
    if start_epoch >= total_epochs:
        if rank == 0:
            print(f"[rank 0] already trained {total_epochs} epochs. Done.",
                  flush=True)
        dist.destroy_process_group()
        return

    step_count = 0
    train_start = time.time()
    for epoch in range(start_epoch, total_epochs):
        sampler.set_epoch(epoch)
        epoch_start = time.time()
        for step, (x, y) in enumerate(loader):
            x = x.to(device, non_blocking=True)
            y = y.to(device, non_blocking=True)
            pred = model(x)
            loss = loss_fn(pred, y)
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            optimizer.step()
            step_count += 1
            if rank == 0 and step % 5 == 0:
                print(f"[rank 0] epoch {epoch} step {step} "
                      f"loss={loss.item():.4f} "
                      f"cumulative_time={time.time() - train_start:.1f}s",
                      flush=True)

        # Save checkpoint from rank 0 only. Sync all ranks first.
        dist.barrier()
        if rank == 0:
            t = time.time()
            save_checkpoint(model, optimizer, epoch + 1)
            print(f"[rank 0] epoch {epoch} took "
                  f"{time.time() - epoch_start:.1f}s, "
                  f"checkpoint saved in {time.time() - t:.2f}s",
                  flush=True)
        dist.barrier()

    if rank == 0:
        total = time.time() - train_start
        thr = step_count * 32 * world / total  # global batch size
        print(f"[rank 0] SUCCESS: {step_count} steps across "
              f"{total_epochs - start_epoch} epochs in {total:.1f}s "
              f"({thr:.1f} samples/sec across {world} GPUs)",
              flush=True)
        print(f"[rank 0] checkpoints in {CKPT_DIR}:", flush=True)
        for f in sorted(CKPT_DIR.glob("epoch-*.pt")):
            print(f"           {f.name}  ({f.stat().st_size / 1e6:.1f} MB)",
                  flush=True)

    dist.destroy_process_group()


if __name__ == "__main__":
    main()
