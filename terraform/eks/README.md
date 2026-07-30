# HyperPod EKS on AWS Local Zones — Terraform Quickstart

Deploys a SageMaker HyperPod cluster orchestrated by **EKS** into an AWS Local
Zone, using the **official** [`awsome-distributed-ai`](https://github.com/awslabs/awsome-distributed-ai)
Terraform. This is the Terraform counterpart to the CloudFormation-based
[`../../cloudformation/eks/`](../../cloudformation/eks/) variant.

> Looking for the CloudFormation variants? See [`../../cloudformation/eks/`](../../cloudformation/eks/) (EKS) and
> [`../../cloudformation/slurm/`](../../cloudformation/slurm/) (Slurm).

## There is no Terraform in this directory — just a tfvars file

The entire deployment is the upstream reference stack. All this quickstart adds is
a single variable file, [`local-zone.tfvars`](local-zone.tfvars), that configures
it for a Local Zone. You clone the official repo, then run its root module with
this file:

```bash
# Sketch only — see Prerequisites and Deploy below for the full, ordered steps
# (tool versions, Local Zone opt-in, editing the tfvars for your account).

# Prereq: the helm_chart module installs from a local clone at /tmp/helm-repo.
git clone https://github.com/aws/sagemaker-hyperpod-cli.git /tmp/helm-repo

# Clone the official reference stack (this branch carries the Local Zone inputs).
git clone --branch hpeks-localzone-2026-07-29 \
  https://github.com/awslabs/awsome-distributed-ai.git
cd awsome-distributed-ai/1.architectures/7.sagemaker-hyperpod-eks/terraform-modules/hyperpod-eks-tf

# Edit local-zone.tfvars for your account (LZ AZ IDs, instance groups) first — see Deploy.
terraform init
terraform apply -var-file=/path/to/hyperpod-local-zone-quickstart/terraform/eks/local-zone.tfvars
```

This mirrors the Slurm variant's pattern (clone-official + supply config) rather
than shipping a forked or thin-wrapper stack.

### Why this works: a backward-compatible upstream input

The upstream `vpc`, `private_subnet`, and `eks_cluster` modules discover AZs with
the filter `opt-in-status = "opt-in-not-required"`, which **excludes Local Zones**
(LZs are opt-in). That single assumption was the only thing preventing the
reference stack from targeting an LZ. One root variable closes the gap, and it
defaults to standard-AZ behavior when unset, so existing deployments are unaffected:

| Variable | What it does |
|---|---|
| `private_subnet_availability_zone_ids` | Pins the HyperPod private subnets to explicit AZ **IDs** (1:1 with `private_subnet_cidrs`), including opt-in Local Zones the discovery filter would skip. Default `[]` = discover as before. |

The `private_subnet` module emits an `az_to_subnet_map` (AZ ID → subnet ID) that
the `hyperpod_cluster` module already consumes: each instance group names an
`availability_zone_id`, resolved to a subnet through that map. Pointing an
instance group's AZ ID at the LZ subnet lands its workers in the Local Zone.

> **Where this input lives:** it is on the branch
> [`hpeks-localzone-2026-07-29`](https://github.com/awslabs/awsome-distributed-ai/tree/hpeks-localzone-2026-07-29/1.architectures/7.sagemaker-hyperpod-eks/terraform-modules)
> of `awsome-distributed-ai` (commit `d24a5bb`), pending merge into `main`. The
> clone command above checks out that branch, so no hand-patching is needed. The
> branch adds two backward-compatible inputs — the `private_subnet` module's
> `availability_zone_ids` variable (used here) and a root `fsx_availability_zone_id`
> override for placing FSx in a parent AZ (**not** used here; see the FSx note
> below). Once merged into `main`, drop the `--branch` flag.

### Architecture

```
VPC (10.192.0.0/16 primary + 10.1.0.0/16 secondary CIDR; us-west-2)
├── Parent AZ 1 (us-west-2a)
│   ├── public subnet          → NAT Gateway
│   └── EKS control-plane /28   → EKS control plane ENI
├── Parent AZ 2 (us-west-2b)
│   └── EKS control-plane /28   → EKS control plane ENI (HA)
└── Local Zone (us-west-2-phx-2a, usw2-phx2-az1, secondary CIDR 10.1.0.0/16)
    └── worker subnet           → HyperPod instance group (nodes land here)
```

Key constraint: **the EKS control plane cannot create ENIs in a Local Zone.**
Control-plane subnets stay in parent AZs; only the HyperPod workers live in the LZ.
The worker subnet CIDR is associated as its own secondary VPC block.

> **NAT Gateway placement.** The upstream `vpc` module creates a single NAT Gateway
> in `public_subnet_1`, whose AZ is chosen by **AZ name** order (`us-west-2a`) — a
> standard region AZ, never the Local Zone. LZ workers reach it via the private
> route table's `0.0.0.0/0 → NAT` route, so egress is `LZ → region NAT → internet`.
> Whether that NAT lands in the LZ's **parent** AZ is not guaranteed: AZ name↔ID
> mapping is randomized per account (e.g. here `us-west-2a == usw2-az2`, which *is*
> the parent, but another account may differ). A non-parent NAT adds one
> intra-region cross-AZ hop — small, and not tunable from tfvars (the public-subnet
> AZ is hardcoded in the module). The larger lever is `create_vpc_endpoints_module`
> (enabled here), which keeps S3/ECR/STS traffic off the NAT path entirely.

> **No FSx filesystem here.** FSx for Lustre is not offered in most Local Zones,
> and mounting it cross-AZ from a parent AZ is not recommended (latency +
> cross-zone data transfer). This quickstart provisions no FSx filesystem —
> `create_new_fsx_filesystem` stays at its upstream default (`false`), so no
> filesystem, PV, PVC, or StorageClass is created. (The upstream `create_fsx_module`
> default of `true` still installs the idle FSx CSI driver + IAM role; that's
> harmless and left as-is to keep the diff minimal.) For shared storage, prefer
> an in-zone option or stage data separately. The upstream branch does carry an
> `fsx_availability_zone_id` override for the cross-AZ case if you decide you need it.

## Prerequisites

1. **Tools:** Terraform >= 1.14, `aws` CLI, `kubectl`, `helm` >= 3, `git`.
2. **AWS:** credentials with SageMaker + EKS + IAM + EC2 + S3 permissions.
3. **Local Zone opted in:**
   ```bash
   aws ec2 modify-availability-zone-group \
     --group-name us-west-2-phx-2a --opt-in-status opted-in
   ```
   Opt-in is asynchronous — verify it reports `opted-in` before deploying (a
   not-yet-opted-in zone makes the private subnet fail to create):
   ```bash
   aws ec2 describe-availability-zones --all-availability-zones \
     --filters Name=zone-id,Values=usw2-phx2-az1 \
     --query "AvailabilityZones[].[ZoneName,ZoneId,OptInStatus]" --output table
   ```
   > First time in a zone group you may hit `InvalidAZGroup.NotFound` ("you must
   > request access"). Some Local Zones require requesting access via the AWS
   > console (EC2 → Zones, or the Local Zones signup form) before the opt-in call
   > succeeds.
4. **FTP (recommended):** a Flexible Training Plan purchased for p5e capacity in
   the target LZ. Set `training_plan_arn` on the instance group in the tfvars.
5. **Helm repo checkout** — the upstream `helm_chart` module installs from a local
   clone at `/tmp/helm-repo`, checked out at the same revision as
   `helm_repo_revision`:
   ```bash
   git clone https://github.com/aws/sagemaker-hyperpod-cli.git /tmp/helm-repo
   ```

## Deploy

```bash
# 1. Look up your Local Zone's AZ IDs (ZoneId + ParentZoneName)
aws ec2 describe-availability-zones --all-availability-zones \
  --query "AvailabilityZones[?ZoneType=='local-zone'].[ZoneName,ZoneId,ParentZoneName]" \
  --output table

# 2. Copy local-zone.tfvars and edit it for your account:
#    - private_subnet_availability_zone_ids    = [<lz-az-id>]
#    - instance_groups[].availability_zone_id  = <lz-az-id>
#    - instance_groups[].training_plan_arn     (recommended)

# 3. From the upstream root, deploy with the file:
cd awsome-distributed-ai/1.architectures/7.sagemaker-hyperpod-eks/terraform-modules/hyperpod-eks-tf
terraform init
terraform plan  -var-file=/path/to/local-zone.tfvars
terraform apply -var-file=/path/to/local-zone.tfvars

# 4. Configure kubectl (terraform prints the exact command as an output)
$(terraform output -raw configure_kubectl_command)
```

## Verify

```bash
# HyperPod side
aws sagemaker list-cluster-nodes --cluster-name "$(terraform output -raw hyperpod_cluster_name)"

# Kubernetes side
kubectl get nodes --show-labels          # hyperpod-i-* nodes, Schedulable
kubectl describe node <hyperpod-i-...> | grep -E "nvidia.com/gpu|vpc.amazonaws.com/efa"
```

For EFA/NCCL and DDP smoke tests, the manifests in [`../../cloudformation/eks/manifests/`](../../cloudformation/eks/manifests/)
apply unchanged (same cluster shape, same pod-spec requirements — see the
CloudFormation EKS README's "Key pod-spec requirements for EFA on HyperPod EKS").

## Local Zone gotchas

These are the non-obvious ways a Local Zone deploy fails. All were hit during a
real end-to-end verification in Phoenix (`usw2-phx2-az1`).

| Symptom | Cause & fix |
|---|---|
| Instance group fails with **"Failed to process Instance Group Network Configuration details"** (VPC/EKS all succeed; EC2 dry-run shows capacity is fine) | **Not every Local Zone is HyperPod-supported.** This is a HyperPod service-side rejection of the LZ, not a capacity or Terraform issue. There is no API to enumerate supported LZs — confirm with the HyperPod team. In us-west-2, only `usw2-phx2-az1` (Phoenix) is supported; `usw2-lax1-az1` (LA) is not. |
| `terraform plan` rejects the instance type, or the cluster is created with no eligible type | **The type must clear two gates:** (a) offered in the LZ — `aws ec2 describe-instance-type-offerings --location-type availability-zone-id --filters Name=location,Values=<lz-az-id>`; and (b) in HyperPod's `ClusterInstanceType` enum. e.g. `ml.m5.2xlarge` is in the enum but not offered in Phoenix; `ml.c6i.2xlarge` clears both. |

## Configuration surface

[`local-zone.tfvars`](local-zone.tfvars) **is** the upstream
`hyperpod-eks-tf/terraform.tfvars` example with the minimal Local-Zone edits
layered on — every changed line is tagged `# LZ:`, so
`diff terraform.tfvars local-zone.tfvars` shows exactly what a Local Zone
requires. Those edits are:

| Variable | Local-Zone change |
|---|---|
| `private_subnet_cidrs` | Trimmed to a single worker subnet CIDR (a secondary VPC block) |
| `private_subnet_availability_zone_ids` | **Added** — `[<lz-az-id>]`, 1:1 with the CIDR; bypasses the AZ-discovery filter |
| `instance_groups[].availability_zone_id` | Set to the **LZ** AZ ID — lands workers in the Local Zone |
| `instance_groups[].training_plan_arn` | Commented example — FTP ARN for reserved LZ capacity (recommended) |

Everything else (region, VPC/EKS CIDRs, helm, IAM, S3, cluster name) is stock
upstream and can be tuned as usual.

## Teardown

```bash
terraform destroy -var-file=/path/to/local-zone.tfvars
```

If destroy stalls on VPC dependencies (GuardDuty-managed SG, EKS-installed VPC
endpoints leaving orphan ENIs), see the "Known gotchas" table in
[`../../cloudformation/eks/README.md`](../../cloudformation/eks/README.md) — the same manual cleanups apply.
