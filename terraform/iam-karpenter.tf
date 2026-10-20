# Karpenter controller IAM (Pod Identity), node role, SQS interruption queue and EventBridge rules.
# Maintained module pinned exactly; hand-rolling the v1 controller policy is the larger risk.
module "karpenter" {
  count   = local.enable_karpenter ? 1 : 0
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "20.37.2"

  cluster_name = module.eks_cluster.cluster_name

  enable_v1_permissions   = true
  enable_spot_termination = true

  # Pod Identity, not IRSA (the cluster has no OIDC provider).
  enable_pod_identity             = true
  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"

  # v1 EC2NodeClass uses `role`, not an instance profile.
  create_instance_profile       = false
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"

  tags = local.tags

  depends_on = [module.eks_cluster]
}
