# Derived from boutique-eks-argocd@446ed56 terraform/modules/eks-cluster/main.tf; modified for finops-spot-demo
# Rewritten around the same structure: cluster role, cluster, node role, node groups, add-ons.
# Adds: access entries, Auto Mode (no built-in pools), Pod Identity agent, Spot node group for
# Cluster Autoscaler, STANDARD support policy. Dropped: extra cluster security group,
# AmazonSSMReadOnlyAccess (only External Secrets needed it).

locals {
  node_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]

  # Policies for the cluster role when Auto Mode is on (AWS docs: Auto Mode cluster IAM role).
  automode_cluster_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicyV2",
    "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy",
  ]
}

# ---------------------------------------------------------------- cluster role
data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole", "sts:TagSession"]
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_automode" {
  for_each   = var.enable_automode ? toset(local.automode_cluster_policies) : toset([])
  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# Custom tags on Auto Mode resources (Project, Scaler): statement copied from
# https://docs.aws.amazon.com/eks/latest/userguide/auto-cluster-iam-role.html (checked 2026-10-20).
resource "aws_iam_role_policy" "automode_custom_tags" {
  count = var.enable_automode ? 1 : 0
  name  = "automode-custom-tags"
  role  = aws_iam_role.cluster.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Compute"
        Effect   = "Allow"
        Action   = ["ec2:CreateFleet", "ec2:RunInstances", "ec2:CreateLaunchTemplate"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestTag/eks:eks-cluster-name" = "$${aws:PrincipalTag/eks:eks-cluster-name}" }
          StringLike = {
            "aws:RequestTag/eks:kubernetes-node-class-name" = "*"
            "aws:RequestTag/eks:kubernetes-node-pool-name"  = "*"
          }
        }
      },
      {
        Sid      = "Storage"
        Effect   = "Allow"
        Action   = ["ec2:CreateVolume", "ec2:CreateSnapshot"]
        Resource = ["arn:aws:ec2:*:*:volume/*", "arn:aws:ec2:*:*:snapshot/*"]
        Condition = {
          StringEquals = { "aws:RequestTag/eks:eks-cluster-name" = "$${aws:PrincipalTag/eks:eks-cluster-name}" }
        }
      },
      {
        Sid      = "Networking"
        Effect   = "Allow"
        Action   = "ec2:CreateNetworkInterface"
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestTag/eks:eks-cluster-name" = "$${aws:PrincipalTag/eks:eks-cluster-name}" }
          StringLike   = { "aws:RequestTag/eks:kubernetes-cni-node-name" = "*" }
        }
      },
      {
        Sid    = "LoadBalancer"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:CreateRule",
          "ec2:CreateSecurityGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestTag/eks:eks-cluster-name" = "$${aws:PrincipalTag/eks:eks-cluster-name}" }
        }
      },
      {
        Sid      = "ShieldProtection"
        Effect   = "Allow"
        Action   = ["shield:CreateProtection"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestTag/eks:eks-cluster-name" = "$${aws:PrincipalTag/eks:eks-cluster-name}" }
        }
      },
      {
        Sid      = "ShieldTagResource"
        Effect   = "Allow"
        Action   = ["shield:TagResource"]
        Resource = "arn:aws:shield::*:protection/*"
        Condition = {
          StringEquals = { "aws:RequestTag/eks:eks-cluster-name" = "$${aws:PrincipalTag/eks:eks-cluster-name}" }
        }
      },
      {
        Sid      = "ModifyTagsOnClusterResources"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags", "ec2:DeleteTags", "elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:ResourceTag/eks:eks-cluster-name" = "$${aws:PrincipalTag/eks:eks-cluster-name}" }
        }
      },
    ]
  })
}

# --------------------------------------------------------------------- cluster
resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  # Always false: changing it later forces cluster replacement. Add-ons are managed below.
  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Never fall into paid extended support silently.
  upgrade_policy {
    support_type = "STANDARD"
  }

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.endpoint_public_access_cidrs
  }

  # EKS Auto Mode with NO built-in node pools and no node_role_arn (custom NodeClass in automode.tf).
  # compute_config, ELB and block storage must be enabled together.
  dynamic "compute_config" {
    for_each = var.enable_automode ? [1] : []
    content {
      enabled = true
    }
  }

  dynamic "kubernetes_network_config" {
    for_each = var.enable_automode ? [1] : []
    content {
      elastic_load_balancing {
        enabled = true
      }
    }
  }

  dynamic "storage_config" {
    for_each = var.enable_automode ? [1] : []
    content {
      block_storage {
        enabled = true
      }
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.cluster_automode,
    aws_iam_role_policy.automode_custom_tags,
  ]

  tags = var.tags
}

# Karpenter and Auto Mode NodeClasses select the EKS primary security group by this tag.
resource "aws_ec2_tag" "cluster_sg_discovery" {
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.name
}

# Optional extra cluster admins (the creator is already admin).
resource "aws_eks_access_entry" "admin" {
  for_each      = toset(var.admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each      = toset(var.admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# ------------------------------------------------------------- system node group
data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each   = toset(local.node_policies)
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# System pods (CoreDNS, Karpenter, Cluster Autoscaler, Prometheus, OpenCost, probe) run here.
# No Cluster Autoscaler discovery tags on purpose: CA must never resize this group.
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.system_desired_size
    min_size     = var.system_desired_size
    max_size     = var.system_desired_size + 1
  }

  instance_types = var.system_instance_types
  capacity_type  = "ON_DEMAND"

  labels = {
    role = "system"
  }

  depends_on = [aws_iam_role_policy_attachment.node]

  tags = merge(var.tags, { Scaler = "system" })
}

# ------------------------------------------------- Spot node group for Cluster Autoscaler
resource "aws_iam_role" "ca_node" {
  count              = var.enable_cluster_autoscaler ? 1 : 0
  name               = "${var.name}-ca-node"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ca_node" {
  for_each   = var.enable_cluster_autoscaler ? toset(local.node_policies) : toset([])
  role       = aws_iam_role.ca_node[0].name
  policy_arn = each.value
}

resource "aws_eks_node_group" "ca" {
  count           = var.enable_cluster_autoscaler ? 1 : 0
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-ca-spot"
  node_role_arn   = aws_iam_role.ca_node[0].arn
  subnet_ids      = var.private_subnet_ids
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 0
    min_size     = 0
    max_size     = var.ca_max_size
  }

  instance_types = var.ca_instance_types
  capacity_type  = "SPOT"

  labels = {
    scaler = "ca"
  }

  taint {
    key    = "scaler"
    value  = "ca"
    effect = "NO_SCHEDULE"
  }

  depends_on = [aws_iam_role_policy_attachment.ca_node]

  tags = merge(var.tags, {
    Scaler                                  = "ca"
    "k8s.io/cluster-autoscaler/enabled"     = "true"
    "k8s.io/cluster-autoscaler/${var.name}" = "owned"
  })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# --------------------------------------------------------------------- add-ons
# No addon_version: add-ons float within the cluster minor; versions are recorded after 01-up.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.system, aws_eks_addon.vpc_cni]
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.system, aws_eks_addon.vpc_cni]
}
