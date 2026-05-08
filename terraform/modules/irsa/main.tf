# ── IRSA Module ───────────────────────────────────────────────────────────────
# Creates an IAM role that a Kubernetes service account can assume.
# Principle: each pod gets exactly the permissions it needs — nothing more.

locals {
  oidc_host = replace(var.oidc_provider_url, "https://", "")
}

resource "aws_iam_role" "irsa" {
  name = "${var.cluster_name}-${var.service_account_name}-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # Scoped to EXACTLY this service account in this namespace
          "${local.oidc_host}:sub" = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

# Attach caller-supplied policies (e.g. ECR read, Secrets Manager)
resource "aws_iam_role_policy_attachment" "irsa" {
  count      = length(var.policy_arns)
  role       = aws_iam_role.irsa.name
  policy_arn = var.policy_arns[count.index]
}

# Inline policy for fine-grained ECR access (pull only — not push)
resource "aws_iam_role_policy" "ecr_pull" {
  name = "${var.cluster_name}-${var.service_account_name}-ecr-pull"
  role = aws_iam_role.irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      }
    ]
  })
}
