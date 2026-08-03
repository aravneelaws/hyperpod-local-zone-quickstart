# HyperPod Slurm on AWS Local Zones — Quickstart

Deploys a HyperPod (Slurm) cluster in an AWS Local Zone. Tested end-to-end with `p5e.48xlarge` (H200 x 8, 32 EFA interfaces) in Phoenix Local Zone (`us-west-2-phx-2a`) via SageMaker Flexible Training Plans (FTP).

> Looking for the **EKS variant**? See [`../eks/`](../eks/). For the **Terraform** counterpart to the EKS variant, see [`../../terraform/eks/`](../../terraform/eks/).

## What this validates

- HyperPod Slurm clusters can run in a Local Zone (Phoenix / `us-west-2-phx-2a` tested; other LZs untested)
- p5e.48xlarge (H200) is available in PHX LZ via FTP
- 32 EFA interfaces per node enumerated and functional; 2-node NCCL all-reduce reaches **484 GB/s busBw at 16 GB** — consistent with the full multi-rail fabric being active
- FSx Lustre in the LZ's **parent AZ** (`us-west-2b`) mounts cleanly from LZ workers over cross-zone network (July 2026 baseline). Template now also supports FSx **in the LZ** for co-located storage — see `FsxLocation` below.
- Template now supports **`LocalZoneEgress=true`** for LZ-local internet egress instead of hairpinning through the parent Region (validated in LAX for the EKS variant; same CFN mechanism)
- SSH via SSM works
- Slurm + PyTorch DDP works out of the box

## Key finding: keep controller in the same subnet as workers

**In our testing (July 2026, us-west-2-phx-2a), the controller must be in the Local Zone subnet, not the parent AZ.** We first tried a "cross-zone" layout with controller in the parent AZ (`us-west-2b`) and workers in the LZ (`us-west-2-phx-2a`) using `OverrideVpcConfig`. The controller instance failed with no CloudWatch logs emitted, and the cluster rolled back. Workers in the LZ ran their lifecycle scripts successfully — the LZ itself was fine.

Cross-zone deployment is documented as supported by HyperPod via `OverrideVpcConfig` for standard AZs, but did not work in our LZ test. Until AWS documents this scenario as supported, put both the controller and workers in the LZ subnet. The controller can use a smaller instance type (e.g., `ml.m6i.4xlarge`) available in the LZ; it is on-demand and not billed against the FTP.

## Architecture

Two supported topologies. The default (`LocalZoneEgress=false`) matches the layout used by our July 2026 validation runs. `LocalZoneEgress=true` adds an LZ-local NAT so LZ workers egress directly instead of hairpinning through the parent Region.

**Default topology (`LocalZoneEgress=false`, shipped default):**

```
VPC (10.42.0.0/16, us-west-2)
├── Parent AZ subnet (us-west-2b, 10.42.10.0/24, public)
│   ├── NAT Gateway (LZ workers egress via this NAT, ~24-35 ms hairpin)
│   └── FSx Lustre file system (when FsxLocation=parent, default; cross-zone mounted)
│
├── LZ subnet (us-west-2-phx-2a, 10.42.20.0/24, private)
│   ├── Controller (ml.m6i.4xlarge)   ← Slurm head node
│   ├── Worker 1 (ml.p5e.48xlarge)    ← FTP-reserved
│   └── Worker 2 (ml.p5e.48xlarge)    ← FTP-reserved
│
├── S3 gateway endpoint (parent public RT + LZ private RT)
└── Security group: all self→self (EFA); all egress to 0.0.0.0/0
```

**LZ-egress topology (`LocalZoneEgress=true`, recommended):**

```
VPC (10.42.0.0/16, us-west-2)
├── Parent AZ subnet (us-west-2b, public)
│   └── NAT Gateway  ← retained but unused for LZ egress
│
├── LZ public subnet (us-west-2-phx-2a, 10.42.30.0/24, public)
│   └── LZ NAT Gateway with border-group EIP (first hop ~0.1 ms)
│
├── LZ private subnet (us-west-2-phx-2a, 10.42.20.0/24, private)
│   ├── Controller (ml.m6i.4xlarge)
│   ├── Worker 1 (ml.p5e.48xlarge)
│   ├── Worker 2 (ml.p5e.48xlarge)
│   └── FSx Lustre (when FsxLocation=lz; in-LZ, co-located)
│
└── S3 gateway endpoint (parent + LZ private + LZ public route tables)
```

