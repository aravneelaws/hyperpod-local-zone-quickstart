# Storage Backend Benchmark

Comparing storage-backend options for HyperPod training in an AWS Local Zone: FSx Lustre (parent AZ + LZ) vs. S3 Mountpoint (single-NIC + multi-NIC).

> This document covers the **experimental design, methodology, and results** only. For infra setup (VPC, EKS, PVCs, IAM), see the parent [`eks/README.md`](../README.md). Everything here assumes the cluster is already up and the PVCs are bound per the quickstart there.

## Why this benchmark exists

An AWS specialist on the account told a customer (Boltz) that on a p5e.48xlarge instance, **multi-NIC S3 Mountpoint should theoretically reach 200 Gbps (25 GB/s) reading from S3**. This benchmark is intended to empirically validate or refute that claim on real p5e hardware.

More broadly, downstream customers are choosing between:
- FSx Lustre in the LZ (recently enabled by AWS in Phoenix LZ, PERSISTENT_2 up to 250 MB/s per TiB)
- FSx Lustre in the parent AZ (cross-zone mounted from LZ workers — what customers used before LZ FSx was available)
- S3 Mountpoint (cheaper, no fixed-capacity commitment, but is it fast enough?)

We give a specific, reproducible answer for each backend against two representative workload shapes.

## What we are measuring

For each combination of **storage backend × dataset × test**, we record throughput, metadata ops/sec, and wall-clock time.

### Storage backends under test (four)

