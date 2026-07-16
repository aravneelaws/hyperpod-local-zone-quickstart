# HyperPod on AWS Local Zones — Quickstart

Amazon SageMaker HyperPod for GPU training clusters running in AWS Local Zones. Validated end-to-end with `ml.p5e.48xlarge` (H200 × 8, 32 EFA interfaces) in Phoenix Local Zone (`us-west-2-phx-2a`) via SageMaker Flexible Training Plans (FTP).

Two orchestrator variants: **Slurm** and **EKS**. Both share the same architectural pattern (EFA workers in the LZ, FSx Lustre in the parent AZ, cross-zone mounted).

Everything you need to reproduce the deployment lives in this repo: CloudFormation templates, deploy scripts, smoke tests, and sample results from a working run.

## Variants

| | [Slurm](slurm/) | EKS |
|---|---|---|
| **Status** | Validated end-to-end | Coming in a follow-up (see [`eks/`](eks/) for the in-progress placeholder) |
| **Orchestrator** | Slurm on a dedicated controller instance | Amazon EKS (managed by AWS) |
| **Best for** | HPC-style workloads, `sbatch` habits, minimal moving parts | Kubernetes teams, container-native workflows |
| **Deploy steps** | 3 shell scripts | 4 shell scripts + optional smoke test |
| **Job submission** | `sbatch` sbatch files | `kubectl apply -f` (Kubeflow PyTorchJob) |
| **Node access** | SSH via SSM | `kubectl exec` |
| **FSx Lustre** | Yes, in parent AZ, cross-zone mount | Yes, in parent AZ, cross-zone mount |
| **Validated 2-node NCCL busBw @ 16 GB** | **484 GB/s** | 479 GB/s (in progress) |
| **Docs** | [`slurm/README.md`](slurm/README.md) | [`eks/README.md`](eks/README.md) |

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

## Key finding: cluster nodes must be in the Local Zone subnet

For the **Slurm variant**, we found that the controller must be in the LZ subnet, same as the workers. A parent-AZ controller with LZ workers fails silently during bootstrap. See the [Slurm README](slurm/README.md#key-finding-keep-controller-in-the-same-subnet-as-workers) for details.

The **EKS variant** doesn't hit this issue because the EKS control plane is managed by AWS in parent AZs by design; only the workers live in the LZ.

## Prereqs shared across variants

1. An AWS account with SageMaker + EKS + CFN + IAM + EC2 + FSx permissions
2. An FTP purchased against `hyperpod-cluster` in the target Local Zone (2× `ml.p5e.48xlarge` for these tests)
3. Local Zone opted in via `aws ec2 modify-availability-zone-group`
4. Local tools: `aws` CLI, `session-manager-plugin`. EKS variant additionally needs `helm` (>= 3) and `kubectl`.

## Repo layout

```
/
├── README.md          ← this file
├── LICENSE            ← MIT-0
├── slurm/             ← Slurm variant (CFN + scripts + smoke tests + sample results)
│   └── README.md
└── eks/               ← EKS variant
    └── README.md
```

## License

MIT-0 — see [LICENSE](LICENSE).