## Local Zone egress (`LocalZoneEgress`)

By default, the LZ private subnet's `0.0.0.0/0` route points at a NAT gateway in the parent AZ. Every packet hairpins across the region link before touching the public internet. Measured in LAX (2026-08-03, EKS variant, same network topology at the CFN layer): traceroute hop 1 = 23.8 ms, Cloudflare 25 MB download 44 MB/s, PyPI index fetch 797 ms. The Slurm variant inherits the same architectural bug because it inherits the same NAT-in-parent-AZ pattern.

`LocalZoneEgress=true` adds an LZ-local NAT gateway with a `NetworkBorderGroup`-scoped EIP and an LZ public subnet, and points the LZ private subnet's default route at the LZ NAT. Same LAX rig (single-variable A/B):

| Metric | Off (default) | On | Improvement |
|---|---:|---:|---:|
| Traceroute hop 1 | 23.8 ms | **0.095 ms** | 250× |
| PyPI TTFB | 111 ms | **17 ms** | 6.5× |
| PyPI throughput | 56 MB/s | **311 MB/s** | 5.6× |
| Cloudflare 25 MB total | 565 ms | **132 ms** | 4.3× |
| Ubuntu InRelease total | 1,535 ms | **567 ms** | 2.7× |

Enable it by setting three parameters:

```bash
aws cloudformation deploy \
  --template-file cloudformation/slurm/hyperpod-lz-stack.yaml \
  --stack-name hyperpod-phx-lz \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    LocalZoneEgress=true \
    LocalZone=us-west-2-phx-2a \
    NetworkBorderGroup=us-west-2-phx-2 \
    LzPublicSubnetCidr=10.42.30.0/24     # optional; default matches this
```

**Why `NetworkBorderGroup` is a separate parameter:** the EIP for an LZ NAT must be allocated in the LZ's border group (a plain vpc-scoped EIP will not attach). The border group is the LZ zone name minus the trailing zone letter (`us-west-2-phx-2a` → `us-west-2-phx-2`), but CFN string functions cannot reliably suffix-strip on multi-letter zone names (`us-west-2-lax-1a` breaks a naive `!Split ['a', ...]`), so it's passed explicitly.

