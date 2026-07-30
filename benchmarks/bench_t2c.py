"""T2c — Training-pipeline benchmark for storage backends.

Simulates a real training workload: PyTorch DDP with a DataLoader that streams
parquet files from the mounted backend, decodes to tensors, and feeds a small
MLP model. Reports samples/sec across all ranks.

This is more realistic than T1a/T1b because:
- Uses DataLoader with num_workers and prefetch (standard training pattern)
- Includes tensor materialization on GPU (matches actual training data flow)
- DDP gradient sync overlaps with next-batch prefetch

Bounds designed so I/O is the bottleneck, not compute:
- Small MLP (~10M params) with tiny forward+backward
- Batch size 32 per rank (16 ranks × 32 = 512 global batch)
- 100 training steps
- Fixed step count => samples/sec is comparable across backends

Env vars:
- BACKEND: label (fsx-lz, fsx-parent, s3mp-single)
- DATASET: subpath under /data (typically "openalex")
- RUNID: unique run identifier
- RESULTS_ROOT: where to write JSON result
- NUM_WORKERS: DataLoader num_workers (default 4)
- STEPS: training steps (default 100)
- BATCH_SIZE: per-rank batch size (default 32)

Output: /results/<backend>/<backend>_<dataset>_t2c_<runid>_<hostname>.json
"""
from __future__ import annotations

import io
import json
import os
import random
import socket
import time
from pathlib import Path
from typing import List

import torch
import torch.distributed as dist
import torch.nn as nn
from torch.nn.parallel import DistributedDataParallel as DDP
from torch.utils.data import DataLoader, Dataset


DATA_ROOT = Path(os.environ.get("DATA_ROOT", "/data"))
DATASET = os.environ.get("DATASET", "openalex")
DATASET_PATH = DATA_ROOT / DATASET
RESULTS_ROOT = Path(os.environ.get("RESULTS_ROOT", "/results"))
BACKEND = os.environ.get("BACKEND", "unknown")
RUNID = os.environ.get("RUNID", time.strftime("%Y%m%d-%H%M%S"))

NUM_WORKERS = int(os.environ.get("NUM_WORKERS", "4"))
PREFETCH_FACTOR = int(os.environ.get("PREFETCH_FACTOR", "2"))
STEPS = int(os.environ.get("STEPS", "100"))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "32"))
# SAMPLE_MODE = "random_partial" (default; per-sample 64KB random read within a file)
#             = "whole_file" (each sample reads a whole file sequentially; mimics WebDataset-style)
SAMPLE_MODE = os.environ.get("SAMPLE_MODE", "random_partial")
FILE_LIST_TIME_LIMIT_S = 90.0
MAX_FILES_PER_RANK = 200


def _find_files(root: Path, time_limit_s: float, max_files: int) -> List[Path]:
    """Time-bounded file enumeration for parquet files."""
    out: List[Path] = []
    t0 = time.time()
    for p in root.rglob("*.parquet"):
        if time.time() - t0 > time_limit_s:
            print(f"[t2c] file enumeration time limit reached at {len(out)} files", flush=True)
            break
        if p.is_file():
            out.append(p)
            if len(out) >= max_files:
                break
    return out


