#!/usr/bin/env bash
# ── Complete Setup Script ─────────────────────────────────────────────────────
# This replaces ALL manual steps.
# Run this ONCE on your laptop before the first git push.
#
# What it does:
#   1. Verifies prerequisites
#   2. Creates GitHub OIDC trust in AWS
#   3. Runs Terraform bootstrap (S3 + DynamoDB) via Terraform
#   4. Creates secrets in AWS Secrets Manager
#   5. Prints what to add to GitHub

set -euo pipefail

# ── Config — CHANGE THESE ─────────────────────────────────────────────────────
GITHUB_USERNAME="${GITHUB_USERNAME:-}"
REPO_NAME="${REPO_NAME:-eks-production}"
AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-hello-world}"
ENV="${ENV:-prod}"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()  { echo -e "${RED}❌ $1${NC}"; exit 1; }

echo ""
echo "╔════════════════════════════════════════════╗"
echo "║   EKS Production Setup — One Time Run      ║"
echo "╚════════════════════════════════════════════╝"
echo ""

# ── Step 0: Validate config ───────────────────────────────────────────────────
if [ -z "$GITHUB_USERNAME" ]; then
  read -rp "Enter your GitHub username: " GITHUB_USERNAME
fi
echo "GitHub: $GITHUB_USERNAME/$REPO_NAME"
echo "AWS Region: $AWS_REGION"
echo ""

# ── Step 1: Check prerequisites ───────────────────────────────────────────────
echo "Checking prerequisites..."
for tool in aws terraform git; do
  if ! command -v "$tool" &>/dev/null; then
    err "$tool is not installed. Install it first."
  fi
  log "$tool found: $(command -v $tool)"
done

# Check AWS credentials work
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || err "AWS credentials not configured. Run: aws configure"
log "AWS Account: $ACCOUNT_ID"
echo ""

# ── Step 2: GitHub OIDC Provider ──────────────────────────────────────────────
echo "Setting up GitHub OIDC trust in AWS..."

# Create OIDC provider (idempotent — safe to run multiple times)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  --region "$AWS_REGION" 2>/dev/null \
  && log "OIDC provider created" \
  || log "OIDC provider already exists"

# Create trust policy
cat > /tmp/github-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringLike": {
        "token.actions.githubusercontent.com:sub":
          "repo:${GITHUB_USERNAME}/${REPO_NAME}:*"
      },
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

ROLE_NAME="github-actions-${PROJECT}"

# Create or update role
if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  warn "Role already exists — updating trust policy"
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document file:///tmp/github-trust-policy.json
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file:///tmp/github-trust-policy.json \
    --description "GitHub Actions OIDC role for $REPO_NAME" \
    > /dev/null
  log "IAM role created: $ROLE_NAME"
fi

# Attach permissions
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess 2>/dev/null || true
log "AdministratorAccess attached"

ROLE_ARN=$(aws iam get-role \
  --role-name "$ROLE_NAME" \
  --query Role.Arn --output text)
log "Role ARN: $ROLE_ARN"
echo ""

# ── Step 3: Terraform Bootstrap (S3 + DynamoDB via Terraform) ─────────────────
echo "Running Terraform bootstrap (creates S3 + DynamoDB)..."
echo "This is pure Terraform — no bash hacks for infrastructure."
echo ""

cd terraform/bootstrap

terraform init -upgrade
terraform apply -auto-approve \
  -var="aws_region=$AWS_REGION" \
  -var="project=$PROJECT" \
  -var="environment=$ENV"

STATE_BUCKET=$(terraform output -raw state_bucket_name)
LOCK_TABLE=$(terraform output -raw dynamodb_table_name)
log "S3 bucket created: $STATE_BUCKET"
log "DynamoDB table created: $LOCK_TABLE"

cd ../..
echo ""

# ── Step 4: Create Secrets in AWS Secrets Manager ─────────────────────────────
echo "Creating secrets in AWS Secrets Manager..."
echo "These NEVER go into Terraform, GitHub, or any config file."
echo ""

PREFIX="${PROJECT}/${ENV}"

create_secret() {
  local name="$1"
  local desc="$2"
  local value="$3"
  local full="${PREFIX}/${name}"

  if aws secretsmanager describe-secret \
       --secret-id "$full" --region "$AWS_REGION" &>/dev/null; then
    aws secretsmanager update-secret \
      --secret-id "$full" \
      --secret-string "$value" \
      --region "$AWS_REGION" > /dev/null
    warn "Updated existing secret: $full"
  else
    aws secretsmanager create-secret \
      --name "$full" \
      --description "$desc" \
      --secret-string "$value" \
      --region "$AWS_REGION" \
      --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENV}" \
      > /dev/null
    log "Created secret: $full"
  fi
}

gen_password() { openssl rand -base64 32 | tr -d "=+/" | cut -c1-24; }

# Grafana password
GRAFANA_PASS=$(gen_password)
create_secret "grafana" \
  "Grafana admin credentials" \
  "{\"admin-user\":\"admin\",\"admin-password\":\"${GRAFANA_PASS}\"}"

# LetsEncrypt email
read -rp "Enter email for Let's Encrypt (cert expiry notifications): " LE_EMAIL
create_secret "letsencrypt" \
  "LetsEncrypt ACME account" \
  "{\"email\":\"${LE_EMAIL}\"}"

# App secret key
APP_SECRET=$(gen_password)
create_secret "app" \
  "Hello World application secrets" \
  "{\"secret-key\":\"${APP_SECRET}\"}"

echo ""

# ── Step 5: Print Summary ─────────────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║              SETUP COMPLETE                            ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "Add this ONE secret to GitHub:"
echo ""
echo "  Repo → Settings → Secrets → Actions → New repository secret"
echo ""
echo "  Name:  AWS_ROLE_ARN"
echo "  Value: $ROLE_ARN"
echo ""
echo "Your Grafana password (save this):"
echo "  $GRAFANA_PASS"
echo ""
echo "To retrieve any secret later:"
echo "  aws secretsmanager get-secret-value \\"
echo "    --secret-id ${PREFIX}/grafana \\"
echo "    --query SecretString --output text | python3 -m json.tool"
echo ""
echo "Next steps:"
echo "  1. Add AWS_ROLE_ARN to GitHub secrets (above)"
echo "  2. git push origin main"
echo "  3. Watch the pipeline run!"
echo ""
