# Derived from boutique-eks-argocd@446ed56 terraform/modules/eks-cluster/outputs.tf; modified for finops-spot-demo

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "EKS-managed primary security group (tagged karpenter.sh/discovery)."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_role_arn" {
  description = "System node group role."
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  value = aws_iam_role.node.name
}

output "ca_node_role_arn" {
  value = try(aws_iam_role.ca_node[0].arn, null)
}

output "ca_node_group_name" {
  value = try(aws_eks_node_group.ca[0].node_group_name, null)
}

output "ca_asg_name" {
  description = "Auto Scaling group behind the Cluster Autoscaler node group."
  value       = try(aws_eks_node_group.ca[0].resources[0].autoscaling_groups[0].name, null)
}