class ParquetStreamingDataset(Dataset):
    """Streams parquet files from the mounted backend.

    Two modes:
    - SAMPLE_MODE='random_partial' (default): each sample opens a file, seeks to
      a random offset, reads 64KB. Mimics per-sample random-file-access training
      pipelines. Puts open()+seek()+read() overhead on the critical path per sample.
    - SAMPLE_MODE='whole_file': each sample reads one whole file sequentially
      (up to 256MB). Mimics WebDataset/MDS-shard training pipelines. Amortizes
      open() overhead across many bytes.
    """

    def __init__(self, files: List[Path], samples_per_step: int, total_steps: int,
                 mode: str = "random_partial"):
        self.files = files
        self.mode = mode
        self.total_samples = samples_per_step * total_steps
        self.bytes_per_sample_partial = 64 * 1024        # random_partial mode
        self.max_bytes_per_whole_file = 256 * 1024 * 1024  # whole_file mode cap

    def __len__(self):
        return self.total_samples

    def _read_random_partial(self, idx: int) -> bytes:
        f = self.files[idx % len(self.files)]
        try:
            size = f.stat().st_size
            if size < self.bytes_per_sample_partial:
                offset = 0
                to_read = size
            else:
                offset = (idx * 1024) % max(1, size - self.bytes_per_sample_partial)
                to_read = self.bytes_per_sample_partial
            with open(f, "rb", buffering=0) as fp:
                fp.seek(offset)
                return fp.read(to_read)
        except OSError:
            return b"\x00" * self.bytes_per_sample_partial

    def _read_whole_file(self, idx: int) -> bytes:
        f = self.files[idx % len(self.files)]
        try:
            with open(f, "rb", buffering=0) as fp:
                # Cap max bytes to keep memory bounded
                return fp.read(self.max_bytes_per_whole_file)
        except OSError:
            return b"\x00" * self.bytes_per_sample_partial

    def __getitem__(self, idx: int):
        if self.mode == "whole_file":
            buf = self._read_whole_file(idx)
        else:
            buf = self._read_random_partial(idx)

        # Convert bytes → fixed 4096-dim fp16 tensor (pad/truncate)
        # Only use first 8KB of buffer for the tensor to keep decode uniform.
        arr = bytearray(buf[:8192].ljust(8192, b"\x00"))
        x = torch.frombuffer(bytes(arr), dtype=torch.float16).clone()  # 4096
        y = x.clone()
        return x, y


def build_model() -> nn.Module:
    # Small MLP — ~10M params. Forward+backward much faster than data load.
    return nn.Sequential(
        nn.Linear(4096, 512),
        nn.ReLU(),
        nn.Linear(512, 512),
        nn.ReLU(),
        nn.Linear(512, 4096),
    )


def _emit(metrics: dict) -> None:
    RESULTS_ROOT.mkdir(parents=True, exist_ok=True)
    result = {
        "backend": BACKEND,
        "dataset": DATASET,
        "test": "t2c",
        "runid": RUNID,
        "hostname": socket.gethostname(),
        "timestamp": time.time(),
        **metrics,
    }
    out = RESULTS_ROOT / f"{BACKEND}_{DATASET}_t2c_{RUNID}_{socket.gethostname()}.json"
    with open(out, "w") as f:
        json.dump(result, f, indent=2)
    print(f"[t2c] wrote {out}", flush=True)
    print(f"[t2c] {json.dumps(metrics)}", flush=True)


