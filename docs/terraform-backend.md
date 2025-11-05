# Terraform Backend (OCI Object Storage S3互換) 設定ガイド

本プロジェクトは `main.tf` の backend で S3 互換設定を使用し Terraform State を OCI Object Storage に保存する想定です。

## 1. Object Storage バケット準備

1. OCI Console で Object Storage バケット作成
   - 名前例: `heracles-terraform-state`
   - 標準ストレージ / バージョニング任意
2. Namespace を確認 (例: `namespace` は endpoint に利用)

## 2. S3互換エンドポイント

Terraform `backend "s3"` 内:
```hcl
backend "s3" {
  bucket   = "heracles-terraform-state"
  key      = "prod/terraform.tfstate"
  region   = "ap-tokyo-1"               # ダミー (skip_region_validation=true)
  endpoint = "https://<namespace>.compat.objectstorage.ap-tokyo-1.oraclecloud.com"
  skip_region_validation      = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  force_path_style            = true
}
```

## 3. 認証方式

OCI Object Storage S3互換 API は AWS 署名方式をエミュレートします。Terraform S3 backend は以下の環境変数を参照するため、適切なキーを設定してください。

```bash
export AWS_ACCESS_KEY_ID="<generated_access_key>"
export AWS_SECRET_ACCESS_KEY="<generated_secret_key>"
```

### キー生成
- OCI Console > User > Customer Secret Keys > 追加
  - 生成された値を上記環境変数へ設定

## 4. 初期化とロック注意点

Terraform S3 backend は DynamoDB によるロックを前提とするオプションがありますが、OCIでは未対応。並行実行を避け単一操作を遵守してください。

## 5. 代替案

| 方法 | 利点 | 注意点 |
|------|------|--------|
| Terraform Cloud | ロック/履歴標準 | 外部SaaS依存 |
| ローカル state + Git バージョン | シンプル | 競合/漏洩リスク |
| 自前小規模鍵値ストア (Redis等) | 柔軟 | 実装工数 |

## 6. 運用推奨
- State バックアップ: バケット Lifecycleルールで週次アーカイブ
- アクセス制御: IAMポリシーでアクセスキー権限を最小化
- 定期棚卸: 使っていないキーは失効

## 7. トラブルシュート
| 症状 | 対処 |
|------|------|
| AccessDenied | キー権限/名前空間/endpoint再確認 |
| PermanentRedirect | endpoint URL / path-style 設定確認 |
| SSLHandshakeError | Corporate Proxy 影響 / CA 証明書確認 |
| StateLockTimeout | 並行実行回避 (CIのジョブ重複) |

## 8. 次のステップ
- バケットバージョニング有効化で災害復旧向上
- CI環境で AWS_* 環境変数を安全に注入 (Vault + GitHub Actions OIDC)

---
このガイドは heracles の Terraform backend 利用方針に関する補助資料です。
