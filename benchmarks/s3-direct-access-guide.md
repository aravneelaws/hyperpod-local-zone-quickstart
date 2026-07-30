# Reading Training Data from S3 without FUSE

This guide covers two ways to read training data from Amazon S3 directly in PyTorch training code, bypassing the S3 Mountpoint FUSE filesystem:

1. **`s3torchconnector`** — AWS's official PyTorch S3 dataset library (recommended)
2. **`boto3` direct** — raw AWS SDK with a thread pool (recommended when `s3torchconnector` doesn't fit)

Both approaches deliver 100-1000x higher throughput than S3 Mountpoint on per-sample random-access training workloads. They require modest changes to the DataLoader Dataset class in the training code (~30 lines).

## Why not S3 Mountpoint?

S3 Mountpoint exposes an S3 bucket as a POSIX filesystem via FUSE. Training code reads with normal `open()` calls, and the FUSE driver translates each call into an S3 API request under the hood.

This works well for sequential streaming of large objects. It fails for per-sample random-access workloads because:

- **FUSE metadata operations are serialized on a shared channel.** Even if 32 DataLoader worker threads try to `open()` different files concurrently, FUSE processes those `open()`s one at a time.
- **Each `open()` triggers an S3 `HeadObject` call** (~30-50 ms in a Local Zone). At best you get ~20-30 file opens per second per FUSE mount, regardless of client concurrency.
- **The AWS Common Runtime (CRT) beneath FUSE cannot help small reads.** CRT parallelizes large-object downloads via multipart GETs, but a 64 KB per-sample read is below the multipart threshold.

Bypassing FUSE and calling the S3 API directly from Python eliminates this bottleneck. Each concurrent `s3.get_object()` call is a plain HTTPS request handled by the OS network stack, which supports hundreds of concurrent in-flight requests natively.

## Approach 1: `s3torchconnector` (recommended)

`s3torchconnector` is AWS's official PyTorch S3 dataset library. It wraps the Mountpoint-S3 Rust client (which uses CRT under the hood) via PyO3 bindings and exposes it as a familiar `torch.utils.data.Dataset`.

**Pros:**
- AWS-maintained, versioned, and supported
- Uses CRT natively — same fast transfer path as S3 Mountpoint, without the FUSE layer
- Drop-in `Dataset` / `IterableDataset` replacement — plugs into standard `DataLoader`
- Handles retries, backoff, and prefix listing internally
- Minimal Python-side overhead

**Cons:**
- Only supports S3 (not other object stores)
- Uses lexical-order prefix listing; for workloads that need custom key selection logic, you have to build an index

### Install

```bash
pip install s3torchconnector
```

### Minimal example — one file per sample

Before (reads from a mounted filesystem):

```python
from pathlib import Path
from torch.utils.data import Dataset, DataLoader

class MyDataset(Dataset):
    def __init__(self, data_root):
        self.data_root = Path(data_root)
        self.file_paths = sorted(self.data_root.glob("*.parquet"))

    def __len__(self):
        return len(self.file_paths)

    def __getitem__(self, idx):
        with open(self.file_paths[idx], "rb") as f:
            data = f.read()
        return process(data)

dataset = MyDataset("/mnt/training-data")
loader = DataLoader(dataset, batch_size=32, num_workers=4)
```

After (reads directly from S3):

```python
from s3torchconnector import S3MapDataset
from torch.utils.data import Dataset, DataLoader

class MyDataset(Dataset):
    def __init__(self, bucket, prefix, region):
        self._s3 = S3MapDataset.from_prefix(
            f"s3://{bucket}/{prefix}",
            region=region,
        )

    def __len__(self):
        return len(self._s3)

    def __getitem__(self, idx):
        reader = self._s3[idx]        # S3Reader object
        data = reader.read()          # bytes
        return process(data)

dataset = MyDataset(
    bucket="my-training-bucket",
    prefix="parquet-shards/",
    region="us-west-2",
)
loader = DataLoader(dataset, batch_size=32, num_workers=32, prefetch_factor=8)
```

The only conceptual difference: instead of `open(path)`, you index into `S3MapDataset` and call `.read()` on the returned `S3Reader`.

### Example — bundle-per-sample (multiple files per training example)

Common in protein structure prediction, molecule design, and similar pipelines where one training sample is composed of several files under a shared prefix.

```python
from s3torchconnector import S3MapDataset
from torch.utils.data import Dataset

class BundleDataset(Dataset):
    """
    Each sample is a 'bundle' of N files under one protein_id/ prefix.
    Groups keys under the first path segment beneath the top-level prefix.
    """
    def __init__(self, bucket, prefix, region):
        self._bucket = bucket
        self._s3 = S3MapDataset.from_prefix(
            f"s3://{bucket}/{prefix}",
            region=region,
        )
        # Get the list of keys (in lexical order) so we can group them by
        # protein_id. S3MapDataset lists in lexical order at construction time.
        # For very large datasets, cache this list to disk after first build.
        self._bundles = self._build_bundles(prefix, region)

    def _build_bundles(self, prefix, region):
        """Group s3 dataset indices by the first path segment after prefix."""
        prefix_stripped = prefix.rstrip("/")
        # s3torchconnector doesn't expose the enumerated key list directly.
        # List keys separately via boto3; s3torchconnector uses the same
        # lexical order, so indices align.
        import boto3
        s3 = boto3.client("s3", region_name=region)
        paginator = s3.get_paginator("list_objects_v2")
        keys = []
        for page in paginator.paginate(Bucket=self._bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                keys.append(obj["Key"])

        # Group indices by first path segment beneath prefix
        groups = {}
        for i, key in enumerate(keys):
            rel = key[len(prefix_stripped):].lstrip("/")
            parts = rel.split("/")
            if len(parts) < 2:
                continue
            protein_id = parts[0]
            groups.setdefault(protein_id, []).append(i)

        return list(groups.values())

    def __len__(self):
        return len(self._bundles)

    def __getitem__(self, idx):
        bundle_indices = self._bundles[idx]
        # Read each file in the bundle. s3torchconnector handles per-request
        # concurrency internally via CRT, so sequential Python calls here
        # still overlap on the network.
        buffers = [self._s3[i].read() for i in bundle_indices]
        return process_bundle(buffers)

dataset = BundleDataset(
    bucket="my-training-bucket",
    prefix="protein-data/",
    region="us-west-2",
)
loader = DataLoader(dataset, batch_size=32, num_workers=32, prefetch_factor=8)
```

For deeper prefix hierarchies or complex grouping logic, adapt `_build_bundles()`. The pattern is: list keys once at construction, build an in-memory index of sample-id → list-of-indices, then have `__getitem__` fetch the bundle's files by index.

### DataLoader tuning knobs

Reasonable starting-point values for a bundle-per-sample workload on p5e-class hardware:

```python
DataLoader(
    dataset,
    batch_size=32,
    num_workers=32,              # ~2× GPUs on the node
    prefetch_factor=8,           # batches queued per worker
    persistent_workers=True,
    pin_memory=True,
)
```

- **`num_workers`**: too few and you're CPU-bound in the main process; too many and workers contend for CPU and connection pool.
- **`prefetch_factor`**: how many batches each worker queues ahead of the training loop. Higher = more concurrent S3 GETs in flight = higher throughput, up to a point where contention kicks in.
- **`persistent_workers=True`**: avoids re-forking workers between epochs. Important because `S3MapDataset` connection state is per-process.

**Tune empirically for your workload.** Different workload shapes (larger/smaller batches, larger/smaller files, more/fewer files per sample, different hardware) will have different optima. See [`benchmark-observations.md`](./benchmark-observations.md) for the tuning sweep we did to find the values above, and use similar methodology on your setup.

## Approach 2: `boto3` direct

Use raw `boto3` with `ThreadPoolExecutor` for concurrent range-GETs. Choose this when `s3torchconnector` doesn't fit your access pattern — for example if you need custom key selection logic that doesn't map cleanly to `from_prefix()`, or if you're on a Python version `s3torchconnector` doesn't support yet, or if you want to add local NVMe caching between S3 and your DataLoader.

**Pros:**
- Full control over which keys are fetched and how
- Works with any custom key-selection logic (metadata-driven, database-driven, etc.)
- Easy to layer caching, retries, or preprocessing on top
- Uses standard `boto3` — no additional dependency

**Cons:**
- Default `boto3` does not use CRT for small transfers (only `s3transfer` multipart uploads do). For per-sample small reads this is fine because Python overhead per GET is small compared to network latency, but for large sequential streams a CRT-based client would be faster.
- You have to write and tune the thread-pool concurrency yourself

### Install

```bash
pip install boto3
```

### Minimal example — one file per sample

```python
import boto3
import concurrent.futures
from botocore.config import Config as BotoConfig
from torch.utils.data import Dataset, DataLoader

# Per-worker state: each DataLoader worker process gets its own boto3 client
# and thread pool. Module-level dict works because torch DataLoader workers
# are separate processes.
_worker_state = {"s3": None, "pool": None}

def _worker_init(threads_per_worker=8):
    """Called by each DataLoader worker at start."""
    session = boto3.session.Session()
    _worker_state["s3"] = session.client(
        "s3",
        config=BotoConfig(
            max_pool_connections=max(50, threads_per_worker * 4),
            retries={"max_attempts": 3, "mode": "standard"},
            connect_timeout=10,
            read_timeout=30,
        ),
    )
    _worker_state["pool"] = concurrent.futures.ThreadPoolExecutor(
        max_workers=threads_per_worker,
    )

def _get_object(bucket, key):
    """Runs in worker's thread pool."""
    s3 = _worker_state["s3"]
    return s3.get_object(Bucket=bucket, Key=key)["Body"].read()

class MyDataset(Dataset):
    def __init__(self, bucket, prefix):
        self.bucket = bucket
        self.keys = self._list_keys(prefix)

    def _list_keys(self, prefix):
        # One-time key listing at construction; cache in file for large datasets.
        s3 = boto3.client("s3")
        paginator = s3.get_paginator("list_objects_v2")
        keys = []
        for page in paginator.paginate(Bucket=self.bucket, Prefix=prefix):
            keys.extend(obj["Key"] for obj in page.get("Contents", []))
        return keys

    def __len__(self):
        return len(self.keys)

    def __getitem__(self, idx):
        data = _get_object(self.bucket, self.keys[idx])
        return process(data)

# Wire into DataLoader with worker_init_fn to build per-worker state
dataset = MyDataset(bucket="my-training-bucket", prefix="parquet-shards/")
loader = DataLoader(
    dataset,
    batch_size=32,
    num_workers=8,
    prefetch_factor=8,
    persistent_workers=True,
    pin_memory=True,
    worker_init_fn=lambda _wid: _worker_init(threads_per_worker=16),
)
```

### Example — bundle-per-sample with per-sample concurrent GETs

For workloads where each sample requires reading N files, use the thread pool to fetch them concurrently within a single `__getitem__` call. Override `__getitems__` (batched fetch, Python 3.7+ compatible via monkey-patch or plain method):

```python
class BundleDataset(Dataset):
    def __init__(self, bucket, prefix):
        self.bucket = bucket
        self.bundles = self._build_bundles(prefix)  # list of [(key1, size1), (key2, size2), ...]

    def __len__(self):
        return len(self.bundles)

    def _fetch_bundle(self, idx):
        bundle = self.bundles[idx]
        pool = _worker_state["pool"]
        # Fetch all N files in the bundle concurrently
        futures = [pool.submit(_get_object, self.bucket, key) for key, _ in bundle]
        buffers = [f.result() for f in futures]
        return process_bundle(buffers)

    def __getitem__(self, idx):
        return self._fetch_bundle(idx)

    def __getitems__(self, indices):
        """DataLoader calls this if defined — batched fetch."""
        # Bundle mode already parallelizes within-sample, so sequential over batch:
        return [self._fetch_bundle(i) for i in indices]
```

### Tuning knobs

Two levels of concurrency in this pattern:

- **`num_workers`** (DataLoader): how many worker PROCESSES fetch data. Each has its own boto3 client and thread pool.
- **`threads_per_worker`**: how many concurrent S3 GETs each worker can issue simultaneously.

Total in-flight requests per rank = `num_workers * threads_per_worker * prefetch_factor * batch_size`. A reasonable starting point on p5e-class hardware:

```python
num_workers = 8
threads_per_worker = 8
prefetch_factor = 4
```

For maximum throughput on bundle workloads (with sufficient CPU headroom), push toward:

```python
num_workers = 16
threads_per_worker = 16
prefetch_factor = 8
batch_size = 32
```

Scale up if throughput isn't saturating the ENA (monitor per-node network bandwidth), and scale down if you see CPU thrashing or connection pool exhaustion errors. See [`benchmark-observations.md`](./benchmark-observations.md) for tuning sweep results on our specific test setup.

## IAM setup

Both approaches use IRSA (IAM Roles for Service Accounts). Create a ServiceAccount annotated with your IAM role ARN, and reference it in the pod spec.

### IAM role trust policy

The role must trust your EKS cluster's OIDC provider. Get the OIDC issuer:

```bash
aws eks describe-cluster --name <cluster-name> \
    --query 'cluster.identity.oidc.issuer' --output text
# outputs e.g. https://oidc.eks.us-west-2.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE
```

Trust policy (replace placeholders):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>:sub": "system:serviceaccount:<NAMESPACE>:<SA_NAME>"
        }
      }
    }
  ]
}
```

### Permissions policy

Minimum needed for reading training data:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::<BUCKET_NAME>",
        "arn:aws:s3:::<BUCKET_NAME>/*"
      ]
    }
  ]
}
```

