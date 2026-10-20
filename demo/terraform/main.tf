locals {
  enable_ca        = contains(var.enabled_scalers, "ca")
  enable_karpenter = contains(var.enabled_scalers, "karpenter")
  enable_automode  = contains(var.enabled_scalers, "automode")

  tags = {
    Project = "finops-spot-demo"
  }
}

module "network" {
  source = "./modules/network"

  name                    = var.cluster_name
  cidr                    = var.vpc_cidr
  az_count                = var.az_count
  single_nat_gateway      = true
  kubernetes_cluster_name = var.cluster_name
  tags                    = local.tags

  # Karpenter and Auto Mode NodeClasses discover subnets by this tag.
  private_subnet_extra_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

module "eks_cluster" {
  source = "./modules/eks-cluster"

  name                         = var.cluster_name
  vpc_id                       = module.network.vpc_id
  private_subnet_ids           = module.network.private_subnet_ids
  kubernetes_version           = var.kubernetes_version
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs
  enable_automode              = local.enable_automode
  enable_cluster_autoscaler    = local.enable_ca
  system_instance_types        = var.system_instance_types
  system_desired_size          = var.system_desired_size
  ca_instance_types            = var.ca_instance_types
  ca_max_size                  = var.ca_max_size
  admin_principal_arns         = var.admin_principal_arns
  tags                         = local.tags
}
