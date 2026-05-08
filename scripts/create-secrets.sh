#!/usr/bin/env bash
# ── Secrets Bootstrap ─────────────────────────────────────────────────────────
# Run ONCE to create all secrets in AWS Secrets Manager.
# After this, External Secrets Operator syncs them to K8s automatically.
# You NEVER store these in GitHub or environment variables.

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-hello-world}"
ENV="${ENV:-prod}"

PREFIX="${PROJECT}/${ENV}"

echo "🔐 Creating secrets in AWS Secrets Manager..."
echo "   Prefix: ${PREFIX}"
echo "   Region: ${AWS_REGION}"
echo ""

# ── Helper function ───────────────────────────────────────────────────────────
create_or_update_secret() {
  local name="$1"
  local description="$2"
  local secret_value="$3"

  local full_name="${PREFIX}/${name}"

  if aws secretsmanager describe-secret \
       --secret-id "$full_name" \
       --region "$AWS_REGION" &>/dev/null; then
    echo "  Updating: $full_name"
    aws secretsmanager update-secret \
      --secret-id "$full_name" \
      --secret-string "$secret_value" \
      --region "$AWS_REGION" > /dev/null
  else
    echo "  Creating: $full_name"
    aws secretsmanager create-secret \
      --name "$full_name" \
      --description "$description" \
      --secret-string "$secret_value" \
      --region "$AWS_REGION" \
      --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENV}" \
      > /dev/null
  fi
}

# ── Generate strong passwords ─────────────────────────────────────────────────
generate_password() {
  openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# ── Grafana ───────────────────────────────────────────────────────────────────
echo "📊 Grafana credentials..."
GRAFANA_PASS=$(generate_password)
create_or_update_secret \
  "grafana" \
  "Grafana admin credentials" \
  "{\"admin-user\":\"admin\",\"admin-password\":\"${GRAFANA_PASS}\"}"

echo "   ✅ Grafana password: ${GRAFANA_PASS}"
echo "   Save this — you'll need it to log in!"

# ── Let's Encrypt (stored for reference) ─────────────────────────────────────
echo ""
echo "📧 Let's Encrypt config..."
read -rp "Enter your email for Let's Encrypt notifications: " LE_EMAIL
create_or_update_secret \
  "letsencrypt" \
  "Let's Encrypt ACME account config" \
  "{\"email\":\"${LE_EMAIL}\"}"

# ── App secrets (example) ─────────────────────────────────────────────────────
echo ""
echo "🔑 Application secrets..."
APP_SECRET=$(generate_password)
create_or_update_secret \
  "app" \
  "Hello World application secrets" \
  "{\"secret-key\":\"${APP_SECRET}\"}"

echo ""
echo "✅ All secrets created in AWS Secrets Manager!"
echo ""
echo "Secrets created:"
aws secretsmanager list-secrets \
  --region "$AWS_REGION" \
  --filter Key=name,Values="${PREFIX}/" \
  --query 'SecretList[].Name' \
  --output table

echo ""
echo "Next: External Secrets Operator will sync these to"
echo "Kubernetes secrets automatically after cluster is up."
echo ""
echo "To view a secret value later:"
echo "  aws secretsmanager get-secret-value \\"
echo "    --secret-id ${PREFIX}/grafana \\"
echo "    --query SecretString \\"
echo "    --output text | python3 -m json.tool"
