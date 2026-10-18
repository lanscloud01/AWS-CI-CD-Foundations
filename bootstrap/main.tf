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

# --- Apply role: code on main, or jobs in the sandbox environment ---

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
        "repo:${local.repo}:ref:refs/heads/main",
        "repo:${local.repo_with_ids}:ref:refs/heads/main",
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

resource "aws_iam_role_policy_attachment" "apply_admin" {
  #checkov:skip=CKV_AWS_274:Admin on the apply role for now; narrowing is on the roadmap
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
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
