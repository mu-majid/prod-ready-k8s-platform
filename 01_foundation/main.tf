locals {
  cluster_name = "cluster-prod"
  tags = {
    "karpenter.sh/discovery" = local.cluster_name
    "author"                 = "majid"
  }
}

variable "domain" {
  description = "AWS Route53 hosted zone domain name"
  type        = string
  default     = "terraform-aws-platform.xyz"
}

data "aws_route53_zone" "default" {
  name = var.domain
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.2.0"

  name = local.cluster_name
  cidr = "10.0.0.0/16" # group of IPs in our network (vpc)

  azs             = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  intra_subnets   = ["10.0.51.0/24", "10.0.52.0/24", "10.0.53.0/24"]

  enable_nat_gateway = true # one-way door for nodes to allow outbound traffic, but block inbound public traffic

  tags = local.tags
}

module "cluster" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.20"

  cluster_name    = local.cluster_name
  cluster_version = "1.28"

  cluster_endpoint_public_access = true # important during dev - maybe make it private later
  # or as a middle ground:
  
  # cluster_endpoint_public_access = true
  # cluster_endpoint_public_access_cidrs = [
  #   "GITHUB_ACTIONS_IPS",
  #   "YOUR_OFFICE_IP/32", 
  #   "CI_SYSTEM_IPS"
  # ]

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets # workers in private subnet -> no internet access
  control_plane_subnet_ids = module.vpc.intra_subnets  # put the control plane in the intra subnet from the vpc module

  eks_managed_node_groups = {
    default = {
      iam_role_name            = "node-${local.cluster_name}"
      iam_role_use_name_prefix = false
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
      }

      ami_type = "BOTTLEROCKET_x86_64"
      platform = "bottlerocket"

      min_size     = 3
      desired_size = 4
      max_size     = 6

      instance_types = ["t3.xlarge"]
    }
  }

  tags = local.tags
}

# IAM roles (irsa = IAM Roles for Service Accounts)

module "cert_manager_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.32.0"

  role_name                     = "cert-manager"
  attach_cert_manager_policy    = true
  cert_manager_hosted_zone_arns = [data.aws_route53_zone.default.arn]

  oidc_providers = {
    ex = {
      provider_arn               = module.cluster.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cert-manager"]
    }
  }

  tags = local.tags
}

module "external_secrets_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.32.0"

  role_name                           = "secret-store"
  attach_external_secrets_policy      = true
  external_secrets_ssm_parameter_arns = ["arn:aws:ssm:*:*:parameter/${local.cluster_name}-*"] # clusters can only access their secrets (secret store paramters startsWith clusterName)

  oidc_providers = {
    ex = {
      provider_arn               = module.cluster.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:secret-store"] # ServiceAccount taking this role exists in external-secrets namespace, the ServiceAccount name is secret-store
    }
  }

  tags = local.tags
}

module "cluster_autoscaler_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.32.0"

  role_name                        = "cluster-autoscaler"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_ids   = [module.cluster.cluster_name]

  oidc_providers = {
    ex = {
      provider_arn               = module.cluster.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"] # Role cluster-autoscaler
    }
  }

  tags = local.tags
}

# For the EBS CSI driver
module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.32.0"

  role_name             = "ebs-csi-controller"
  attach_ebs_csi_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.cluster.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

# Outputs
output "cluster_name" {
  description = "EKS cluster name"
  value       = local.cluster_name
}

output "domain" {
  description = "Domain name"
  value       = var.domain
}