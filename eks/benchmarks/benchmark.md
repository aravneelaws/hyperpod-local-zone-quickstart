# Storage Backend Benchmark for HyperPod Training in a Local Zone

Comparing storage backend options for HyperPod training in an AWS Local Zone: FSx Lustre (parent AZ + LZ), S3 Mountpoint (FUSE), boto3-direct, and `s3torchconnector`.

> This document covers the **experimental design and methodology**. For infra setup (VPC, EKS, PVCs, IAM), see the parent [`eks/README.md`](../README.md). For point observations from one specific benchmark run — including tuning sweep tables and observed throughput numbers — see [`benchmark-observations.md`](./benchmark-observations.md). Those observations are not performance commitments; the disclaimer on that file explains how to interpret them.

## Why this benchmark exists

Training workloads in AWS Local Zones face several storage tradeoffs that are not well characterized in public documentation:

- **FSx Lustre in Local Zones is a recent addition** (Phoenix LZ now supports PERSISTENT_2 at 125 or 250 MB/s per TiB). Previously, FSx had to be provisioned in the parent AZ and cross-zone mounted, which introduces network hops that affect metadata and small-file operations.
- **S3 Mountpoint** offers a fundamentally different storage model (object storage as a filesystem) with different scaling characteristics: no fixed capacity commitment, pay-per-request pricing, and — with recent versions — the ability to fan out requests across multiple network interfaces.
- **Multi-NIC S3 Mountpoint** (via `--bind` in mountpoint-s3 v1.9.0+) is theoretically capable of saturating aggregate instance bandwidth on p5-class hardware, but on SageMaker HyperPod it is architecturally blocked (see the "Multi-NIC on HyperPod" section below).
- **Direct-SDK S3 access from training code** (boto3, `aiobotocore`, `s3torchconnector`) bypasses FUSE entirely. It is the fastest path today for per-sample random-access workloads, but requires DataLoader-level code changes in the training script.

The goal is to produce a reproducible methodology and comparable numbers across all four (well, five) storage paths, so a customer team can pick the right backend for their workload shape.

## What we tested

For each combination of **storage backend × dataset × test**, we record throughput, metadata ops/sec, and wall-clock time.

### Storage backends under test

