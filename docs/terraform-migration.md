# Terraform Migration Guide

## 概要

HeraclesプロジェクトのOCIインフラストラクチャをOCI CLIからTerraformに移行しました。

## 変更内容

### Before (OCI CLI)

- `bootstrap-oke.sh` スクリプト内でOCI CLIコマンドを直接実行
- リソースのOCIDを環境変数で管理
- 手動での状態管理

### After (Terraform)

- Terraformでインフラストラクチャを定義
- `.tfstate` ファイルでの状態管理
- OCI Object Storageでのリモートバックエンド

## ファイル構成

```plaintext
platform/environments/prod/
├── main.tf                    # Kubernetes リソース（既存）
├── oci-infrastructure.tf      # OCI インフラリソース（新規）
├── providers.tf               # プロバイダー設定（新規）
├── variables.tf               # 変数定義（新規）
├── outputs.tf                 # 出力値定義（新規）
└── terraform.tfvars.example   # 設定例ファイル（新規）
```

## セットアップ手順

### 1. Object Storage Bucket作成

```bash
# Object Storage namespace取得
oci os ns get

# Terraform状態管理用バケット作成
oci os bucket create \
  --compartment-id $OCI_COMPARTMENT_OCID \
  --name heracles-terraform-state
```

### 2. 設定ファイル作成

```bash
cd platform/environments/prod
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` を編集して以下を設定：

- `tenancy_ocid`: テナンシーOCID
- `compartment_ocid`: コンパートメントOCID  
- `user_ocid`: ユーザーOCID
- `fingerprint`: APIキーのフィンガープリント
- `private_key_path`: 秘密鍵ファイルのパス
- `object_storage_namespace`: Object Storageの名前空間

### 3. Backend設定更新

`main.tf` のbackend設定で `namespace` を実際の値に更新：

```hcl
backend "s3" {
  bucket                      = "heracles-terraform-state"
  key                         = "prod/terraform.tfstate"
  region                      = "ap-tokyo-1"
  endpoint                    = "https://<your-namespace>.compat.objectstorage.ap-tokyo-1.oraclecloud.com"
  skip_region_validation      = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  force_path_style            = true
}
```

### 4. デプロイ実行

```bash
./bootstrap-oke.sh
```

## メリット

1. **状態管理**: Terraformの状態ファイルでリソースの状態を管理
2. **冪等性**: 何度実行しても同じ結果
3. **変更管理**: `terraform plan` で変更内容を事前確認
4. **依存関係**: リソース間の依存関係を自動管理
5. **リモートバックエンド**: 複数人での開発に対応

## 無料枠設定

Oracle Cloud Always Free tierの制限内で動作するよう設定：

- **Compute**: VM.Standard.A1.Flex (ARM) 4 OCPU、24GB RAM
- **OKE**: 管理クラスター（無料）
- **Object Storage**: 20GB（無料）
- **Load Balancer**: 1個（無料）

## トラブルシューティング

### terraform.tfvars が見つからない

```bash
cp platform/environments/prod/terraform.tfvars.example platform/environments/prod/terraform.tfvars
# 必要な値を設定
```

### Object Storage 認証エラー

- S3用OCI認証情報を設定（S3互換）：

```bash
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
```

### Node Image OCID エラー

- 最新のOracle Linux ARM64イメージOCIDを確認：

```bash
oci compute image list \
  --compartment-id $OCI_COMPARTMENT_OCID \
  --operating-system "Oracle Linux" \
  --shape "VM.Standard.A1.Flex"
```
