# Production-Grade EKS Deployment — Hello World

A production-quality deployment of a Python microservice on AWS EKS, built to demonstrate end-to-end DevOps engineering: infrastructure as code, a hardened CI/CD pipeline, canary deployments, and a full observability stack.

---

## Live Endpoints

| Service | URL |
|---------|-----|
| **Hello World App** | `http://ac5679e0b9ec34c07bb290bd10b7e057-99ce421dcc8d5c5d.elb.ap-south-1.amazonaws.com` |
| **Grafana** | `http://ac5679e0b9ec34c07bb290bd10b7e057-99ce421dcc8d5c5d.elb.ap-south-1.amazonaws.com/grafana` |

**Grafana credentials:** username `admin` / password `ChangeMe123!`

Both services are routed through the same AWS NLB via NGINX Ingress Controller — no separate load balancer for monitoring.

---

## What Was Built

### Infrastructure (Terraform)
- **VPC** — public/private subnets across 2 AZs, single NAT Gateway, VPC Flow Logs to CloudWatch
- **Network ACLs** — stateless subnet-level defence in depth (TCP + UDP rules for cross-subnet DNS)
- **EKS Cluster** — Kubernetes 1.30, private node subnets, KMS-encrypted secrets, all control plane logs to CloudWatch
- **Managed Node Group** — t3.small instances (Free Tier compatible), Cluster Autoscaler scaling 1–5 nodes
- **EBS CSI Driver** — EKS managed addon for persistent volume support
- **OIDC Provider** — enables IRSA (IAM Roles for Service Accounts) scoped per service account
- **ECR Repository** — immutable image tags, scan-on-push, lifecycle policies (keep last 10)
- **AWS Secrets Manager** — stores Grafana credentials, synced to Kubernetes via External Secrets Operator

### Application
- **FastAPI microservice** — `/` returns Hello World JSON, `/health` liveness, `/ready` readiness, `/metrics` Prometheus scrape endpoint
- **OpenTelemetry** — distributed tracing via OTLP gRPC to Tempo
- **Prometheus client** — request counter + latency histogram exposed natively
- **Multi-stage Dockerfile** — non-root user (UID 1001), read-only root filesystem, dropped all Linux capabilities

### Helm Chart
- **Canary-aware** — single chart supports both canary and stable releases via values overrides
- **HPA** — horizontal pod autoscaler (CPU + memory, min 1, max 5)
- **PodDisruptionBudget** — minimum 1 pod always available during node drain
- **NetworkPolicy** — default deny, explicit allow only for ingress-nginx and Prometheus scraping
- **Pod Security** — `restricted` policy enforced on the hello-world namespace

### Secrets Management

Secrets never live in Git or environment variables. The flow is:

```
AWS Secrets Manager  →  External Secrets Operator (ESO)  →  Kubernetes Secret  →  Pod
```

- **Grafana credentials**, **Let's Encrypt email**, and **app secrets** are stored in AWS Secrets Manager
- ESO runs with its own IRSA role scoped only to `secretsmanager:GetSecretValue`
- ESO syncs secrets into Kubernetes on first deploy and refreshes every hour
- If a secret is rotated in Secrets Manager, Kubernetes picks it up automatically within the refresh window — no pipeline re-run needed

### Horizontal Pod Autoscaler & Cluster Autoscaler

Two levels of autoscaling are configured:

**HPA (pod-level)** — scales the `hello-world` deployment between 1 and 5 replicas based on CPU (>70%) and memory (>80%). Managed by the Kubernetes metrics server.

**Cluster Autoscaler (node-level)** — when pods are pending because nodes are full, CA adds t3.small nodes up to a maximum of 5. When nodes are underutilised, CA removes them. This mirrors how real production clusters handle variable load without over-provisioning.

### Canary Deployment Strategy

Every push to `main` goes through a canary release before reaching 100% of traffic:

