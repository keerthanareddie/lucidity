# ── Production Environment ────────────────────────────────────────────────────
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes",  version = "~> 2.0" }
    helm       = { source = "hashicorp/helm",        version = "~> 2.0" }
    tls        = { source = "hashicorp/tls",         version = "~> 4.0" }
    null       = { source = "hashicorp/null",        version = "~> 3.0" }
  }

  backend "s3" {
    bucket         = "hello-world-eks-tfstate-prod"
    key            = "prod/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "hello-world-eks-tfstate-lock"
    encrypt        = true
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

provider "aws" {
  region = var.aws_region
  default_tags { tags = local.common_tags }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name]
    command     = "aws"
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name]
      command     = "aws"
    }
  }
}

locals {
  cluster_name = "${var.project}-${var.environment}"
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = "platform-team"
  }
}

# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source             = "../../modules/vpc"
  name               = local.cluster_name
  cluster_name       = local.cluster_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  tags               = local.common_tags
}

# ── EKS ───────────────────────────────────────────────────────────────────────
module "eks" {
  source             = "../../modules/eks"
  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = var.vpc_cidr
  private_subnet_ids = module.vpc.private_subnet_ids
  node_instance_type = var.node_instance_type
  node_desired_size  = var.node_desired_size
  node_min_size      = var.node_min_size
  node_max_size      = var.node_max_size
  environment        = var.environment
  # CA discovery tags must be on the node group so they propagate to the ASG
  tags = merge(local.common_tags, {
    "k8s.io/cluster-autoscaler/enabled"               = "true"
    "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
  })
}

# ── External Secrets Operator ─────────────────────────────────────────────────
module "external_secrets" {
  source            = "../../modules/external-secrets"
  cluster_name      = local.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  aws_region        = var.aws_region
  aws_account_id    = data.aws_caller_identity.current.account_id
  project           = var.project
  tags              = local.common_tags
  depends_on        = [module.eks]
}

# ── IRSA: Hello World App ─────────────────────────────────────────────────────
module "irsa_hello_world" {
  source               = "../../modules/irsa"
  cluster_name         = local.cluster_name
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_provider_url
  namespace            = "hello-world"
  service_account_name = "hello-world"
  policy_arns          = []
  tags                 = local.common_tags
}

# ── Cluster Autoscaler ────────────────────────────────────────────────────────
module "cluster_autoscaler" {
  source            = "../../modules/cluster-autoscaler"
  cluster_name      = local.cluster_name
  aws_region        = var.aws_region
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  tags              = local.common_tags
  depends_on        = [module.eks]
}

# ── Secrets Manager ──────────────────────────────────────────────────────────
import {
  to = aws_secretsmanager_secret.grafana
  id = "arn:aws:secretsmanager:ap-south-1:164761934645:secret:hello-world/prod/grafana-2PvWW9"
}

import {
  to = aws_secretsmanager_secret.letsencrypt
  id = "arn:aws:secretsmanager:ap-south-1:164761934645:secret:hello-world/prod/letsencrypt-YJSWwR"
}

import {
  to = aws_secretsmanager_secret.app
  id = "arn:aws:secretsmanager:ap-south-1:164761934645:secret:hello-world/prod/app-VtXtLm"
}
# Placeholders created here so ESO can sync on first apply.
# Real values must be updated manually via AWS console or CLI after creation —
# never commit real credentials to git.
resource "aws_secretsmanager_secret" "grafana" {
  name                    = "${var.project}/prod/grafana"
  description             = "Grafana admin credentials"
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id = aws_secretsmanager_secret.grafana.id
  secret_string = jsonencode({
    admin-user     = "admin"
    admin-password = "ChangeMe123!"   # rotate immediately after first deploy
  })
  lifecycle {
    ignore_changes = [secret_string]  # prevent Terraform overwriting manual rotations
  }
}

