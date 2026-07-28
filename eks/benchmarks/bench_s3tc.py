#!/usr/bin/env python3
"""
T2c-s3torchconnector: training-pipeline benchmark using AWS's official
s3torchconnector library.

Same workload as bench_boto3.py bundle mode, but uses S3IterableDataset
and S3MapDataset from s3torchconnector. This is the library we'd
recommend to customers as the idiomatic PyTorch path for S3 training.

Under the hood, s3torchconnector uses the Mountpoint-S3 Rust client
(via PyO3 bindings). No FUSE — direct library calls. So we expect
throughput comparable to or better than raw boto3 with threaded
concurrency.

Environment:
  S3_BUCKET            (required)
  S3_PREFIX            (required)
  BACKEND              (default 's3torchconnector')
  DATASET              (default 'openfold-pdb')
  RESULTS_ROOT         (default /results)
  NUM_WORKERS          (default 8) DataLoader worker processes per rank
  PREFETCH_FACTOR      (default 2)
  STEPS                (default 100)
  BATCH_SIZE           (default 32)
  RUNID                (default now)
  DDP env: WORLD_SIZE, RANK, MASTER_ADDR, MASTER_PORT
"""
import json
import os
import random
import socket
import time
from pathlib import Path
from typing import List, Tuple

import torch
import torch.distributed as dist
import torch.nn as nn
from torch.utils.data import DataLoader, Dataset

from s3torchconnector import S3ClientConfig, S3MapDataset, S3Reader


# ─────────────── config ───────────────
S3_BUCKET = os.environ.get("S3_BUCKET", "")
S3_PREFIX = os.environ.get("S3_PREFIX", "")
BACKEND = os.environ.get("BACKEND", "s3torchconnector")
DATASET = os.environ.get("DATASET", "openfold-pdb")
RESULTS_ROOT = Path(os.environ.get("RESULTS_ROOT", "/results"))
RUNID = os.environ.get("RUNID", time.strftime("%Y%m%d-%H%M%S"))
REGION = os.environ.get("AWS_DEFAULT_REGION", "us-west-2")

NUM_WORKERS = int(os.environ.get("NUM_WORKERS", "8"))
PREFETCH_FACTOR = int(os.environ.get("PREFETCH_FACTOR", "2"))
STEPS = int(os.environ.get("STEPS", "100"))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "32"))
MAX_KEYS = int(os.environ.get("MAX_KEYS", "15000"))
BUNDLE_GROUP_DEPTH = int(os.environ.get("BUNDLE_GROUP_DEPTH", "1"))
MAX_FILES_PER_BUNDLE = int(os.environ.get("MAX_FILES_PER_BUNDLE", "20"))


def _emit(payload: dict) -> None:
    RESULTS_ROOT.mkdir(parents=True, exist_ok=True)
    host = socket.gethostname()
    out = RESULTS_ROOT / f"{BACKEND}_{DATASET}_t2c-s3tc_{RUNID}_{host}.json"
    with open(out, "w") as f:
        json.dump(payload, f, indent=2)
    print(f"[t2c-s3tc] wrote {out}", flush=True)
    print(f"[t2c-s3tc] {json.dumps(payload)}", flush=True)


class BundleDataset(Dataset):
    """
    Bundle-per-sample dataset built on top of s3torchconnector's S3MapDataset.

    Each sample = one protein bundle = all files under one protein_id/ prefix.
    Uses s3torchconnector's internal client for the actual GETs; we just
    fetch the N keys in a bundle sequentially per sample. The library's
    per-object throughput is high enough that sequential fan-out per sample
    is usually good — no thread pool needed at the Python level.
    """

    def __init__(self, s3_dataset: S3MapDataset, bundles: List[List[int]],
                 samples_per_step: int, total_steps: int, bundle_mean_bytes: float):
        self.s3_dataset = s3_dataset
        self.bundles = bundles  # list of lists of indices into s3_dataset
        self.total_samples = samples_per_step * total_steps
        self.bundle_mean_bytes = bundle_mean_bytes
        self.bundle_mean_files = sum(len(b) for b in bundles) / max(1, len(bundles))

    def __len__(self):
        return self.total_samples

    def _fetch_bundle(self, bundle_idx: int) -> bytes:
        bundle = self.bundles[bundle_idx % len(self.bundles)]
        chunks = []
        for key_idx in bundle:
            reader: S3Reader = self.s3_dataset[key_idx]
            chunks.append(reader.read())
        return b"".join(chunks)

    def __getitem__(self, idx: int):
        buf = self._fetch_bundle(idx)
        arr = bytearray(buf[:8192].ljust(8192, b"\x00"))
        x = torch.frombuffer(bytes(arr), dtype=torch.float16).clone()
        y = x.clone()
        return x, y


