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

### Why this works: three backward-compatible upstream inputs

The upstream `vpc`, `private_subnet`, and `eks_cluster` modules discover AZs with
the filter `opt-in-status = "opt-in-not-required"`, which **excludes Local Zones**
(LZs are opt-in). That was the first assumption preventing the reference stack
from targeting an LZ. The second was NAT gateway placement — by default the
module pins the regional NAT to a standard AZ, so LZ workers hairpin every
packet ~24-35 ms across the region link. Three inputs close both gaps; all
default to standard-AZ behavior when unset, so existing deployments are unaffected:

| Variable | What it does |
|---|---|
| `private_subnet_availability_zone_ids` | Pins the HyperPod private subnets to explicit AZ **IDs** (1:1 with `private_subnet_cidrs`), including opt-in Local Zones the discovery filter would skip. Default `[]` = discover as before. |
| `local_zone_egress_zone_ids` | List of LZ AZ IDs that get an LZ-local NAT gateway. Default `[]` = no LZ NATs (workers use regional NAT, ~24-35 ms hairpin). |
| `local_zone_public_subnet_cidrs` | LZ public subnet CIDRs, 1:1 with the above. Typically carved from the VPC primary CIDR. |
| `local_zone_network_border_groups` | NetworkBorderGroup names for the LZ NAT EIPs, 1:1 with the zone IDs. Required — a plain vpc-scoped EIP cannot attach to a NAT in an LZ subnet. |

The `private_subnet` module emits an `az_to_subnet_map` (AZ ID → subnet ID) that
the `hyperpod_cluster` module already consumes: each instance group names an
`availability_zone_id`, resolved to a subnet through that map. Pointing an
instance group's AZ ID at the LZ subnet lands its workers in the Local Zone.

The `vpc` module additionally emits `nat_gateway_ids_by_zone_id` (AZ ID → NAT ID),
which the `private_subnet` module consumes to route matching subnets to their
LZ-local NAT instead of the regional NAT.

