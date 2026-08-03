# Local Zone egress benchmark

Reproducible test rig for the `LocalZoneEgress` feature in the HyperPod LZ
CloudFormation templates
(`cloudformation/eks/hyperpod-eks-lz-stack.yaml`,
`cloudformation/slurm/hyperpod-lz-stack.yaml`) and the matching upstream
Terraform inputs in
[`awslabs/awsome-distributed-ai`](https://github.com/awslabs/awsome-distributed-ai/tree/hpeks-localzone-2026-07-29).

Runs an A/B (or A/B/C) experiment that isolates the network topology
under test:

| Config | LZ private subnet's `0.0.0.0/0` route | Optional FSx-in-LZ |
|---|---|---|
| **A** | Parent-AZ NAT | No |
| **B** | LZ-local NAT (with `NetworkBorderGroup`-scoped EIP) | No |
| **C** | LZ-local NAT | Yes (metadata smoke test) |

A minimal CFN stack in each configuration provisions a VPC, subnets, NAT
gateway(s), a small CPU instance in the LZ private subnet, and — for
Config C — an FSx Lustre filesystem in the LZ subnet. A single measurement
script runs on the instance via SSM, emits JSON, and the stack is torn
down.

The rig is deliberately scoped to the LZ egress feature: it does **not**
deploy HyperPod, EKS, Slurm, or any of the production LZ stack. That
keeps the deploy cycle short (about a minute) and the cost per iteration
minimal.

## What each config proves

- **A (baseline).** Reproduces the default LZ topology when
  `LocalZoneEgress=false`: the LZ private subnet's default route points at
  a NAT gateway in the parent AZ. Every packet crosses the LZ-to-region
  link before reaching the internet.
- **B (`LocalZoneEgress=true`).** Adds an LZ-local NAT with a
  `NetworkBorderGroup`-scoped EIP and an LZ public subnet, and routes the
  LZ private subnet through that new NAT. Public-internet egress no longer
  hairpins through the parent region.
- **C (FSx-in-LZ smoke test).** Same egress topology as B, plus a small
  FSx Lustre filesystem placed in the LZ private subnet. The measurement
  script mounts it and times a handful of metadata operations against
  50 tiny files. Useful for confirming that a given LZ supports the FSx
  tier you plan to use.

## Prerequisites

- **AWS credentials.** A profile with permission to create VPC, EC2, IAM
  (managed-policy attach only), SSM, and optionally FSx in the target
  region. Set `AWS_PROFILE` in your shell before running.
- **Local Zone opted in.** The target LZ must be opted-in on the account
  you're using. Confirm with:
  ```bash
  aws ec2 describe-availability-zones --all-availability-zones \
    --query "AvailabilityZones[?ZoneType=='local-zone']
             .[ZoneName,ZoneId,ParentZoneName,OptInStatus]" --output table
  ```
  If the target zone shows `not-opted-in`, request access via the AWS
  console (EC2 → Zones → Manage). First-time requests can take from
  minutes to a day.
- **Instance-type availability.** The default is `c5.large`, which is
  broadly offered in current us-west-2 LZs. If you're targeting an LZ
  where `c5` isn't offered, list what is:
  ```bash
  aws ec2 describe-instance-type-offerings \
    --location-type availability-zone-id \
    --filters Name=location,Values=<lz-az-id> \
              Name=instance-type,Values=c5.large,m5.large,t3.large \
    --query "InstanceTypeOfferings[].InstanceType"
  ```
  Override `InstanceType` in `test-stack.yaml` if needed.
- **FSx PERSISTENT_2 availability (Config C only).** Not offered in every
  LZ. If Config C fails at create with `"The requested Lustre
  configuration: PERSISTENT_2 is not available in this availability
  zone"`, either switch `FsxDeploymentType` to `PERSISTENT_1` or skip
  Config C for that LZ. Note that some LZs offer PERSISTENT_1 with an
  older Lustre server version that is incompatible with recent AL2023
  clients (the mount will fail with a `Server MGS version ... refused
  connection` error in `dmesg`). When that happens, Config C's egress
  numbers are still valid — only the FSx smoke test is affected.
- **Local tools.** `bash`, `aws` CLI, `python3` (for JSON parsing in the
  runner), and `base64`. That's it — nothing is installed on the test
  instance from your laptop; the measurement script is shipped over SSM.

## Files

| File | Purpose |
|---|---|
| `test-stack.yaml` | CloudFormation template. VPC, subnets, NAT gateway(s), IAM, security group, EC2 instance, optional FSx. All parameters documented inline. |
| `measure.sh` | Runs on the test EC2 instance. Emits a single JSON document to stdout covering curl timings, traceroute, path-MTU probes, DNS timings, and optional FSx metadata. Portable AL2023 bash; no laptop dependencies. |
| `run.sh` | End-to-end: deploy stack → wait for SSM → run `measure.sh` via `send-command` → save JSON under `./results/` → tear down. Defaults to Phoenix; override via env vars for other LZs. |
| `measure-only.sh` | Runs `measure.sh` against an already-deployed stack. Useful for repeat measurements without paying the NAT create/delete cycle. |
| `results/` | Output directory; created on first run. Not tracked in git (`.gitignore`). |

## How to run

### Basic A/B (Phoenix, default parameters)

```bash
export AWS_PROFILE=<your-profile>
export AWS_REGION=us-west-2   # optional; this is the default

# Config A: parent-AZ NAT baseline
./run.sh A

# Config B: LocalZoneEgress=true
./run.sh B
```

Each invocation deploys its own stack (`hp-lz-egress-test-a`,
`hp-lz-egress-test-b`), measures, and tears down. Results land in
`./results/A.json` and `./results/B.json`.

### Include the FSx-in-LZ smoke test

```bash
./run.sh C
```

Requires the target LZ to support the FSx configuration selected in the
template (see Prerequisites above). Adds around 10-15 minutes to the
deploy time and non-trivial cost while the filesystem exists.

### Target a different Local Zone

```bash
LOCAL_ZONE_ID=usw2-lax1-az1 \
LOCAL_ZONE_NAME=us-west-2-lax-1a \
NETWORK_BORDER_GROUP=us-west-2-lax-1 \
PARENT_AZ=us-west-2b \
  ./run.sh B
```

`NETWORK_BORDER_GROUP` is the LZ zone name minus the trailing zone
letter (e.g. `us-west-2-phx-2a` → `us-west-2-phx-2`,
`us-west-2-lax-1a` → `us-west-2-lax-1`). It's a required parameter,
not derived, because HCL/CFN string ops don't reliably suffix-strip
multi-letter zone names.

### Keep the stack up between measurements

```bash
KEEP_STACK=1 ./run.sh B
# ...poke at the instance manually via SSM if you want...
./measure-only.sh B
./measure-only.sh B    # a few more trials
# When done, delete the stack yourself:
aws cloudformation delete-stack --stack-name hp-lz-egress-test-b
```

## What to look at in the results

`results/<config>.json` is a single JSON document with these keys:

- `meta` — instance ID, AZ name, AZ ID, local + public IPv4 (public will
  be `"none"` in this rig; the test instance intentionally has no public
  IP).
- `curl` — one object per (URL, trial). Fields: `dns`, `connect`,
  `appconn`, `pretxfer`, `ttfb`, `total`, `http`, `size`, `speed`. Times
  are seconds; `speed` is bytes/sec. Three trials per URL over five
  URLs = 15 entries.
- `traceroute` — full `traceroute -n` output as a string. The first
  hop tells you whether egress leaves through the LZ or the parent
  region: an LZ-local NAT shows sub-millisecond hop 1; a parent-AZ NAT
  shows the LZ-to-region RTT (typically tens of milliseconds).
- `mtu` — three ping probes with DF set, probing 9001, 1500, and 1300
  byte MTUs. Public-internet paths are typically capped at 1500, so
  the 9001 probe usually fails in both A and B. This is expected; the
  9001-byte MTU documented for LZ-to-LZ traffic does not apply to
  internet egress.
- `dns_ms` — dig query time in milliseconds against the VPC resolver,
  five hosts x three trials each.
- `fsx` — object with per-op timings (`create_50`, `stat_50`, `list`,
  `delete_50`) in seconds when Config C ran and mount succeeded;
  `"skipped"` otherwise; `{"mount_error": "see log"}` if mount was
  attempted and failed.

Compare the two configs directly. The metrics that move meaningfully
between A and B are the traceroute hop-1 latency, curl TTFB and total
time for large public downloads, and download throughput. Metrics that
tend to move little are TTFB against origin-anchored public services
(GitHub, HuggingFace) — those are dominated by CDN routing rather than
egress.

## What this rig does not measure

- **DNS latency inside Kubernetes.** The `dns_ms` block queries the VPC
  resolver directly, not CoreDNS-in-cluster. If you're diagnosing pod
  DNS performance (`ndots:5` amplification, CoreDNS placement), that's
  a separate investigation on an actual cluster.
- **Cross-zone FSx / OpenZFS syscall latency.** Egress-focused; touches
  FSx only in the optional Config C smoke test, and only against an
  in-LZ filesystem.
- **Multi-node throughput scaling.** Single instance, single ENA.
  Aggregate throughput across a real cluster is out of scope; the
  storage-backend suite at [`../`](../) covers that side of the story
  (`bench_boto3.py`, `bench_s3tc.py`, `bench_t2c.py`).

## Cleanup and cost

Each config deploys one NAT gateway (Config A) or two NAT gateways
(Config B/C, one parent + one LZ) plus a small CPU instance and,
optionally, an FSx filesystem. `run.sh` tears the stack down by default
(`KEEP_STACK=1` to override). If teardown gets stuck on VPC
dependencies, the usual suspects are GuardDuty-injected VPC endpoints
and security groups; see the "Known gotchas" table in
[`../../cloudformation/eks/README.md`](../../cloudformation/eks/README.md)
for the cleanup commands.
