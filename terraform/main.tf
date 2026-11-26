# Throwaway EKS lab for Multigres failure drills: 3 AZs, one node per AZ,
# EBS CSI (gp3), an S3 bucket for pgBackRest with IRSA, and a budget alarm.
# Nothing here is shared with any other workload. Destroy it after each day.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile
  default_tags {
    tags = {
      Project = var.name
      Purpose = "self-training"
      Owner   = var.owner
      TTL     = "destroy-daily"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  azs         = slice(data.aws_availability_zones.available.names, 0, 3)
  zone_ids    = slice(data.aws_availability_zones.available.zone_ids, 0, 3)
  backup_ns   = "multigres-demo"
  backup_sa   = "multigres-backup"
  s3_prefix   = "multigres-demo"
  bucket_name = "${var.name}-backups-${data.aws_caller_identity.current.account_id}"
}

# Public subnets only: no NAT gateway to pay for. The API endpoint is limited
# to var.admin_cidrs.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.16"

  name                    = var.name
  cidr                    = "10.42.0.0/16"
  azs                     = local.azs
  public_subnets          = ["10.42.0.0/20", "10.42.16.0/20", "10.42.32.0/20"]
  map_public_ip_on_launch = true
  enable_nat_gateway      = false
  enable_dns_hostnames    = true
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name                             = var.name
  cluster_version                          = var.kubernetes_version
  cluster_endpoint_public_access           = true
  cluster_endpoint_public_access_cidrs     = var.admin_cidrs
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    # One group per AZ so each zone always has exactly one node, and a zone
    # can be taken down by scaling its group to zero.
    for i, az in local.azs : "az${i + 1}" => {
      instance_types = [var.instance_type]
      subnet_ids     = [module.vpc.public_subnets[i]]
      min_size       = 0
      max_size       = 2
      desired_size   = 1
      labels         = { "lab/az-index" = tostring(i + 1) }
    }
  }
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name             = "${var.name}-ebs-csi"
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_s3_bucket" "backups" {
  bucket        = local.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The policy from the Multigres EKS guide, scoped to the backup prefix.
resource "aws_iam_policy" "backup" {
  name = "${var.name}-backup"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource  = aws_s3_bucket.backups.arn
        Condition = { StringLike = { "s3:prefix" = ["${local.s3_prefix}/", "${local.s3_prefix}/*"] } }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.backups.arn}/${local.s3_prefix}/*"
      }
    ]
  })
}

module "backup_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name        = "${var.name}-backup"
  role_policy_arns = { backup = aws_iam_policy.backup.arn }
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${local.backup_ns}:${local.backup_sa}"]
    }
  }
}

resource "aws_budgets_budget" "lab" {
  name         = "${var.name}-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$${var.name}"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
