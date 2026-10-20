output "cluster_name" {
  value = module.eks_cluster.cluster_name
}

output "region" {
  value = var.region
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "cluster_endpoint" {
  value = module.eks_cluster.cluster_endpoint
}

output "enabled_scalers" {
  value = var.enabled_scalers
}

output "karpenter_queue_name" {
  description = "SQS interruption queue for the Karpenter chart (settings.interruptionQueue)."
  value       = try(module.karpenter[0].queue_name, null)
}

output "karpenter_node_role_name" {
  description = "Role name for EC2NodeClass.spec.role."
  value       = try(module.karpenter[0].node_iam_role_name, null)
}

output "automode_node_role_name" {
  description = "Role name for the Auto Mode NodeClass.spec.role."
  value       = try(aws_iam_role.automode_node[0].name, null)
}

output "ca_node_group_name" {
  value = module.eks_cluster.ca_node_group_name
}

output "ca_asg_name" {
  description = "Auto Scaling group behind the Cluster Autoscaler node group."
  value       = module.eks_cluster.ca_asg_name
}

output "fis_template_ids" {
  description = "FIS experiment template id per scaler (empty unless enable_fis=true)."
  value       = { for k, t in aws_fis_experiment_template.spot_interruption : k => t.id }
}

output "kubeconfig_command" {
  description = "Creates the demo-only kubeconfig (never the default one) with the context alias = cluster name."
  value       = "aws eks update-kubeconfig --name ${module.eks_cluster.cluster_name} --region ${var.region} --kubeconfig ${abspath("${path.module}/../.kube/config")} --alias ${module.eks_cluster.cluster_name}"
}
