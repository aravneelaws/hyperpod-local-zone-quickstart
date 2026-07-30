# Benchmark Observations

> **Read this first.** The numbers in this document are point observations from a specific benchmark run on a specific hardware setup with specific software versions and specific tuning. They are NOT performance commitments, SLA figures, or expected values for other deployments. Every dimension that affects throughput (hardware type and count, dataset shape, library versions, network path, DataLoader tuning, cluster size) can shift these numbers substantially. If you are planning a deployment based on these observations, treat them as a starting point for your own measurements and always re-benchmark on your target setup with your actual data.

The methodology behind these numbers lives in [`benchmark.md`](./benchmark.md). The code that produced them is in this directory (`bench.py`, `bench_t2c.py`, `bench_boto3.py`, `bench_s3tc.py` and the companion PyTorchJob manifests). Anyone should be able to reproduce the setup and get comparable directional signals; exact numbers will vary.

---

## Test setup used for these observations

**Hardware and cluster**
- 2 × `ml.p5e.48xlarge` HyperPod EKS nodes in `us-west-2-phx-2a` (Phoenix Local Zone)
- 8 GPUs per node, 16 GPUs total, world size 16 for DDP tests
- Single primary ENA per node (multi-NIC not enabled — see the "Multi-NIC on HyperPod" section of `benchmark.md`)
- DLAMI 1.4.2 (Amazon Linux 2023, kernel 6.12)

**Software**
- PyTorch 2.6.0, CUDA 12.6 (from `pytorch-training:2.6.0-gpu-py312-cu126-ubuntu22.04-ec2-v1.47`)
- `s3torchconnector` (latest at time of test)
- `boto3` (default `boto3.client('s3')`; does NOT use CRT for transfers)
- Mountpoint-S3 CSI driver v2.7.0

**Datasets (proxies for real workload shapes)**
- `openalex` — large sequential shards: ~600 GB total, 2008 parquet files, ~184 MB median file size. Proxy for LLM-style pipelines.
- `openfold-pdb` — small-file per-sample bundles: ~644 GB total, 524k files, ~1.2 MB median. Grouped into ~3800 "protein bundles" of ~4 files × ~1 MB each. Proxy for structure-prediction-style pipelines.

**Access patterns tested** (parameterized in `bench_boto3.py`)
- `random_partial` — per-sample 64 KB range-GET at a pseudorandom offset within a chosen file
- `whole_file` — per-sample full GetObject on a chosen file
- `bundle` — per-sample fan-out to N concurrent GetObjects for all files under a grouping prefix

**Storage backends compared**
- Parent-AZ FSx Lustre (1.2 TiB, cross-zone mounted from LZ nodes)
- LZ FSx Lustre (2.4 TiB, co-located with compute)
- S3 Mountpoint (FUSE) single-NIC
- `boto3` direct SDK with `ThreadPoolExecutor` (no CRT)
- `s3torchconnector` (uses Mountpoint-S3 Rust client + CRT under the hood)

---

## Headline observations (comparative)

Comparative statements travel more reliably than absolute numbers. Under the same hardware and workload, we observed:

- On per-sample random-access training workloads (bundle-per-sample or partial-file reads), **`s3torchconnector` delivered roughly 1000× higher aggregate throughput than S3 Mountpoint (FUSE)**. This gap was not closed by increasing DataLoader concurrency on the FUSE side — the bottleneck is FUSE metadata serialization, not client-side parallelism.
- **`s3torchconnector` and best-tuned `boto3` direct converged to within ~5% of each other** at their respective sweet-spot tuning configurations. Both use similar underlying network paths; the differences are in Python-side overhead and how each library manages concurrency.
- **LZ FSx delivered roughly 10× higher aggregate throughput than parent-AZ FSx** on the same DDP workload. The gap is dominated by cross-AZ latency for metadata operations rather than raw bandwidth.
- **On sequential-streaming workloads, S3 Mountpoint was competitive** — within 2-3× of the SDK-based clients on the same setup. It is specifically the per-sample random-access pattern where FUSE fails.
- **DataLoader tuning matters as much as backend choice** for SDK-based clients. We saw peak throughput at specific `num_workers × prefetch_factor` combinations; going higher regressed performance due to CPU/connection-pool contention.

---

## Full observations

All numbers below are aggregate across 16 ranks (2 nodes × 8 GPUs). All tests ran for a fixed step count after a 5-step warmup unless otherwise noted.

### T1a — Single-pod sequential read (MB/s)

| Backend | `openalex` |
|---|---|
| parent-AZ FSx | 62 |
| LZ FSx | 131 |
| S3 Mountpoint single-NIC | 249 |

