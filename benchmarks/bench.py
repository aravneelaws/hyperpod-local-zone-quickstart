"""Storage backend benchmarks for HyperPod EKS in AWS Local Zone.

Runs a suite of benchmarks against a mounted storage backend (FSx or S3 Mountpoint)
and emits structured JSON results.

The pod mounts exactly one backend at /data and one shared /results volume
where JSON results go. Which benchmarks to run is controlled by the BENCH env var
(comma-separated: t1a,t1b,t1c,t2a,t2b,t2c). The DATASET env var picks the dataset
subpath (openalex or openfold-pdb). BACKEND env var is a label for the results.

Individual benchmarks:
    t1a - Single-pod sustained sequential read of a 4 GiB shard via DataLoader
          num_workers=4. Reports MB/s.
    t1b - Distributed read: N ranks each read a distinct slice of the dataset.
          Reports per-rank and aggregate MB/s. Run once with N=1 rank per pod
          launched across all 16 GPUs via PyTorchJob.
    t1c - Single-stream 5 GiB write from rank 0. Reports MB/s and wall-clock.
    t2a - Small-file metadata: stat() 10k files, ls -R the dataset root.
          Reports ops/sec and total wall-clock.
    t2b - Sharded checkpoint write via torch.distributed.checkpoint from all 16
          ranks concurrently. Reports aggregate MB/s.
    t2c - End-to-end DDP training: 440M-param MLP, 5 epochs, checkpoint per epoch
          to /data/ckpt-<runid>/. Reports samples/sec.

Each benchmark writes a JSON blob to /results/<backend>_<dataset>_<test>_<runid>.json:
    {"backend": "fsx-lz", "dataset": "openfold-pdb", "test": "t1a", ...metrics...}
"""
from __future__ import annotations

import json
import os
import random
import socket
import statistics
import sys
import time
from pathlib import Path
from typing import Callable

# Config from env
DATA_ROOT = Path(os.environ.get("DATA_ROOT", "/data"))
RESULTS_ROOT = Path(os.environ.get("RESULTS_ROOT", "/results"))
BACKEND = os.environ.get("BACKEND", "unknown")
DATASET = os.environ.get("DATASET", "unknown")
RUNID = os.environ.get("RUNID", time.strftime("%Y%m%d-%H%M%S"))
BENCH_LIST = os.environ.get("BENCH", "t1a,t1c,t2a").split(",")

RESULTS_ROOT.mkdir(parents=True, exist_ok=True)
DATASET_PATH = DATA_ROOT / DATASET  # e.g., /data/openfold-pdb


def _emit(test: str, metrics: dict) -> None:
    """Write one JSON result file per test."""
    result = {
        "backend": BACKEND,
        "dataset": DATASET,
        "test": test,
        "runid": RUNID,
        "hostname": socket.gethostname(),
        "timestamp": time.time(),
        **metrics,
    }
    out = RESULTS_ROOT / f"{BACKEND}_{DATASET}_{test}_{RUNID}_{socket.gethostname()}.json"
    with open(out, "w") as f:
        json.dump(result, f, indent=2)
    print(f"[{test}] wrote {out}", flush=True)
    print(f"[{test}] {json.dumps(metrics)}", flush=True)


def _list_files(root: Path, min_size: int = 0, max_files: int = 5000, time_limit_sec: float = 60.0) -> list[Path]:
    """List files under root with size >= min_size, up to max_files or time_limit_sec.

    Bounded by both count and time. On lazy-hydrated backends (FSx with DRA to
    S3), a full walk can take hours because each stat triggers an S3 fetch. So
    we cap walk duration.
    """
    out = []
    t0 = time.time()
    for p in root.rglob("*"):
        if time.time() - t0 > time_limit_sec:
            print(f"[_list_files] time limit reached ({time_limit_sec}s); returning {len(out)} files scanned so far", flush=True)
            break
        if not p.is_file():
            continue
        try:
            if p.stat().st_size >= min_size:
                out.append(p)
                if len(out) >= max_files:
                    break
        except OSError:
            continue
    return out


