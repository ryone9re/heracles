# heracles

ryone's lab.

## Configuration

```plaintext
platform/               ← Kubernetesクラスタ基盤周りのIaC
├── environments/
│   └── prod/
│       └── main.tf
└── modules/

gitops/                 ← ArgoCDブートストラップ + 基盤サービス管理
├── argocd/             ← ArgoCD自己引き管理用 Application配置
├── observability/      ← Observability基盤
├── rollouts/           ← Argo Rollouts用ポリシー・分析ルール
├── secrets/            ← ExternalSecrets/CSI Secrets Store用構成
└── services/           ← Knative/PG/Redis/Harbor/MinIO Operator

apps/                   ← ラボ/サーバーレスアプリケーション
└── <service-name>/
    ├── base/
    └── prod/
```

### ArgoCD

#### 🧩 デプロイと管理フロー（GitOps）

1. `gitops/rollouts/`にRollout定義を格納
2. ArgoCDのApplicationSetが該当ファイルを全環境で同期
3. 各アプリServiceのDeploymentを置き換えてRolloutリソースが動作
4. Prometheus & metricsによるRollout認可 → 安定化した自動デプロイ実現

### Observability

| データ種   | 収集・解析              | 可視化/管理 |
|------------|-------------------------|-------------|
| メトリクス | Prometheus              | Grafana     |
| ログ       | Grafana Loki            | Grafana     |
| トレース   | Grafana Tempo           | Grafana     |
| アラート   | Prometheus Alertmanager | Grafana     |

- Prometheus + Grafanaスタック上で運用
- 各種出力はOpenTelemetry（OTel）によって収集

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

#### ✅ 順序の理由と依存関係

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

#### 📋 全体構成フロー

1. ingress → cert → dns（出口系整備）
2. cilium → vault（ネットワーク・セキュリティ基盤）
3. knative（アプリ環境）
4. harbor（レジストリ）
5. postgres → redis → minio（ステートフルDB/キャッシュ/オブジェクトストレージ）
