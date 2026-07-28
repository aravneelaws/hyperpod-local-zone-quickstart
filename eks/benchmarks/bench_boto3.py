#!/usr/bin/env python3
"""
T2c-boto3: training-pipeline benchmark using boto3 direct S3 range-GETs.

Same conceptual workload as bench_t2c.py (per-sample partial reads across a
set of parquet files), but bypasses the S3 Mountpoint FUSE layer entirely
and issues concurrent range-GET requests directly against the S3 API.

The point: measure the ceiling of "S3-native training pipeline" access,
where per-sample concurrency happens via threaded/async boto3 calls rather
than DataLoader-worker parallelism.

Environment:
  S3_BUCKET            (required) e.g. hp-eks-lz-s3mp-bench-<ACCOUNT>-<REGION>
  S3_PREFIX            (required) e.g. openalex/
  BACKEND              (default 'boto3') label for output filename
  DATASET              (default 'openalex') label
  RESULTS_ROOT         (default /results) mount point for JSON output
  NUM_WORKERS          (default 4) DataLoader worker processes per rank
  THREADS_PER_WORKER   (default 8) boto3 concurrent range-GETs per worker
  STEPS                (default 100) measured steps
  BATCH_SIZE           (default 32) samples per step per rank
  BYTES_PER_SAMPLE     (default 65536) size of each range-GET (matches T2c)
  RUNID                (default now)
  DDP-related env from torchrun: WORLD_SIZE, RANK, MASTER_ADDR, MASTER_PORT

The IRSA role backing this benchmark must have s3:GetObject and s3:ListBucket
on the target bucket. Auth is via IRSA token; boto3 picks it up automatically
from the standard env vars set by the EKS Pod Identity Webhook.
"""
import concurrent.futures
import json
import os
import random
import socket
import time
from pathlib import Path
from typing import List, Tuple

import boto3
from botocore.config import Config as BotoConfig
import torch
import torch.distributed as dist
import torch.nn as nn
from torch.utils.data import DataLoader, Dataset


# ─────────────── configuration ───────────────
S3_BUCKET = os.environ.get("S3_BUCKET", "")
S3_PREFIX = os.environ.get("S3_PREFIX", "")
BACKEND = os.environ.get("BACKEND", "boto3")
DATASET = os.environ.get("DATASET", "openalex")
RESULTS_ROOT = Path(os.environ.get("RESULTS_ROOT", "/results"))
RUNID = os.environ.get("RUNID", time.strftime("%Y%m%d-%H%M%S"))

NUM_WORKERS = int(os.environ.get("NUM_WORKERS", "4"))
THREADS_PER_WORKER = int(os.environ.get("THREADS_PER_WORKER", "8"))
PREFETCH_FACTOR = int(os.environ.get("PREFETCH_FACTOR", "2"))
STEPS = int(os.environ.get("STEPS", "100"))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "32"))
BYTES_PER_SAMPLE = int(os.environ.get("BYTES_PER_SAMPLE", str(64 * 1024)))
# SAMPLE_MODE = "random_partial" (default) → each sample is a 64KB range-GET
#                                             at a pseudorandom offset in a
#                                             chosen key. Mimics per-sample
#                                             random access on large files.
#             = "whole_file"                → each sample is a full GetObject
#                                             (no Range). Mimics per-sample
#                                             whole-small-file access.
#             = "bundle"                    → each sample is N GetObjects for
#                                             all files under one protein/
#                                             prefix. Mimics realistic
#                                             per-sample workloads that
#                                             materialize multiple files per
#                                             training example (e.g.
#                                             AlphaFold or similar structure-
#                                             prediction pipelines: MSA +
#                                             templates + structure per
#                                             sample).
SAMPLE_MODE = os.environ.get("SAMPLE_MODE", "random_partial")
# For whole_file mode, the min key size for inclusion.
MIN_KEY_SIZE = int(os.environ.get("MIN_KEY_SIZE", "1024"))
MAX_KEYS = int(os.environ.get("MAX_KEYS", "5000"))
# Bundle mode: group keys by the Nth path segment beneath S3_PREFIX.
# For openfold-pdb prefix "openfold-pdb/", the first segment beneath is the
# protein id (e.g. "101m_A"). BUNDLE_GROUP_DEPTH=1 means grouping key =
# first segment after prefix.
BUNDLE_GROUP_DEPTH = int(os.environ.get("BUNDLE_GROUP_DEPTH", "1"))
# Max files fetched per bundle (safety cap for outliers).
MAX_FILES_PER_BUNDLE = int(os.environ.get("MAX_FILES_PER_BUNDLE", "20"))

