# Custom NodeClass support for EKS Auto Mode. Built-in node pools are disabled, so the built-in
# `default` NodeClass does not exist and the NodeClass in kubernetes/automode needs its own node role
# plus an EC2 access entry (AWS docs: "Create node class access entry").

data "aws_iam_policy_document" "automode_node_assume" {
  count = local.enable_automode ? 1 : 0

  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "automode_node" {
  count              = local.enable_automode ? 1 : 0
  name               = "${var.cluster_name}-automode-node"
  assume_role_policy = data.aws_iam_policy_document.automode_node_assume[0].json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "automode_node" {
  for_each = local.enable_automode ? toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ]) : toset([])

  role       = aws_iam_role.automode_node[0].name
  policy_arn = each.value
}

resource "aws_eks_access_entry" "automode_node" {
  count         = local.enable_automode ? 1 : 0
  cluster_name  = module.eks_cluster.cluster_name
  principal_arn = aws_iam_role.automode_node[0].arn
  type          = "EC2"
}

resource "aws_eks_access_policy_association" "automode_node" {
  count         = local.enable_automode ? 1 : 0
  cluster_name  = module.eks_cluster.cluster_name
  principal_arn = aws_iam_role.automode_node[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAutoNodePolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.automode_node]
}
