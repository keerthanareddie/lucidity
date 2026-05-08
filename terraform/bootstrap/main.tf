# ── Bootstrap: Creates S3 + DynamoDB for Terraform remote state ───────────────
# This runs ONCE with a LOCAL backend.
# After apply, we migrate state to the S3 backend.
#
# Why separate from main Terraform?
# Because main Terraform NEEDS S3 to exist before it can init.
# This is the bootstrap problem — solved by a tiny separate config.

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  # LOCAL backend intentionally — this is the bootstrap module
  # After apply, run: terraform init -migrate-state
  # to move this state to the S3 bucket it just created
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      ManagedBy   = "Terraform"
      Purpose     = "terraform-state-backend"
      Project     = var.project
      Environment = var.environment
    }
  }
}

# ── S3 Bucket for Terraform State ─────────────────────────────────────────────
resource "aws_s3_bucket" "terraform_state" {
  bucket = "${var.project}-eks-tfstate-${var.environment}"

  # Prevent accidental deletion of state bucket
  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "${var.project}-eks-tfstate-${var.environment}" }
}

# Enable versioning — lets you recover from bad applies
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state at rest with AES256 (KMS would need the key to exist first)
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access — state files contain sensitive data
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable access logging on state bucket
resource "aws_s3_bucket" "state_logs" {
  bucket = "${var.project}-eks-tfstate-logs-${var.environment}"
}

resource "aws_s3_bucket_logging" "terraform_state" {
  bucket        = aws_s3_bucket.terraform_state.id
  target_bucket = aws_s3_bucket.state_logs.id
  target_prefix = "state-access-logs/"
}

# ── DynamoDB Table for State Locking ─────────────────────────────────────────
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "${var.project}-eks-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"   # no capacity planning needed
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # Protect lock table from deletion
  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "${var.project}-eks-tfstate-lock" }
}

# ── GitHub Actions OIDC Provider ─────────────────────────────────────────────
# Allows GitHub Actions to assume AWS roles without long-lived credentials.
# token.actions.githubusercontent.com is the fixed OIDC issuer for all GHA.
resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags = {
    Name    = "github-actions-oidc"
    Purpose = "github-actions-oidc"
  }
}

# ── IAM Role: GitHub Actions Deploy ──────────────────────────────────────────
# Trusted only by this specific repo (sub condition prevents other repos using it)
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "github_deploy" {
  name = "${var.project}-github-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github_actions.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
        }
      }
    }]
  })
  tags = { Name = "${var.project}-github-deploy" }
}

