provider "aws" {
  region = var.region

  # Terraform refuses any other account, so running terraform directly cannot bypass the shell guards.
  allowed_account_ids = [var.expected_aws_account_id]

  default_tags {
    tags = {
      Project     = "finops-spot-demo"
      Environment = "demo"
      ManagedBy   = "terraform"
      Owner       = var.owner
    }
  }
}