resource "aws_secretsmanager_secret" "letsencrypt" {
  name                    = "${var.project}/prod/letsencrypt"
  description             = "Let's Encrypt ACME account email"
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "letsencrypt" {
  secret_id     = aws_secretsmanager_secret.letsencrypt.id
  secret_string = jsonencode({ email = "pagasaikeerthanareddy@gmail.com" })
  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.project}/prod/app"
  description             = "Hello World app secrets"
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({ secret-key = "replace-with-real-secret" })
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ── EKS Addon Imports ─────────────────────────────────────────────────────────
import {
  to = module.eks.aws_eks_addon.vpc_cni
  id = "hello-world-prod:vpc-cni"
}

# ── ECR Repository ────────────────────────────────────────────────────────────
import {
  to = aws_ecr_repository.hello_world
  id = "hello-world"
}

resource "aws_ecr_repository" "hello_world" {
  name                 = "hello-world"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.common_tags
}

resource "aws_ecr_lifecycle_policy" "hello_world" {
  repository = aws_ecr_repository.hello_world.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ── Namespaces ────────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "namespaces" {
  for_each = toset(["hello-world", "monitoring", "cert-manager", "ingress-nginx", "external-secrets"])
  metadata {
    name = each.key
    labels = {
      environment = var.environment
      managed-by  = "terraform"
      "pod-security.kubernetes.io/enforce"         = each.key == "hello-world" ? "restricted" : "baseline"
      "pod-security.kubernetes.io/enforce-version" = "latest"
    }
  }
  depends_on = [module.eks]
}

# ── cert-manager ──────────────────────────────────────────────────────────────
resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.14.5"
  namespace  = "cert-manager"
  atomic     = true
  wait       = true
  timeout    = 300
  set {
    name  = "installCRDs"
    value = "true"
  }
  depends_on = [kubernetes_namespace.namespaces]
}

# ── NGINX Ingress ─────────────────────────────────────────────────────────────
resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.10.1"
  namespace  = "ingress-nginx"
  atomic     = true
  wait       = true
  timeout    = 300
  values = [<<-EOF
    controller:
      service:
        type: LoadBalancer
        annotations:
          service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
          service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
      config:
        ssl-redirect: "true"
        force-ssl-redirect: "true"
  EOF
  ]
  depends_on = [kubernetes_namespace.namespaces]
}

# ── Prometheus + Grafana ──────────────────────────────────────────────────────
resource "helm_release" "prometheus_stack" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "58.2.2"
  namespace  = "monitoring"
  atomic     = true
  wait       = true
  timeout    = 600
  values = [<<-EOF
    grafana:
      admin:
        existingSecret: grafana-admin-credentials
        userKey: admin-user
        passwordKey: admin-password
      sidecar:
        dashboards:
          enabled: true
          searchNamespace: ALL
        datasources:
          enabled: true
      additionalDataSources:
        - name: Loki
          type: loki
          url: http://loki.monitoring.svc.cluster.local:3100
          access: proxy
          isDefault: false
        - name: Tempo
          type: tempo
          url: http://tempo.monitoring.svc.cluster.local:3100
          access: proxy
          isDefault: false
      grafana.ini:
        auth.anonymous:
          enabled: false
        server:
          root_url: "%(protocol)s://%(domain)s/grafana"
    prometheus:
      prometheusSpec:
        retention: 15d
        retentionSize: "10GB"
        serviceMonitorSelectorNilUsesHelmValues: false
        ruleNamespaceSelector: {}
        ruleSelectorNilUsesHelmValues: false
    alertmanager:
      config:
        global:
          resolve_timeout: 5m
        route:
          group_by: ["namespace", "alertname", "severity"]
          group_wait: 30s
          group_interval: 5m
          repeat_interval: 4h
          receiver: "null"
          routes:
            - matchers:
                - alertname = "Watchdog"
              receiver: "null"
            - matchers:
                - severity = "critical"
              receiver: "critical"
              repeat_interval: 1h
            - matchers:
                - severity = "warning"
              receiver: "warning"
        receivers:
          - name: "null"
          - name: "critical"
            # Replace with your notification config (Slack/PagerDuty/email)
            # Example Slack:
            # slack_configs:
            #   - api_url: "https://hooks.slack.com/services/YOUR/WEBHOOK"
            #     channel: "#alerts-critical"
            #     send_resolved: true
            #     title: "[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}"
            #     text: "{{ range .Alerts }}{{ .Annotations.description }}\n{{ end }}"
          - name: "warning"
            # slack_configs:
            #   - api_url: "https://hooks.slack.com/services/YOUR/WEBHOOK"
            #     channel: "#alerts-warning"
            #     send_resolved: true
        inhibit_rules:
          - source_matchers:
              - severity = "critical"
            target_matchers:
              - severity = "warning"
            equal: ["namespace", "alertname"]
  EOF
  ]
  depends_on = [kubernetes_namespace.namespaces, null_resource.apply_external_secrets]
}