Add `s3:PutObject` if the training code also writes checkpoints to S3.

### ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: training-sa
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/<ROLE_NAME>
```

### Reference in pod spec

```yaml
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: training-job
spec:
  pytorchReplicaSpecs:
    Master:
      template:
        spec:
          serviceAccountName: training-sa
          # ...
```

Boto3 and `s3torchconnector` will automatically pick up the IRSA credentials from the standard AWS environment variables that the EKS Pod Identity Webhook injects.

## When to pick which

**Default: `s3torchconnector`.** Simpler code, AWS-maintained, uses CRT natively, and delivers our best measured throughput on the benchmark workloads.

**Choose `boto3` direct when:**
- Your key-selection logic is too custom for `S3MapDataset.from_prefix()` (e.g. keys come from a database query, or you need custom filtering that doesn't map to a prefix)
- You want to layer local NVMe caching between S3 and the DataLoader
- You need to read from other object stores (MinIO, GCS in S3 compat mode, etc.)
- You're constrained to a Python version `s3torchconnector` doesn't support
- You want fine-grained control over retries, backoff, and connection pooling

Both approaches converge on similar throughput ceilings on our test cluster (roughly 3 GB/s per p5e node in the LZ). If in doubt, start with `s3torchconnector` and switch only if you hit a real limitation.

## Other considerations

**Checkpoint writes.** Checkpoints are typically written by rank 0 only, in a small number of large `torch.save()` calls. For this pattern, `torch.save(state_dict, "s3://bucket/checkpoint.pt")` via `smart_open` works fine, or use `s3torchconnector.S3Writer`. FSx-Lustre for checkpoints is also fine if you already have it provisioned.

**Local NVMe caching.** For multi-epoch training over data that fits in local NVMe, add a caching layer: on first fetch write the bytes to `/tmp/cache/<key>`, on subsequent fetches read from local disk. Can boost per-epoch throughput 2-5x for epochs 2+. Not built into `s3torchconnector` yet; easy to add on top of `boto3` direct.

**Per-prefix S3 request rate limits.** S3 supports 3,500 PUT and 5,500 GET requests per second per prefix. For very hot bundles (many concurrent samples reading from the same prefix), spread keys across many prefixes at data-ingest time to avoid throttling. Not an issue for the workloads we benchmarked (thousands of prefixes, requests spread evenly).

**VPC gateway endpoint.** Make sure your VPC has an S3 gateway endpoint in the same region. This routes S3 traffic over the AWS backbone rather than the internet, gives you free bandwidth (no NAT gateway data-processing charges), and higher throughput.

## References

- `s3torchconnector` on GitHub: https://github.com/awslabs/s3-connector-for-pytorch
- `s3torchconnector` docs: https://awslabs.github.io/s3-connector-for-pytorch/
- Mountpoint-S3 Rust client (used by `s3torchconnector` internally): https://github.com/awslabs/mountpoint-s3
- AWS Common Runtime S3 client: https://github.com/awslabs/aws-c-s3
- IRSA (IAM Roles for Service Accounts) docs: https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- PyTorch DataLoader tuning: https://pytorch.org/docs/stable/data.html
