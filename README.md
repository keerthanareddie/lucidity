# Production-Grade EKS Deployment — Hello World

The assignment asked for a Hello World service on Kubernetes with Prometheus and Grafana. What's here is a production-like system: hardened CI/CD pipeline with canary releases and auto-rollback, secrets never touching Git, two layers of autoscaling, distributed tracing, SLO dashboards, and 10 security controls layered from the AWS account down to the container runtime.

---

## Live Endpoints

| Service              | URL |
|----------------------|-----|
| **Hello World App**  | `http://ac5679e0b9ec34c07bb290bd10b7e057-99ce421dcc8d5c5d.elb.ap-south-1.amazonaws.com` |
| **Grafana**          | `http://ac5679e0b9ec34c07bb290bd10b7e057-99ce421dcc8d5c5d.elb.ap-south-1.amazonaws.com/grafana` |

**Grafana credentials:** username `admin` / password `mjht5%%gfdda8*ghh`

Both services share the same AWS NLB via NGINX Ingress — no separate load balancer for monitoring.

> Credentials are managed via AWS Secrets Manager and synced into Kubernetes automatically — they are never stored in Git.

---

## Requirements vs What Was Delivered

| Assignment Requirement                    | What Was Built |
|-------------------------------------------|----------------|
| EKS cluster via Terraform                 | Full VPC, EKS 1.30, node group, KMS encryption, OIDC — modular Terraform |
| Hello World microservice                  | FastAPI (Python) — `/`, `/health`, `/ready`, `/metrics` |
| Helm chart                                | Production Helm chart with HPA, PDB, NetworkPolicy, canary support |
| Prometheus + Grafana                      | Full kube-prometheus-stack + Loki + Tempo + Alertmanager |
| Deploy the application *(optional)*       | Live on EKS, publicly accessible |
| CI/CD pipeline *(beyond scope)*           | GitHub Actions — security gates, Trivy scan, canary deploy, auto-rollback |
| Canary releases *(beyond scope)*          | 20% traffic split via NGINX, health check, promotes or rolls back automatically |
| Secrets management *(beyond scope)*       | AWS Secrets Manager + External Secrets Operator — nothing in Git |
| Cluster Autoscaler *(beyond scope)*       | Node-level scaling 1–5 nodes based on pending pods |
| Distributed tracing *(beyond scope)*      | OpenTelemetry → Tempo, traces visible in Grafana Explore |
| SLO dashboards + alerts *(beyond scope)*  | Google SRE multi-window burn-rate alerting, error budget tracking |
| Security hardening *(beyond scope)*       | IRSA, Pod Security Admission, NetworkPolicy, NACLs, read-only FS |

---

## System Architecture

```
GitHub Actions
    │
    ├── Security scans (Gitleaks, Bandit, Trivy, Checkov, Hadolint)
    ├── Docker build → ECR (tagged with git SHA)
    ├── Terraform apply (infrastructure as code)
    └── Helm deploy
          ├── Canary release (20% traffic) → 60s health check
          │       ├── Healthy → promote to stable (100%)
          │       └── Unhealthy → auto-rollback, pipeline fails
          └── Stable release (100% traffic)

AWS Infrastructure
    ├── VPC (public + private subnets, 2 AZs, NAT Gateway, VPC Flow Logs)
    ├── EKS 1.30 (private nodes, KMS-encrypted etcd, all logs to CloudWatch)
    ├── ECR (immutable tags, scan-on-push)
    └── AWS Secrets Manager (Grafana creds, app secrets)

Kubernetes
    ├── NGINX Ingress Controller → AWS NLB
    ├── hello-world namespace
    │     ├── FastAPI pods (HPA: 1–5 replicas, CPU >70% / memory >80%)
    │     └── NetworkPolicy (default deny, allow ingress-nginx + Prometheus only)
    └── monitoring namespace
          ├── Prometheus (scrapes app every 15s via ServiceMonitor)
          ├── Grafana (SLO dashboard, cluster dashboard, logs, traces)
          ├── Loki + Promtail (log aggregation from all pods)
          ├── Tempo (distributed traces via OTLP gRPC)
          └── Alertmanager (multi-window burn-rate alerts)
```

---

## Standout Design Decisions

### 1. No AWS keys anywhere in the pipeline

GitHub Actions authenticates to AWS via **OIDC** (`sts:AssumeRoleWithWebIdentity`). Each workflow run gets a short-lived token scoped to that run. There are no `AWS_ACCESS_KEY_ID` secrets in GitHub at all — if the repo is compromised, there are no static credentials to steal.

### 2. Secrets flow — nothing in Git, nothing in env vars

```
AWS Secrets Manager → External Secrets Operator → Kubernetes Secret → Pod
```

ESO runs with its own IRSA role scoped to `secretsmanager:GetSecretValue` only. Rotating a secret in Secrets Manager is picked up within 1 hour with no pipeline re-run. Each service account (ESO, Cluster Autoscaler, hello-world app) has its own scoped IAM role — no shared credentials.

### 3. Canary deploy with automatic rollback

Every push to `main` deploys to 20% of traffic first. After a 60-second observation window, the pipeline checks pod readiness and restart count. If either check fails, the canary Helm release is uninstalled and the pipeline fails — the stable release continues serving 100% of traffic untouched.

```
Build → Canary (20%) → Health check → Promote stable (100%) → Remove canary
                              │
                         Unhealthy → Rollback + fail pipeline
```

In a real production system this would use **ArgoCD Rollouts** or **Harness** with automated Prometheus metric analysis per traffic step instead of a fixed time window.

### 4. Two layers of autoscaling

