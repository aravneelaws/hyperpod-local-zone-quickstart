# HyperPod EKS on AWS Local Zones — WORKING

Companion to the top-level Slurm variant. Deploys the same 2-node H200 topology, orchestrated by **EKS** instead of Slurm, in the Phoenix Local Zone (`us-west-2-phx-2a`).

> **Status: working end-to-end.** VPC + EKS + helm dependencies + HyperPod cluster all deploy successfully. Nodes register as k8s nodes with `Schedulable` health status. Cross-node PyTorch DDP works (rendezvous, gradient sync). NCCL falls back to TCP-over-ENA in the default container — using an AWS Deep Learning Container with `aws-ofi-nccl` baked in is expected to restore EFA multi-rail (untested).

## Architecture

```
VPC (10.44.0.0/16 primary + 10.45.0.0/16 secondary, us-west-2)
├── us-west-2a (parent AZ 1)
│   ├── public subnet     → NAT
│   └── /28 subnet        → EKS control plane ENI
├── us-west-2b (parent AZ 2 = LZ's parent)
│   ├── public subnet
│   └── /28 subnet        → EKS control plane ENI (HA)
└── us-west-2-phx-2a (Local Zone, secondary CIDR 10.45.0.0/24)
    └── worker subnet     → HyperPod accelerated instance group (ml.p5e.48xlarge x 2)
```

Key insight: **EKS control plane cannot create ENIs in a Local Zone**, so the control plane subnets must be in parent AZs. HyperPod's `AWS::SageMaker::Cluster.VpcConfig.Subnets` places workers in the LZ subnet. Workers join the EKS cluster via HyperPod-managed ENIs.

## Deploy workflow

Three stages, run in order:

```bash
export AWS_PROFILE=<your-profile>
export AWS_DEFAULT_REGION=us-west-2

# 1. Deploy infrastructure (~15 min: VPC, EKS, add-ons, IAM, S3)
./deploy-eks.sh

# 2. Install HyperPod helm dependencies (needs helm + kubectl locally)
./install-helm.sh

# 3. Create the HyperPod cluster attached to the EKS cluster
TRAINING_PLAN_NAME=<your-ftp-name> ./create-hyperpod-cluster.sh
```

Why 3 stages: the AWS reference CFN uses a Lambda-based helm installer that's currently broken (urllib3 v1 vs Python 3.12 stdlib mismatch — see `.local/context.md` in the parent repo). The AWS workshop's own "Manual HyperPod Cluster Creation" path uses the local `helm` CLI, which is simpler and works reliably.

## Prereqs

- `AWS_PROFILE` with SageMaker + EKS + CFN + IAM + EC2 permissions
- Local machine: `helm >= 3`, `kubectl`, `aws` CLI, `git`, `python3`
- FTP purchased against `hyperpod-cluster` in the target LZ (2× p5e.48xlarge for this test)
- Local Zone opted in

## Files

- `hyperpod-eks-lz-stack.yaml` — CFN template. Creates VPC, subnets (parent AZ + LZ), EKS with add-ons, IAM, S3. Does NOT install helm charts or create HyperPod cluster.
- `deploy-eks.sh` — Stage 1: deploy the CFN stack.
- `install-helm.sh` — Stage 2: install HyperPod dependencies via local helm CLI.
- `create-hyperpod-cluster.sh` — Stage 3: create the HyperPod cluster attached to EKS.
- `results/nccl-2node-eks-tcp.log` — Sample PyTorchJob output on 2 nodes × 8 GPUs. `~3.2 GB/s busBw` (TCP fallback, no aws-ofi-nccl in container).

## Verification after Stage 3

```bash
# HyperPod side
aws sagemaker list-cluster-nodes --cluster-name hp-eks-lz-cluster
# → 2 nodes, InstanceStatus.Status=Running

# Kubernetes side
kubectl get nodes --show-labels
# → 2 hyperpod-i-* nodes, label sagemaker.amazonaws.com/node-health-status=Schedulable
kubectl get pods -A | grep -E "hyperpod|health|efa|nvidia"
# → all DaemonSets 1/1 Running per node
kubectl describe node hyperpod-i-<id> | grep -E "nvidia.com/gpu|vpc.amazonaws.com/efa"
# → nvidia.com/gpu: 8, vpc.amazonaws.com/efa: 32
```

## What we tested

- **Infrastructure**: VPC (with secondary CIDR for LZ), NAT, IGW, 4 subnets across 3 AZs (2 parent + 1 LZ)
- **EKS**: 1.33 cluster with vpc-cni, kube-proxy, coredns, eks-pod-identity-agent add-ons
- **Helm chart**: `hyperpod-dependencies` release installed with 17 subcharts (nvidia-device-plugin, aws-efa-k8s-device-plugin, health-monitoring-agent, kubeflow training operator, MPI operator, cert-manager, more)
- **HyperPod cluster**: 2× ml.p5e.48xlarge in the LZ subnet, attached to EKS as `Orchestrator.Eks`
- **Node health**: both nodes `Ready` with `Schedulable` health status, GPU topology labels applied (`network-node-layer-1/2/3`, `zone-id=usw2-phx2-az1`)
- **Resource visibility**: `nvidia.com/gpu: 8` and `vpc.amazonaws.com/efa: 32` per node
- **PyTorchJob**: `nccl-2node` PyTorchJob spawns 1 Master + 1 Worker pod on separate nodes, torchrun coordinates via c10d rendezvous, 16-rank all-reduce completes

## Known gotchas

| Gotcha | Fix |
|---|---|
| EKS control plane can't be created in a Local Zone | Put EKS control-plane subnets in parent AZs; put HyperPod worker subnet in the LZ; do NOT include the LZ subnet in `AWS::EKS::Cluster.ResourcesVpcConfig.SubnetIds` |
| Reference CFN's `AvailabilityZoneId` regex rejects LZ zone IDs like `usw2-phx2-az1` | Relaxed regex: `^[a-z]{3,4}[0-9](-[a-z0-9]+)?-az[0-9]$` |
| Workshop Studio helm-install Lambda fails with urllib3 import error | Skip the Lambda entirely; use the AWS workshop's "Manual HyperPod Cluster Creation" path with local `helm` CLI |
| First helm install may hit `http2: client connection lost` mid-CRD-install | Rerun with `helm uninstall`+`kubectl delete secret sh.helm.release.v1.hyperpod-dependencies.v1`+`helm install` |
| GuardDuty auto-creates a security group in the VPC that CFN can't delete | Manually `aws ec2 delete-security-group --group-id <GuardDutyManagedSecurityGroup-*>` before stack delete |
| CFN VPC delete blocked by EKS-installed VPC endpoints leaving orphan ENIs | Manually delete VPC endpoints, wait ~60s for ENIs to release, retry stack delete |
| NCCL on EKS falls back to TCP without aws-ofi-nccl | Use an AWS Deep Learning Container image (763104351884.dkr.ecr.<region>.amazonaws.com/pytorch-training:...-efa or ...-gpu variants) that ships aws-ofi-nccl plugin |

## Teardown

```bash
aws sagemaker delete-cluster --cluster-name hp-eks-lz-cluster
aws sagemaker wait cluster-deleted --cluster-name hp-eks-lz-cluster
./deploy-eks.sh delete
```

If stack delete fails on VPC dependencies, run through the gotchas above (GuardDuty SG, VPC endpoints).