> **Where these inputs live:** on the branch
> [`hpeks-localzone-2026-07-29`](https://github.com/awslabs/awsome-distributed-ai/tree/hpeks-localzone-2026-07-29/1.architectures/7.sagemaker-hyperpod-eks/terraform-modules)
> of `awsome-distributed-ai`. The `private_subnet_availability_zone_ids` input
> is at commit `d24a5bb` (LZ private subnet, pending merge into `main`). The
> three `local_zone_*` egress inputs are the follow-up patch validated in LAX
> on 2026-08-03 — see [`local-zone.tfvars`](local-zone.tfvars) for use, and
> the LAX A/B numbers in the [Configuration surface](#configuration-surface)
> section below for the measured evidence. The clone command above checks out
> the current branch; once fully merged into `main`, drop the `--branch` flag.

### Architecture

```
VPC (10.192.0.0/16 primary + 10.1.0.0/16 secondary CIDR; us-west-2)
├── Parent AZ 1 (us-west-2a)
│   ├── public subnet          → regional NAT Gateway
│   └── EKS control-plane /28   → EKS control plane ENI
├── Parent AZ 2 (us-west-2b, LZ parent)
│   └── EKS control-plane /28   → EKS control plane ENI (HA)
└── Local Zone (us-west-2-phx-2a, usw2-phx2-az1, secondary CIDR 10.1.0.0/16)
    ├── LZ public subnet        → LZ NAT Gateway (only if local_zone_egress_zone_ids is set)
    └── worker subnet           → HyperPod instance group (routes to LZ NAT if enabled, else regional NAT)
```

Key constraint: **the EKS control plane cannot create ENIs in a Local Zone.**
Control-plane subnets stay in parent AZs; only the HyperPod workers live in the LZ.
The worker subnet CIDR is associated as its own secondary VPC block.

> **NAT Gateway placement — the LZ egress fix.** By default the upstream
> `vpc` module creates a single regional NAT Gateway in `public_subnet_1`,
> whose AZ is chosen by AZ-name order (typically `us-west-2a`). LZ workers
> reach it via the private route table's `0.0.0.0/0 → NAT` route, so egress
> takes the path `LZ → regional NAT → internet` and pays a ~24-35 ms
> cross-region hop per packet (measured LAX→parent-AZ 23.8 ms;
> customer-observed Phoenix→parent-AZ ~35 ms).
>
> Set the three `local_zone_*` variables in [`local-zone.tfvars`](local-zone.tfvars)
> to add an LZ-local NAT gateway with a border-group-scoped EIP. Measured
> impact (LAX, 2026-08-03, single-variable A/B):
>
> | | Regional NAT (default) | LZ-local NAT |
> |---|---:|---:|
> | Traceroute hop 1 | 23.8 ms | **0.09 ms** (250×) |
> | PyPI TTFB | 111 ms | **17 ms** (6.5×) |
> | PyPI throughput | 56 MB/s | **311 MB/s** (5.6×) |
> | Cloudflare 25 MB | 565 ms | **132 ms** (4.3×) |
>
> Does not help origin-anchored services (GitHub, HuggingFace saw ~5%
> improvement — those are dominated by CDN routing). Does not fix
> DNS latency, FSx cross-zone syscalls, or EKS API latency — those need
> separate mitigations.

> **FSx-in-LZ portability.** FSx for Lustre in Local Zones is offered per-zone,
> and per-tier availability varies. Verified:
>
> - **Phoenix (`usw2-phx2-az1`)**: PERSISTENT_2 offered and works. Our
>   earlier benchmarks show 21× DDP read speedup vs cross-zone parent-AZ FSx.
> - **LAX (`usw2-lax1-az1`)**: PERSISTENT_2 **not offered** — CFN/TF create
>   returns `"The requested Lustre configuration: PERSISTENT_2 is not
>   available in this availability zone."`. PERSISTENT_1 is offered but the
>   server runs Lustre 2.10.5, which is incompatible with the AL2023-bundled
>   2.15.6 client: `"Server MGS version (2.10.5.0) refused connection from
>   this client with an incompatible version (2.15.6)"`. Verified 2026-08-03.
>
> **FSx placement is already configurable upstream on this branch** — no
> patch needed. `fsx_lustre` module's `subnet_id` (`main.tf:72-77`) resolves to:
>
> - **`fsx_availability_zone_id = ""` (default)** → FSx in the first
>   instance group's subnet. Since our tfvars puts that group in the LZ,
>   simply setting `create_new_fsx_filesystem = true` co-locates FSx with
>   compute — no LZ-specific input needed. This is what `local-zone.tfvars`
>   does by default now.
> - **`fsx_availability_zone_id = "<parent-AZ-ID>"`** → FSx in that AZ,
>   mounted cross-zone. Use this in LZs that don't offer FSx (e.g. LAX)
>   or don't offer PERSISTENT_2.
>
> The idle FSx CSI driver + IAM role are installed regardless of
> `create_new_fsx_filesystem` because `create_fsx_module` defaults to true;
> harmless if you don't create a filesystem.

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
| `local_zone_egress_zone_ids` | **Added, commented** — set to `[<lz-az-id>]` to enable an LZ-local NAT gateway. Verified in LAX 2026-08-03; measured 250× first-hop RTT improvement, 4-6× internet throughput. |
| `local_zone_public_subnet_cidrs` | **Added, commented** — 1:1 with above. Carve from the VPC primary CIDR (secondary CIDRs are consumed by the worker subnet). |
| `local_zone_network_border_groups` | **Added, commented** — 1:1 with above. LZ zone name minus the trailing letter (`us-west-2-phx-2a` → `us-west-2-phx-2`). Required for the LZ EIP. |
| `create_new_fsx_filesystem` | **Set to `true`** — creates an FSx Lustre filesystem in the instance group's subnet (i.e. in-LZ for Phoenix). Upstream default is `false`. |
| `fsx_storage_capacity` / `fsx_throughput` | **Set to `1200` / `250`** — the PERSISTENT_2 tier validated in Phoenix (our July benchmarks). Not available in LAX; see the FSx-in-LZ portability note. |
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