**What LZ egress does not fix.** The scope is public-internet egress from the LZ private subnet. It does not affect DNS resolution paths, cross-zone FSx syscalls, or Slurm↔controller latency (that's intra-VPC and already fast). Origin-anchored services (GitHub, HuggingFace) improved only ~5% in our measurements — those are dominated by CDN routing, not our egress path.

## FSx location (`FsxLocation`)

The template supports three placements, mirroring the EKS variant:

| `FsxLocation` | Where | When to use |
|---|---|---|
| `parent` (default) | Parent AZ subnet | LZs that do not offer FSx Lustre, or offer only tiers your workload can't use |
| `lz` | LZ private subnet | Recommended when the target LZ supports it. FSx co-located with compute; no cross-zone latency. |
| `none` | No filesystem provisioned | Bring your own, or run without shared storage |

**Per-LZ FSx portability.** Not every LZ offers PERSISTENT_2 or a modern Lustre server version. Verified per-LZ status:

| LZ | PERSISTENT_2 offered? | Notes |
|---|---|---|
| Phoenix (`usw2-phx2-az1`) | **Yes** | Validated with 1.2 TiB @ 250 MB/s per TiB. Our earlier EKS benchmarks show 21× DDP read speedup vs cross-zone parent-AZ FSx. |
| LAX (`usw2-lax1-az1`) | **No** | CFN rejects with `"The requested Lustre configuration: PERSISTENT_2 is not available in this availability zone."` PERSISTENT_1 is offered but runs Lustre server 2.10.5, incompatible with the AL2023-bundled 2.15.6 client (verified 2026-08-03). |

If deploying to a non-Phoenix LZ with `FsxLocation=lz`, verify PERSISTENT_2 availability first or expect create-time failures. Fall back to `FsxLocation=parent` for cross-zone mount, or `FsxLocation=none` to bring your own storage.

**Legacy input (`CreateFsx`).** Still honored for backward compatibility when `FsxLocation=parent` (default). Deploying with the shipped defaults today reproduces the old behavior exactly: one parent-AZ FSx, no LZ FSx.

## Recommended deploy (LZ-egress + in-LZ FSx)

For a HyperPod-supported LZ that offers FSx PERSISTENT_2 (Phoenix today):

```bash
export AWS_PROFILE=<your-profile>
export AWS_DEFAULT_REGION=us-west-2

# Deploy with LZ egress + FSx co-located in the LZ
aws cloudformation deploy \
  --template-file cloudformation/slurm/hyperpod-lz-stack.yaml \
  --stack-name hyperpod-phx-lz \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    LocalZoneEgress=true \
    LocalZone=us-west-2-phx-2a \
    NetworkBorderGroup=us-west-2-phx-2 \
    FsxLocation=lz

# Continue with the standard stages
./upload-lifecycle.sh
export TRAINING_PLAN_NAME=my-training-plan
./create-cluster.sh
./verify-cluster.sh
```

The `LocalZoneEgress` and `FsxLocation` settings are independent from the "controller in LZ subnet" requirement documented above — those are network-layer topology; controller placement is a HyperPod cluster-configuration concern set in `create-cluster.sh`.

## Test results (H200 p5e.48xlarge in Phoenix Local Zone)

**Single-node NCCL all-reduce (8 GPUs, NVSwitch only):**

| Size | busBw (GB/s) |
|---|---|
| 1 GB | 458 |
| 2 GB | 462 |
| 4 GB | 476 |

**2-node NCCL all-reduce (16 GPUs, cross-node via EFA):**

| Size | busBw (GB/s) |
|---|---|
| 1 GB | 442 |
| 4 GB | 465 |
| 8 GB | 479 |
| 16 GB | 484 |

**PyTorch DDP training (2 nodes × 8 GPUs = 16 GPUs, ~440M-parameter MLP on synthetic data):**

- 100 training steps in **3.2 seconds**
- **16,239 samples/sec** across 16 GPUs
- torch 2.6.0 + cu124, NCCL 2.21.5
- Confirms the full stack works: Slurm + torchrun c10d rendezvous + NCCL + EFA all functional

Raw output logs are in `results/`.

## Tip: install venv on instance NVMe, not FSx

Installing PyTorch to FSx Lustre from the LZ took over 20 minutes and eventually timed out our Slurm job. FSx Lustre is optimized for large sequential I/O; pip installs are dominated by tens of thousands of small-file operations (creation of `.py`, `.dist-info`, metadata files) which stress the FSx metadata target. Cross-zone latency (LZ ↔ parent AZ) compounds the per-syscall overhead.

Installing the same venv to `/opt/dlami/nvme/` (local NVMe on each p5e.48xlarge node) took approximately 3 minutes. Use FSx only for **shared** data (datasets, checkpoints, training scripts):

```bash
srun -N $NODES --gres=gpu:1 bash -c '
  VENV=/opt/dlami/nvme/venv-ddp
  [ ! -d "$VENV/lib/python3.10/site-packages/torch" ] && {
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install torch torchvision --index-url https://download.pytorch.org/whl/cu124
  }
'
```

## Prereqs

1. `AWS_PROFILE` with SageMaker + IAM + CFN + EC2 + FSx permissions
2. FTP purchased against `hyperpod-cluster` in the target LZ (defaults in scripts assume `us-west-2-phx-2a`; override for other LZs)
3. Local Zone opted in (`aws ec2 modify-availability-zone-group`)
4. Local machine: [`session-manager-plugin`](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for SSM

## Files

- `hyperpod-lz-stack.yaml` — CloudFormation template
- `deploy.sh` — Deploy VPC/subnets/SG/IAM/S3/FSx (~10 min)
- `upload-lifecycle.sh` — Push AWS reference lifecycle scripts + patched `provisioning_parameters.json` to S3
- `create-cluster.sh` — Submit `create-cluster` API call, referencing the FTP by name
- `verify-cluster.sh` — Show status, list nodes, print SSH command
- `smoke-tests/` — sbatch scripts for NCCL 1-node, NCCL 2-node, PyTorch DDP
- `results/` — Sample NCCL and DDP logs from a working run in PHX LZ

## Run sequence

```bash
export AWS_PROFILE=<your-profile>
export AWS_DEFAULT_REGION=us-west-2

# 1. Deploy infra (~10 min)
./deploy.sh

# 2. Upload lifecycle + provisioning_parameters.json
./upload-lifecycle.sh

# 3. Create the cluster (~15 min to InService).
# Set TRAINING_PLAN_NAME to your FTP name; the script looks up its ARN and attaches it.
export TRAINING_PLAN_NAME=my-training-plan
./create-cluster.sh

# 4. Verify + SSH
./verify-cluster.sh
```

### SSH to the controller

Add an entry to `~/.ssh/config` that proxies through SSM (`session-manager-plugin` required):

```
Host hyperpod-phx-lz-cluster
    User ubuntu
    ProxyCommand aws ssm start-session --target sagemaker-cluster:CLUSTER_ID_controller-machine-INSTANCE_ID --document-name AWS-StartSSHSession --parameters "portNumber=%p"
    StrictHostKeyChecking no
```

Then push your public key to the controller once (via SSM), and run `ssh hyperpod-phx-lz-cluster`.
`verify-cluster.sh` prints the exact `sagemaker-cluster:...` target string for your deployment.

## Parameterizing for other Local Zones

Edit `hyperpod-lz-stack.yaml` parameters:
- `LocalZone` → e.g., `us-east-1-bos-1a` for Boston (untested)
- `ParentAz` → the LZ's parent AZ (`aws ec2 describe-availability-zones --all-availability-zones`)
- Update `create-cluster.sh` worker instance type if the LZ doesn't offer p5e

## Teardown

```bash
aws sagemaker delete-cluster --cluster-name hyperpod-phx-lz-cluster
aws sagemaker wait cluster-deleted --cluster-name hyperpod-phx-lz-cluster
./deploy.sh delete
```

`deploy.sh delete` will refuse to run if the HyperPod cluster still exists.

## Known caveats

1. **Controller must be in the LZ subnet** in our test — see "Key finding" above. AWS documentation shows cross-zone as supported for standard AZs; treat this as a validated workaround for LZ deployments.
2. **FSx-in-LZ is per-LZ.** Phoenix supports PERSISTENT_2 (validated); LAX does not (`"The requested Lustre configuration: PERSISTENT_2 is not available in this availability zone."`) and LAX's PERSISTENT_1 runs Lustre server 2.10.5 which is incompatible with the AL2023-bundled 2.15.6 client. See the `FsxLocation` section for the fallback pattern.
3. **`LocalZoneEgress=true` requires an explicit `NetworkBorderGroup`.** It's the LZ zone name minus the trailing letter (`us-west-2-phx-2a` → `us-west-2-phx-2`). Without it, the EIP is region-scoped and the LZ NAT create fails with `"EIP is not associated with the border group of the subnet"`.
4. **Default egress hairpin.** With `LocalZoneEgress=false` (default), LZ workers reach the internet via the parent-AZ NAT — ~24-35 ms per packet. `LocalZoneEgress=true` fixes this; see the LZ egress section above.
5. **Security group allows all egress to `0.0.0.0/0`.** Standard for HyperPod but broader than production would want; replace with VPC endpoints for a hardened deployment.
6. **GuardDuty auto-injects a VPC endpoint + security group** in the VPC that CFN can't delete on teardown. Manually `aws ec2 delete-vpc-endpoints --vpc-endpoint-ids <vpce-...>` and `aws ec2 delete-security-group --group-id <GuardDutyManagedSecurityGroup-*>` before retrying stack delete.
7. **Some `spank_pyxis.so` SPANK warnings** appear during `srun` — cosmetic only, safe to ignore.
8. **CUDA path is auto-detected** by all smoke tests via `/usr/local/cuda-*/efa/test-cuda-*/`. Works across DLAMI versions.

## License

MIT-0 — see [LICENSE](../../LICENSE).