# Boto3 client config: pool size must accommodate concurrent threads per worker.
BOTO_CONFIG = BotoConfig(
    max_pool_connections=max(50, THREADS_PER_WORKER * 4),
    retries={"max_attempts": 3, "mode": "standard"},
    connect_timeout=10,
    read_timeout=30,
)


def _emit(payload: dict) -> None:
    RESULTS_ROOT.mkdir(parents=True, exist_ok=True)
    host = socket.gethostname()
    out = RESULTS_ROOT / f"{BACKEND}_{DATASET}_t2c-boto3_{RUNID}_{host}.json"
    with open(out, "w") as f:
        json.dump(payload, f, indent=2)
    print(f"[t2c-boto3] wrote {out}", flush=True)
    print(f"[t2c-boto3] {json.dumps(payload)}", flush=True)


def _list_keys(s3, bucket: str, prefix: str, max_keys: int, time_limit_s: float = 90.0) -> List[Tuple[str, int]]:
    """List up to max_keys S3 keys with the given prefix, bounded by time.

    Returns list of (key, size) tuples.
    """
    keys = []
    paginator = s3.get_paginator("list_objects_v2")
    t0 = time.time()
    # min-size filter: for random_partial we need file >= BYTES_PER_SAMPLE;
    # for whole_file we accept files >= MIN_KEY_SIZE; for bundle we accept all.
    if SAMPLE_MODE == "random_partial":
        min_size = BYTES_PER_SAMPLE
    elif SAMPLE_MODE == "whole_file":
        min_size = MIN_KEY_SIZE
    else:  # bundle
        min_size = 0
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        if time.time() - t0 > time_limit_s:
            print(f"[t2c-boto3] key listing time limit reached at {len(keys)} keys", flush=True)
            break
        for obj in page.get("Contents", []):
            if obj["Size"] < min_size:
                continue
            keys.append((obj["Key"], obj["Size"]))
            if len(keys) >= max_keys:
                break
        if len(keys) >= max_keys:
            break
    return keys


def _build_bundles(keys: List[Tuple[str, int]], prefix: str, group_depth: int, max_files: int) -> List[List[Tuple[str, int]]]:
    """Group keys into bundles by the first `group_depth` path segments beneath `prefix`.

    Example: prefix="openfold-pdb/", group_depth=1, key="openfold-pdb/101m_A/a3m/hits.a3m"
    → group_id="101m_A"

    Returns list of bundles, each bundle is a list of (key, size) tuples,
    capped at max_files entries per bundle.
    """
    prefix_stripped = prefix.rstrip("/")
    groups: dict[str, List[Tuple[str, int]]] = {}
    for k, sz in keys:
        # Strip prefix, split, take first `group_depth` segments as group id
        rel = k[len(prefix_stripped):].lstrip("/")
        parts = rel.split("/")
        if len(parts) < group_depth + 1:
            continue  # not enough depth (would be top-level file, no bundle)
        gid = "/".join(parts[:group_depth])
        groups.setdefault(gid, []).append((k, sz))
    # Cap per-bundle file count, drop empty
    bundles = []
    for gid, items in groups.items():
        if not items:
            continue
        bundles.append(items[:max_files])
    return bundles


# ─────────────── worker-side globals ───────────────
# Each DataLoader worker process gets its own boto3 client + thread pool.
# Because torch.utils.data workers are subprocesses, module-level state
# is not shared — each worker builds its own on first __getitem__.
_worker_state = {"s3": None, "pool": None}


def _worker_init():
    """Called by each DataLoader worker process at start."""
    session = boto3.session.Session()
    _worker_state["s3"] = session.client("s3", config=BOTO_CONFIG)
    _worker_state["pool"] = concurrent.futures.ThreadPoolExecutor(
        max_workers=THREADS_PER_WORKER
    )


