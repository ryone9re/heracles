# heracles

ryone のラボ環境 / コンテナオーケストレーション基盤。

## 構成概要 (ディレクトリ)

```plaintext
platform/                 Terraform IaC (OCI ネットワーク / OKE / ArgoCD Helm)
  environments/prod/      本番相当環境用 Terraform 定義
    main.tf               Namespace作成 + ArgoCD Helm Release
    oci-infrastructure.tf VCN / サブネット / クラスター / ノードプール
    providers.tf          プロバイダ (oci, kubernetes, helm)
    variables.tf          変数定義

gitops/                   GitOps ルート (App-of-Apps パターン)
  kustomization.yaml      argocd/, observability/, rollouts/, secrets/, services/ を集約
  argocd/                 ArgoCD Application 群 (bootstrap + コンポーネント)
  observability/          Prometheus / Grafana / Loki / Tempo / OTel 設定
  rollouts/               Argo Rollouts テンプレート & ポリシー
  secrets/                Vault / External Secrets 関連
  services/               Ingress, cert-manager, ExternalDNS, Cilium, Knative, Harbor, DB オペレータなど

apps/                     ワークロード / Knative サービス用（今後追加）
```

### GitOps フロー (ArgoCD)

1. Terraform applies ArgoCD Helm Release (provisions ArgoCD controllers only).
2. `deploy-oke.sh` bootstraps the root App-of-Apps (`gitops/argocd/app-of-apps.yaml`).
3. ArgoCD reconciles `gitops/kustomization.yaml` which fans out base infrastructure Applications.
4. AppProjects and sync waves orchestrate ordered bring-up (infra before platform, before data, before workloads).
5. `deploy-apps.sh` can optionally force a manual sync + readiness check (observability, infra) but is not required for routine operation.
6. ApplicationSet continuously discovers `apps/*/prod` workload folders (project: workloads) and auto-creates Application CRs.
7. Progressive delivery (Argo Rollouts) applied after core ingress/cert and metrics stacks are healthy.

結果: （短命な Knative Service を除き）全クラスタコンポーネントは GitOps 管理下。手動 `kubectl apply` は初期ブートストラップに限定。

#### AppProjects 区分

| Project        | Scope / Components | Namespace policy |
|----------------|--------------------|------------------|
| infra          | ingress, cert-manager, external-dns, vault (PKI/secrets), base networking | any |
| observability  | prometheus, loki, tempo, grafana, otel collector/operator | observability only |
| platform       | knative (operator/serving/eventing), harbor, rollouts | any |
| data           | postgres, redis, minio, scylladb operators & clusters | any |
| workloads      | application workloads discovered via ApplicationSet under `apps/*` | apps |

理由: RBAC とライフサイクル境界を明確化（例: 観測系は専用 namespace に閉じ込める）し、ドメイン別権限管理を簡素化。

#### Sync-Wave 順序 (argocd.argoproj.io/sync-wave)

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

注: Wave 数値は調整可能。小さい値から同期が進行する単調順序を担保。

#### TLS & DNS 戦略
ClusterIssuer は HTTP-01 (Ingress) と DNS-01 (Cloudflare) のデュアルソルバで冗長化。Wildcard 証明書 (`*.heracles.ryone.dev`) により Knative ルート確立を高速化。Vault PKI Issuer は将来的なサービスメッシュ / SPIFFE mTLS を見据えた内部証明書発行を提供。

### 観測スタック (Observability)

| Type        | Collection/Processing | Visualization |
|-------------|-----------------------|---------------|
| Metrics     | Prometheus            | Grafana       |
| Logs        | Loki                  | Grafana       |
| Traces      | Tempo                 | Grafana       |
| Alerts      | Prometheus Alertmanager | Grafana    |

メトリクス/ログ/トレースは OpenTelemetry Collector で収集。ダッシュボードとアラートルールは GitOps によりコード管理。

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

### サービス構成

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

#### ✅ 導入順序 (依存関係考慮)

1. Ingress Controller
   - 外部トラフィックの入口として最初に導入
   - IngressリソースやDNS/証明書関連の基盤になるため最優先

2. cert-manager
   - TLS証明書発行に必須
   - IngressやKnativeとの連携の前提として先行導入されるべき

3. ExternalDNS
   - 指定ドメイン（例：`app.heracles.ryone.dev`）へ Let’s Encryptやヘルスチェック自動付与のために必須cert-managerとの連携が前提

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

### Vault PKI Issuer (Kubernetes Auth) 運用

`vault-pki-issuer` は静的トークンではなく Kubernetes Auth ロール `cert-manager-pki` を介して Vault にアクセスする方式。これにより以下を実現:

- リポジトリにトークン平文を保持しない (Git 上の漏洩リスク低減)
- Token ローテーション不要 (ServiceAccount JWT を短期利用)
- 最小権限 (pki_int/sign|issue のみ update 権限)

Issuer マニフェスト抜粋 (`gitops/services/cert/vault-issuer.yaml`):
```yaml
spec:
   vault:
      server: http://vault.vault:8200
      path: pki_int/sign/heracles
      auth:
         kubernetes:
            role: cert-manager-pki
```

`deploy-oke.sh` 内の `configure_vault_cert_manager_role()` が以下を自動化:
1. `auth/kubernetes/config` (APIエンドポイント / CA / reviewer JWT)
2. `cert-manager-pki` ポリシー作成
3. `auth/kubernetes/role/cert-manager-pki` ロール作成 (SA: cert-manager, NS: cert-manager, ttl=1h)

