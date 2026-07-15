# HyperPod EKS on AWS Local Zones — EXPERIMENTAL / UNTESTED

> ## ⚠️ THIS VARIANT IS NOT WORKING AS-IS
>
> This directory contains a **draft** CFN template for HyperPod with EKS orchestration in a Local Zone. **Cluster creation is known to fail** because HyperPod EKS requires helm chart dependencies to be installed on the EKS cluster before the HyperPod cluster resource. This template does not install them.
>
> Do not use this as-is. It is committed as a starting point for future work.

## What's needed to make this work

The AWS reference `hyperpod-eks-full-stack.yaml` (in `aws-samples/awsome-distributed-training`) uses a nested helm-chart-injector stack that:

1. Installs the [HyperPod helm chart](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-eks-install-packages-using-helm-chart.html) which provides the nvidia-device-plugin, EFA k8s plugin, HyperPod resiliency operator, health monitoring agent, and training operator
2. Sets up Pod Identity for the various operators
3. Configures the EKS aws-auth ConfigMap so SageMaker can register HyperPod nodes

Without those, the HyperPod cluster's accelerated instance group cannot join the EKS cluster.

## What we've validated (Slurm variant)

See the [top-level README](../README.md). The Slurm variant is fully tested and working. Key HyperPod-in-LZ finding validated there: **all cluster nodes must be in the LZ subnet, not split across parent AZ + LZ**.

## Files

- `hyperpod-eks-lz-stack.yaml` — CFN template. Creates VPC (2 parent AZ subnets + 1 LZ subnet), EKS cluster, HyperPod cluster, FSx. Missing: helm chart injection.
- `deploy-eks.sh` — Deploy wrapper. Will fail without the missing steps.

## Architecture (intended)

```
VPC (10.44.0.0/16, us-west-2)              <-- Uses a different CIDR from the Slurm stack (10.42.0.0/16)
├── us-west-2a (parent AZ 1)
│   ├── public subnet    → EKS control plane, NAT
│   └── private subnet   → EKS system workers (optional)
├── us-west-2b (parent AZ 2 = LZ's parent)
│   ├── public subnet    → EKS control plane, FSx Lustre
│   └── private subnet   → EKS system workers (optional)
└── us-west-2-phx-2a (Local Zone)
    └── private subnet   → HyperPod accelerated instance group (p5e.48xlarge)
```

EKS requires 2+ parent AZs for control plane HA. The HyperPod accelerated instance group uses `OverrideVpcConfig` to place workers in the LZ subnet. This layout works for the AWS-managed EKS control plane; the HyperPod workers still need helm charts installed on the cluster before they can register.

## Contributions welcome

If you complete the helm chart injection and get this working end-to-end, please open a PR.
