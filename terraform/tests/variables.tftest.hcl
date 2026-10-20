# Input validation contract. Runs offline: mock provider, no credentials.
#   terraform -chdir=demo/terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  expected_aws_account_id      = "000000000000"
  endpoint_public_access_cidrs = ["203.0.113.10/32"]
}

run "defaults_are_accepted" {
  command = plan
}

run "rejects_short_account_id" {
  command = plan
  variables {
    expected_aws_account_id = "12345"
  }
  expect_failures = [var.expected_aws_account_id]
}

run "rejects_account_id_with_letters" {
  command = plan
  variables {
    expected_aws_account_id = "00000000000a"
  }
  expect_failures = [var.expected_aws_account_id]
}

run "rejects_bad_region" {
  command = plan
  variables {
    region = "Singapore"
  }
  expect_failures = [var.region]
}

run "rejects_foreign_cluster_name" {
  command = plan
  variables {
    cluster_name = "boutique-dev-eks"
  }
  expect_failures = [var.cluster_name]
}

run "rejects_bad_kubernetes_version" {
  command = plan
  variables {
    kubernetes_version = "v1.35"
  }
  expect_failures = [var.kubernetes_version]
}

run "rejects_non_16_vpc_cidr" {
  command = plan
  variables {
    vpc_cidr = "10.60.0.0/24"
  }
  expect_failures = [var.vpc_cidr]
}

run "rejects_invalid_vpc_cidr" {
  command = plan
  variables {
    vpc_cidr = "not-a-cidr"
  }
  expect_failures = [var.vpc_cidr]
}

run "rejects_az_count_4" {
  command = plan
  variables {
    az_count = 4
  }
  expect_failures = [var.az_count]
}

run "rejects_empty_system_instance_types" {
  command = plan
  variables {
    system_instance_types = []
  }
  expect_failures = [var.system_instance_types]
}

run "rejects_single_system_node" {
  command = plan
  variables {
    system_desired_size = 1
  }
  expect_failures = [var.system_desired_size]
}

run "rejects_empty_scalers" {
  command = plan
  variables {
    enabled_scalers = []
  }
  expect_failures = [var.enabled_scalers]
}

run "rejects_unknown_scaler" {
  command = plan
  variables {
    enabled_scalers = ["ca", "keda"]
  }
  expect_failures = [var.enabled_scalers]
}

run "rejects_empty_ca_instance_types" {
  command = plan
  variables {
    ca_instance_types = []
  }
  expect_failures = [var.ca_instance_types]
}

run "rejects_ca_max_size_7" {
  command = plan
  variables {
    ca_max_size = 7
  }
  expect_failures = [var.ca_max_size]
}

run "rejects_empty_endpoint_cidrs" {
  command = plan
  variables {
    endpoint_public_access_cidrs = []
  }
  expect_failures = [var.endpoint_public_access_cidrs]
}

run "rejects_open_endpoint_by_default" {
  command = plan
  variables {
    endpoint_public_access_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.endpoint_public_access_cidrs]
}

run "rejects_wide_endpoint_range" {
  command = plan
  variables {
    endpoint_public_access_cidrs = ["0.0.0.0/1"]
  }
  expect_failures = [var.endpoint_public_access_cidrs]
}

run "rejects_invalid_endpoint_cidr" {
  command = plan
  variables {
    endpoint_public_access_cidrs = ["300.1.1.1/32"]
  }
  expect_failures = [var.endpoint_public_access_cidrs]
}

run "accepts_open_endpoint_when_explicitly_allowed" {
  command = plan
  variables {
    endpoint_public_access_cidrs = ["0.0.0.0/0"]
    allow_open_endpoint          = true
  }
}

run "rejects_bad_admin_arn" {
  command = plan
  variables {
    admin_principal_arns = ["arn:aws:iam::123:user/x"]
  }
  expect_failures = [var.admin_principal_arns]
}

run "rejects_bad_owner_tag" {
  command = plan
  variables {
    owner = "bad<owner>"
  }
  expect_failures = [var.owner]
}

run "accepts_single_scaler_without_others" {
  command = plan
  variables {
    enabled_scalers = ["karpenter"]
  }
}

run "accepts_fis_enabled" {
  command = plan
  variables {
    enable_fis = true
  }
}