| Backend | Location | Provisioning | K8s access |
|---|---|---|---|
| Parent-AZ FSx Lustre | `us-west-2b` (LZ's parent AZ, cross-zone mounted from LZ workers) | PERSISTENT_2, 1.2 TiB @ 250 MB/s per TiB | PVC `fsx-lustre-pvc` |
| LZ FSx Lustre | Local Zone, co-located with compute | PERSISTENT_2, 2.4 TiB @ 250 MB/s per TiB | PVC `fsx-lz-pvc` |
| S3 Mountpoint, single-NIC | Regional S3, `aws-mountpoint-s3-csi-driver` v2.7.0, default config | Bucket via primary ENI | PVC `s3mp-pvc` |
| boto3-direct | Same S3 bucket, no CSI driver | Pod calls S3 via boto3 SDK with IRSA | ServiceAccount |
| `s3torchconnector` | Same S3 bucket, no CSI driver | Pod uses `S3MapDataset` (AWS-official, wraps Mountpoint-S3 Rust client via PyO3 → uses CRT) | ServiceAccount |

**Notes:**
- FSx Lustre is not offered in most Local Zones. Phoenix is a recent exception. This is why LZ FSx is tested as a first-class backend.
- Parent-AZ FSx was capped at 1.2 TiB rather than 2.4 TiB because a resize operation returned `insufficient capacity in this availability zone` twice. This is not a benchmark artifact — it is a real constraint a customer could encounter.
- Multi-NIC S3 Mountpoint was attempted but is blocked on HyperPod (see dedicated section below).
- `s3torchconnector` and boto3-direct are library-level clients, not filesystem mounts. They require the training code to call S3 SDK APIs rather than `open()` on a path. This is a code change of ~30 lines in a Dataset class.

### Datasets under test

Both datasets pre-loaded into the S3 Mountpoint bucket and made visible in both FSx file systems via AWS FSx Data Repository Associations (DRA).

| Dataset | Access pattern | Size | Files | Median file size | Source |
|---|---|---|---|---|---|
| **`openalex`** | Large sequential shards (LLM/HPC-style) | ~600 GB | 2,008 | 184 MB | `s3://openalex/data/parquet/works/updated_date=2025-*` |
| **`openfold-pdb`** | Small-file per sample (structure-prediction / bioinformatics style) | ~644 GB | 524,453 | ~1.2 MB (4 files per PDB chain: 3 MSA hits + 1 template hits) | `s3://openfold/pdb/` |

**Why two datasets**: file-size distribution and access pattern dominate storage performance far more than the actual bytes. A single dataset gives a single answer. Two datasets bracket the space — `openalex` favors sequential-read backends; `openfold-pdb` favors metadata-rich backends AND matches typical protein-structure workload patterns.

### Access-pattern parameterization

We introduced three sample modes in `bench_boto3.py` (and mirrored in `bench_t2c.py`) so we can compare backends fairly across different training patterns:

- **`random_partial`** — each sample is a 64 KB range-GET at a pseudorandom offset within a chosen large file. Approximates LLM-style pipelines that read a random row from a parquet file.
- **`whole_file`** — each sample is a full GetObject (no Range). Approximates image classification or single-file-per-sample training pipelines.
- **`bundle`** — each sample is N concurrent GetObjects for all files under one grouping prefix (e.g. one protein directory). Approximates protein-structure workloads where each training sample = 1 protein × 4-10 associated files.

### Tests

Each test writes a structured JSON result per pod invocation to `/results/<backend>/<backend>_<dataset>_<test>_<runid>_<hostname>.json`.

- **T1a — Single-pod sustained sequential read**. One pod, one node, 4 GiB read in 64 MiB chunks. Measures single-worker feed-a-GPU throughput.
- **T1b — Distributed parallel read across 16 ranks**. PyTorchJob with 2 pods × 8 ranks each; each rank sequentially reads 2 GiB from a distinct dataset slice. Measures aggregate cluster throughput.
- **T1c — Single-stream 5 GiB write**. One pod writes 5 GiB. Simulates rank-0 checkpoint save.
- **T2a — Metadata operations**. `stat()` up to 10,000 files + `os.walk()` up to 50,000. Measures the FSx-vs-S3 metadata differentiator.
- **T2c — Realistic DDP training pipeline**. 16-rank PyTorch DDP with DataLoader, `num_workers` × `threads_per_worker` concurrent GetObjects per rank, real per-sample fetch behavior. This is the most important test because it matches how actual training pipelines read data.

## Why S3 Mountpoint fails at per-sample workloads (technical detail)

S3 Mountpoint is fine for some workloads and unusable for others. The failure mode matters because it drives the recommendation. Two layers to the problem:

**1. FUSE metadata serialization.** S3 Mountpoint mounts S3 as a POSIX filesystem via FUSE. Every `open()` call in your training code becomes a FUSE syscall, which the driver translates into an S3 `HeadObject` API call (~30-50 ms in LZ). FUSE has a shared channel for metadata operations — even if 32 DataLoader threads each try to `open()` a different file concurrently, FUSE serializes them on the metadata channel. Client-side concurrency does not scale FUSE metadata throughput; it is a FUSE architecture limitation, not an S3 limitation.

**2. CRT below FUSE doesn't help small reads.** S3 Mountpoint internally uses the AWS Common Runtime (CRT) S3 client, which is highly optimized. CRT splits large GETs into parallel multipart requests (default 8 MB parts). But for per-sample small reads (e.g. 64 KB), there's nothing for CRT to parallelize — you're below the multipart threshold, so CRT just does one small GET per sample. FUSE metadata serialization then dominates.

**Contrast with `s3torchconnector` / boto3-direct**: no FUSE. Each concurrent `s3.get_object()` call is a plain HTTPS request; the OS network stack handles concurrency natively via TCP sockets. Many concurrent requests can all be in flight simultaneously with no serialization.

## Common Runtime (CRT): what it is and where it's used

The AWS Common Runtime (`aws-c-s3`) is a set of C libraries that AWS uses internally for high-performance S3 transfer. Key properties:
- Native async I/O; no Python GIL involvement in the transfer hot path
- Automatic multipart parallel GETs for large objects (default 8 MB parts)
- Adaptive bandwidth targeting
- Used under the hood by Mountpoint-S3, `s3torchconnector`, `s5cmd`, and CRT-enabled boto3

**Which clients use CRT**:

| Client | Uses CRT? | Note |
|---|---|---|
| `boto3.client('s3')` default | No | Pure Python transfer path |
| `boto3` with explicit CRT config | Yes | Via `botocore.client.Config` with CRT transfer manager |
| `s3torchconnector` | Yes | Wraps Mountpoint-S3 Rust client → CRT |
| S3 Mountpoint (FUSE) | Yes | Rust client → CRT |
| `s5cmd`, `awscrt.s3` direct | Yes | |
| `aioboto3` / `aiobotocore` | No | Async Python, not CRT |

CRT is the ceiling for S3 throughput on any single client. All CRT-based clients hit similar per-node throughput ceilings; the difference is language/binding overhead (which matters for tiny transfers, less for MB-sized transfers).

## Recommended architecture

For per-sample random-access training workloads:

**Compute**: HyperPod EKS cluster, N nodes of p5e.48xlarge (or equivalent) in the target Local Zone. No CSI drivers for S3 or FSx are required for training data.

**Data storage**: Regional S3 bucket in the same region as the LZ. Same bucket used for both training data reads and checkpoint writes.

**Auth**: IRSA — a ServiceAccount with an IAM role granting `s3:GetObject`, `s3:ListBucket`, and `s3:PutObject` on the target bucket.

**Training code**: DataLoader replaces filesystem-based Dataset with `s3torchconnector.S3MapDataset`. Approximate code diff:

```python
# BEFORE (filesystem path)
class MyDataset(Dataset):
    def __init__(self, data_root):
        self.data_root = Path(data_root)
        self.sample_ids = [p.name for p in self.data_root.iterdir()]

    def __getitem__(self, idx):
        sid = self.sample_ids[idx]
        f1 = open(f"{self.data_root}/{sid}/subdir/file1.bin", "rb").read()
        f2 = open(f"{self.data_root}/{sid}/subdir/file2.bin", "rb").read()
        return process(f1, f2)

# AFTER (s3torchconnector)
from s3torchconnector import S3MapDataset

class MyDataset(Dataset):
    def __init__(self, bucket, prefix, region):
        self._s3 = S3MapDataset.from_prefix(f"s3://{bucket}/{prefix}", region=region)
        self._bundles = self._build_bundles()  # group indices by sample id

    def __getitem__(self, idx):
        bundle = self._bundles[idx]
        f1 = self._s3[bundle["f1_idx"]].read()
        f2 = self._s3[bundle["f2_idx"]].read()
        return process(f1, f2)
```

Scope: ~30 lines changed in the Dataset class. Parsing, tensor construction, training loop, and DDP setup all stay identical.

**Concurrency knobs to tune for training**:
- `DataLoader(num_workers=..., prefetch_factor=..., persistent_workers=True, pin_memory=True)` — the optimal values depend on hardware and workload. See [`benchmark-observations.md`](./benchmark-observations.md) for observed sweet-spot configurations on our test hardware and how they varied with tuning.
- `S3MapDataset` handles per-request concurrency internally via CRT.

**Optional: local NVMe caching for multi-epoch training.** If a workload trains multiple epochs over the same data, adding a local NVMe cache layer (write files to `/tmp/cache` as they arrive from S3, read from local disk on subsequent epochs) could boost throughput 2-5× for epochs 2+. We did NOT test this.

## Multi-NIC S3 Mountpoint on HyperPod

Multi-NIC S3 Mountpoint (via `--bind`) would potentially allow saturating the aggregate network bandwidth of a p5e node (~200-300 Gbps across 32 ENAs vs. ~50 Gbps on the primary ENA alone). This would multiply per-node throughput by 4-6×.

**Status: architecturally blocked on HyperPod EKS as of 2026-07.**

### What we tried

1. Attached `NetworkInterface: {InterfaceType: efa}` in the InstanceGroup spec. Accepted by the API. 32 EFA endpoints attached correctly.
2. Verified via `lspci -k` that 32 ENA PCI devices are attached and bound to the `ena` driver.
3. Attempted to enumerate ENA netdevs via `/sys/bus/pci/devices/<pci>/net/` — only 1 of 32 has a netdev entry.

### Root cause (per HyperPod engineering)

Each Nitro network card has two independent PCI functions (one ENA, one EFA), each requiring its own ENI to be usable. HyperPod's ENI provisioner attaches:
- Card 0 (primary): both an ENA ENI and an EFA ENI → both functions active
- Cards 1-31 (secondary): only an EFA ENI → EFA function active, ENA function idle (no MAC, no queues, no kernel netdev)

This is by design; HyperPod optimizes for NCCL collective bandwidth (EFA/RDMA) on secondary cards, not TCP bandwidth. S3 traffic goes over TCP → needs ENA netdevs → not available on secondary cards.

### Workaround investigated but not tested

A second HyperPod engineer indicated the ENIs may exist in a separate network namespace (`sagemaker_agent_namespace`), and could be moved to the root namespace via:

```bash
ip netns exec sagemaker_agent_namespace ip link set <eni_name> netns 1
ip link set <eni_name> up
```

This is documented as an unsupported workaround and would need to be scripted as a lifecycle hook or DaemonSet to survive node recycling. We did not fully test it because for typical target throughputs on 2-node clusters, single-NIC (via `s3torchconnector`) already delivers substantial headroom.

An internal SIM ticket has been filed with the HyperPod team requesting an official opt-in for attaching ENA ENIs to secondary cards.

## What we are NOT measuring (yet)

- **End-to-end training convergence**. Our T2c uses a tiny MLP model so compute doesn't dominate. Real training would have larger models and different compute-vs-I/O ratios. For measuring throughput ceiling, our design is correct; for wall-clock time to convergence, a real training script would be needed.
- **Sharded parallel checkpoint writes**. Would use `torch.distributed.checkpoint` from all 16 ranks. Interesting for large-model workflows. Not measured.
- **Data hydration time from S3 into FSx via DRA**. In our setup, DRAs are `AVAILABLE` but the actual file bytes are lazy-loaded on first access from S3 into FSx. First reads on FSx are S3-speed; subsequent reads are Lustre-native. We accepted this and note warm-vs-cold behavior where it appeared.
- **Cost per GB**. Spreadsheet exercise, not a benchmark.
- **Multi-node scaling validation**. Our tests ran on 2 nodes. Scaling to 8-64 nodes assumes linear per-node throughput scaling, which is plausible (S3 has vastly more capacity than a small cluster can consume, and each node has an independent ENA), but not directly validated. If a customer commits to a large-cluster deployment based on our numbers, it is worth validating at intermediate (4-8 node) scale first.
- **Boto3 + explicit CRT config**. `s3torchconnector` already uses CRT and delivers our best measured throughput; testing boto3-with-CRT is expected to match.

## Data preparation

Before running the benchmarks, you need to populate your S3 bucket with the two datasets (or your own data if you want to test different workload shapes). Both source datasets are public.

```bash
export DEST_BUCKET=<your-bucket>  # e.g. myorg-storage-bench-<account>-<region>

# openalex: LLM-style large sequential shards (~600 GB, 2008 files, ~184 MB each)
# Source: OpenAlex parquet snapshot on the OpenAlex public S3 bucket
# Recent partitions from 2025 are a reasonable slice; adjust the date range as
# needed for your test size.
aws s3 cp --recursive --no-sign-request \
  s3://openalex/data/parquet/works/updated_date=2025-01-01/ \
  s3://${DEST_BUCKET}/openalex/updated_date=2025-01-01/
# Add more updated_date=... prefixes to grow the dataset to your target size.

# openfold-pdb: protein-structure-style small-file bundles (~644 GB, 524k files)
# Source: OpenProteinSet on the AWS Open Data registry (Requester Pays bucket)
aws s3 cp --recursive --request-payer requester \
  s3://openfold/pdb/ \
  s3://${DEST_BUCKET}/openfold-pdb/
```

For FSx-backed tests you also need FSx Data Repository Associations (DRAs) so the same S3 prefixes are visible via the FSx mount. See the AWS docs on [FSx Data Repository Associations](https://docs.aws.amazon.com/fsx/latest/LustreGuide/create-dra.html). Once the DRA is created, files hydrate on first read.

If you want to use different data (recommended, since your workload shape matters more than these specific datasets), point `S3_PREFIX` in the benchmark manifests at your own prefix. The three sample modes (`random_partial`, `whole_file`, `bundle`) let you probe different access patterns without changing the data.

## How to reproduce

Assuming the infra from [`../README.md`](../README.md) is up (2 p5e nodes in the target LZ) and PVCs `fsx-lustre-pvc`, `fsx-lz-pvc`, `s3mp-pvc` are Bound:

**Important**: the `envsubst` calls below use an explicit variable whitelist (e.g. `envsubst '$BACKEND $DATASET ...'`). Do NOT drop the whitelist — the manifests contain `$WORLD_SIZE`, `$RANK`, `$MASTER_ADDR`, `$MASTER_PORT` which must be preserved literally and only expanded by kubelet at pod runtime.

```bash
export AWS_PROFILE=<profile> AWS_DEFAULT_REGION=us-west-2
cd eks/benchmarks

# 1. Sanity-check pod (multi-backend mount check)
kubectl apply -f ../manifests/mount-check-3-backends.yaml
kubectl logs -f mount-check-3

# 2. Original T1a/T1b/T1c/T2a benchmarks (single-pod + distributed)
./run-benchmarks.sh single-pod   # 8 combinations (backend × dataset × test)
./run-benchmarks.sh t1b          # T1b distributed read

# 3. T2c training-pipeline benchmark on FUSE backends
kubectl create configmap ddp-bench-t2c-py --from-file=bench_t2c.py=./bench_t2c.py \
  --dry-run=client -o yaml | kubectl apply -f -
export BACKEND=s3mp-single DATA_PVC=s3mp-pvc DATASET=openalex
export NUM_WORKERS=4 PREFETCH_FACTOR=2 SAMPLE_MODE=random_partial STEPS=100
export JOB_SUFFIX=""
export RUNID=$(date +%Y%m%d-%H%M%S)
envsubst '$BACKEND $DATA_PVC $DATASET $NUM_WORKERS $PREFETCH_FACTOR $SAMPLE_MODE $STEPS $JOB_SUFFIX $RUNID' \
  < manifests/bench-t2c-pytorchjob.yaml | kubectl apply -f -

# 4. boto3-direct benchmark
# 4a. Create ServiceAccount with IRSA. The IAM role must trust your EKS OIDC
#     provider and grant s3:GetObject + s3:ListBucket on your bucket.
#     See s3-direct-access-guide.md for the full trust policy + permissions.
kubectl create sa boto3-bench-sa
kubectl annotate sa boto3-bench-sa \
  eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT>:role/<S3-ROLE>

# 4b. ConfigMap with the bench script
kubectl create configmap ddp-bench-boto3-py \
  --from-file=bench_boto3.py=./bench_boto3.py \
  --dry-run=client -o yaml | kubectl apply -f -

# 4c. Launch
export S3_BUCKET=<your-bucket>
export S3_PREFIX=<your-prefix>/
export DATASET=<dataset-label>
export NUM_WORKERS=8 THREADS_PER_WORKER=16 PREFETCH_FACTOR=8
export SAMPLE_MODE=bundle MIN_KEY_SIZE=0 MAX_KEYS=15000 STEPS=100
export JOB_SUFFIX="-bundle-nw8t16pf8"
export RUNID=$(date +%Y%m%d-%H%M%S)
envsubst '$S3_BUCKET $S3_PREFIX $DATASET $NUM_WORKERS $THREADS_PER_WORKER $PREFETCH_FACTOR $SAMPLE_MODE $MIN_KEY_SIZE $MAX_KEYS $STEPS $JOB_SUFFIX $RUNID' \
  < manifests/bench-boto3-pytorchjob.yaml | kubectl apply -f -

# 5. s3torchconnector benchmark (reuses boto3-bench-sa)
kubectl create configmap ddp-bench-s3tc-py \
  --from-file=bench_s3tc.py=./bench_s3tc.py \
  --dry-run=client -o yaml | kubectl apply -f -

export S3_BUCKET=<your-bucket>
export S3_PREFIX=<your-prefix>/
export DATASET=<dataset-label>
export NUM_WORKERS=32 PREFETCH_FACTOR=8 STEPS=100 MAX_KEYS=15000
export JOB_SUFFIX="-nw32pf8"
export RUNID=$(date +%Y%m%d-%H%M%S)
envsubst '$S3_BUCKET $S3_PREFIX $DATASET $NUM_WORKERS $PREFETCH_FACTOR $STEPS $MAX_KEYS $JOB_SUFFIX $RUNID' \
  < manifests/bench-s3tc-pytorchjob.yaml | kubectl apply -f -

# 6. Collect result JSONs from FSx-LZ to your laptop
./run-benchmarks.sh collect
```

## Files in this directory

| File | Purpose |
|---|---|
| `benchmark.md` | This file — experimental design and methodology |
| `benchmark-observations.md` | Point observations from one benchmark run (numbers, tuning sweep tables, disclaimers) |
| `s3-direct-access-guide.md` | Customer-facing guide for reading training data from S3 without FUSE (`s3torchconnector` or `boto3` direct) |
| `bench.py` | T1a/T1b/T1c/T2a Python driver |
| `bench_t2c.py` | DDP training-pipeline driver (FUSE-mount based) |
| `bench_boto3.py` | `boto3`-direct DDP training-pipeline driver |
| `bench_s3tc.py` | `s3torchconnector` DDP training-pipeline driver |
| `run-benchmarks.sh` | Orchestrator for T1a/T1b/T1c/T2a |
| `manifests/bench-single-pod-job.yaml` | Job template for T1a/T1c/T2a |
| `manifests/bench-fsx-lz-job.yaml` | Single-mount workaround for FSx-LZ single-pod tests |
| `manifests/bench-t1b-pytorchjob.yaml` | PyTorchJob for distributed T1b |
| `manifests/bench-t1b-fsx-lz-pytorchjob.yaml` | Single-mount variant for FSx-LZ T1b |
| `manifests/bench-t2c-pytorchjob.yaml` | T2c template (parametrized by `NUM_WORKERS`, `PREFETCH_FACTOR`, `SAMPLE_MODE`) |
| `manifests/bench-t2c-fsx-lz-pytorchjob.yaml` | T2c FSx-LZ single-mount variant |
| `manifests/bench-boto3-pytorchjob.yaml` | `boto3`-direct benchmark PyTorchJob |
| `manifests/bench-s3tc-pytorchjob.yaml` | `s3torchconnector` benchmark PyTorchJob |
| `../manifests/mount-check-3-backends.yaml` | Sanity check pod (lives in the parent `eks/manifests/` directory) |

## Interpretation guide

Once benchmark results are collected, the questions to answer are:

1. **Which backend fits the workload?**
   - `s3torchconnector` on regional S3 — best throughput on per-sample random-access workloads. Requires ~30-line DataLoader change.
   - FSx Lustre — works transparently with filesystem-based DataLoaders; throughput ceiling scales with provisioned size.
   - S3 Mountpoint (FUSE) — good for sequential-shard streaming (large files, few opens); unusable for per-sample random access on small files.

2. **What's the per-node throughput ceiling on the workload?**
   - Measured with T2c at the tuning sweet spot for each backend.
   - Compare against single-ENA network ceiling (~6 GB/s on p5e) to determine per-node headroom before hitting the network limit.

3. **How does this scale with node count?**
   - S3-based backends should scale approximately linearly with client count until each node approaches the single-ENA ceiling.
   - FSx-based backends are bounded by the provisioned filesystem throughput regardless of client count.

4. **What is the operational cost tradeoff?**
   - S3-only architecture: no CSI drivers, no PVCs, no FSx provisioning. Simpler operations.
   - FSx architecture: filesystem semantics for any client tool that expects POSIX paths, but higher $/TB and fixed capacity commitment.

## References

- Mountpoint for Amazon S3 configuration: https://github.com/awslabs/mountpoint-s3/blob/main/doc/CONFIGURATION.md
- Mountpoint for S3 multi-NIC (`--bind`, WIP): https://github.com/awslabs/mountpoint-s3/blob/main/doc/CONFIGURATION.md#using-multiple-network-cards
- s3torchconnector: https://github.com/awslabs/s3-connector-for-pytorch
- AWS Common Runtime (CRT) S3: https://github.com/awslabs/aws-c-s3
- FSx Lustre PERSISTENT_2 deployment: https://docs.aws.amazon.com/fsx/latest/LustreGuide/lustre-deployment-types.html
- AWS FSx Data Repository Associations: https://docs.aws.amazon.com/fsx/latest/LustreGuide/create-dra.html
- OpenAlex parquet dumps: https://docs.openalex.org/download-all-data/openalex-snapshot
- OpenProteinSet (openfold): https://registry.opendata.aws/openfold/
