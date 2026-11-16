# ONE-TIME SETUP. Run this from your laptop (terraform init && terraform apply).
# It creates the things GitHub Actions needs BEFORE it can run:
#   1. An S3 bucket to store Terraform state
#   2. A limited IAM user for GitHub Actions (OIDC is blocked on this account)
# Its own state stays local (bootstrap/terraform.tfstate). Do not delete that file.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "ap-southeast-2"
}

variable "project_name" {
  type    = string
  default = "ebs-snapshot-cleanup"
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  state_bucket = "${var.project_name}-tfstate-${local.account_id}"
}

# ---------- 1. S3 bucket for Terraform state ----------

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------- 2. IAM user for GitHub Actions ----------
# GitHub OIDC is blocked on this account by an AWS-managed SCP
# (iam:*OpenIDConnectProvider* is explicitly denied). Fallback: a dedicated
# IAM user with ONLY the permissions this project needs. You create its access
# key in the console and store it as encrypted GitHub Secrets.

resource "aws_iam_user" "github_actions" {
  name = "${var.project_name}-github-actions"
}

# What GitHub Actions may do: manage only this project's resources.
data "aws_iam_policy_document" "github_permissions" {
  statement {
    sid = "ManageProjectServices"
    actions = [
      "lambda:*",
      "events:*",
      "sns:*",
      "cloudwatch:*",
      "logs:*",
      "budgets:*",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ManageOnlyProjectRoles"
    actions = [
      "iam:GetRole",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:PassRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project_name}-*"]
  }

  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "StateBucketObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_user_policy" "github_actions" {
  name   = "${var.project_name}-github-actions-policy"
  user   = aws_iam_user.github_actions.name
  policy = data.aws_iam_policy_document.github_permissions.json
}

output "state_bucket_name" {
  description = "Put this in terraform/backend.tf"
  value       = aws_s3_bucket.state.bucket
}

output "github_actions_user_name" {
  description = "Create an access key for this user in the IAM console"
  value       = aws_iam_user.github_actions.name
}