前提: Vault にて `pki_int` (中間CA) が初期化済みで、`heracles` ロールが適切な Key Usage / TTL 設定で存在すること。未設定なら証明書発行は失敗します。


### OCI 構築前段階手順

1. Terraform `platform/environments/prod/terraform.tfvars` を作成
2. `export OCI_COMPARTMENT_OCID=...` 必要変数設定
3. （検証）`./deploy-oke.sh --dry-run` で計画ステップログ確認
4. 問題なければ OCI 上で実行 (本ドキュメントは構築前で停止)

### Terraform 変数と機密情報の扱い

`terraform.tfvars` は公開リポジトリにコミットしない前提です。代わりに `terraform.tfvars.example` をテンプレートとしてコピーし、ローカルで値を補完してください。

推奨パターン:

1. ローカル開発
   - `cp platform/environments/prod/terraform.tfvars.example platform/environments/prod/terraform.tfvars`
   - 機密値 (OCID, fingerprint, private_key_path) を編集
   - `.gitignore` で `terraform.tfvars` / `*.tfvars` を除外済み
2. CI/CD (Terraform Cloud / GitHub Actions)
   - 変数は環境変数 `TF_VAR_tenancy_ocid` などとして注入
   - もしくは Terraform Cloud の Workspace Variables に設定
3. Vault 連携 (将来)
   - Vault Provider や `terraform login` + Remote Backend で長期保管を排除
   - `private_key` を Vault の Transit 機能を使い署名のみで活用

セキュリティ注意点:

- `private_key_path` は権限 0600 を推奨 (`chmod 600 ~/.oci/oci_api_key.pem`)
- `fingerprint` だけでは秘密鍵がないと悪用困難だが、関連付けられた User OCID と組み合わさると攻撃面情報になるため公開不要
- Object Storage Namespace は公開しても大きなリスクはないが、他のテナントメタデータとの相関で識別され得るため慎重に扱う
- Always Free 上限内: Arm(A1.Flex) 合計 4 OCPU / 24GB メモリ → 設定例では node_count=4 * (1 OCPU, 6GB) = 4 OCPU / 24GB で適合

改善候補:
- `node_image_id` をハードコードせず Data Source 取得 (`data "oci_core_images" ...`) で最新パッチを自動選択
- `node_ocpus` / `node_memory_gb` を variables.tf に記述し default を Example と一致させる
- Terraform Backend を OCI Object Storage に切替し `.terraform` ディレクトリを安全に共有 (State Locking は DynamoDB 互換が無いため慎重に運用)

簡易バリデーション Checklist:

| 項目 | OK 条件 |
|------|----------|
| tenancy_ocid | `ocid1.tenancy.oc1..` で始まる |
| compartment_ocid | 利用対象 Compartment (専用 Subcompartment 推奨) |
| user_ocid | Terraform 実行ユーザー (Dynamic Group + Instance Principals 検討可) |
| fingerprint | OCI Console で表示されるキー Fingerprint と一致 |
| private_key_path | ローカル実ファイル存在 & 権限 0600 |
| region | 利用サービスが全て対応 (`ap-tokyo-1` OK) |
| object_storage_namespace | `oci os ns get` の結果 |
| A1.Flex ノード合計 | OCPU <= 4 / メモリ <= 24GB |

問題なければそのまま Example を流用して `terraform.tfvars` に実値を記入してください。

### 環境変数一覧
`OCI_COMPARTMENT_OCID`, `GITHUB_TOKEN`(private repo), `SHOW_CREDENTIALS`(true=print secrets), `CF_API_TOKEN`(Cloudflare DNS), `KNATIVE_DOMAIN`(override domain)

### トラブルシュート クイックヒント
- ArgoCD apps missing: check `gitops/kustomization.yaml` & repo access
- Vault errors: verify `vault status` (Initialized=true?)
- No metrics: ensure ServiceMonitor namespaces match (`observability`)
- DNS not updating: validate ExternalDNS secret `cloudflare-api-token` & `domainFilters`
- Knative host mismatch: confirm `domain-template` & desired subdomain pattern

### Cloudflare + Knative ドメイン戦略

ExternalDNS (Cloudflare) が Ingress/Service の A/AAAA/TXT レコードを自動管理。
Knative の domain-template は `{{.Name}}.{{.Namespace}}.heracles.ryone.dev`。もしアプリ分離サブドメイン `apps.heracles.ryone.dev` 下に集約したい場合は `{{.Name}}.{{.Namespace}}.apps.heracles.ryone.dev` へ変更し wildcard TLS を追加。

1. Create/update `ClusterIssuer` with DNS-01 solver (Cloudflare) if HTTP-01 not feasible.
2. Provide `CF_API_TOKEN` secret (`cloudflare-api-token`) in `external-dns` namespace.
3. Patch `KnativeServing` domain template or add `config-domain` ConfigMap.
4. Deploy a sample Knative Service (`apps/sample-service`).
5. Verify: `kubectl get ksvc -A` & DNS entry presence in Cloudflare.

### Knative アプリ高速スキャフォールド

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

後から ApplicationSet ルールを追加し、新規サービスを自動同期可能。

またはヘルパースクリプト使用例:
```bash
./scripts/create-knative-service.sh echo ghcr.io/ryone9re/echo:latest
git add apps/echo && git commit -m "feat: add echo knative service" && git push
```
`ApplicationSet` により ArgoCD が Application を自動生成し `apps` 名前空間へデプロイ。

---
本 README は最新改善を反映済み。Terraform Backend 認証や自動アプリ検出詳細は今後さらに拡張予定です。
