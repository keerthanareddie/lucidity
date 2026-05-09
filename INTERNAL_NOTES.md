# 🚀 Production-Grade EKS Hello World

A production-quality Kubernetes deployment on AWS EKS, built to demonstrate
senior DevOps engineering practices across infrastructure, security, CI/CD,
observability, and deployment strategy.

---

## 🏗️ Architecture Overview

```
Internet
    │
    ▼
Route 53 (free domain: nip.io or duckdns.org)
    │
    ▼
AWS ALB (provisioned by NGINX Ingress Controller)
    │ HTTPS only (cert-manager + Let's Encrypt — FREE)
    ▼
NGINX Ingress Controller
    │  Canary routing (20% → new, 80% → stable)
    ▼
┌─────────────────────────────────────────────┐
│  VPC (10.0.0.0/16)                          │
│  ┌─────────────────┐  ┌─────────────────┐  │
│  │  Public Subnet  │  │  Public Subnet  │  │
│  │  (NAT Gateway)  │  │  (NAT Gateway)  │  │
│  └────────┬────────┘  └────────┬────────┘  │
│           │ NACLs               │            │
│  ┌────────▼────────┐  ┌────────▼────────┐  │
│  │ Private Subnet  │  │ Private Subnet  │  │
│  │  EKS Nodes      │  │  EKS Nodes      │  │
│  │                 │  │                 │  │
│  │  hello-world ns │  │  monitoring ns  │  │
│  │  ┌───────────┐  │  │  ┌──────────┐  │  │
│  │  │ App Pods  │  │  │  │Prometheus│  │  │
│  │  │ (FastAPI) │  │  │  │ Grafana  │  │  │
│  │  └───────────┘  │  │  │   Loki   │  │  │
│  │                 │  │  │   Tempo  │  │  │
│  └─────────────────┘  └──────────────────┘ │
└─────────────────────────────────────────────┘
```

---

## 📁 Project Structure

```
.
├── app/                          # Python FastAPI microservice
│   ├── main.py                   # App with /health /ready /metrics
│   ├── Dockerfile                # Multi-stage, non-root, hardened
│   └── requirements.txt
├── terraform/
│   ├── modules/
│   │   ├── vpc/                  # VPC, subnets, NACLs, flow logs
│   │   ├── eks/                  # EKS cluster, OIDC, node group
│   │   └── irsa/                 # IAM roles for service accounts
│   └── environments/
│       └── prod/                 # Production root config
├── helm/
│   └── hello-world/              # Helm chart with canary support
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
├── monitoring/
│   └── prometheus/
│       ├── servicemonitor.yaml   # Auto-scrape config
│       └── grafana-dashboard.yaml
├── .github/
│   └── workflows/
│       ├── ci-cd.yaml            # Main CI/CD pipeline
│       └── terraform.yaml        # Infrastructure pipeline
├── .pre-commit-config.yaml       # Pre-commit security hooks
└── scripts/
    └── bootstrap.sh              # One-time state backend setup
```

---

## 🔒 Security Decisions

| Layer | Decision | Why |
|---|---|---|
| AWS Auth | OIDC (no long-lived keys) | Keys can leak; OIDC tokens expire |
| Image pull | IRSA | Pod-scoped ECR access |
| Container | Non-root user (UID 1001) | Principle of least privilege |
| Container | Read-only root filesystem | Prevents runtime tampering |
| Container | Drop ALL capabilities | Only add what's needed |
| Network | Pods in private subnets | Nodes never reachable from internet |
| Network | NACLs on subnets | Defence in depth |
| Network | NetworkPolicy: default deny | Only allow explicit ingress/egress |
| Secrets | EKS KMS encryption | Secrets encrypted at rest |
| IaC | Checkov + tfsec in CI | Catch misconfigs before apply |
| Code | Bandit + Gitleaks | SAST + secret scanning |
| Images | Trivy in CI | Block CRITICAL/HIGH CVEs |
| Dockerfile | Hadolint | Best practice enforcement |
| TLS | cert-manager + Let's Encrypt | Free, auto-renewing certificates |

---

## 🌐 How to Get a Free Domain + HTTPS

### Option 1 — nip.io (Zero setup)
```bash
# Get your ALB IP after ingress-nginx deploys
kubectl get svc -n ingress-nginx
# e.g. ALB IP: 54.123.45.67

# Your domain is automatically:
# hello-world.54.123.45.67.nip.io
# No DNS config needed — it just works!

# Update helm values:
# ingress.hosts[0].host: hello-world.54.123.45.67.nip.io
```

### Option 2 — DuckDNS (Free subdomain, persistent)
```
1. Go to https://www.duckdns.org
2. Sign in with GitHub
3. Create domain: hello-world.duckdns.org (free)
4. Point it to your ALB IP
5. cert-manager gets Let's Encrypt cert automatically
```

### Option 3 — Freenom (.tk / .ml / .ga — free TLD)
```
1. Go to https://www.freenom.com
2. Search for a free .tk domain
3. Create DNS A record → ALB IP
4. cert-manager handles TLS
```