`openfold-pdb` T1a was 0 MB/s on all backends because cold-cache file enumeration on 524k files timed out within our test window. This is a metadata-warm-up artifact, not a throughput measurement.

### T1b — 16-rank distributed sequential read (aggregate MB/s)

| Backend | `openalex` aggregate |
|---|---|
| parent-AZ FSx | 191 |
| LZ FSx | 652 (near the FSx-LZ provisioned ceiling of ~600 MB/s) |
| S3 Mountpoint single-NIC | 1,411 |

### T1c — Single-stream 5 GiB write (MB/s)

| Backend | MB/s |
|---|---|
| parent-AZ FSx | 88 |
| LZ FSx (`openalex` prefix) | 484 |
| LZ FSx (`openfold` prefix) | 489 |
| S3 Mountpoint single-NIC | 719 |

### T2a — Metadata walk (files/sec)

| Backend | `openalex` | `openfold-pdb` (524k files) |
|---|---|---|
| parent-AZ FSx | 70 | not measured (cold-walk did not finish in test window) |
| LZ FSx | 16,016 | 180 cold / 216 warm |
| S3 Mountpoint | 28 | ~0 (cold enumeration did not converge) |

### T2c — Realistic DDP training pipeline

The T2c benchmark constructs a real PyTorch DDP training loop with a `DataLoader` and measures samples/sec at various tuning configurations. This is the most representative test for training-pipeline performance.

**`openalex` × `random_partial` mode** (large parquet files, 64 KB per sample):

| Backend / config | samples/sec agg | agg MB/s |
|---|---|---|
| parent-AZ FSx | 498 | 33 |
| LZ FSx | 10,689 | 700 |
| S3 Mountpoint (nw=4, pf=2) | 62 | 4 |
| S3 Mountpoint (nw=8, pf=8, aggressive tune) | 56 | 4 |

**Note on S3 Mountpoint here**: doubling worker count and quadrupling prefetch did not help — it slightly regressed. The FUSE metadata serialization does not benefit from client-side parallelism.

**`openfold-pdb` × `whole_file` mode** (small files, ~1 MB each, 1 file per sample, boto3-direct):

| Config | samples/sec agg | agg MB/s |
|---|---|---|
| boto3 nw=4 t=1 (baseline) | 828 | 910 |
| **boto3 nw=4 t=8** | **3,806** | **4,186** |
| boto3 nw=4 t=16 (over-threaded) | 2,583 | 2,841 |
| boto3 nw=8 t=16 (over-workered) | 2,291 | 2,520 |

The plateau at nw=4/t=8 illustrates that tuning has a sweet spot; more concurrency past that point regresses performance due to worker contention.

**`openfold-pdb` × `bundle` mode** (4 files × ~1 MB per sample; per-sample fan-out; matches structure-prediction-style workloads):

| Client / config | samples/sec agg | agg MB/s |
|---|---|---|
| boto3 nw=4 t=8 pf=2 | 370 | 1,600 |
| boto3 nw=8 t=16 pf=2 | 897 | 3,879 |
| boto3 nw=8 t=16 pf=8 | 1,091 | 4,715 |
| boto3 nw=16 t=16 pf=8 | 1,340 | 5,792 |
| s3torchconnector nw=8 pf=2 | 384 | 1,611 |
| s3torchconnector nw=16 pf=2 | 837 | 3,514 |
| s3torchconnector nw=24 pf=2 | 665 | 2,790 |
| s3torchconnector nw=32 pf=2 | 1,048 | 4,398 |
| s3torchconnector nw=32 pf=4 | 1,078 | 4,525 |
| **s3torchconnector nw=32 pf=8 (100 steps)** | **1,412** | **5,926** |
| **s3torchconnector nw=32 pf=8 (500 steps sustained)** | **1,446** | **6,069** |
| s3torchconnector nw=32 pf=16 | 1,247 | 5,232 |
| s3torchconnector nw=48 pf=2 | 891 | 3,737 |
| s3torchconnector nw=48 pf=8 | 746 | 3,132 |
| s3torchconnector nw=64 pf=2 | 976 | 4,097 |

Observations from this sweep:
- The sweet spot for `s3torchconnector` in our setup was `num_workers=32, prefetch_factor=8`, sustaining ~6.07 GB/s aggregate over a 500-step run
- Going higher on either dimension (nw=48, nw=64, pf=16) regressed performance
- `boto3` direct converged to a comparable peak (5.79 GB/s at nw=16/t=16/pf=8), within ~5% of `s3torchconnector`
- We stopped tuning at this point because the results were sufficient for the questions we were investigating. We did not measure the true per-node ceiling — further tuning (larger batch sizes, tuned thread pool sizes at higher worker counts, or different sample-encoding overhead) would likely have yielded somewhat higher throughput.

