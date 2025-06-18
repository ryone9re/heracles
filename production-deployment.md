# 本番環境への展開とシークレット管理

## 本番環境デプロイメント戦略

### 1. GitOps アプローチ

```mermaid
graph TD
    A[開発者] --> B[Git Push]
    B --> C[ArgoCD]
    C --> D[Kubernetes Cluster]
    C --> E[Monitoring/Alerts]
```

### 2. 環境分離

- **Development**: `dev` ブランチ → 開発クラスター
- **Staging**: `staging` ブランチ → ステージングクラスター  
- **Production**: `main` ブランチ → 本番クラスター

### 3. プロモーション戦略

```bash
# 開発 → ステージング
git checkout staging
git merge dev
git push origin staging

# ステージング → 本番（プルリクエスト経由）
# レビュー・承認後のマージ
```

## シークレット管理アーキテクチャ

### 概要

Heraclesでは **Vault + External Secrets Operator** を使用したシークレット管理を実装：

```mermaid
graph TD
    A[HashiCorp Vault] --> B[External Secrets Operator]
    B --> C[Kubernetes Secrets]
    C --> D[アプリケーション Pod]
    
    E[クラウドプロバイダー] --> A
    F[CI/CD Pipeline] --> A
    G[運用チーム] --> A
```

### コンポーネント

#### 1. HashiCorp Vault

- **高可用性構成**: 3レプリカのHA構成
- **TLS暗号化**: 内部/外部通信の暗号化
- **認証方式**: Kubernetes Service Account認証
- **秘匿データ**: パスワード、APIキー、証明書

#### 2. External Secrets Operator

- **自動同期**: Vaultから1時間毎に秘匿情報を同期
- **テンプレート機能**: 動的なSecret生成
- **マルチクラスター対応**: ClusterSecretStore使用

#### 3. 管理対象シークレット

```yaml
# 例: データベース認証情報
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgres-credentials
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-cluster-backend
    kind: ClusterSecretStore
  target:
    name: postgres-credentials
    template:
      data:
        username: "{{ .username }}"
        password: "{{ .password }}"
  data:
    - secretKey: username
      remoteRef:
        key: postgres/main
        property: username
```

## セキュリティベストプラクティス

### 1. ゼロトラスト原則

- **最小権限**: 必要最小限のアクセス権限
- **相互認証**: すべてのコンポーネント間でmTLS
- **監査ログ**: 全アクセスの記録・監視

### 2. 秘匿情報のライフサイクル

```mermaid
graph LR
    A[生成] --> B[保存]
    B --> C[配布]
    C --> D[使用]
    D --> E[ローテーション]
    E --> F[廃棄]
```

### 3. アクセス制御

- **Vault Policies**: 細粒度のアクセス制御
- **RBAC**: Kubernetes Role-Based Access Control
- **Network Policies**: ネットワークレベルの分離

## 本番環境固有の設定

### 1. 高可用性

```yaml
# Vault HA設定例
ha:
  enabled: true
  replicas: 3
  
# データベースクラスター
postgresql:
  replicaCount: 3
  
# Redis クラスター
redis:
  cluster:
    enabled: true
    slaveCount: 2
```

### 2. 永続化ストレージ

- **CSI Driver**: 各クラウドプロバイダーのCSI
- **バックアップ**: 自動スナップショット
- **暗号化**: 保存時暗号化（AES-256）

### 3. 監視・アラート

```yaml
# Prometheus アラートルール例
groups:
- name: vault.rules
  rules:
  - alert: VaultDown
    expr: up{job="vault"} == 0
    for: 5m
    annotations:
      summary: "Vault is down"
      
  - alert: ExternalSecretsFailure
    expr: external_secrets_sync_calls_error > 0
    for: 2m
```

## デプロイメント手順

### 1. 事前準備

```bash
# Vault初期化・アンシール
kubectl exec vault-0 -- vault operator init
kubectl exec vault-0 -- vault operator unseal

# 認証設定
kubectl exec vault-0 -- vault auth enable kubernetes
kubectl exec vault-0 -- vault write auth/kubernetes/config \
    token_reviewer_jwt="$(kubectl get secret --output=jsonpath='{.data.token}' vault-auth-secret | base64 -d)" \
    kubernetes_host=https://kubernetes.default.svc:443 \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```

### 2. シークレット投入

```bash
# 初期シークレットをVaultに保存
vault kv put secret/postgres/main username=postgres password=secure-password
vault kv put secret/redis/main password=redis-password
vault kv put secret/harbor/main admin-password=harbor-admin secret-key=harbor-secret
```

### 3. ArgoCD設定

```bash
# プライベートリポジトリの認証情報
argocd repo add https://github.com/ryone9re/heracles \
    --username git-user \
    --password git-token \
    --name heracles-repo
```

## 災害復旧・バックアップ

### 1. Vaultバックアップ

```bash
# スナップショット作成
vault operator raft snapshot save backup.snap

# 復元
vault operator raft snapshot restore backup.snap
```

### 2. データベースバックアップ

- **自動バックアップ**: S3/GCS等への定期バックアップ
- **ポイントインタイム復旧**: WAL-G使用
- **クロスリージョン複製**: 異なるリージョンへのレプリケーション

## 環境別設定例

### Development

- シングルレプリカ
- ローカルストレージ
- 簡略化されたTLS設定

### Staging

- 本番同等のHA構成
- 本番データのマスキング版使用
- 全機能のテスト環境

### Production

- フル冗長化構成
- 暗号化ストレージ
- 24/7監視・アラート
- 定期バックアップ
- コンプライアンス対応

## セキュリティ監査

### 1. 定期チェック項目

- [ ] 未使用のシークレットの特定・削除
- [ ] パスワードポリシーの遵守確認
- [ ] アクセスログの監査
- [ ] 脆弱性スキャン

### 2. コンプライアンス

- **SOC 2**: システム制御の監査
- **ISO 27001**: 情報セキュリティマネジメント
- **GDPR**: 個人データ保護規則対応

## トラブルシューティング

### よくある問題

1. **External Secrets同期失敗**
   - Vault認証の確認
   - ネットワーク接続の確認
   - ポリシー設定の確認

2. **Vault Unseal失敗**
   - キーシェアの確認
   - ストレージ接続の確認

3. **シークレット更新の遅延**
   - refreshInterval設定の確認
   - Operator のリソース制限確認
