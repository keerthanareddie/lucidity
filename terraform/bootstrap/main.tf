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