| Backend | Location | Provisioning | Mounted via PVC |
|---|---|---|---|
| Parent-AZ FSx Lustre | `us-west-2b` (LZ's parent AZ, cross-zone mounted from LZ workers) | PERSISTENT_2, 1.2 TiB @ 250 MB/s per TiB → 300 MB/s ceiling | `fsx-lustre-pvc` |
| **LZ FSx Lustre** | `us-west-2-phx-2a` (Local Zone, co-located with compute) | PERSISTENT_2, 2.4 TiB @ 250 MB/s per TiB → 600 MB/s ceiling | `fsx-lz-pvc` |
| **S3 Mountpoint, single-NIC** | Regional S3 (`us-west-2`), `aws-mountpoint-s3-csi-driver` v2.7.0, default config | Bucket `hp-eks-lz-s3mp-bench-*`, all traffic on primary ENI | `s3mp-pvc` |
| **S3 Mountpoint, multi-NIC** | Same bucket + driver, but `--bind` to 4 NICs (`eth0..eth3`) via `mountOptions` in the PV | Same bucket | `s3mp-multinic-pvc` |

**Notes:**
- FSx Lustre is not offered in most Local Zones. Phoenix is a recent exception (PERSISTENT_2 at 125 or 250 MB/s per TiB), which is why LZ FSx is a first-class backend under test.
- The **parent-AZ FSx** sits at 1.2 TiB rather than 2.4 TiB because the resize operation returned `insufficient capacity in this availability zone` twice. Its ceiling is 300 MB/s vs. LZ FSx's 600 MB/s — a real disadvantage worth noting; a real customer could hit the same.
- **Multi-NIC S3 Mountpoint** is a work-in-progress feature in `mountpoint-s3` (added in v1.9.0, still officially labeled WIP as of v1.23.0). It requires passing `--bind <IFACE>` through pod `mountOptions` in the PV spec. No AWS-published benchmark currently validates the theoretical 200 Gbps / 25 GB/s per p5e — this benchmark is intended to produce that data.

### Datasets under test (two)

Both datasets pre-loaded into the S3 Mountpoint bucket and made visible in both FSx file systems via AWS FSx Data Repository Associations. Same bytes, three different mount paths for the same content.

| Dataset | Access pattern | Size | Files | Median file size | Source |
|---|---|---|---|---|---|
| **`openalex`** | Large sequential shards (LLM/HPC-style) | ~600 GB | 2,008 | 184 MB | `s3://openalex/data/parquet/works/updated_date=2025-*` + 2026-01..05 |
| **`openfold-pdb`** | Small-file per sample (Boltz/protein-training-style) | ~644 GB | 524,453 | ~1.2 MB (4 files per PDB chain: 3 MSA hits + 1 template hits) | `s3://openfold/pdb/` |

Why two datasets: file-size distribution and access pattern dominate storage performance far more than the actual bytes. A single dataset gives a single answer. **Two datasets bracket the space** — `openalex` favors sequential-read backends (S3 Mountpoint should shine), `openfold-pdb` favors metadata-rich backends (FSx should shine).

### Tests (four)

Each test writes a structured JSON result per pod invocation to `/results/<backend>/<backend>_<dataset>_<test>_<runid>_<hostname>.json`. Post-run collection tars up the results dir for local analysis.

#### T1a — Single-pod sustained sequential read

- **What**: One pod on one node reads 4 GiB of data sequentially, 64 MiB chunks. If a single large file ≥ 512 MiB exists, reads it; otherwise reads many small files back-to-back until 4 GiB total.
- **Why**: Simulates one training worker feeding one GPU. Most basic "how fast can I stream data" test.
- **Reports**: `throughput_MBps`, `bytes_read`, `elapsed_sec`, plus a `mode` flag indicating single-large-file vs. many-small-files.

#### T1b — Distributed parallel read across 16 ranks

- **What**: A `PyTorchJob` with 2 pods (1 per node), each running `torchrun` with 8 ranks per node. Each rank sequentially reads 2 GiB from a distinct slice of the dataset (rank *i* takes every *world*-th file starting at *i*).
- **Why**: Simulates a real DDP training run where every rank pulls a different data shard. Exercises **aggregate throughput** across the cluster — the metric that most directly maps to training throughput.
- **Reports**: per-rank `throughput_MBps_per_rank`; aggregate is computed post-hoc by summing rank JSONs.

#### T1c — Single-stream 5 GiB write

- **What**: One pod writes a 5 GiB file to the backend. Uses 64 MiB chunks of precomputed random bytes. Calls `fsync()` at the end. (S3 Mountpoint no-ops fsync, which is fine — the multipart upload complete provides durability.)
- **Why**: Simulates a single-rank checkpoint save from rank 0 — the pattern used by most PyTorch training scripts today.
- **Reports**: `throughput_MBps`, `elapsed_sec`.

#### T2a — Small-file metadata operations

- **What**: One pod enumerates up to 10,000 files under the dataset root, then calls `stat()` on each. Also runs an `os.walk()` over the tree, counting up to 50,000 files.
- **Why**: The classic FSx-vs-S3 differentiator. Filesystems handle metadata operations fundamentally differently from object stores. Small-file-per-sample training pipelines (Boltz, ProteinGym, most image-classification pipelines) can be dominated by metadata cost, not I/O throughput.
- **Reports**: `stat_ops_per_sec`, `walk_files_per_sec`, `stat_errors`, wall-clock for each phase.

### What we are NOT measuring (yet)

- **End-to-end training throughput (T2c placeholder)**. One 5-epoch MLP training run per dataset+backend combo. Meaningful but adds ~1 hour per combo and depends on training script details, not just storage. Deferred to a follow-up if the four core tests leave open questions.
- **Sharded parallel checkpoint writes (T2b placeholder)**. Would use `torch.distributed.checkpoint` to write from all 16 ranks concurrently. Interesting for large-model workflows. Deferred.
- **Data hydration time from S3 into FSx via DRA**. In our setup, DRAs are `AVAILABLE` but the actual file bytes are lazy-loaded on first access from S3 into FSx. **This means the first T1a read on FSx will be slow** (network-bound, ~S3 speeds) and subsequent reads will be fast (Lustre-native). We accept this as an artifact and will note warm-vs-cold behavior in results if it shows up.
- **Cost per GB**. Spreadsheet exercise, not a benchmark.
- **Verifying that `--bind` actually distributes across NICs**. We're trusting mountpoint-s3's implementation. If multi-NIC results look identical to single-NIC, we'll investigate at that point.

## How to reproduce

Assuming the infra from [`../README.md`](../README.md) is up (2 p5e nodes, all 4 PVCs bound, all 4 DRAs `AVAILABLE`):

```bash
export AWS_PROFILE=<profile> AWS_DEFAULT_REGION=us-west-2
cd eks/benchmarks

# Sanity check first: mount 3 backends in one pod, verify each writes+reads
kubectl apply -f ../manifests/mount-check-3-backends.yaml
kubectl logs -f mount-check-3
# Expect: "ALL BACKENDS WORKING" as the last output line

# Run the single-pod tests (T1a, T1c, T2a): 8 combinations (4 backends × 2 datasets)
./run-benchmarks.sh single-pod

# Run T1b distributed read: 8 PyTorchJobs
./run-benchmarks.sh t1b

# Collect all result JSONs from FSx to laptop
./run-benchmarks.sh collect
```

Files in this directory:
- `bench.py` — Python driver, all four tests
- `manifests/bench-single-pod-job.yaml` — Job template for T1a/T1c/T2a (envsubst-templated)
- `manifests/bench-t1b-pytorchjob.yaml` — PyTorchJob for distributed T1b
- `run-benchmarks.sh` — Orchestrator: iterates backend × dataset combinations, applies templates, waits for jobs, collects results

## Results

*(Awaiting benchmark run — will be populated inline after each phase completes.)*

### T1a — Single-pod sequential read (MB/s)

| Backend | `openalex` | `openfold-pdb` |
|---|---|---|
| parent-AZ FSx | TBD | TBD |
| LZ FSx | TBD | TBD |
| S3 Mountpoint single-NIC | TBD | TBD |
| S3 Mountpoint multi-NIC | TBD | TBD |

### T1b — Distributed parallel read, aggregate MB/s across 16 ranks

| Backend | `openalex` aggregate | `openfold-pdb` aggregate |
|---|---|---|
| parent-AZ FSx | TBD | TBD |
| LZ FSx | TBD | TBD |
| S3 Mountpoint single-NIC | TBD | TBD |
| S3 Mountpoint multi-NIC | TBD | TBD (target: ~25 GB/s if colleague's claim holds) |

### T1c — Single-stream 5 GiB write (MB/s)

| Backend | `openalex` (mount) | `openfold-pdb` (mount) |
|---|---|---|
| parent-AZ FSx | TBD | TBD |
| LZ FSx | TBD | TBD |
| S3 Mountpoint single-NIC | TBD | TBD |
| S3 Mountpoint multi-NIC | TBD | TBD |

### T2a — Small-file metadata (stat ops/sec)

| Backend | `openalex` | `openfold-pdb` |
|---|---|---|
| parent-AZ FSx | TBD | TBD |
| LZ FSx | TBD | TBD |
| S3 Mountpoint single-NIC | TBD | TBD |
| S3 Mountpoint multi-NIC | TBD | TBD |

## Interpretation guide

Once results are in, we'll answer:

1. **Large-shard sequential workloads (openalex-like)** — which backend scales best in aggregate throughput? Does multi-NIC S3 Mountpoint approach or exceed FSx? Does it reach the specialist-projected 25 GB/s?
2. **Small-file-per-sample workloads (openfold-pdb-like)** — is FSx's metadata advantage decisive, or can S3 Mountpoint be workable with the right prefetching?
3. **Checkpoint writes** — is FSx materially faster than S3 for single-rank rank-0 saves? If so, does that push a customer toward sharded parallel writes as a workaround?
4. **Cost/perf tradeoff** — for a given workload shape, does the throughput difference justify FSx's higher $/GB-month? (Compared against S3 Standard pricing + Mountpoint request costs.)

Final conclusions and recommendations will be written up as a section below once results are in.

## References

- Mountpoint for Amazon S3 configuration: https://github.com/awslabs/mountpoint-s3/blob/main/doc/CONFIGURATION.md
- Mountpoint for S3 multi-NIC (`--bind`, WIP): https://github.com/awslabs/mountpoint-s3/blob/main/doc/CONFIGURATION.md#using-multiple-network-cards
- FSx Lustre PERSISTENT_2 deployment: https://docs.aws.amazon.com/fsx/latest/LustreGuide/lustre-deployment-types.html
- AWS FSx Data Repository Associations: https://docs.aws.amazon.com/fsx/latest/LustreGuide/create-dra.html
- OpenAlex parquet dumps: https://docs.openalex.org/download-all-data/openalex-snapshot
- OpenProteinSet (openfold): https://registry.opendata.aws/openfold/
