# OPTIONAL (default off, var.enable_fis): AWS Fault Injection Service templates that send a
# 2-minute Spot interruption notice to ONE instance tagged FisTarget=true and Project=finops-spot-demo.
# 05-chaos-node-down.sh tags the victim just before starting the experiment and removes the tag after.

locals {
  fis_scalers = var.enable_fis ? toset(var.enabled_scalers) : toset([])
}

data "aws_iam_policy_document" "fis_assume" {
  count = var.enable_fis ? 1 : 0

  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "fis" {
  count = var.enable_fis ? 1 : 0

  statement {
    sid       = "Describe"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "InterruptTaggedSpotInstances"
    effect    = "Allow"
    actions   = ["ec2:SendSpotInstanceInterruptions"]
    resources = ["arn:aws:ec2:${var.region}:${var.expected_aws_account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["finops-spot-demo"]
    }
  }
}

resource "aws_iam_role" "fis" {
  count              = var.enable_fis ? 1 : 0
  name               = "${var.cluster_name}-fis"
  assume_role_policy = data.aws_iam_policy_document.fis_assume[0].json
  tags               = local.tags
}

resource "aws_iam_role_policy" "fis" {
  count  = var.enable_fis ? 1 : 0
  name   = "fis-spot-interruption"
  role   = aws_iam_role.fis[0].id
  policy = data.aws_iam_policy_document.fis[0].json
}

resource "aws_fis_experiment_template" "spot_interruption" {
  for_each    = local.fis_scalers
  description = "finops-spot-demo (${each.key}): 2-minute Spot interruption notice for one tagged instance"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "interrupt-spot"
    action_id = "aws:ec2:send-spot-instance-interruptions"

    parameter {
      key   = "durationBeforeInterruption"
      value = "PT2M"
    }

    target {
      key   = "SpotInstances"
      value = "victim"
    }
  }

  target {
    name           = "victim"
    resource_type  = "aws:ec2:spot-instance"
    selection_mode = "COUNT(1)"

    resource_tag {
      key   = "FisTarget"
      value = "true"
    }

    resource_tag {
      key   = "Project"
      value = "finops-spot-demo"
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }

  tags = merge(local.tags, { Scaler = each.key })
}