class TinyMLP(nn.Module):
    def __init__(self, dim: int = 4096, hidden: int = 512):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(dim, hidden),
            nn.ReLU(),
            nn.Linear(hidden, hidden),
            nn.ReLU(),
            nn.Linear(hidden, dim),
        )

    def forward(self, x):
        return self.net(x.float()).half()


def main():
    if not S3_BUCKET or not S3_PREFIX:
        raise SystemExit("S3_BUCKET and S3_PREFIX required")

    dist.init_process_group(backend="nccl")
    rank = dist.get_rank()
    world = dist.get_world_size()
    local_rank = int(os.environ.get("LOCAL_RANK", "0"))
    device = torch.device(f"cuda:{local_rank}")
    torch.cuda.set_device(device)

    if rank == 0:
        print(f"[t2c-s3tc] world={world} bucket={S3_BUCKET} prefix={S3_PREFIX}", flush=True)
        print(f"[t2c-s3tc] NUM_WORKERS={NUM_WORKERS} PREFETCH_FACTOR={PREFETCH_FACTOR} "
              f"STEPS={STEPS} BATCH_SIZE={BATCH_SIZE}", flush=True)

    t0 = time.time()
    s3_uri = f"s3://{S3_BUCKET}/{S3_PREFIX}"
    # S3MapDataset enumerates all keys under the prefix at construction time
    # and gives you a __getitem__(int) -> S3Reader interface.
    s3_dataset = S3MapDataset.from_prefix(
        s3_uri=s3_uri,
        region=REGION,
    )
    # Build (key, size, s3_index) list by iterating through the dataset objects
    # Note: s3_dataset supports len() and __getitem__, but doesn't expose the
    # raw key list directly. We can access .bucket_key_data or _get_object() ...
    # simpler: iterate and index.
    if rank == 0:
        print(f"[t2c-s3tc] S3MapDataset built, {len(s3_dataset)} keys", flush=True)

    # Get all (key, size) via probing the dataset. We need the key names to
    # bundle them. s3torchconnector exposes .bucket and per-item key via
    # S3Reader.key when you access the item. But we don't want to fetch all
    # objects just to get keys — that would download the entire dataset.
    #
    # Workaround: use boto3 to list keys, then map them to s3_dataset indices
    # by ORDER (s3torchconnector lists in lexical order by default).
    import boto3
    s3client = boto3.client("s3", region_name=REGION)
    paginator = s3client.get_paginator("list_objects_v2")
    all_keys: List[Tuple[str, int]] = []
    t_enum = time.time()
    for page in paginator.paginate(Bucket=S3_BUCKET, Prefix=S3_PREFIX):
        if time.time() - t_enum > 90:
            break
        for obj in page.get("Contents", []):
            all_keys.append((obj["Key"], obj["Size"]))
            if len(all_keys) >= MAX_KEYS:
                break
        if len(all_keys) >= MAX_KEYS:
            break
    enum_time = time.time() - t0
    if rank == 0:
        print(f"[t2c-s3tc] listed {len(all_keys)} keys in {enum_time:.1f}s", flush=True)

    # Build bundles by grouping keys under first path segment after prefix
    prefix_stripped = S3_PREFIX.rstrip("/")
    key_to_index = {k: i for i, (k, _) in enumerate(all_keys)}
    groups: dict = {}
    for i, (k, sz) in enumerate(all_keys):
        rel = k[len(prefix_stripped):].lstrip("/")
        parts = rel.split("/")
        if len(parts) < BUNDLE_GROUP_DEPTH + 1:
            continue
        gid = "/".join(parts[:BUNDLE_GROUP_DEPTH])
        groups.setdefault(gid, []).append((i, k, sz))
    bundles = []
    for gid, items in groups.items():
        if not items:
            continue
        items = items[:MAX_FILES_PER_BUNDLE]
        # bundle is list of INDICES into all_keys (which correspond 1:1 with
        # S3MapDataset indices assuming same lexical ordering)
        bundles.append([i for i, _, _ in items])
    mean_bytes = sum(sum(sz for _, sz in [(all_keys[i][0], all_keys[i][1]) for i in b])
                     for b in bundles) / max(1, len(bundles))
    if rank == 0:
        print(f"[t2c-s3tc] built {len(bundles)} bundles, mean bytes={mean_bytes/1024:.1f} KB", flush=True)

    # Rank-shard bundles
    my_bundles = [b for i, b in enumerate(bundles) if i % world == rank]
    random.seed(42 + rank)
    random.shuffle(my_bundles)

    if len(my_bundles) == 0:
        if rank == 0:
            _emit({"error": "no bundles after sharding",
                   "world_size": world, "enum_time_s": enum_time})
        dist.destroy_process_group()
        return

    dataset = BundleDataset(
        s3_dataset=s3_dataset, bundles=my_bundles,
        samples_per_step=BATCH_SIZE, total_steps=STEPS,
        bundle_mean_bytes=mean_bytes,
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

    model = TinyMLP(dim=4096, hidden=512).to(device)
    model = nn.parallel.DistributedDataParallel(model, device_ids=[local_rank])
    optimizer = torch.optim.SGD(model.parameters(), lr=0.001)
    loss_fn = nn.MSELoss()

    if rank == 0:
        print(f"[t2c-s3tc] warmup 5 steps", flush=True)
    it = iter(loader)
    for _ in range(5):
        try:
            x, y = next(it)
            x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            out = model(x)
            loss = loss_fn(out, y)
            loss.backward()
            optimizer.step()
        except StopIteration:
            break
    dist.barrier()

    if rank == 0:
        print(f"[t2c-s3tc] measuring {STEPS} steps", flush=True)
    torch.cuda.synchronize(device)
    dist.barrier()
    t_start = time.time()
    samples_processed = 0
    for step in range(STEPS):
        try:
            x, y = next(it)
        except StopIteration:
            it = iter(loader)
            x, y = next(it)
        x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
        optimizer.zero_grad(set_to_none=True)
        out = model(x)
        loss = loss_fn(out, y)
        loss.backward()
        optimizer.step()
        samples_processed += x.size(0)
        if rank == 0 and step % 10 == 0:
            print(f"[t2c-s3tc] step {step}/{STEPS} elapsed={time.time()-t_start:.1f}s "
                  f"cum_samples_per_rank={samples_processed}", flush=True)

    torch.cuda.synchronize(device)
    dist.barrier()
    elapsed = time.time() - t_start
    total_samples = samples_processed * world

    if rank == 0:
        _emit({
            "world_size": world,
            "library": "s3torchconnector",
            "sample_mode": "bundle",
            "num_workers": NUM_WORKERS,
            "prefetch_factor": PREFETCH_FACTOR,
            "steps": STEPS,
            "batch_size": BATCH_SIZE,
            "elapsed_sec": elapsed,
            "enum_time_s": enum_time,
            "keys_enumerated": len(all_keys),
            "bundles_built": len(bundles),
            "bundle_mean_files": dataset.bundle_mean_files,
            "effective_bytes_per_sample": mean_bytes,
            "total_samples": total_samples,
            "samples_per_sec_aggregate": total_samples / elapsed,
            "samples_per_sec_per_rank": samples_processed / elapsed,
            "aggregate_MBps": total_samples * mean_bytes / elapsed / 1e6,
        })

    dist.destroy_process_group()


if __name__ == "__main__":
    main()
