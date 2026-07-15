# HyperPod on AWS Local Zones — Quickstart

Deploys a HyperPod (Slurm) cluster in an AWS Local Zone. Tested end-to-end with `p5e.48xlarge` (H200 x 8, 32 EFA interfaces) in Phoenix Local Zone (`us-west-2-phx-2a`) via SageMaker Flexible Training Plans (FTP).

## What this validates

- HyperPod Slurm clusters can run in a Local Zone (Phoenix / `us-west-2-phx-2a` tested; other LZs untested)
- p5e.48xlarge (H200) is available in PHX LZ via FTP
- 32 EFA interfaces per node enumerated and functional; 2-node NCCL all-reduce reaches **484 GB/s busBw at 16 GB** — consistent with the full multi-rail fabric being active
- FSx Lustre in the LZ's **parent AZ** (`us-west-2b`) mounts cleanly from LZ workers over cross-zone network
- SSH via SSM works
- Slurm + PyTorch DDP works out of the box

## Key finding: keep controller in the same subnet as workers

**In our testing (July 2026, us-west-2-phx-2a), the controller must be in the Local Zone subnet, not the parent AZ.** We first tried a "cross-zone" layout with controller in the parent AZ (`us-west-2b`) and workers in the LZ (`us-west-2-phx-2a`) using `OverrideVpcConfig`. The controller instance failed with no CloudWatch logs emitted, and the cluster rolled back. Workers in the LZ ran their lifecycle scripts successfully — the LZ itself was fine.

Cross-zone deployment is documented as supported by HyperPod via `OverrideVpcConfig` for standard AZs, but did not work in our LZ test. Until AWS documents this scenario as supported, put both the controller and workers in the LZ subnet. The controller can use a smaller instance type (e.g., `ml.m6i.4xlarge`) available in the LZ; it is on-demand and not billed against the FTP.

## Architecture

```
VPC (10.42.0.0/16, us-west-2)
├── Parent AZ subnet (us-west-2b, 10.42.10.0/24, public)
│   ├── NAT Gateway (for LZ egress)
│   └── FSx Lustre file system (PERSISTENT_2, 1.2 TiB)  ← cross-zone mounted from LZ
│
├── LZ subnet (us-west-2-phx-2a, 10.42.20.0/24, private)
│   ├── Controller (ml.m6i.4xlarge)   ← Slurm head node
│   ├── Worker 1 (ml.p5e.48xlarge)    ← FTP-reserved
│   └── Worker 2 (ml.p5e.48xlarge)    ← FTP-reserved
│
├── S3 gateway endpoint (both subnets)
└── Security group: all self→self (EFA); all egress to 0.0.0.0/0
```

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
- `eks/` — **EXPERIMENTAL / UNTESTED** — draft EKS variant (see `eks/README.md`)

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
2. **FSx Lustre is not available in most Local Zones.** We create FSx in the parent AZ and cross-zone mount it. Adequate for functional testing; production workloads should evaluate the I/O throughput impact.
3. **NAT Gateway in parent AZ** is required for LZ egress (S3, apt, etc.).
4. **Security group allows all egress to `0.0.0.0/0`.** Standard for HyperPod but broader than production would want; replace with VPC endpoints for a hardened deployment.
5. **Some `spank_pyxis.so` SPANK warnings** appear during `srun` — cosmetic only, safe to ignore.
6. **CUDA path is auto-detected** by all smoke tests via `/usr/local/cuda-*/efa/test-cuda-*/`. Works across DLAMI versions.
7. **EKS variant is untested and will not deploy successfully** as of this commit — it is committed as a starting point for future work. See `eks/README.md`.

## License

MIT-0 — see [LICENSE](LICENSE).