# ---------- T1a: single-pod sustained read ----------
def t1a_single_pod_read() -> None:
    """Read a large single file sequentially. Fall back to combining many files if none is large enough."""
    target_bytes = 4 * 1024 * 1024 * 1024  # 4 GiB

    print(f"[t1a] scanning {DATASET_PATH} for a large file (>= 512 MiB)...", flush=True)
    # Bounded scan: give up after 30s if no large file found — most likely the
    # dataset is small-file-only. We'll fall back to many-small-files read.
    large_files = _list_files(DATASET_PATH, min_size=512 * 1024 * 1024, max_files=10, time_limit_sec=30.0)

    if large_files:
        # Use the largest single file to hit the target
        largest = max(large_files, key=lambda p: p.stat().st_size)
        print(f"[t1a] reading {largest} ({largest.stat().st_size/1e9:.2f} GB)", flush=True)
        t0 = time.time()
        bytes_read = 0
        chunk = 64 * 1024 * 1024  # 64 MiB chunks
        with open(largest, "rb", buffering=0) as f:
            while bytes_read < target_bytes:
                b = f.read(chunk)
                if not b:
                    # Loop if file is smaller than target (re-open)
                    break
                bytes_read += len(b)
        elapsed = time.time() - t0
        throughput_mbs = bytes_read / elapsed / 1e6
        _emit("t1a", {
            "file": str(largest),
            "bytes_read": bytes_read,
            "elapsed_sec": elapsed,
            "throughput_MBps": throughput_mbs,
            "mode": "single-large-file",
        })
    else:
        # Fall back: read many files sequentially until we hit target bytes.
        # Bounded: cap enumeration at 20k files or 90s (whichever comes first)
        # so we don't get stuck rglob'ing 500k+ files on cold FSx-via-DRA.
        print("[t1a] no single large file; falling back to many-small-files read", flush=True)
        all_files = _list_files(DATASET_PATH, min_size=1, max_files=20_000, time_limit_sec=90.0)
        print(f"[t1a] enumerated {len(all_files)} files", flush=True)
        # NOTE: intentionally NOT shuffling. Sequential read of first-N-files
        # gives a deterministic, comparable measurement across backends.
        t0 = time.time()
        bytes_read = 0
        files_read = 0
        for p in all_files:
            if bytes_read >= target_bytes:
                break
            try:
                with open(p, "rb", buffering=0) as f:
                    while True:
                        b = f.read(1024 * 1024)
                        if not b:
                            break
                        bytes_read += len(b)
                        if bytes_read >= target_bytes:
                            break
                files_read += 1
            except OSError as e:
                print(f"[t1a] skip {p}: {e}", flush=True)
        elapsed = time.time() - t0
        throughput_mbs = bytes_read / elapsed / 1e6
        _emit("t1a", {
            "files_read": files_read,
            "bytes_read": bytes_read,
            "elapsed_sec": elapsed,
            "throughput_MBps": throughput_mbs,
            "mode": "many-small-files",
        })


# ---------- T1c: single-stream checkpoint write ----------
def t1c_single_stream_write() -> None:
    """Write a 5 GiB file sequentially. Reports MB/s."""
    target_bytes = 5 * 1024 * 1024 * 1024
    out_path = DATA_ROOT / f"bench-write-t1c-{RUNID}-{socket.gethostname()}.bin"
    print(f"[t1c] writing {target_bytes/1e9:.1f} GB to {out_path}", flush=True)
    chunk = os.urandom(64 * 1024 * 1024)  # 64 MiB of random once, reused
    t0 = time.time()
    bytes_written = 0
    with open(out_path, "wb", buffering=0) as f:
        while bytes_written < target_bytes:
            remaining = target_bytes - bytes_written
            b = chunk if remaining >= len(chunk) else chunk[:remaining]
            f.write(b)
            bytes_written += len(b)
        # Force flush to backend (matters for S3 Mountpoint: completes multipart upload)
        f.flush()
        try:
            os.fsync(f.fileno())
        except OSError:
            pass  # S3 Mountpoint may not support fsync; that's fine
    elapsed = time.time() - t0
    throughput_mbs = bytes_written / elapsed / 1e6
    _emit("t1c", {
        "file": str(out_path),
        "bytes_written": bytes_written,
        "elapsed_sec": elapsed,
        "throughput_MBps": throughput_mbs,
    })
    # Cleanup so we don't fill up the backend
    try:
        out_path.unlink()
    except OSError:
        pass