- **HPA** — pod-level, scales `hello-world` 1–5 replicas on CPU >70% or memory >80%
- **Cluster Autoscaler** — node-level, adds/removes EC2 nodes when pods are pending or underutilised

For a greenfield production cluster **Karpenter** is the better choice — it provisions EC2 directly via the Fleet API (seconds vs minutes), supports heterogeneous instance types, and handles spot interruptions natively.

### 5. Observability beyond Prometheus + Grafana

| Signal  | Tool             | How |
|---------|------------------|-----|
| Metrics | Prometheus       | ServiceMonitor scrapes `/metrics` every 15s |
| Logs    | Loki + Promtail  | Promtail DaemonSet ships all pod logs |
| Traces  | Tempo            | App sends traces via OTLP gRPC on startup |
| Alerts  | Alertmanager     | Google SRE multi-window burn-rate (14.4×, 6×, 3×) |

Recording rules pre-compute 5m/30m/1h/6h/24h rates so dashboards load instantly. Error budget is tracked against a 99.9% SLO target.

### 6. Security layered from AWS account to container runtime

| Layer         | Control |
|---------------|---------|
| AWS account   | OIDC auth, no static keys |
| IAM           | IRSA — one role per service account, least-privilege |
| Secrets       | AWS Secrets Manager + ESO — nothing in Git |
| Network (AWS) | Private node subnets, NACLs (stateless, TCP + UDP) |
| Network (K8s) | NetworkPolicy default-deny per namespace |
| etcd          | KMS-encrypted at rest |
| Pod           | Security Admission `restricted`, non-root UID 1001, read-only FS, all Linux capabilities dropped |
| Image         | Trivy blocks on CRITICAL/HIGH before any push to ECR |

### 7. TLS infrastructure is in place

**cert-manager** is deployed as a Kubernetes operator with `ClusterIssuer` resources configured for Let's Encrypt. It automates the full certificate lifecycle — ACME HTTP-01 challenge, stores the cert as a Kubernetes Secret, auto-renews 30 days before expiry. The only gap is a custom domain: AWS NLB hostnames (`.elb.amazonaws.com`) are not eligible for public certificates. Adding a domain + CNAME to the NLB + one annotation on the Ingress is all that's needed to enable HTTPS end-to-end.

---

## Accessing the Application

> The application is served over HTTP. If your browser shows a security warning when opening the URLs below, click **Advanced** → **Proceed to site**.

**App:**
```bash
curl http://ac5679e0b9ec34c07bb290bd10b7e057-99ce421dcc8d5c5d.elb.ap-south-1.amazonaws.com/
```
Returns:
```json
{"message": "Hello World", "version": "1.0.0", "env": "production"}
```

**Grafana:**
1. Open `http://ac5679e0b9ec34c07bb290bd10b7e057-99ce421dcc8d5c5d.elb.ap-south-1.amazonaws.com/grafana`
2. Login: `admin` / `mjht5%%gfdda8*ghh`
3. **Dashboards → Browse** — SLO dashboard and Kubernetes cluster dashboard
4. **Explore → Prometheus** → run `hello_world_requests_total` for live request metrics
5. **Explore → Loki** → run `{namespace="hello-world"}` for app logs
6. **Explore → Tempo** → search by trace ID for distributed traces

---

## Repository Structure

```
.
├── app/                        # FastAPI microservice
│   ├── main.py                 # Metrics, tracing, health endpoints
│   ├── Dockerfile              # Multi-stage, non-root, hardened
│   └── requirements.txt
├── terraform/
│   ├── bootstrap/              # S3 + DynamoDB for Terraform remote state
│   ├── modules/
│   │   ├── vpc/                # VPC, subnets, NACLs, flow logs
│   │   ├── eks/                # Cluster, node group, addons, OIDC
│   │   ├── irsa/               # IAM Roles for Service Accounts
│   │   ├── external-secrets/   # ESO Helm + IRSA
│   │   └── cluster-autoscaler/ # CA Helm + IRSA
│   └── environments/prod/      # Root module — wires everything together
├── helm/hello-world/           # Helm chart (canary + stable via values overrides)
├── monitoring/
│   ├── external-secrets.yaml   # ESO ExternalSecret manifests
│   ├── prometheus/             # ServiceMonitor, PrometheusRules
│   └── grafana/                # Pre-built dashboard ConfigMaps
├── .github/workflows/
│   └── ci-cd.yml               # Full CI/CD pipeline (security → build → infra → deploy)
└── scripts/
    └── bootstrap.sh            # One-time Terraform state backend setup
```

---

## What Would Be Added in Production

### Multi-environment promotion
Single `prod` environment currently. Production would be `dev → staging → prod`, each with its own Terraform state backend and environment-specific variable files. Promotion to staging/prod would require explicit approval gates in GitHub Actions.

### PR-based deployment
Currently deploys on push to `main`. In production: feature branch → PR triggers `terraform plan` + security scans as checks → merge to `dev` → auto-promote through environments with approval gates.

### Advanced canary (ArgoCD Rollouts or Harness)
Current canary uses a fixed 60-second health window. Production would use **ArgoCD Rollouts** with `AnalysisTemplate` querying Prometheus directly — each traffic step (5% → 20% → 50% → 100%) is gated by actual error rate and p99 latency thresholds, not a timer. The Prometheus recording rules in this repo are already written in the format ArgoCD expects — no metric changes needed.

### Alertmanager notification receivers
Alertmanager routing rules and severity tiers are configured but notification receivers (Slack, PagerDuty) are commented out as no webhook/key is available. In production these would be populated from Secrets Manager via ESO.

### Per-AZ NAT Gateways
Single NAT Gateway used across both AZs to minimise cost. Production would have one per AZ to eliminate cross-AZ traffic charges and remove the single point of outbound failure.