### Sample-mode comparison at fixed concurrency

To isolate the effect of access pattern from tuning, comparing `boto3` direct at nw=4/t=8 across sample modes on the same cluster:

| Mode | agg MB/s |
|---|---|
| `openalex` `random_partial` (64 KB per sample from large files) | 421 |
| `openfold-pdb` `whole_file` (whole ~1 MB file per sample) | 4,186 |
| `openfold-pdb` `bundle` (4 × ~1 MB files per sample) | 1,600 |

The 10× difference between `random_partial` and `whole_file` at the same concurrency reflects that per-request bytes-per-sample dominates when the per-request latency is roughly constant. Bigger per-request payloads amortize per-request overhead.

---

## What we did NOT measure

Being explicit about the gaps, because these matter for how the numbers should be interpreted:

- **Multi-node scaling beyond 2 nodes.** All tests ran on 2 nodes. Any expected throughput at higher cluster sizes is extrapolation, not observation. S3-based backends should scale approximately linearly with client count until per-node network bandwidth becomes the bottleneck; validate at intermediate cluster sizes (4-8 nodes) before committing to a plan that depends on it.
- **Multi-NIC S3 Mountpoint.** Investigated, blocked by an interaction between HyperPod's ENI provisioner and AWS Nitro network fabric. See the "Multi-NIC on HyperPod" section of `benchmark.md` for what was tried.
- **Multi-epoch training with local NVMe caching.** For workloads that train multiple passes over the same dataset, a cache-to-local-disk layer between S3 and the DataLoader could deliver significantly higher effective throughput on epochs 2+. Not measured.
- **Other DLAMI versions or other regions.** All tests on DLAMI 1.4.2 in Phoenix LZ. Results may differ on other DLAMI versions or in other AZs / regions (in particular, LZ vs regular-AZ has different S3 latency characteristics).
- **Different DataLoader configurations at large batch sizes.** All tests used `batch_size=32`. Larger batches with fewer steps would shift the CPU-vs-I/O balance and may unlock more per-node throughput.
- **`boto3` with explicit CRT configuration.** `boto3` default does not use CRT; we tested that path. `s3torchconnector` uses CRT natively via the Mountpoint-S3 Rust client. Explicitly-CRT-configured `boto3` was not benchmarked separately but is expected to be comparable to `s3torchconnector` given both use the same underlying transfer library.
- **End-to-end training convergence.** All T2c tests used a tiny MLP so compute doesn't dominate. Real training with larger models has different compute-vs-I/O ratios; storage throughput may or may not be the bottleneck for a given real workload.

---

## How to think about these numbers

Some dimensions of these observations extrapolate reasonably. Others do not.

**Extrapolates reasonably**:
- **S3-side scaling with more clients.** S3 is designed to handle very high aggregate request rates. Adding more nodes to a cluster reading from the same S3 bucket should scale close to linearly until per-node network bandwidth becomes the constraint or per-prefix request rate limits are hit.
- **Comparative claims within our observations.** "`s3torchconnector` is much faster than S3 Mountpoint on per-sample workloads" is a durable statement across cluster sizes and datasets. The exact ratio will vary; the direction won't.
- **Access-pattern impact.** The dramatic difference between `random_partial`, `whole_file`, and `bundle` modes on the same cluster illustrates a real phenomenon that reproduces on any S3-based client. Workloads that fetch many bytes per request will always outperform workloads that fetch few bytes per request at similar API-call rates.

**Does NOT extrapolate cleanly**:
- **Per-node absolute throughput.** Our per-node observations depend on this specific hardware (p5e single-NIC), this specific DLAMI, this specific PyTorch version, and this specific set of DataLoader parameters. All of these can shift the per-node ceiling substantially.
- **Aggregate cluster throughput at large scales.** Linear extrapolation from 2 nodes to 64 nodes assumes no other bottleneck becomes dominant (S3 prefix hot-spotting, DDP collective overhead at large world sizes, network path saturation between the cluster and S3). We did not validate any of these.
- **Sweet-spot tuning parameters.** `num_workers=32, prefetch_factor=8` was our sweet spot on 2 p5e nodes. On different hardware, different datasets, or different cluster sizes, the optimum will be different.

**If you are planning a deployment based on these observations**: run the benchmarks on your target hardware with your actual data (or a close proxy). The code in this repo is parameterized for exactly this — swap the S3 bucket/prefix and dataset shape, rerun the tuning sweep, and use those numbers rather than these.
