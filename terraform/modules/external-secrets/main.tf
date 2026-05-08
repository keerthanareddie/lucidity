# ── External Secrets Operator Module ─────────────────────────────────────────
# Installs ESO via Helm and creates:
#   - IRSA role so ESO can read from Secrets Manager
#   - ClusterSecretStore pointing to AWS Secrets Manager
#
# Flow:
#   AWS Secrets Manager
#         ↓  (ESO polls every refreshInterval)
#   ExternalSecret CR
#         ↓
#   Kubernetes Secret (auto-created/synced)
#         ↓
#   Pod reads secret (env var or mounted file)

terraform {
  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 5.0" }
    helm       = { source = "hashicorp/helm",        version = "~> 2.0" }
    kubernetes = { source = "hashicorp/kubernetes",  version = "~> 2.0" }
  }
}

locals {
  oidc_host = replace(var.oidc_provider_url, "https://", "")
  namespace = "external-secrets"
  sa_name   = "external-secrets"
}

# ── IAM Role for ESO (IRSA) ───────────────────────────────────────────────────
resource "aws_iam_role" "eso" {
  name = "${var.cluster_name}-external-secrets-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:${local.namespace}:${local.sa_name}"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
  tags = var.tags
}

# ESO only needs to READ secrets — not create/delete
resource "aws_iam_role_policy" "eso_secrets" {
  name = "${var.cluster_name}-eso-secrets-policy"
  role = aws_iam_role.eso.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
        ]
        # Scope to secrets with our project prefix only
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.project}/*"
      },
      {
        Sid    = "ListSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:ListSecrets"]
        Resource = "*"
      }
    ]
  })
}

# ── Install External Secrets Operator via Helm ────────────────────────────────
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.9.13"
  namespace        = local.namespace
  create_namespace = true
  atomic           = true
  wait             = true
  timeout          = 300

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.eso.arn
  }

  set {
    name  = "serviceAccount.name"
    value = local.sa_name
  }

  # Enable webhook for secret validation
  set {
    name  = "webhook.create"
    value = "true"
  }
}

# ── ClusterSecretStore → AWS Secrets Manager ──────────────────────────────────
# Cluster-wide store — all namespaces can reference it
resource "kubernetes_manifest" "cluster_secret_store" {
  depends_on = [helm_release.external_secrets]

  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "aws-secrets-manager"
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = local.sa_name
                namespace = local.namespace
              }
            }
          }
        }
      }
    }
  }
}