def _get_range(bucket: str, key: str, offset: int, length: int) -> bytes:
    """Single S3 range-GET; runs in the worker thread pool."""
    s3 = _worker_state["s3"]
    resp = s3.get_object(
        Bucket=bucket, Key=key, Range=f"bytes={offset}-{offset + length - 1}"
    )
    return resp["Body"].read()


def _get_whole(bucket: str, key: str) -> bytes:
    """Full-object GET (no Range); runs in the worker thread pool."""
    s3 = _worker_state["s3"]
    resp = s3.get_object(Bucket=bucket, Key=key)
    return resp["Body"].read()


class S3RangeGetDataset(Dataset):
    """Dataset that issues per-sample S3 GetObject calls.

    Three modes controlled by SAMPLE_MODE:
    - random_partial: __getitem__ does 1 range-GET (64KB) on a chosen key
    - whole_file:     __getitem__ does 1 whole GetObject on a chosen key
    - bundle:         __getitem__ does N GetObjects for all files in one
                      bundle (grouped by prefix path segment). Uses the
                      worker's thread pool to fetch the N files concurrently
                      within a single sample.

    Concurrency:
    1. DataLoader worker processes (NUM_WORKERS)
    2. Within each worker, ThreadPoolExecutor (THREADS_PER_WORKER) used both
       for per-batch parallelism (via __getitems__) and for per-sample
       parallelism (bundle mode fans out N files per sample).
    """

    def __init__(self, samples_per_step: int, total_steps: int,
                 keys: List[Tuple[str, int]] = None,
                 bundles: List[List[Tuple[str, int]]] = None):
        self.keys = keys or []
        self.bundles = bundles or []
        self.total_samples = samples_per_step * total_steps
        # For bundle mode: precompute mean bytes-per-sample for MB/s reporting
        if bundles:
            self.bundle_mean_bytes = (
                sum(sum(sz for _, sz in b) for b in bundles) / max(1, len(bundles))
            )
            self.bundle_mean_files = (
                sum(len(b) for b in bundles) / max(1, len(bundles))
            )
        else:
            self.bundle_mean_bytes = 0
            self.bundle_mean_files = 0

    def __len__(self):
        return self.total_samples

    def _fetch(self, idx: int) -> Tuple[bytes, int]:
        """Returns (data, actual_bytes_fetched)."""
        if SAMPLE_MODE == "bundle":
            bundle = self.bundles[idx % len(self.bundles)]
            pool = _worker_state["pool"]
            try:
                if pool is not None and len(bundle) > 1:
                    # Fetch all N files in the bundle concurrently.
                    futures = [pool.submit(_get_whole, S3_BUCKET, key)
                               for key, _ in bundle]
                    bufs = [f.result() for f in futures]
                else:
                    bufs = [_get_whole(S3_BUCKET, key) for key, _ in bundle]
                combined = b"".join(bufs)
                return combined, len(combined)
            except Exception as e:
                if idx % 100 == 0:
                    print(f"[t2c-boto3] bundle fetch error idx={idx}: {e}", flush=True)
                return b"\x00" * 8192, 0
        elif SAMPLE_MODE == "whole_file":
            key, size = self.keys[idx % len(self.keys)]
            try:
                buf = _get_whole(S3_BUCKET, key)
                return buf, len(buf)
            except Exception as e:
                if idx % 100 == 0:
                    print(f"[t2c-boto3] fetch error idx={idx} key={key}: {e}", flush=True)
                return b"\x00" * BYTES_PER_SAMPLE, 0
        else:  # random_partial
            key, size = self.keys[idx % len(self.keys)]
            try:
                max_offset = max(0, size - BYTES_PER_SAMPLE)
                offset = (idx * 1024) % max(1, max_offset) if max_offset > 0 else 0
                to_read = min(BYTES_PER_SAMPLE, size)
                buf = _get_range(S3_BUCKET, key, offset, to_read)
                return buf, len(buf)
            except Exception as e:
                if idx % 100 == 0:
                    print(f"[t2c-boto3] fetch error idx={idx} key={key}: {e}", flush=True)
                return b"\x00" * BYTES_PER_SAMPLE, 0

    def _to_tensor(self, buf: bytes):
        arr = bytearray(buf[:8192].ljust(8192, b"\x00"))
        x = torch.frombuffer(bytes(arr), dtype=torch.float16).clone()
        y = x.clone()
        return x, y

    def __getitem__(self, idx: int):
        buf, _ = self._fetch(idx)
        return self._to_tensor(buf)

    def __getitems__(self, indices: List[int]) -> List[Tuple[torch.Tensor, torch.Tensor]]:
        """Batched fetch — DataLoader calls this if defined.

        For random_partial/whole_file: fetches all samples in the batch
        concurrently via the worker's thread pool.

        For bundle mode: still batches, but each sample internally already
        parallelizes its N-file fetch, so batch-level parallelism competes
        with within-sample parallelism for the same thread pool. This is
        intentional — real training code has this same tension.
        """
        pool = _worker_state["pool"]
        if pool is None:
            results = [self._fetch(i) for i in indices]
        elif SAMPLE_MODE == "bundle":
            # Bundle mode: don't fan-out at the batch level too, since each
            # sample already uses the pool. Sequential loop over samples.
            results = [self._fetch(i) for i in indices]
        else:
            futures = [pool.submit(self._fetch, i) for i in indices]
            results = [f.result() for f in futures]
        return [self._to_tensor(b) for b, _ in results]


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
        raise SystemExit("S3_BUCKET and S3_PREFIX env vars are required")

    # DDP init
    dist.init_process_group(backend="nccl")
    rank = dist.get_rank()
    world = dist.get_world_size()
    local_rank = int(os.environ.get("LOCAL_RANK", "0"))
    device = torch.device(f"cuda:{local_rank}")
    torch.cuda.set_device(device)

    if rank == 0:
        print(f"[t2c-boto3] world={world} bucket={S3_BUCKET} prefix={S3_PREFIX}", flush=True)
        print(f"[t2c-boto3] NUM_WORKERS={NUM_WORKERS} THREADS_PER_WORKER={THREADS_PER_WORKER} "
              f"STEPS={STEPS} BATCH_SIZE={BATCH_SIZE} BYTES_PER_SAMPLE={BYTES_PER_SAMPLE}", flush=True)

    # List keys once
    s3 = boto3.client("s3", config=BOTO_CONFIG)
    t0 = time.time()
    all_keys = _list_keys(s3, S3_BUCKET, S3_PREFIX, max_keys=MAX_KEYS)
    enum_time = time.time() - t0
    if rank == 0:
        print(f"[t2c-boto3] enumerated {len(all_keys)} keys in {enum_time:.1f}s", flush=True)

    all_bundles = []
    if SAMPLE_MODE == "bundle":
        all_bundles = _build_bundles(all_keys, S3_PREFIX, BUNDLE_GROUP_DEPTH, MAX_FILES_PER_BUNDLE)
        if rank == 0:
            if all_bundles:
                mean_files = sum(len(b) for b in all_bundles) / len(all_bundles)
                mean_bytes = sum(sum(sz for _, sz in b) for b in all_bundles) / len(all_bundles)
                print(f"[t2c-boto3] built {len(all_bundles)} bundles, "
                      f"mean {mean_files:.1f} files/bundle, "
                      f"mean {mean_bytes/1024:.1f} KB/bundle", flush=True)
            else:
                print(f"[t2c-boto3] ERROR: 0 bundles built. Check BUNDLE_GROUP_DEPTH and prefix.", flush=True)

        # Rank-shard bundles
        my_bundles = [b for i, b in enumerate(all_bundles) if i % world == rank]
        random.seed(42 + rank)
        random.shuffle(my_bundles)

        if len(my_bundles) == 0:
            if rank == 0:
                _emit({"error": "no bundles after sharding",
                       "world_size": world, "enum_time_s": enum_time,
                       "keys_enumerated": len(all_keys),
                       "bundles_built": len(all_bundles)})
            dist.destroy_process_group()
            return

        dataset = S3RangeGetDataset(
            samples_per_step=BATCH_SIZE, total_steps=STEPS,
            bundles=my_bundles,
        )
    else:
        # Rank-shard the key list
        my_keys = [k for i, k in enumerate(all_keys) if i % world == rank]
        random.seed(42 + rank)
        random.shuffle(my_keys)

        if len(my_keys) == 0:
            if rank == 0:
                _emit({"error": "no keys enumerated after sharding",
                       "world_size": world, "enum_time_s": enum_time})
            dist.destroy_process_group()
            return

        dataset = S3RangeGetDataset(
            samples_per_step=BATCH_SIZE, total_steps=STEPS,
            keys=my_keys,
        )
    loader = DataLoader(
        dataset,
        batch_size=BATCH_SIZE,
        shuffle=False,
        num_workers=NUM_WORKERS,
        pin_memory=True,
        prefetch_factor=PREFETCH_FACTOR if NUM_WORKERS > 0 else None,
        persistent_workers=NUM_WORKERS > 0,
        worker_init_fn=lambda _wid: _worker_init(),
    )

    # If NUM_WORKERS=0 we run in-process; init here so the main proc can fetch.
    if NUM_WORKERS == 0:
        _worker_init()

    model = TinyMLP(dim=4096, hidden=512).to(device)
    model = nn.parallel.DistributedDataParallel(model, device_ids=[local_rank])
    optimizer = torch.optim.SGD(model.parameters(), lr=0.001)
    loss_fn = nn.MSELoss()

    if rank == 0:
        print(f"[t2c-boto3] warmup 5 steps", flush=True)
    warmup_steps = 0
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
            warmup_steps += 1
        except StopIteration:
            break
    dist.barrier()

    if rank == 0:
        print(f"[t2c-boto3] measuring {STEPS} steps", flush=True)
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
            elapsed = time.time() - t_start
            print(f"[t2c-boto3] step {step}/{STEPS} loss={loss.item():.4f} "
                  f"elapsed={elapsed:.1f}s cum_samples_per_rank={samples_processed}",
                  flush=True)

    torch.cuda.synchronize(device)
    dist.barrier()
    elapsed = time.time() - t_start
    total_samples = samples_processed * world

    if rank == 0:
        samples_per_sec_aggregate = total_samples / elapsed
        samples_per_sec_per_rank = samples_processed / elapsed
        # Effective bytes/sample:
        # - random_partial: exactly BYTES_PER_SAMPLE
        # - whole_file:     mean key size (varies per key, use dataset avg)
        # - bundle:         mean total bytes across all files in a bundle
        if SAMPLE_MODE == "whole_file":
            mean_key_size = sum(s for _, s in all_keys) / max(1, len(all_keys))
            effective_bytes_per_sample = mean_key_size
        elif SAMPLE_MODE == "bundle":
            effective_bytes_per_sample = dataset.bundle_mean_bytes
        else:
            effective_bytes_per_sample = BYTES_PER_SAMPLE
        payload = {
            "world_size": world,
            "sample_mode": SAMPLE_MODE,
            "num_workers": NUM_WORKERS,
            "threads_per_worker": THREADS_PER_WORKER,
            "prefetch_factor": PREFETCH_FACTOR,
            "steps": STEPS,
            "batch_size": BATCH_SIZE,
            "bytes_per_sample_target": BYTES_PER_SAMPLE,
            "effective_bytes_per_sample": effective_bytes_per_sample,
            "elapsed_sec": elapsed,
            "enum_time_s": enum_time,
            "keys_enumerated": len(all_keys),
            "total_samples": total_samples,
            "samples_per_sec_aggregate": samples_per_sec_aggregate,
            "samples_per_sec_per_rank": samples_per_sec_per_rank,
            "aggregate_MBps": total_samples * effective_bytes_per_sample / elapsed / 1e6,
        }
        if SAMPLE_MODE == "bundle":
            payload["bundles_built"] = len(all_bundles)
            payload["bundle_mean_files"] = dataset.bundle_mean_files
        _emit(payload)

    dist.destroy_process_group()


if __name__ == "__main__":
    main()
