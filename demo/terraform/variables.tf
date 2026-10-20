variable "expected_aws_account_id" {
  description = "12-digit AWS account the demo may run in. No default: passed by 01-up.sh from EXPECTED_AWS_ACCOUNT_ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_aws_account_id))
    error_message = "expected_aws_account_id must be a 12-digit AWS account id."
  }
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-southeast-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.region))
    error_message = "region must look like ap-southeast-1."
  }
}

variable "cluster_name" {
  description = "EKS cluster name. Same pattern the scripts enforce."
  type        = string
  default     = "finops-spot-demo"

  validation {
    condition     = can(regex("^finops-spot-demo(-[a-z0-9-]{1,20})?$", var.cluster_name))
    error_message = "cluster_name must match ^finops-spot-demo(-[a-z0-9-]{1,20})?$."
  }
}

variable "kubernetes_version" {
  description = "EKS version. Support status is checked by 01-up.sh (describe-cluster-versions), not frozen here."
  type        = string
  default     = "1.35"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must look like 1.35."
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR, must be a /16 (subnets are cut as /20)."
  type        = string
  default     = "10.60.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) == 16
    error_message = "vpc_cidr must be a /16 (subnets are cut as /20)."
  }
}

variable "az_count" {
  description = "Number of availability zones (2 or 3)."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "system_instance_types" {
  description = "Instance types of the On-Demand system node group. t3.medium is cheaper but its 17-pod / 4 GiB limits would be stressed by Prometheus + Karpenter + CA + OpenCost."
  type        = list(string)
  default     = ["t3.large"]

  validation {
    condition     = length(var.system_instance_types) > 0
    error_message = "system_instance_types must not be empty."
  }
}

variable "system_desired_size" {
  description = "Number of system nodes (2 for CoreDNS HA)."
  type        = number
  default     = 2

  validation {
    condition     = var.system_desired_size >= 2 && var.system_desired_size <= 3
    error_message = "system_desired_size must be 2 or 3."
  }
}

variable "enabled_scalers" {
  description = "Which node autoscalers to build: subset of ca, karpenter, automode."
  type        = list(string)
  default     = ["ca", "karpenter", "automode"]

  validation {
    condition     = length(var.enabled_scalers) > 0 && alltrue([for s in var.enabled_scalers : contains(["ca", "karpenter", "automode"], s)])
    error_message = "enabled_scalers must be a non-empty subset of ca, karpenter, automode."
  }
}

variable "ca_instance_types" {
  description = "Instance types of the Spot node group used by Cluster Autoscaler. All must be 2 vCPU / 8 GiB class (documented, not machine-validated)."
  type        = list(string)
  default     = ["m5.large", "m5a.large", "m6i.large", "m6a.large"]

  validation {
    condition     = length(var.ca_instance_types) > 0
    error_message = "ca_instance_types must not be empty."
  }
}

variable "ca_max_size" {
  description = "Max nodes of the Cluster Autoscaler node group (6 x 2 vCPU = 12 vCPU quota guard)."
  type        = number
  default     = 4

  validation {
    condition     = var.ca_max_size >= 1 && var.ca_max_size <= 6
    error_message = "ca_max_size must be between 1 and 6."
  }
}

variable "allow_open_endpoint" {
  description = "Allow wide public API endpoint CIDRs such as 0.0.0.0/0. Leave false and use your /32."
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. No default: use your own /32."
  type        = list(string)

  validation {
    condition = length(var.endpoint_public_access_cidrs) > 0 && alltrue([
      for c in var.endpoint_public_access_cidrs :
      can(cidrhost(c, 0)) && (var.allow_open_endpoint || tonumber(split("/", c)[1]) >= 24)
    ])
    error_message = "Provide at least one CIDR of /24 or narrower (use your /32), or set allow_open_endpoint=true."
  }
}

variable "admin_principal_arns" {
  description = "Optional extra cluster admins (IAM user or role ARNs)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.admin_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(user|role)/.+$", a))])
    error_message = "Each admin principal must be an IAM user or role ARN."
  }
}

variable "owner" {
  description = "Value of the Owner tag."
  type        = string
  default     = "unset"

  validation {
    condition     = can(regex("^[A-Za-z0-9 _.:/=+@-]{1,64}$", var.owner))
    error_message = "owner must be 1-64 chars from the AWS tag charset."
  }
}

variable "enable_fis" {
  description = "Create the optional FIS role and Spot-interruption experiment templates (default off)."
  type        = bool
  default     = false
}
