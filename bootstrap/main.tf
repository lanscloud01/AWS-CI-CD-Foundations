terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "tfstate-318432260330-eu-north-1"
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-north-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = "eu-north-1"

  default_tags {
    tags = {
      Project = "aws-cicd-foundations"
    }
  }
}

locals {
  repo          = "lanscloud01/AWS-CI-CD-Foundations"
  repo_with_ids = "lanscloud01@271969168/AWS-CI-CD-Foundations@1415903297"
  bucket        = "tfstate-318432260330-eu-north-1"
  environment   = "sandbox"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# --- Apply role: jobs in the sandbox environment only ---

data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.repo}:environment:${local.environment}",
        "repo:${local.repo_with_ids}:environment:${local.environment}",
      ]
    }
  }
}

resource "aws_iam_role" "apply" {
  name               = "github-actions-apply"
  assume_role_policy = data.aws_iam_policy_document.apply_trust.json
}

data "aws_caller_identity" "current" {}

locals {
  account_id           = data.aws_caller_identity.current.account_id
  instance_role_arn    = "arn:aws:iam::${local.account_id}:role/cicd-foundations-instance"
  instance_profile_arn = "arn:aws:iam::${local.account_id}:instance-profile/cicd-foundations-instance"
}

data "aws_iam_policy_document" "apply_permissions" {
  # IAM: only the instance role, nothing else (so the apply role can't edit itself)
  statement {
    sid = "InstanceRole"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
      "iam:TagRole", "iam:UntagRole",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = [local.instance_role_arn]
  }

  statement {
    sid = "InstanceProfile"
    actions = [
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
      "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
    ]
    resources = [local.instance_profile_arn]
  }

  # Attach or detach exactly one managed policy
  statement {
    sid       = "AttachSsmPolicyOnly"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = [local.instance_role_arn]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
    }
  }

  # Hand the instance role to EC2 and nothing else
  statement {
    sid       = "PassInstanceRole"
    actions   = ["iam:PassRole"]
    resources = [local.instance_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # EC2 and VPC, Stockholm only
  statement {
    sid = "Ec2Network"
    actions = [
      "ec2:AssociateRouteTable", "ec2:AttachInternetGateway",
      "ec2:AuthorizeSecurityGroupEgress", "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CreateInternetGateway", "ec2:CreateRoute", "ec2:CreateRouteTable",
      "ec2:CreateSecurityGroup", "ec2:CreateSubnet", "ec2:CreateTags", "ec2:CreateVpc",
      "ec2:DeleteInternetGateway", "ec2:DeleteRouteTable", "ec2:DeleteSecurityGroup",
      "ec2:DeleteSubnet", "ec2:DeleteTags", "ec2:DeleteVpc",
      "ec2:DescribeImages", "ec2:DescribeInstanceAttribute",
      "ec2:DescribeInstanceCreditSpecifications", "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypes", "ec2:DescribeInternetGateways",
      "ec2:DescribeNetworkAcls", "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeRouteTables", "ec2:DescribeSecurityGroupRules",
      "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeTags",
      "ec2:DescribeVolumes", "ec2:DescribeVpcAttribute", "ec2:DescribeVpcs",
      "ec2:DetachInternetGateway", "ec2:DisassociateRouteTable",
      "ec2:ModifySubnetAttribute", "ec2:ModifyVpcAttribute",
      "ec2:RevokeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress",
      "ec2:RunInstances", "ec2:TerminateInstances",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["eu-north-1"]
    }
  }

  # Encrypted root volume uses the default EBS key, only via EC2
  statement {
    sid = "EbsEncryption"
    actions = [
      "kms:CreateGrant", "kms:GenerateDataKeyWithoutPlaintext",
      "kms:DescribeKey", "kms:Decrypt",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ec2.eu-north-1.amazonaws.com"]
    }
  }

  # SSM: run the shell document on instances in this account, read results
  statement {
    sid     = "SsmSendCommand"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ssm:eu-north-1::document/AWS-RunShellScript",
      "arn:aws:ec2:eu-north-1:${local.account_id}:instance/*",
    ]
  }

  statement {
    sid       = "SsmRead"
    actions   = ["ssm:GetCommandInvocation", "ssm:DescribeInstanceInformation"]
    resources = ["*"]
  }

  statement {
    sid       = "AmiLookup"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:eu-north-1::parameter/aws/service/ami-amazon-linux-latest/*"]
  }

  # S3: Terraform state (infra/ only) and the artifacts bucket
  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.bucket}"]
  }

  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.bucket}/infra/*"]
  }

  statement {
    sid     = "UploadBuilds"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.artifacts.arn}/app/*",
      "${aws_s3_bucket.artifacts.arn}/deploy/*",
    ]
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "terraform-apply"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_permissions.json
}

# --- Plan role: pull requests, read-only ---

data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.repo}:pull_request",
        "repo:${local.repo_with_ids}:pull_request"
      ]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "github-actions-plan"
  assume_role_policy = data.aws_iam_policy_document.plan_trust.json
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_state" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.bucket}"]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.bucket}/infra/*"]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state-access"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_state.json
}

# --- Build artifacts: pipeline uploads, EC2 pulls via SSM ---

resource "aws_s3_bucket" "artifacts" {
  #checkov:skip=CKV_AWS_21:Disposable builds expire after 7 days; versioning would only add cost
  #checkov:skip=CKV_AWS_145:Bucket is already encrypted with SSE-S3; KMS adds cost for no benefit here
  #checkov:skip=CKV_AWS_18:Access logging needs a second bucket; overkill for disposable build artifacts
  #checkov:skip=CKV_AWS_144:Cross-region replication is pointless for disposable single-region artifacts
  #checkov:skip=CKV2_AWS_62:Nothing consumes bucket events
  bucket = "artifacts-318432260330-eu-north-1"
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-builds"
    status = "Enabled"

    filter {
      prefix = "app/"
    }

    expiration {
      days = 7
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

output "apply_role_arn" {
  value = aws_iam_role.apply.arn
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.id
}