### How cert-manager gets the certificate:
```
cert-manager sees Ingress with cert-manager.io/cluster-issuer annotation
        ↓
Creates CertificateRequest to Let's Encrypt ACME
        ↓
Let's Encrypt says: "prove you own the domain"
        ↓
cert-manager creates a temporary HTTP endpoint on /.well-known/acme-challenge/
        ↓
Let's Encrypt checks it via HTTP → verified
        ↓
Certificate issued → stored as Kubernetes Secret
        ↓
NGINX Ingress uses the secret for HTTPS — auto-renewed 30 days before expiry
```

---

## 🚀 Deployment Guide

### Prerequisites
```bash
# Install tools
brew install awscli terraform helm kubectl pre-commit

# Configure AWS CLI
aws configure

# Install pre-commit hooks
pre-commit install
pre-commit install --hook-type commit-msg
```

### Step 1 — Bootstrap Terraform state
```bash
export AWS_REGION=us-east-1
export PROJECT=hello-world
export ENVIRONMENT=prod
bash scripts/bootstrap.sh
```

### Step 2 — Configure GitHub Secrets
```
AWS_ROLE_ARN        → IAM role GitHub Actions assumes (OIDC)
GRAFANA_PASSWORD    → Grafana admin password
LETSENCRYPT_EMAIL   → Email for Let's Encrypt notifications
```

### Step 3 — Create GitHub OIDC Trust
```bash
# Create IAM role that GitHub Actions can assume
aws iam create-role \
  --role-name github-actions-hello-world \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "token.actions.githubusercontent.com:sub":
            "repo:<YOUR_GITHUB_ORG>/eks-production:*"
        }
      }
    }]
  }'

# Attach AdministratorAccess for infra provisioning
# (scope down to specific services in real prod)
aws iam attach-role-policy \
  --role-name github-actions-hello-world \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

### Step 4 — Push to GitHub
```bash
git add .
git commit -m "feat: initial production EKS setup"
git push origin main

# CI/CD pipeline triggers automatically:
# 1. Security scans (Checkov, Bandit, Gitleaks, Trivy, Hadolint)
# 2. Terraform plan → apply
# 3. Build & push Docker image to ECR
# 4. Canary deploy (20% traffic)
# 5. Health check (60 seconds)
# 6. Promote to stable (100%)
```

---

## 📊 Observability Stack

### Access Grafana
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open http://localhost:3000
# user: admin / pass: <GRAFANA_PASSWORD secret>
```

### Dashboards included
- **Hello World Service** — RPS, p95 latency, error rate, pod metrics
- **Kubernetes Cluster** — node CPU/mem, pod count, PVC usage
- **Loki** — structured JSON logs from all pods
- **Tempo** — distributed traces (click a Grafana panel → drill into trace)

### Log aggregation (Loki + Promtail)
```bash
# View logs in Grafana → Explore → Loki
# Query: {namespace="hello-world"}
# App logs are structured JSON — filterable by level, msg, etc.
```

### Traces (Tempo + OpenTelemetry)
```bash
# App sends traces to Tempo via OTLP gRPC on port 4317
# View in Grafana → Explore → Tempo
# Trace ID is returned in response headers
```

---

## 🎯 Canary Deployment Strategy

```
PR merged to main
        │
        ▼
Build & push new image (tagged with git SHA)
        │
        ▼
Deploy canary (20% traffic) via NGINX Ingress weight annotation
        │
        ▼
60-second health window
  - Error rate checked via Prometheus
  - If error rate > 1% → auto-rollback canary, pipeline fails
  - If healthy → continue
        │
        ▼
Promote to stable (100% traffic)
        │
        ▼
Remove canary deployment
```

---

## 💡 Why These Choices (Interview Talking Points)

**Why private subnets for EKS nodes?**
Nodes never get public IPs. Even if a pod is compromised, the attacker is inside a private subnet — no direct internet exposure. All outbound traffic goes via NAT Gateway.

**Why NACLs AND Security Groups?**
Security Groups are stateful and resource-level. NACLs are stateless and subnet-level — defence in depth. If a Security Group is misconfigured, the NACL is a second line of defence.

**Why OIDC instead of access keys for GitHub Actions?**
Access keys are long-lived secrets that can leak. OIDC tokens are ephemeral — they expire after the workflow run. No credential stored in GitHub.

**Why IRSA instead of node IAM role?**
Node IAM roles give all pods on the node the same AWS permissions. IRSA scopes permissions to exactly one service account — blast radius of a compromised pod is minimal.

**Why single node group?**
The assignment specifies starting with one node. The node group is configured with min=1, max=3 so it scales automatically. In real prod, you'd have dedicated node groups for system, monitoring, and app workloads.

**Why cert-manager + Let's Encrypt?**
Free, automated, auto-renewing TLS certificates. cert-manager pre-alerts 30 days before expiry. Zero manual certificate management.

**Why Loki instead of CloudWatch Logs?**
Loki is cheaper at scale (stores compressed log streams) and integrates natively with Grafana — single pane of glass for metrics, logs, and traces. CloudWatch works but costs more and requires switching tools.
