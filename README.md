# HyperPod on AWS Local Zones — Quickstart

Amazon SageMaker HyperPod for GPU training clusters running in AWS Local Zones. Validated end-to-end with `ml.p5e.48xlarge` (H200 × 8, 32 EFA interfaces) in Phoenix Local Zone (`us-west-2-phx-2a`) via SageMaker Flexible Training Plans (FTP).

Two orchestrator variants (Slurm and EKS) and two IaC tools (CloudFormation and Terraform). Pick the combination that fits your team; benchmarks are separate and work with any HyperPod EKS deployment.

## Repo layout

```
/
├── cloudformation/
│   ├── eks/          ← CFN + shell scripts for HyperPod EKS
│   └── slurm/        ← CFN + shell scripts for HyperPod Slurm
├── terraform/
│   └── eks/          ← Terraform tfvars against the upstream awsome-distributed-ai reference stack
├── benchmarks/       ← Storage backend benchmarks for HyperPod EKS (deploy-agnostic within EKS)
├── README.md         ← this file
└── LICENSE           ← MIT-0
```

## Pick a deployment path

| | [CFN + Slurm](cloudformation/slurm/) | [CFN + EKS](cloudformation/eks/) | [Terraform + EKS](terraform/eks/) |
|---|---|---|---|
| **Orchestrator** | Slurm on a dedicated controller | Amazon EKS | Amazon EKS |
| **IaC** | CloudFormation + shell scripts | CloudFormation + shell scripts | Terraform (via upstream reference stack) |
| **Best for** | HPC-style workloads, sbatch habits | Kubernetes teams, container-native workflows | Teams standardized on Terraform |
| **Deploy steps** | 3 shell scripts | 4 shell scripts + optional smoke test | Clone upstream + apply with our tfvars |
| **Job submission** | `sbatch` files | `kubectl apply -f` (Kubeflow PyTorchJob) | Same as CFN + EKS once deployed |
| **Node access** | SSH via SSM | `kubectl exec` | `kubectl exec` |
| **FSx Lustre** | Parent AZ, cross-zone mounted | Parent AZ, cross-zone mounted (optional in-LZ too) | Same as CFN + EKS |
| **Validated 2-node NCCL busBw @ 16 GB** | **484 GB/s** | **479 GB/s** | Same infrastructure as CFN + EKS |
| **DDP training validated** | Yes (see [cloudformation/slurm/README.md](cloudformation/slurm/README.md#test-results-h200-p5e48xlarge-in-phoenix-local-zone)) | Yes, including checkpoint resume (see [cloudformation/eks/README.md](cloudformation/eks/README.md#test-results)) | Same underlying stack |
| **Docs** | [`cloudformation/slurm/README.md`](cloudformation/slurm/README.md) | [`cloudformation/eks/README.md`](cloudformation/eks/README.md) | [`terraform/eks/README.md`](terraform/eks/README.md) |

## How to pick

Pick **Slurm** if any of these apply:
- Your team writes sbatch scripts today
- You want the fewest moving parts and the simplest teardown
- You don't already have EKS tooling / clusters to integrate with

Pick **EKS** if any of these apply:
- You already use Kubernetes for other workloads
- You want to reuse existing container images, ArgoCD, Karpenter, Prometheus, etc.
- You want Kubeflow-style PyTorchJob / MPIJob semantics
- You need multi-tenancy on the cluster

Pick **Terraform** if you already manage AWS resources via Terraform. Otherwise CloudFormation is fine and requires no additional tooling beyond `aws` CLI.

## Storage backend benchmarks

Once you have a HyperPod EKS cluster running (via any of the paths above), the [`benchmarks/`](benchmarks/) directory contains a benchmark suite that measures storage-backend performance for realistic training workloads. Compares FSx Lustre (parent-AZ vs. in-LZ), S3 Mountpoint (FUSE), `boto3` direct SDK, and `s3torchconnector`. See:

- [`benchmarks/benchmark.md`](benchmarks/benchmark.md) — experimental design and methodology
- [`benchmarks/benchmark-observations.md`](benchmarks/benchmark-observations.md) — point observations from one benchmark run
- [`benchmarks/s3-direct-access-guide.md`](benchmarks/s3-direct-access-guide.md) — customer-facing guide for reading training data from S3 without FUSE

## Key finding: cluster nodes must be in the Local Zone subnet

For the **Slurm variant**, we found that the controller must be in the LZ subnet, same as the workers. A parent-AZ controller with LZ workers fails silently during bootstrap. See the [Slurm README](cloudformation/slurm/README.md#key-finding-keep-controller-in-the-same-subnet-as-workers) for details.

The **EKS variants** don't hit this issue because the EKS control plane is managed by AWS in parent AZs by design; only the workers live in the LZ.

## Prereqs shared across variants

1. An AWS account with SageMaker + EKS + CFN + IAM + EC2 + FSx permissions
2. An FTP purchased against `hyperpod-cluster` in the target Local Zone (2× `ml.p5e.48xlarge` for these tests)
3. Local Zone opted in via `aws ec2 modify-availability-zone-group`
4. Local tools: `aws` CLI, `session-manager-plugin`. EKS variants additionally need `helm` (>= 3) and `kubectl`. Terraform variant needs `terraform` (>= 1.5).

## License

MIT-0 — see [LICENSE](LICENSE).
