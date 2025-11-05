# Heracles 完全ブートストラップガイド

Oracle Kubernetes Engine (OKE) 上に Heracles 基盤を 0 から構築し、Cloudflare 管理ドメインで Knative アプリを即時公開するまでの最短手順をまとめます。

## 🎯 概要

| カテゴリ | 内容 |
|----------|------|
| クラスター | OKE (制御プレーン無料) + A1.Flex ワーカー最大4台 |
| ノード形状 | VM.Standard.A1.Flex (1 OCPU / 6GB RAM) × 4 = 4 OCPU / 24GB RAM |
| GitOps | ArgoCD (HelmでTerraform適用 + App-of-Apps) |
| Secrets | Vault + External Secrets Operator |
| Observability | Prometheus / Grafana / Loki / Tempo / OTel Collector |
| Delivery | Argo Rollouts (段階的デプロイ) |
| Registry | Harbor |
| Serverless | Knative (domain-template 変更可能) |
| DNS | ExternalDNS (Cloudflare) + cert-manager (ACME) |

> 無料枠前提構成。負荷増に合わせて `node_count` / リソース requests を後で調整してください。

## 🚀 クイックスタート

### 1. 事前準備

```bash
oci --version            # OCI CLI
kubectl version          # Kubernetes CLI
helm version             # Helm
terraform --version      # Terraform

# OCI環境変数設定
export OCI_COMPARTMENT_OCID="ocid1.compartment.oc1..your-compartment-id"
export GITHUB_TOKEN="ghp_your-github-token"              # private repo 認証が必要な場合
export CF_API_TOKEN="cf_api_token_with_dns_edit_rights"  # Cloudflare DNS 用（ExternalDNS）
export SHOW_CREDENTIALS=true                               # 初回のみ管理者PWを表示したい場合
```

### 2. 完全構築（ワンコマンド）

```bash
./deploy-oke.sh            # 基盤構築 (Terraform + ArgoCD + Vault 初期化) 20-30分
./deploy-apps.sh           # 各スタック同期 (Ingress / cert / DNS / Observability / Operators / Knative) 15-20分
```

### 3. 基本アクセス (ポートフォワード)

```bash
# ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Grafana UI
kubectl port-forward -n observability svc/prometheus-grafana 3000:80

# Harbor UI
kubectl port-forward -n harbor svc/harbor-core 8080:80
```

## 📋 詳細手順

### ステップ1: OKE基盤構築

```bash
# deploy-oke.sh の実行内容:
# 1. VCN / Subnets
# 2. OKE Cluster + NodePool
# 3. kubeconfig 生成
# 4. Terraform: Namespaces + ArgoCD Helm Release
# 5. ArgoCD 初期パスワード取得 / CLI インストール
# 6. Vault (idempotent init) & Kubernetes auth enable

./deploy-oke.sh --help  # ヘルプ表示
```

**実行時間**: 約20-30分

**出力例**:

```plaintext
🌐 OKEクラスター: heracles-oke-cluster
🎯 リソース合計: 4 OCPU, 24GB RAM（無料枠フル活用）
🔐 ArgoCD Admin: admin / AbCdEf123456
```

### ステップ2: 基盤サービス / アプリ層展開

```bash
# deploy-apps.sh の実行内容:
# 1. ArgoCD 主要アプリ同期 (bootstrap, observability, secrets, services)
# 2. Ingress / cert-manager / ExternalDNS 準備
# 3. Vault ロール & ポリシー設定 (External Secrets 連携)
# 4. Observability Stack readiness (Prometheus/Grafana etc.)
# 5. DB Operators (Postgres/Redis/MinIO/ScyllaDB) readiness
# 6. Harbor + Knative readiness

./deploy-apps.sh --help  # ヘルプ表示
```

**実行時間**: 約15-20分

**段階的実行例**:

```bash
./deploy-apps.sh --sync-only    # ArgoCD同期のみ
./deploy-apps.sh --verify-only  # 検証のみ
```

### ステップ3: Cloudflare ドメイン設定 (任意)

Cloudflare DNS + ExternalDNS + cert-manager による `{{service}}.{{namespace}}.heracles.ryone.dev` / `apps.heracles.ryone.dev` 発行:
1. `external-dns` Secret 作成: `kubectl create secret generic cloudflare-api-token -n external-dns --from-literal=api-token="$CF_API_TOKEN"`
2. 必要なら DNS-01 ClusterIssuer 追加（`docs/domain-setup.md` 参照）
3. Knative `config-domain` ConfigMap を確認/編集（`gitops/services/knative/config-domain.yaml`）
4. サンプルサービスデプロイ: `kubectl create ns apps && kubectl apply -k apps/sample-service/base`
5. `kubectl get ksvc -n apps sample-service -o jsonpath='{.status.url}'` でホスト確認