# ── IAM Policy: Deploy Permissions ───────────────────────────────────────────
resource "aws_iam_policy" "github_deploy" {
  name        = "${var.project}-github-deploy-policy"
  description = "Permissions for GitHub Actions CI/CD pipeline"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECR"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeRepositories",
          "ecr:CreateRepository",
          "ecr:DeleteRepository",
          "ecr:PutLifecyclePolicy",
          "ecr:GetLifecyclePolicy",
          "ecr:DeleteLifecyclePolicy",
          "ecr:TagResource",
          "ecr:UntagResource",
          "ecr:ListTagsForResource",
          "ecr:GetRepositoryPolicy",
          "ecr:SetRepositoryPolicy",
          "ecr:PutImageScanningConfiguration",
          "ecr:PutImageTagMutability",
        ]
        Resource = "*"
      },
      {
        Sid    = "EKS"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:CreateCluster",
          "eks:DeleteCluster",
          "eks:UpdateClusterConfig",
          "eks:UpdateClusterVersion",
          "eks:DescribeUpdate",
          "eks:ListUpdates",
          "eks:CreateNodegroup",
          "eks:UpdateNodegroupConfig",
          "eks:UpdateNodegroupVersion",
          "eks:DescribeNodegroup",
          "eks:DeleteNodegroup",
          "eks:ListNodegroups",
          "eks:CreateAddon",
          "eks:DescribeAddon",
          "eks:DescribeAddonVersions",
          "eks:UpdateAddon",
          "eks:DeleteAddon",
          "eks:ListAddons",
          "eks:TagResource",
          "eks:UntagResource",
          "eks:ListTagsForResource",
          "eks:CreateAccessEntry",
          "eks:DescribeAccessEntry",
          "eks:DeleteAccessEntry",
          "eks:AssociateAccessPolicy",
          "eks:ListAccessEntries",
          "eks:ListAssociatedAccessPolicies",
        ]
        Resource = "*"
      },
      {
        Sid    = "TerraformState"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketVersioning",
          "s3:GetEncryptionConfiguration",
        ]
        Resource = [
          "arn:aws:s3:::${var.project}-eks-tfstate-${var.environment}",
          "arn:aws:s3:::${var.project}-eks-tfstate-${var.environment}/*",
        ]
      },
      {
        Sid    = "TerraformLock"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
        ]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.project}-eks-tfstate-lock"
      },
      {
        Sid    = "IAMForTerraform"
        Effect = "Allow"
        Action = [
          "iam:CreateServiceLinkedRole",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:ListRoles",
          "iam:UpdateRole",
          "iam:PassRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:ListRolePolicies",
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:ListPolicyVersions",
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:ListRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:TagRole",
          "iam:TagPolicy",
          "iam:ListOpenIDConnectProviders",
        ]
        Resource = "*"
      },
      {
        Sid    = "VPCForTerraform"
        Effect = "Allow"
        Action = [
          "ec2:*",
        ]
        Resource = "*"
      },
      {
        Sid    = "KMSForTerraform"
        Effect = "Allow"
        Action = [
          "kms:CreateKey",
          "kms:DescribeKey",
          "kms:EnableKeyRotation",
          "kms:GetKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:ListKeys",
          "kms:ListResourceTags",
          "kms:PutKeyPolicy",
          "kms:ScheduleKeyDeletion",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:CreateAlias",
          "kms:DeleteAlias",
          "kms:ListAliases",
          "kms:CreateGrant",
          "kms:GenerateDataKey",
          "kms:Decrypt",
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogsForTerraform"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:DescribeLogGroups",
          "logs:PutRetentionPolicy",
          "logs:AssociateKmsKey",
          "logs:TagResource",
          "logs:TagLogGroup",
          "logs:ListTagsLogGroup",
          "logs:ListTagsForResource",
        ]
        Resource = "*"
      },
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project}/*"
      },
      {
        Sid    = "AutoScalingForClusterAutoscaler"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_deploy" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = aws_iam_policy.github_deploy.arn
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "state_bucket_name" {
  value       = aws_s3_bucket.terraform_state.bucket
  description = "S3 bucket for Terraform state"
}

output "dynamodb_table_name" {
  value       = aws_dynamodb_table.terraform_locks.name
  description = "DynamoDB table for state locking"
}

output "backend_config" {
  value = <<-EOF
    Add this to terraform/environments/prod/main.tf backend block:

    backend "s3" {
      bucket         = "${aws_s3_bucket.terraform_state.bucket}"
      key            = "prod/terraform.tfstate"
      region         = "${var.aws_region}"
      dynamodb_table = "${aws_dynamodb_table.terraform_locks.name}"
      encrypt        = true
    }
  EOF
}

output "github_deploy_role_arn" {
  value       = aws_iam_role.github_deploy.arn
  description = "Set this as AWS_DEPLOY_ROLE_ARN in GitHub repo secrets (Settings → Secrets → Actions)"
}

output "next_steps" {
  value = <<-EOF
    After terraform apply:
    1. Copy the github_deploy_role_arn output value
    2. Go to GitHub repo → Settings → Secrets and variables → Actions
    3. Create secret:  Name = AWS_DEPLOY_ROLE_ARN
                       Value = <paste the ARN>
    4. Push to main — the CI/CD pipeline will now authenticate via OIDC
  EOF
}
