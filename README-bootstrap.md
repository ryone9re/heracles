# Heracles 0からの完全構築ガイド

このガイドでは、Oracle Kubernetes Engine (OKE) 上でHeracles環境を完全に0から構築する手順を説明します。

## 🎯 構成概要

**インフラ構成:**
- **OKEクラスター**: コントロールプレーン（無料）+ ワーカー4台
- **ワーカーノード**: VM.Standard.A1.Flex（各1 OCPU, 6GB RAM）
- **総リソース**: 4 OCPU, 24GB RAM（無料枠フル活用）

**アーキテクチャ:**
- **GitOps**: ArgoCD によるアプリケーション管理
- **シークレット管理**: HashiCorp Vault + External Secrets Operator
- **監視**: Prometheus + Grafana + Loki + Tempo
- **データベース**: PostgreSQL/Redis Operators
- **レジストリ**: Harbor
- **サーバーレス**: Knative

## 🚀 クイックスタート

### 1. 事前準備

```bash
# 必要なツールのインストール確認
oci --version           # Oracle Cloud CLI
kubectl version        # Kubernetes CLI
helm version          # Helm Package Manager
terraform --version   # Infrastructure as Code

# OCI環境変数設定
export OCI_COMPARTMENT_OCID="ocid1.compartment.oc1..your-compartment-id"
export GITHUB_TOKEN="ghp_your-github-token"  # オプション
```

### 2. 完全構築（ワンコマンド）

```bash
# OKE環境構築（20-30分）
./bootstrap-oke.sh

# アプリケーション展開（15-20分）
./deploy-apps.sh
```

### 3. アクセス確認

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
# bootstrap-oke.sh の実行内容:
# 1. VCN・サブネット作成
# 2. OKEクラスター作成（コントロールプレーン）
# 3. ワーカーノードプール作成（4台）
# 4. kubectl設定
# 5. Terraform実行（名前空間・ArgoCD）
# 6. ArgoCD初期設定
# 7. Vault初期化・設定

./bootstrap-oke.sh --help  # ヘルプ表示
```

**実行時間**: 約20-30分

**出力例**:
```
🌐 OKEクラスター: heracles-oke-cluster
🎯 リソース合計: 4 OCPU, 24GB RAM（無料枠フル活用）
🔐 ArgoCD Admin: admin / AbCdEf123456
```

### ステップ2: アプリケーション展開

```bash
# deploy-apps.sh の実行内容:
# 1. ArgoCD Applications同期
# 2. コアサービス展開（Ingress、cert-manager）
# 3. Vault設定完了
# 4. 監視スタック展開
# 5. データベースオペレーター展開
# 6. Harbor・Knative展開

./deploy-apps.sh --help  # ヘルプ表示
```

**実行時間**: 約15-20分

**段階実行も可能**:
```bash
./deploy-apps.sh --sync-only    # ArgoCD同期のみ
./deploy-apps.sh --verify-only  # 検証のみ
```

### ステップ3: バックアップ・災害復旧

```bash
# 定期バックアップ
./disaster-recovery.sh backup

# バックアップ一覧
./disaster-recovery.sh list

# 復元
./disaster-recovery.sh restore ~/.heracles/backups/backup.tar.gz

# 災害復旧テスト
./disaster-recovery.sh test
```

## 🔧 個別コンポーネント操作

### ArgoCD

```bash
# Applications確認
kubectl get applications -n argocd

# 手動同期
kubectl patch application <app-name> -n argocd -p '{"operation":{"sync":{}}}' --type merge

# UI アクセス
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080 (admin/パスワード)
```

### Vault

```bash
# 状態確認
kubectl exec vault-0 -n vault -- vault status

# キー情報確認
cat ~/.heracles/vault-keys.json

# UI アクセス
kubectl port-forward -n vault svc/vault 8200:8200
# http://localhost:8200
```

### 監視

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

## 🔒 セキュリティ設定

### 初期パスワード変更

```bash
# ArgoCD パスワード変更
argocd account update-password --account admin --current-password <current> --new-password <new>

# Grafana パスワード変更
kubectl exec -n observability deployment/prometheus-grafana -- grafana-cli admin reset-admin-password <new-password>
```

### Vault認証設定

```bash
# GitHub認証有効化
kubectl exec vault-0 -n vault -- vault auth enable github

# GitHub Organization設定
kubectl exec vault-0 -n vault -- vault write auth/github/config organization=<your-org>
```

## 🚨 トラブルシューティング

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

### 完全リセット

```bash
# 環境完全削除
./bootstrap-oke.sh cleanup

# 完全再構築
./disaster-recovery.sh rebuild
```

## 📊 リソース監視

### 重要メトリクス

```bash
# ノードリソース使用量
kubectl top nodes

# Pod別リソース使用量
kubectl top pods --all-namespaces

# ストレージ使用量
kubectl get pvc --all-namespaces
```

### アラート設定

Grafanaで以下のアラートを設定することを推奨:

- CPU使用率 > 80%
- メモリ使用率 > 85%
- ディスク使用率 > 90%
- Pod再起動頻度
- ArgoCD同期失敗

## 🌟 最適化のヒント

### パフォーマンス

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

## 🤝 サポート

問題が発生した場合:

1. このドキュメントのトラブルシューティングセクションを確認
2. ログ出力をチェック
3. GitHub Issues で報告

---

**🎯 目標**: 無料枠内で本格的なクラウドネイティブ環境の構築完了！