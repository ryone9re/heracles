# Kubernetes サービス デプロイメント順序

## 依存関係分析

### レイヤー1: 基盤インフラ

1. **Cilium** - CNIプロバイダー（ネットワーク基盤）
2. **Cert-manager** - TLS証明書管理
3. **Ingress NGINX** - HTTP/HTTPSリバースプロキシ

### レイヤー2: セキュリティ・ストレージ基盤  

1. **Vault** - シークレット管理
2. **External Secrets Operator** - Vaultとの統合
3. **PostgreSQL** - データベース
4. **Redis** - キャッシュ・メッセージング
5. **MinIO** - オブジェクトストレージ

### レイヤー3: プラットフォームサービス

1. **ArgoCD** - GitOps デプロイメント管理
2. **Harbor** - コンテナレジストリ

### レイヤー4: 監視・運用

1. **Prometheus** - メトリクス収集
2. **Loki** - ログ集約
3. **Tempo** - 分散トレーシング
4. **OpenTelemetry Collector** - 可観測性データ収集
5. **Grafana** - 可視化・ダッシュボード

### レイヤー5: アプリケーションプラットフォーム

1. **Knative Serving** - サーバーレス
2. **Knative Eventing** - イベント処理
3. **Argo Rollouts** - 高度なデプロイメント戦略

## 注意事項

- 各レイヤーは前のレイヤーが完全に起動してから開始する
- CRDインストールと実際のリソース作成を分離する
- ヘルスチェックを各段階で実行する
- ローカル環境では一部サービスは簡略化または無効化が必要