# ── Loki ──────────────────────────────────────────────────────────────────────
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  version    = "2.10.2"
  namespace  = "monitoring"
  atomic     = true
  wait       = true
  timeout    = 300
  set {
    name  = "grafana.enabled"
    value = "false"
  }
  set {
    name  = "promtail.enabled"
    value = "true"
  }
  depends_on = [kubernetes_namespace.namespaces]
}

# ── Tempo ─────────────────────────────────────────────────────────────────────
resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = "1.7.2"
  namespace  = "monitoring"
  atomic     = true
  wait       = true
  timeout    = 300
  depends_on = [kubernetes_namespace.namespaces]
}

# ── Step 1: Apply ClusterSecretStore + ExternalSecrets BEFORE Grafana ─────────
# Grafana needs grafana-admin-credentials secret to exist at deploy time.
# ESO must be installed first (module.external_secrets), then we create the
# ClusterSecretStore and ExternalSecrets so secrets sync before prometheus_stack.
resource "null_resource" "apply_external_secrets" {
  triggers = { cluster = module.eks.cluster_name }
  provisioner "local-exec" {
    command = <<-EOF
      aws eks update-kubeconfig --name ${local.cluster_name} --region ${var.aws_region}

      # Wait for ESO CRDs to be ready
      kubectl wait --for=condition=established crd/externalsecrets.external-secrets.io --timeout=120s
      kubectl wait --for=condition=established crd/clustersecretstores.external-secrets.io --timeout=120s

      # Create ClusterSecretStore pointing to AWS Secrets Manager
      cat <<YAML | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${var.aws_region}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
YAML

      # Apply ExternalSecrets (Grafana, Let's Encrypt, app)
      kubectl apply -f ${path.module}/../../../monitoring/external-secrets.yaml

      # Wait for grafana-admin-credentials to sync (up to 90s)
      for i in $(seq 1 18); do
        kubectl get secret grafana-admin-credentials -n monitoring 2>/dev/null && break
        sleep 5
      done
    EOF
  }
  depends_on = [module.external_secrets, kubernetes_namespace.namespaces]
}

# ── Step 2: Post-monitoring manifests — dashboards, alerts, cert issuers ──────
resource "null_resource" "apply_manifests" {
  triggers = { cluster = module.eks.cluster_name }
  provisioner "local-exec" {
    command = <<-EOF
      aws eks update-kubeconfig --name ${local.cluster_name} --region ${var.aws_region}

      # Get Let's Encrypt email from Secrets Manager (fallback to placeholder)
      LETSENCRYPT_EMAIL=$(aws secretsmanager get-secret-value --secret-id hello-world/prod/letsencrypt --query SecretString --output text 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['email'])" 2>/dev/null || echo "admin@example.com")
      sed "s/REPLACE_WITH_YOUR_EMAIL/$${LETSENCRYPT_EMAIL}/g" ${path.module}/../../../monitoring/dns-and-certs.yaml | kubectl apply -f -

      # Prometheus ServiceMonitor + SLO alerts + recording rules
      kubectl apply -f ${path.module}/../../../monitoring/prometheus/servicemonitor.yaml
      kubectl apply -f ${path.module}/../../../monitoring/prometheus/recording-rules.yaml

      # Grafana dashboards
      kubectl apply -f ${path.module}/../../../monitoring/prometheus/grafana-dashboard.yaml
      kubectl apply -f ${path.module}/../../../monitoring/grafana/slo-dashboard.yaml
      kubectl apply -f ${path.module}/../../../monitoring/grafana/kubernetes-cluster-dashboard.yaml
    EOF
  }
  depends_on = [
    helm_release.cert_manager,
    helm_release.prometheus_stack,
    module.cluster_autoscaler,
    null_resource.apply_external_secrets,
  ]
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "cluster_name"                    { value = module.eks.cluster_name }
output "cluster_endpoint"               { value = module.eks.cluster_endpoint }
output "ecr_repository_url"             { value = aws_ecr_repository.hello_world.repository_url }
output "hello_world_irsa_role_arn"      { value = module.irsa_hello_world.role_arn }
output "cluster_autoscaler_role_arn"    { value = module.cluster_autoscaler.role_arn }
output "get_kubeconfig_command"         { value = "aws eks update-kubeconfig --name ${local.cluster_name} --region ${var.aws_region}" }
output "get_grafana_password"           { value = "aws secretsmanager get-secret-value --secret-id hello-world/prod/grafana --query SecretString --output text | python3 -m json.tool" }
output "get_nlb_hostname"               { value = "kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'" }
