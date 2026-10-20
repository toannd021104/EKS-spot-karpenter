# Derived from boutique-eks-argocd@446ed56 terraform/modules/eks-cluster/variables.tf; modified for finops-spot-demo

variable "name" {
  type        = string
  description = "Cluster name (also the base name of IAM roles and node groups)."
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "endpoint_public_access_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the public API endpoint (use your /32)."
}

variable "enable_automode" {
  type        = bool
  default     = true
  description = "Enable EKS Auto Mode (compute, ELB, block storage) with no built-in node pools."
}

variable "enable_cluster_autoscaler" {
  type        = bool
  default     = true
  description = "Create the Spot managed node group (scaler=ca) that Cluster Autoscaler resizes."
}

variable "system_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}

variable "system_desired_size" {
  type    = number
  default = 2
}

variable "ca_instance_types" {
  type        = list(string)
  description = "All must be the same size class (2 vCPU / 8 GiB) because Cluster Autoscaler needs identical node shapes in a mixed group."
  default     = ["m5.large", "m5a.large", "m6i.large", "m6a.large"]
}

variable "ca_max_size" {
  type    = number
  default = 4
}

variable "admin_principal_arns" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
