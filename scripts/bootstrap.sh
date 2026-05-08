#!/usr/bin/env bash
# ── Bootstrap Script ──────────────────────────────────────────────────────────
# Run ONCE before first terraform init.
# Creates S3 bucket for remote state + DynamoDB table for locking.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-hello-world}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
BUCKET="${PROJECT}-eks-tfstate-${ENVIRONMENT}"
TABLE="${PROJECT}-eks-tfstate-lock"

echo "🚀 Bootstrapping Terraform remote state..."
echo "   Bucket: $BUCKET"
echo "   Table:  $TABLE"
echo "   Region: $AWS_REGION"

# ── S3 Bucket ─────────────────────────────────────────────────────────────────
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "✅ S3 bucket already exists: $BUCKET"
else
  echo "Creating S3 bucket..."
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$AWS_REGION" \
    $( [[ "$AWS_REGION" != "us-east-1" ]] && echo "--create-bucket-configuration LocationConstraint=$AWS_REGION" )

  # Enable versioning — allows rollback to previous state
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

  # Enable encryption
  aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "aws:kms"
        }
      }]
    }'

  # Block all public access
  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  echo "✅ S3 bucket created: $BUCKET"
fi

# ── DynamoDB Table ────────────────────────────────────────────────────────────
if aws dynamodb describe-table --table-name "$TABLE" --region "$AWS_REGION" 2>/dev/null; then
  echo "✅ DynamoDB table already exists: $TABLE"
else
  echo "Creating DynamoDB table..."
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION"
  echo "✅ DynamoDB table created: $TABLE"
fi

echo ""
echo "✅ Bootstrap complete!"
echo ""
echo "Next steps:"
echo "  1. cd terraform/environments/prod"
echo "  2. terraform init"
echo "  3. terraform plan"
echo "  4. Push to GitHub — CI/CD handles apply"
