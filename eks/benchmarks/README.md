# Storage Backend Benchmarks — FSx-in-LZ vs. S3 Mountpoint

This directory captures a benchmark comparing three storage backends for HyperPod training in an AWS Local Zone:

1. **FSx Lustre in the parent AZ** (`us-west-2b`), cross-zone mounted from LZ workers — our baseline from prior work
2. **FSx Lustre in the LZ subnet** (`us-west-2-phx-2a`), co-located with compute — newly enabled by AWS
3. **S3 Mountpoint** via `aws-mountpoint-s3-csi-driver`, regional S3 bucket

**Motivation**: Prior to FSx-in-LZ becoming available, all LZ HyperPod deployments had to cross-zone mount FSx from the parent AZ (adding ~5-10 ms of latency per metadata op). Now we have three practical choices, and downstream customers (e.g., Boltz) are evaluating between them — Boltz's team has expressed a preference for S3 Mountpoint.

## Benchmark scope (planned)

Run each of the following against all three backends. 2 nodes × 8 GPUs = 16 concurrent workers where applicable.

### Tier 1 (must-answer)

- **T1a. Single-pod sustained read**: sequential read of a 4 GiB shard with `num_workers=4` in a DataLoader. Reports MB/s.
- **T1b. Aggregate parallel read**: 16 concurrent readers (one per rank), each reading a distinct 512 MiB shard. Reports aggregate MB/s.
- **T1c. Single-stream checkpoint write**: rank 0 writes a 5 GiB checkpoint. Reports MB/s and wall-clock.

### Tier 2 (nice-to-have)

- **T2a. Small-file metadata**: `stat()` on 10,000 files, `ls -R` on a nested dir with 10k files.
- **T2b. Sharded parallel checkpoint**: all 16 ranks write concurrently via `torch.distributed.checkpoint`. Reports wall-clock and per-rank MB/s.
- **T2c. End-to-end DDP training**: same 440M-param MLP, 5 epochs, checkpoint-per-epoch. Compares against our earlier cross-zone-FSx result of ~16,239 samples/sec.

## Predictions (to compare against)

- FSx-in-LZ read: ~300 MB/s single-stream (matches 250 MB/s per TiB × 1.2 TiB provisioned throughput). Parallel: should exceed 300 MB/s due to client-side caching.
- S3 Mountpoint sequential: 300-800 MB/s single-stream (Mountpoint parallelizes GETs). Scales further with concurrent readers.
- Small-file: FSx clobbers S3 Mountpoint. Lustre metadata is fast; S3 has no real directory concept.
- Checkpoint writes: S3 Mountpoint may struggle with in-place updates; sharded parallel writes should work fine to unique paths.

## Storage backend details

| Backend | K8s PVC | Details |
|---|---|---|
| Parent-AZ FSx (existing) | `fsx-lustre-pvc` | `fs-0a98ab185ccf2de3e`, `us-west-2b`, PERSISTENT_2, 1.2 TiB, 250 MB/s per TiB |
| **LZ FSx (new)** | `fsx-lz-pvc` | `fs-0663665ff74a5f5aa`, `us-west-2-phx-2a`, PERSISTENT_2, 1.2 TiB, 250 MB/s per TiB |
| **S3 Mountpoint (new)** | `s3mp-pvc` | Bucket `hp-eks-lz-s3mp-bench-159553542841-us-west-2`, regional S3, mounted via CSI driver v2.7.0 |

## FTP window

24 hours starting ~2 days from now (2026-07-26 window). 2× `ml.p5e.48xlarge` in `us-west-2-phx-2a`.

## Results

Populated after benchmark runs.