def main():
    dist.init_process_group(backend="nccl")
    rank = dist.get_rank()
    world = dist.get_world_size()
    local_rank = int(os.environ["LOCAL_RANK"])
    torch.cuda.set_device(local_rank)
    device = torch.device(f"cuda:{local_rank}")

    if rank == 0:
        print(f"[t2c] backend={BACKEND} dataset={DATASET} runid={RUNID} "
              f"world={world} num_workers={NUM_WORKERS} steps={STEPS} bs={BATCH_SIZE}",
              flush=True)
    dist.barrier()

    # Enumerate parquet files (time-bounded)
    if rank == 0:
        print(f"[t2c] enumerating parquet files in {DATASET_PATH}", flush=True)
    t0 = time.time()
    all_files = _find_files(DATASET_PATH, FILE_LIST_TIME_LIMIT_S, MAX_FILES_PER_RANK * world)
    enum_time = time.time() - t0
    if rank == 0:
        print(f"[t2c] enumerated {len(all_files)} files in {enum_time:.1f}s", flush=True)
    dist.barrier()

    if len(all_files) == 0:
        if rank == 0:
            _emit({
                "error": "no files enumerated",
                "enum_time_s": enum_time,
                "world_size": world,
                "num_workers": NUM_WORKERS,
                "prefetch_factor": PREFETCH_FACTOR,
                "sample_mode": SAMPLE_MODE,
                "steps": STEPS,
                "batch_size": BATCH_SIZE,
            })
        dist.destroy_process_group()
        return

    # Per-rank file slice
    my_files = all_files[rank::world]
    if rank == 0:
        print(f"[t2c] rank {rank} has {len(my_files)} files", flush=True)
    dist.barrier()

    dataset = ParquetStreamingDataset(
        files=my_files, samples_per_step=BATCH_SIZE, total_steps=STEPS,
        mode=SAMPLE_MODE,
    )
    loader = DataLoader(
        dataset,
        batch_size=BATCH_SIZE,
        shuffle=False,
        num_workers=NUM_WORKERS,
        pin_memory=True,
        prefetch_factor=PREFETCH_FACTOR if NUM_WORKERS > 0 else None,
        persistent_workers=NUM_WORKERS > 0,
    )

    model = build_model().to(device).to(torch.float16)
    model = DDP(model, device_ids=[local_rank])
    opt = torch.optim.AdamW(model.parameters(), lr=1e-4)
    loss_fn = nn.MSELoss()

    # Warmup — 5 steps not counted
    if rank == 0:
        print("[t2c] warmup (5 steps)", flush=True)
    warmup_steps = 5
    it = iter(loader)
    for step in range(warmup_steps):
        try:
            x, y = next(it)
        except StopIteration:
            break
        x = x.to(device, non_blocking=True)
        y = y.to(device, non_blocking=True)
        pred = model(x)
        loss = loss_fn(pred, y)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        opt.step()
    dist.barrier()

    # Measured phase
    if rank == 0:
        print(f"[t2c] measuring {STEPS} steps", flush=True)
    t_start = time.time()
    samples_processed = 0
    for step in range(STEPS):
        try:
            x, y = next(it)
        except StopIteration:
            # Refill the iterator by cycling
            it = iter(loader)
            x, y = next(it)
        x = x.to(device, non_blocking=True)
        y = y.to(device, non_blocking=True)
        pred = model(x)
        loss = loss_fn(pred, y)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        opt.step()
        samples_processed += x.shape[0]
        if rank == 0 and step % 10 == 0:
            elapsed = time.time() - t_start
            print(f"[t2c] step {step}/{STEPS} loss={loss.item():.4f} "
                  f"elapsed={elapsed:.1f}s cum_samples_per_rank={samples_processed}",
                  flush=True)

    torch.cuda.synchronize()
    dist.barrier()
    elapsed = time.time() - t_start

    # Global stats
    local_samples = torch.tensor([samples_processed], dtype=torch.long, device=device)
    global_samples = torch.zeros_like(local_samples)
    dist.all_reduce(local_samples, op=dist.ReduceOp.SUM)
    total_samples = local_samples.item()

    if rank == 0:
        samples_per_sec_aggregate = total_samples / elapsed
        samples_per_sec_per_rank = samples_processed / elapsed
        bytes_per_sample_used = (
            dataset.max_bytes_per_whole_file if SAMPLE_MODE == "whole_file"
            else dataset.bytes_per_sample_partial
        )
        _emit({
            "world_size": world,
            "num_workers": NUM_WORKERS,
            "prefetch_factor": PREFETCH_FACTOR,
            "sample_mode": SAMPLE_MODE,
            "steps": STEPS,
            "batch_size": BATCH_SIZE,
            "elapsed_sec": elapsed,
            "enum_time_s": enum_time,
            "files_enumerated": len(all_files),
            "total_samples": total_samples,
            "samples_per_sec_aggregate": samples_per_sec_aggregate,
            "samples_per_sec_per_rank": samples_per_sec_per_rank,
            "bytes_per_sample_ceiling": bytes_per_sample_used,
        })

    dist.destroy_process_group()


if __name__ == "__main__":
    main()
