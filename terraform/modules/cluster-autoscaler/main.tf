# ── Cluster Autoscaler Module ─────────────────────────────────────────────────
# Provisions:
#   1. IAM policy scoped to ASGs tagged with the cluster name
#   2. IRSA role bound to the cluster-autoscaler service account
#   3. Helm release (kubernetes.github.io/autoscaler chart)
#
# The EKS node group must carry these ASG discovery tags (set in the EKS module
# call in the environment):
#   k8s.io/cluster-autoscaler/enabled               = "true"
#   k8s.io/cluster-autoscaler/<cluster-name>        = "owned"

terraform {
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.0" }
    helm = { source = "hashicorp/helm", version = "~> 2.0" }
  }
}

# ── IAM policy ────────────────────────────────────────────────────────────────
resource "aws_iam_policy" "this" {
  name        = "${var.cluster_name}-cluster-autoscaler"
  description = "Cluster Autoscaler permissions for ${var.cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadASGs"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeImages",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup",
        ]
        Resource = ["*"]
      },
      {
        # Restrict scale actions to ASGs owned by this cluster only
        Sid    = "ModifyOwnedASGs"
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled"               = "true"
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}"   = "owned"
          }
        }
      },
    ]
  })

  tags = var.tags
}

# ── IRSA role ─────────────────────────────────────────────────────────────────
module "irsa" {
  source               = "../irsa"
  cluster_name         = var.cluster_name
  oidc_provider_arn    = var.oidc_provider_arn
  oidc_provider_url    = var.oidc_provider_url
  namespace            = "kube-system"
  service_account_name = "cluster-autoscaler"
  policy_arns          = [aws_iam_policy.this.arn]
  tags                 = var.tags
}

# ── Helm release ──────────────────────────────────────────────────────────────
resource "helm_release" "this" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.chart_version
  namespace  = "kube-system"
  atomic     = true
  wait       = true
  timeout    = 300

  values = [<<-EOF
    autoDiscovery:
      clusterName: ${var.cluster_name}
    awsRegion: ${var.aws_region}
    rbac:
      serviceAccount:
        name: cluster-autoscaler
        annotations:
          eks.amazonaws.com/role-arn: ${module.irsa.role_arn}
    extraArgs:
      balance-similar-node-groups: "true"
      skip-nodes-with-system-pods: "false"
      scale-down-delay-after-add: 5m
      scale-down-unneeded-time: 5m
      scale-down-utilization-threshold: "0.5"
      max-node-provision-time: 15m
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
    podAnnotations:
      prometheus.io/scrape: "true"
      prometheus.io/port: "8085"
      prometheus.io/path: "/metrics"
    priorityClassName: system-cluster-critical
  EOF
  ]

  depends_on = [module.irsa]
}