```
New image built and pushed to ECR (tagged with git SHA)
        │
        ▼
Canary release deployed — 20% of traffic routed to new version
(NGINX Ingress canary weight annotation, not load balancer rules)
        │
        ▼
60-second observation window
  ├── Pod readiness checked — must be Ready
  └── Restart count checked — must be ≤ 2 (no crash loops)
        │
   ┌────┴────┐
HEALTHY    UNHEALTHY
   │            │
   ▼            ▼
Promote     Auto-rollback
stable      (helm uninstall canary)
100%        Pipeline fails with error
```

The canary and stable releases are **separate Helm releases** (`hello-world-canary` and `hello-world`), each managing their own Deployment, Service, and Ingress. NGINX routes traffic by weight annotation — no DNS change, no separate load balancer.

### CI/CD Pipeline (GitHub Actions)

```
Push to main
    │
    ├─ Security Gates (non-blocking, report only)
    │   ├── pre-commit hooks
    │   ├── Gitleaks — secret scanning
    │   ├── Bandit — Python SAST
    │   ├── Checkov — Terraform IaC scan
    │   ├── Helm lint
    │   └── Hadolint — Dockerfile best practices
    │
    ├─ Build & Push
    │   ├── Docker build (tagged with git SHA)
    │   ├── Trivy — container vulnerability scan (blocks on CRITICAL/HIGH)
    │   └── Push to ECR
    │
    ├─ Terraform Apply
    │   └── Provisions/updates all infrastructure
    │
    └─ Deploy
        ├── Canary deploy — 20% traffic
        ├── 60-second health check — readiness + restart count
        ├── Auto-rollback if unhealthy
        └── Promote to stable — 100% traffic, canary removed
```

AWS authentication uses **OIDC** — no long-lived access keys stored in GitHub secrets. Each job assumes an IAM role via `sts:AssumeRoleWithWebIdentity` using a short-lived token scoped to that workflow run.

### Observability Stack

All deployed in the `monitoring` namespace via Helm, accessible through Grafana:

| Tool | Purpose |
|------|---------|
| **Prometheus** | Scrapes app metrics every 15s via ServiceMonitor |
| **Grafana** | Dashboards for SLOs, Kubernetes cluster health, logs, traces |
| **Loki + Promtail** | Log aggregation — Promtail DaemonSet ships all pod logs |
| **Tempo** | Distributed tracing — app sends traces via OTLP gRPC |
| **Alertmanager** | Multi-window burn-rate alerts (Tier 1 critical, Tier 2 warning, Tier 3 info) |

**Pre-built Grafana dashboards:**
- SLO dashboard — request rate, p95/p99 latency, error rate, error budget burn
- Kubernetes cluster — node CPU/memory, pod count, HPA status
- SLO-based alerts — Google SRE model multi-window burn rate (14.4x, 6x, 3x)

**PrometheusRules configured:**
- Recording rules for 5m/30m/1h/6h/24h request and error rates
- Error budget tracking against 99.9% SLO target
- Latency p50/p95/p99 recording rules for fast dashboard loading

### Security

| Control | Implementation |
|---------|---------------|
| No long-lived AWS keys | GitHub OIDC → `sts:AssumeRoleWithWebIdentity` |
| Pod-scoped AWS access | IRSA — each service account has its own IAM role |
| Secrets not in Git | AWS Secrets Manager + External Secrets Operator |
| KMS encryption | EKS etcd secrets encrypted at rest |
| Private node subnets | Nodes have no public IPs |
| Pod Security Admission | `restricted` for app, `privileged` for monitoring (node-exporter) |
| Read-only container FS | Prevents runtime file tampering |
| Network segmentation | NetworkPolicy default-deny per namespace |
| NACLs | Subnet-level stateless firewall |
| Supply chain | Trivy scans every image before it reaches the cluster |

---

## Accessing the Application

**App:**
```
curl http://ac5679e0b9ec34c07bb290bd10b7e057-99ce421dcc8d5c5d.elb.ap-south-1.amazonaws.com/
```
Returns:
```json
{"message": "Hello World", "version": "1.0.0", "env": "production"}
```

