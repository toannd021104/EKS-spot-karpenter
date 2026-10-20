# Derived from boutique-eks-argocd@446ed56 terraform/modules/network/variables.tf; modified for finops-spot-demo
variable "name" {
  description = "Base name for VPC resources."
  type        = string
}

variable "cidr" {
  description = "VPC CIDR."
  type        = string
}

variable "az_count" {
  description = "Number of AZs/subnet pairs to create."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "single_nat_gateway" {
  description = "If true, create one NAT Gateway for all private subnets (cheaper for dev)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

variable "private_subnet_extra_tags" {
  description = "Extra tags for private subnets only (for example karpenter.sh/discovery = <cluster>)."
  type        = map(string)
  default     = {}
}

variable "kubernetes_cluster_name" {
  description = "If set, tag subnets for Kubernetes (kubernetes.io/cluster/<name>=shared)."
  type        = string
  default     = null
}
