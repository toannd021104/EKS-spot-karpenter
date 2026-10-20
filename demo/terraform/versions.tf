terraform {
  # >= 1.9: a variable validation may reference another variable (endpoint CIDRs vs allow_open_endpoint).
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }
}