**Grafana:**
1. Open `http://ac5679e0b9ec34c07bb290bd10b7e057-99ce421dcc8d5c5d.elb.ap-south-1.amazonaws.com/grafana`
2. Login: `admin` / `ChangeMe123!`
3. Go to **Dashboards → Browse** to see pre-built SLO and cluster dashboards
4. Go to **Explore → Prometheus** and run `hello_world_requests_total` for live app metrics
5. Go to **Explore → Loki** and run `{namespace="hello-world"}` for app logs

---

## Repository Structure

```
.
├── app/                        # FastAPI microservice
│   ├── main.py                 # App with metrics, tracing, health endpoints
│   ├── Dockerfile              # Multi-stage, non-root, hardened
│   └── requirements.txt
├── terraform/
│   ├── bootstrap/              # S3 + DynamoDB for Terraform state
│   ├── modules/
│   │   ├── vpc/                # VPC, subnets, NACLs, flow logs
│   │   ├── eks/                # Cluster, node group, addons, OIDC
│   │   ├── irsa/               # IAM Roles for Service Accounts
│   │   ├── external-secrets/   # ESO Helm + IRSA
│   │   └── cluster-autoscaler/ # CA Helm + IRSA
│   └── environments/prod/      # Root module — wires everything together
├── helm/hello-world/           # Helm chart (app + canary support)
├── monitoring/
│   ├── external-secrets.yaml   # ESO ExternalSecret manifests
│   ├── prometheus/             # ServiceMonitor, PrometheusRules, dashboards
│   └── grafana/                # Pre-built Grafana dashboard ConfigMaps
├── .github/workflows/
│   └── ci-cd.yml               # Full CI/CD pipeline
└── scripts/
    └── bootstrap.sh            # One-time state backend setup
```

---

## Known Limitations & What Would Be Added in Production

### HTTPS / TLS
Currently serving over **HTTP only**. The infrastructure for TLS is in place (cert-manager is deployed, ClusterIssuers are configured) but requires a custom domain to complete the Let's Encrypt HTTP-01 challenge. AWS NLB hostnames (`.elb.amazonaws.com`) are not eligible for certificates.

**Production fix:** Register a domain (or use Route 53 with an existing one), point it to the NLB, and cert-manager handles certificate issuance and renewal automatically.

### Multi-Environment Pipeline
Currently there is a **single `prod` environment**. A production-grade setup would have:
- `dev` → auto-deploy on every PR merge
- `staging` → deployed after dev passes integration tests
- `prod` → requires manual approval gate after staging is healthy for N minutes

This would use Terraform workspaces or separate state backends per environment, with environment-specific variable files.

### PR-Based Deployment Strategy
Currently deploys on push to `main`. In production this would be:
- Feature branch → PR opened → runs security scans and `terraform plan` as a PR check
- PR approved + merged → deploys to dev automatically
- Promotion to staging/prod requires explicit approval in GitHub Actions

### Advanced Canary with ArgoCD Rollouts or Harness
The current canary implementation uses NGINX weight annotations and a 60-second manual health window. In real production this would be replaced with **ArgoCD Rollouts** or **Harness**, which offer:
- Automated analysis against Prometheus metrics (error rate, p99 latency) before each traffic step — no fixed time window
- Progressive traffic steps: 5% → 20% → 50% → 100%, each gated by metric thresholds
- Automatic rollback triggered by SLO breach, not just pod restarts
- Full audit trail and approval gates per environment

The Prometheus recording rules and ServiceMonitor already in this repo are ready to plug into an ArgoCD `AnalysisTemplate` — the metric queries don't need to change.

### Persistent Grafana Configuration
Grafana datasources and dashboard provisioning are handled by ConfigMaps and the kube-prometheus-stack sidecar. Some configuration (datasource URLs) required a manual fix post-deploy due to a first-boot race condition in the Prometheus operator. In production this would be handled by a proper Grafana provisioning ConfigMap update in the Helm values.

### Alertmanager Notifications
AlertManager is configured with routing rules and severity tiers but the notification receivers are commented out (no Slack webhook or PagerDuty key). In production, these would be populated from Secrets Manager via ESO.

### Single NAT Gateway
Using one NAT Gateway across both AZs to minimise cost. In production, each AZ would have its own NAT Gateway to eliminate cross-AZ traffic and remove the single point of failure for outbound internet access.
