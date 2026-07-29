# This is the upstream hyperpod-eks-tf/terraform.tfvars with the MINIMAL edits
# needed to deploy into an AWS Local Zone. Every Local-Zone-specific line is
# tagged `# LZ:`; everything else is identical to the upstream example, so a
# `diff` against it shows exactly what a Local Zone requires.
#
# Example target: Phoenix Local Zone (us-west-2-phx-2a / usw2-phx2-az1).
# Look up your own with:
#   aws ec2 describe-availability-zones --all-availability-zones \
#     --query "AvailabilityZones[?ZoneType=='local-zone'].[ZoneName,ZoneId,ParentZoneName]" \
#     --output table

resource_name_prefix = "hp-eks"
aws_region           = "us-west-2"

# VPC Module Variables
create_vpc_module    = true
vpc_cidr             = "10.192.0.0/16"
public_subnet_1_cidr = "10.192.10.0/24"
public_subnet_2_cidr = "10.192.11.0/24"
existing_vpc_id      = ""

# Private Subnet Module Variables
create_private_subnet_module = true
private_subnet_cidrs         = ["10.1.0.0/16"] # LZ: single worker subnet in the Local Zone
# LZ: pin the subnet to an explicit AZ ID, 1:1 with private_subnet_cidrs.
#     This bypasses the opt-in-status="opt-in-not-required" discovery filter
#     that would otherwise exclude the (opt-in) Local Zone.
private_subnet_availability_zone_ids = ["usw2-phx2-az1"]
existing_nat_gateway_id              = ""
existing_private_subnet_ids          = []

# Security Group Module Variables
create_security_group_module = true
existing_security_group_id   = ""

# EKS Cluster Module Variables
create_eks_module         = true
kubernetes_version        = "1.33"
eks_cluster_name          = "sagemaker-hyperpod-eks-cluster"
existing_eks_cluster_name = ""

# EKS Subnet Configuration
# Option 1: Create new subnets for EKS (default)
# NOTE: EKS control-plane subnets stay in parent AZs — the control plane cannot
#       create ENIs in a Local Zone.
create_eks_subnets        = true
eks_private_subnet_1_cidr = "10.192.7.0/28"
eks_private_subnet_2_cidr = "10.192.8.0/28"

# Option 2: Use existing subnets for EKS (uncomment and set create_eks_subnets = false)
# create_eks_subnets           = false
# existing_eks_subnet_ids      = ["", ""]

# S3 Bucket Module Variables
create_s3_bucket_module = true
existing_s3_bucket_name = ""

# S3 Endpoint Module Variables
create_vpc_endpoints_module      = true
existing_private_route_table_ids = []

# Lifecycle Script Module Variables
create_lifecycle_script_module = true

# SageMaker IAM Role Module Variables
create_sagemaker_iam_role_module = true
existing_sagemaker_iam_role_name = ""

# Helm Chart Module Variables
create_helm_chart_module = true
helm_repo_path           = "helm_chart/HyperPodHelmChart"
namespace                = "kube-system"
helm_release_name        = "hyperpod-dependencies"

# HyperPod Cluster Module Variables
create_hyperpod_module       = true
hyperpod_cluster_name        = "ml-cluster"
auto_node_recovery           = true
continuous_provisioning_mode = true

# For the instance_groups variable, you'll need to define specific groups. Here's an example:
instance_groups = [
  {
    name                      = "instance-group-1"
    instance_type             = "ml.m5.12xlarge"
    instance_count            = 1
    availability_zone_id      = "usw2-phx2-az1" # LZ: land this group's nodes in the Local Zone
    ebs_volume_size_in_gb     = 100
    threads_per_core          = 2
    enable_stress_check       = false
    enable_connectivity_check = false
    lifecycle_script          = "on_create.sh"
  }
]

# ==========================================
# Cilium CNI (optional)
# ==========================================
# enable_cilium = true
# cilium_mode   = "overlay"  # Options: overlay, chaining, custom
# cilium_version = "1.19.4"
# cilium_helm_values = {}    # Custom values merged on top of mode defaults
