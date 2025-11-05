# heracles

ryone's lab.

## Configuration Overview

```plaintext
platform/                 Terraform IaC (OCI networking, OKE, ArgoCD Helm)
   environments/prod/      Production env Terraform
      main.tf               Namespaces + ArgoCD Helm Release
      oci-infrastructure.tf VCN / Subnets / Cluster / Node Pool
      providers.tf          Providers (oci, k8s, helm)
      variables.tf          Input variables

gitops/                   GitOps root (App-of-Apps enabled)
   kustomization.yaml      Aggregates argocd/, observability/, rollouts/, secrets/, services/
   argocd/                 ArgoCD applications (bootstrap + component apps)
   observability/          Prometheus / Grafana / Loki / Tempo / OTel
   rollouts/               Argo Rollouts templates & policies
   secrets/                Vault & External Secrets configuration
   services/               Ingress, cert-manager, ExternalDNS, Cilium, Knative, Harbor, DB operators

apps/                     Workload/Knative service repositories (to be added)
   sample-service/         Example skeleton (base + overlays)
```

### GitOps Flow (ArgoCD)

1. Terraform applies ArgoCD Helm Release (provisions ArgoCD controllers only).
2. `deploy-oke.sh` bootstraps the root App-of-Apps (`gitops/argocd/app-of-apps.yaml`).
3. ArgoCD reconciles `gitops/kustomization.yaml` which fans out base infrastructure Applications.
4. AppProjects and sync waves orchestrate ordered bring-up (infra before platform, before data, before workloads).
5. `deploy-apps.sh` can optionally force a manual sync + readiness check (observability, infra) but is not required for routine operation.
6. ApplicationSet continuously discovers `apps/*/prod` workload folders (project: workloads) and auto-creates Application CRs.
7. Progressive delivery (Argo Rollouts) applied after core ingress/cert and metrics stacks are healthy.

Result: All cluster components (except ephemeral Knative Services) are fully GitOps-managed; manual kubectl apply is limited to initial bootstrap.

#### AppProjects Segmentation

| Project        | Scope / Components | Namespace policy |
|----------------|--------------------|------------------|
| infra          | ingress, cert-manager, external-dns, vault (PKI/secrets), base networking | any |
| observability  | prometheus, loki, tempo, grafana, otel collector/operator | observability only |
| platform       | knative (operator/serving/eventing), harbor, rollouts | any |
| data           | postgres, redis, minio, scylladb operators & clusters | any |
| workloads      | application workloads discovered via ApplicationSet under `apps/*` | apps |

Rationale: Clear RBAC & lifecycle boundaries (e.g., observability confined to its namespace) + simplified per-domain access control.

#### Sync-Wave Ordering (argocd.argoproj.io/sync-wave)