## 🔧 コンポーネント操作例

### ArgoCD

```bash
# Applications確認
kubectl get applications -n argocd

argocd app sync <app-name>   # CLI 経由の明示的同期

# UI アクセス
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080 (admin/パスワード)
```

### Vault (初期化後)

```bash
# 状態確認
kubectl exec vault-0 -n vault -- vault status

# キー情報確認
cat ~/.heracles/vault-keys.json

# UI アクセス
kubectl port-forward -n vault svc/vault 8200:8200
# http://localhost:8200
```

### Observability

```bash
# Grafana アクセス
kubectl port-forward -n observability svc/prometheus-grafana 3000:80
# http://localhost:3000 (admin/パスワード)

# Prometheus アクセス
kubectl port-forward -n observability svc/prometheus-kube-prometheus-prometheus 9090:9090
```

### Harbor

```bash
# Harbor アクセス
kubectl port-forward -n harbor svc/harbor-core 8080:80
# http://localhost:8080 (admin/パスワード)

# Docker ログイン
docker login localhost:8080
```

## 🔒 セキュリティ / ハードニング

### 初期パスワード変更

```bash
# ArgoCD パスワード変更
argocd account update-password --account admin --current-password <current> --new-password <new>

# Grafana パスワード変更
kubectl exec -n observability deployment/prometheus-grafana -- grafana-cli admin reset-admin-password <new-password>
```

### Vault追加認証例 (GitHub)

```bash
# GitHub認証有効化
kubectl exec vault-0 -n vault -- vault auth enable github

# GitHub Organization設定
kubectl exec vault-0 -n vault -- vault write auth/github/config organization=<your-org>
```

## 🚨 トラブルシュート

### よくある問題

1. **OCI認証エラー**

   ```bash
   oci setup config  # OCI CLI再設定
   ```

2. **リソース不足**

   ```bash
   kubectl top nodes  # リソース使用量確認
   ```

3. **Pod起動失敗**

   ```bash
   kubectl describe pod <pod-name> -n <namespace>
   kubectl logs <pod-name> -n <namespace>
   ```

4. **ArgoCD同期失敗**

   ```bash
   kubectl describe application <app-name> -n argocd
   ```

### リセット (手動)

現状 `cleanup` スクリプトは未提供。再構築したい場合は Terraform 管理リソースを `terraform destroy` + 手動 OCI リソース削除後に再実行。

## 📊 リソース監視と主要メトリクス

### 基本メトリクス確認

```bash
# ノードリソース使用量
kubectl top nodes

# Pod別リソース使用量
kubectl top pods --all-namespaces

# ストレージ使用量
kubectl get pvc --all-namespaces
```

### 推奨アラート (Grafana / PrometheusRule)

Grafanaで以下のアラートを設定することを推奨:

- CPU使用率 > 80%
- メモリ使用率 > 85%
- ディスク使用率 > 90%
- Pod再起動頻度
- ArgoCD同期失敗

## 🌟 最適化ヒント

### パフォーマンス調整例

1. **リソースリクエスト調整**

   ```yaml
   resources:
     requests:
       cpu: 50m
       memory: 64Mi
     limits:
       cpu: 200m
       memory: 256Mi
   ```

2. **ノードアフィニティ活用**

   ```yaml
   nodeAffinity:
     requiredDuringSchedulingIgnoredDuringExecution:
       nodeSelectorTerms:
       - matchExpressions:
         - key: kubernetes.io/arch
           operator: In
           values: ["arm64"]
   ```

### コスト最適化

1. **無料枠範囲確認**
   - A1.Flex: 最大4 OCPU, 24GB RAM
   - Block Storage: 200GB
   - Load Balancer: 1個

2. **リソース制限設定**

   ```bash
   # 名前空間別リソース制限
   kubectl apply -f gitops/base/resource-quotas.yaml
   ```

## 📚 参考資料

- [Oracle Cloud Always Free](https://www.oracle.com/cloud/free/)
- [OKE Documentation](https://docs.oracle.com/en-us/iaas/Content/ContEng/home.htm)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Vault Documentation](https://www.vaultproject.io/docs)
- [Prometheus Operator](https://prometheus-operator.dev/)

## 🤝 サポート / 次のステップ

1. ApplicationSet 導入で `apps/*` 自動同期
2. Wildcard 証明書 (`*.apps.heracles.ryone.dev`) 追加
3. Rollouts メトリクス判定ルール整備
4. Vault PKI engine を cert-manager Issuer として統合（長期）

問題発生時はトラブルシュート表と `docs/domain-setup.md` を参照してください。

問題が発生した場合:

1. このドキュメントのトラブルシューティングセクションを確認
2. ログ出力をチェック