# ---------- T2a: small-file metadata ----------
def t2a_metadata() -> None:
    """stat() 10k files + ls -R the dataset root."""
    print(f"[t2a] enumerating first 10000 files in {DATASET_PATH}", flush=True)
    # For metadata benchmark, we can spend more time on the initial walk
    all_files = _list_files(DATASET_PATH, min_size=0, max_files=10_000, time_limit_sec=120.0)
    print(f"[t2a] found {len(all_files)}, running stat()", flush=True)

    t0 = time.time()
    stat_ok = 0
    stat_err = 0
    for p in all_files:
        try:
            _ = p.stat()
            stat_ok += 1
        except OSError:
            stat_err += 1
    stat_elapsed = time.time() - t0

    # ls -R style: recursive iteration counting directories/files
    # Bounded: 120s walk budget. On cold FSx-via-DRA with 500k+ files, unbounded
    # walk can take hours.
    print("[t2a] walking directory tree (max 120s)", flush=True)
    t0 = time.time()
    dirs = 0
    files = 0
    walk_timed_out = False
    for dirpath, dirnames, filenames in os.walk(DATASET_PATH):
        if time.time() - t0 > 120.0:
            walk_timed_out = True
            print(f"[t2a] walk time limit reached; scanned {dirs} dirs and {files} files", flush=True)
            break
        dirs += 1
        files += len(filenames)
        # Cap walk to a reasonable subset to avoid multi-hour walks on 500k+ files
        if files >= 50_000:
            break
    walk_elapsed = time.time() - t0

    _emit("t2a", {
        "stat_count": stat_ok,
        "stat_errors": stat_err,
        "stat_elapsed_sec": stat_elapsed,
        "stat_ops_per_sec": stat_ok / stat_elapsed if stat_elapsed > 0 else 0,
        "walk_dirs": dirs,
        "walk_files": files,
        "walk_elapsed_sec": walk_elapsed,
        "walk_files_per_sec": files / walk_elapsed if walk_elapsed > 0 else 0,
    })


# ---------- T1b: distributed parallel read (runs under torchrun) ----------
def t1b_parallel_read() -> None:
    """Each rank reads a distinct slice of the dataset. Requires torchrun.

    Reports per-rank throughput. Aggregate is post-processed from result files.
    """
    import torch
    import torch.distributed as dist

    dist.init_process_group("nccl" if torch.cuda.is_available() else "gloo")
    rank = dist.get_rank()
    world = dist.get_world_size()

    all_files = _list_files(DATASET_PATH, min_size=1024 * 1024, max_files=20_000, time_limit_sec=90.0)  # >= 1 MiB
    if rank == 0:
        print(f"[t1b] world={world} total_files={len(all_files)}", flush=True)
    dist.barrier()

    # Deterministically slice: rank i takes every world-th file starting at i
    my_files = all_files[rank::world]
    per_rank_target_bytes = 2 * 1024 * 1024 * 1024  # 2 GiB per rank

    t0 = time.time()
    bytes_read = 0
    for p in my_files:
        if bytes_read >= per_rank_target_bytes:
            break
        try:
            with open(p, "rb", buffering=0) as f:
                while True:
                    b = f.read(4 * 1024 * 1024)
                    if not b:
                        break
                    bytes_read += len(b)
                    if bytes_read >= per_rank_target_bytes:
                        break
        except OSError:
            continue
    elapsed = time.time() - t0
    throughput_mbs = bytes_read / elapsed / 1e6

    _emit("t1b", {
        "rank": rank,
        "world_size": world,
        "bytes_read": bytes_read,
        "elapsed_sec": elapsed,
        "throughput_MBps_per_rank": throughput_mbs,
    })

    dist.barrier()
    dist.destroy_process_group()


# ---------- Dispatch ----------
BENCHMARKS: dict[str, Callable] = {
    "t1a": t1a_single_pod_read,
    "t1c": t1c_single_stream_write,
    "t2a": t2a_metadata,
    "t1b": t1b_parallel_read,
    # t2b (sharded ckpt) + t2c (DDP training) require torchrun and full stack
    # they are separate scripts / PyTorchJobs
}


def main():
    print(f"backend={BACKEND} dataset={DATASET} runid={RUNID} bench={BENCH_LIST}", flush=True)
    print(f"DATA_ROOT={DATA_ROOT} DATASET_PATH={DATASET_PATH}", flush=True)

    if not DATASET_PATH.exists():
        print(f"ERROR: {DATASET_PATH} does not exist", flush=True)
        sys.exit(2)

    for name in BENCH_LIST:
        name = name.strip()
        if name not in BENCHMARKS:
            print(f"unknown benchmark {name}, skipping", flush=True)
            continue
        try:
            BENCHMARKS[name]()
        except Exception as e:
            print(f"[{name}] FAILED: {type(e).__name__}: {e}", flush=True)
            import traceback
            traceback.print_exc()
            _emit(name, {"error": f"{type(e).__name__}: {e}"})


if __name__ == "__main__":
    main()