| Wave | Components | Reason |
|------|------------|--------|
| 5    | ingress-nginx | Provide HTTP entry + ACME challenge path |
| 10   | cert-manager, external-dns | Enable certificate issuance & DNS automation |
| 15   | ClusterIssuers (Let’s Encrypt prod/staging, Vault PKI) | Must exist before TLS-dependent ingresses/kourier |
| 10   | knative-operator | CRDs/operator before Serving/Eventing resources |
| 20   | knative-serving, knative-eventing | Core control planes (needs operator & certs) |
| 25   | kourier ingress for Knative | Depends on serving + TLS issuers |
| 30   | harbor | After ingress/certs to expose registry securely |
| 35   | vault (if not already applied earlier) | PKI roles post issuers; secrets backing apps |
| 40   | data operators (postgres, redis, minio, scylladb) | Stable infra before stateful services |
| 45   | observability stack (prometheus, loki, tempo, grafana, otel) | Optional earlier, but can trail infra; metrics used by rollouts |
| 50   | rollouts controller | Needs metrics endpoints for analysis templates |
| 60   | workloads (apps/*) | Deployed after platform and observability ready |

Note: Actual wave numbers are adjustable; ensure monotonic ordering. Lower waves reconcile first.

#### TLS & DNS Strategy
Dual-solver ClusterIssuers use both HTTP-01 (ingress) and DNS-01 (Cloudflare) for resilience; wildcard certificate covers `*.ryone.dev` to accelerate Knative route provisioning. Vault PKI Issuer handles internal mTLS for future service mesh/SPIFEE integration.

### Observability Stack

| Type        | Collection/Processing | Visualization |
|-------------|-----------------------|---------------|
| Metrics     | Prometheus            | Grafana       |
| Logs        | Loki                  | Grafana       |
| Traces      | Tempo                 | Grafana       |
| Alerts      | Prometheus Alertmanager | Grafana    |

All telemetry ingested via OpenTelemetry Collector; dashboards & alert rules managed as code.

```plaintext
gitops/observability/
├── prometheus/         ← kube-prometheus-stack Helm values
├── loki/               ← Loki Helm or values
├── tempo/              ← Tempo Helm or values
├── otel/               ← OTel Collector CRD/Helm values
└── grafana/
    ├── operator/       ← Grafana Operator chart
    ├── instance.yaml
    └── dashboards/     ← GrafanaDashboard CRs, AlertRule CRs
```

### Services

```plaintext
gitops/operators/services/
├── ingress/       ← ① Ingress Controller（NGINX, Contour, Traefik）
├── cert/          ← ② cert-manager（証明書発行/管理）
├── dns/           ← ③ ExternalDNS（DNSレコードの自動生成）
├── cilium/        ← ④ Cilium（ネットワーク制御・観測）
├── vault/         ← ⑤ Vault（Secret + PKI）
├── knative/       ← ⑥ Knative Serving/Eventing
├── harbor/        ← ⑦ Harbor（プライベートレジストリ）
├── postgres/      ← ⑧ PostgreSQL Operator
├── redis/         ← ⑨ Redis Operator
└── minio/         ← ⑩ MinIO Operator
```

#### ✅ 導入順序 (依存関係反映)

1. Ingress Controller
   - 外部トラフィックの入口として最初に導入
   - IngressリソースやDNS/証明書関連の基盤になるため最優先

2. cert-manager
   - TLS証明書発行に必須
   - IngressやKnativeとの連携の前提として先行導入されるべき

3. ExternalDNS
   - 指定ドメイン（例：`app.ryone.dev`）へ Let’s Encryptやヘルスチェック自動付与のために必須cert-managerとの連携が前提

4. Cilium
   - ネットワーク可視化やポリシー制御のため、Ingressとの連携（NetworkPolicy 対応）を踏まえ早期に導入

5. Vault
   - PKI backend、Secret管理基盤として
   - 他サービスの証明書やcredential設定に必要cert-managerのIssuerとして活用される可能性あり

6. Knative
   - DomainとTLS構成が完了した後に導入するとアプリ展開がスムーズ

7. Harbor
   - コンテナイメージ登録基盤として
   - Ingress・ドメイン・TLS構成後が適切

8. Postgres / Redis / MinIO
   - ステートフルサービスなので、KnativeやHarborが動くインフラが整った後に導入

#### 📋 導入フロー要約

1. ingress → cert → dns
2. cilium → vault
3. knative
4. harbor
5. postgres → redis → minio → scylladb

### 最近の改善 (2025-11)

改善済み:
- Hardened scripts (`set -euo pipefail`), idempotent Vault init
- Aligned ArgoCD Application names
- Added root `gitops/kustomization.yaml`
- Removed manual Prometheus CRD applies
- Updated SA token retrieval (`kubectl create token` fallback)
- Credential output gated by `SHOW_CREDENTIALS=true`
- Added ArgoCD `ApplicationSet` (`gitops/argocd/apps-applicationset.yaml`) for dynamic `apps/*/prod` onboarding
- Introduced Cloudflare DNS-01 `ClusterIssuer` + wildcard Certificate (`gitops/services/cert/wildcard-certificate.yaml`)
- Added dual-solver (HTTP-01 + DNS-01) Let’s Encrypt ClusterIssuers
- Added Vault PKI Issuer (`gitops/services/cert/vault-issuer.yaml`) for internal service certs
- Added Prometheus alert rules (`gitops/observability/prometheus/alerts/`)
- Added Knative domain config + sample service scaffold (`apps/sample-service`)
- Centralized logging library (`scripts/lib/logging.sh`)

今後の推奨:
- Document OCI Object Storage (S3) backend auth (extended examples)
- Split operator CRDs into separate Apps or Helm-only for idempotent upgrades
- Automate Vault PKI role + cert issuance for mTLS (Cilium + SPIFFE)
- Optimize bootstrap ordering (apply app-of-apps post bootstrap sync) & reduce manual sync script steps
- Formalize RBAC per AppProject (role bindings scoped by project)
- Add health dashboards auto-provision (Grafana Operator values)

### OCI 構築前段階手順

1. Terraform `platform/environments/prod/terraform.tfvars` を作成
2. `export OCI_COMPARTMENT_OCID=...` 必要変数設定
3. （検証）`./deploy-oke.sh --dry-run` で計画ステップログ確認
4. 問題なければ OCI 上で実行 (本ドキュメントは構築前で停止)

### 環境変数
`OCI_COMPARTMENT_OCID`, `GITHUB_TOKEN`(private repo), `SHOW_CREDENTIALS`(true=print secrets), `CF_API_TOKEN`(Cloudflare DNS), `KNATIVE_DOMAIN`(override domain)

### トラブルシュート Quick Tips
- ArgoCD apps missing: check `gitops/kustomization.yaml` & repo access
- Vault errors: verify `vault status` (Initialized=true?)
- No metrics: ensure ServiceMonitor namespaces match (`observability`)
- DNS not updating: validate ExternalDNS secret `cloudflare-api-token` & `domainFilters`
- Knative host mismatch: confirm `domain-template` & desired subdomain pattern

### Cloudflare + Knative Domain Strategy

ExternalDNS (Cloudflare provider) manages A/AAAA & TXT records for Ingress/Service.
Knative domain template set to `{{.Name}}.{{.Namespace}}.ryone.dev`. For app isolation under `apps.heracles.ryone.dev`, adjust to `{{.Name}}.{{.Namespace}}.apps.heracles.ryone.dev` and add a wildcard TLS certificate:

1. Create/update `ClusterIssuer` with DNS-01 solver (Cloudflare) if HTTP-01 not feasible.
2. Provide `CF_API_TOKEN` secret (`cloudflare-api-token`) in `external-dns` namespace.
3. Patch `KnativeServing` domain template or add `config-domain` ConfigMap.
4. Deploy a sample Knative Service (`apps/sample-service`).
5. Verify: `kubectl get ksvc -A` & DNS entry presence in Cloudflare.

### Fast Knative App Scaffold

```bash
mkdir -p apps/echo/base
cat > apps/echo/base/ksvc.yaml <<'YAML'
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
   name: echo
   namespace: apps
spec:
   template:
      spec:
         containers:
            - image: ghcr.io/ryone9re/echo:latest
               ports:
                  - containerPort: 8080
YAML
```

Add an ArgoCD ApplicationSet rule later to auto-sync new services.

Or use helper script:
```bash
./scripts/create-knative-service.sh echo ghcr.io/ryone9re/echo:latest
git add apps/echo && git commit -m "feat: add echo knative service" && git push
```
ArgoCD will auto-create the Application (thanks to `ApplicationSet`) and deploy to namespace `apps`.

---
このREADMEは最新改善を反映しています。詳細（Terraform backend 認証/自動アプリ検出）は今後拡張予定。
