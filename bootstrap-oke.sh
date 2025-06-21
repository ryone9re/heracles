#!/bin/bash

# Oracle Kubernetes Engine (OKE) Bootstrap Script
# 完全な環境破壊からの復旧用スクリプト
# ryone9re/heracles プロジェクト用

set -e

# カラー出力設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# ログ関数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_step() {
    echo -e "${PURPLE}[STEP]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# 設定変数（無料枠対応）
OKE_CLUSTER_NAME="heracles-oke-cluster"
OKE_NODE_POOL_NAME="heracles-node-pool"
COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID:-}"
VCNOCE_SUBNET_OCID="${OCI_SUBNET_OCID:-}"
KUBERNETES_VERSION="v1.28.2"
NODE_SHAPE="VM.Standard.A1.Flex"  # Always Free eligible (Ampere ARM)
NODE_SHAPE_CONFIG='{
    "ocpus": 1,
    "memoryInGBs": 6
}'
NODE_COUNT=4  # 無料枠内（A1.Flex: 合計4 OCPU, 24GB RAM）+ コントロールプレーン（無料）
NODE_IMAGE_TYPE="oci"

# 前提条件チェック
check_prerequisites() {
    log_step "前提条件をチェックしています..."
    
    # OCI CLI チェック
    if ! command -v oci &> /dev/null; then
        log_error "OCI CLI がインストールされていません"
        log_info "インストール方法: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm"
        exit 1
    fi
    
    # kubectl チェック
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl がインストールされていません"
        log_info "インストール方法: https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi
    
    # Helm チェック
    if ! command -v helm &> /dev/null; then
        log_error "Helm がインストールされていません"
        log_info "インストール方法: https://helm.sh/docs/intro/install/"
        exit 1
    fi
    
    # Terraform チェック
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform がインストールされていません"
        log_info "インストール方法: https://learn.hashicorp.com/tutorials/terraform/install-cli"
        exit 1
    fi
    
    # OCI設定チェック
    if ! oci iam region list &> /dev/null; then
        log_error "OCI CLI が正しく設定されていません"
        log_info "設定方法: oci setup config"
        exit 1
    fi
    
    # 必要な環境変数チェック
    if [[ -z "$COMPARTMENT_OCID" ]]; then
        log_error "OCI_COMPARTMENT_OCID 環境変数が設定されていません"
        exit 1
    fi
    
    log_success "前提条件チェック完了"
}

# VCN とサブネットの作成
create_vcn_resources() {
    log_step "VCN とネットワークリソースを作成しています..."
    
    # VCN作成
    VCN_OCID=$(oci network vcn create \
        --compartment-id "$COMPARTMENT_OCID" \
        --display-name "heracles-vcn" \
        --cidr-block "10.0.0.0/16" \
        --query 'data.id' \
        --raw-output)
    
    log_info "VCN作成完了: $VCN_OCID"
    
    # インターネットゲートウェイ作成
    IGW_OCID=$(oci network internet-gateway create \
        --compartment-id "$COMPARTMENT_OCID" \
        --vcn-id "$VCN_OCID" \
        --display-name "heracles-igw" \
        --is-enabled true \
        --query 'data.id' \
        --raw-output)
    
    log_info "インターネットゲートウェイ作成完了: $IGW_OCID"
    
    # ルートテーブル更新
    ROUTE_TABLE_OCID=$(oci network vcn get \
        --vcn-id "$VCN_OCID" \
        --query 'data."default-route-table-id"' \
        --raw-output)
    
    oci network route-table update \
        --rt-id "$ROUTE_TABLE_OCID" \
        --route-rules '[{
            "destination": "0.0.0.0/0",
            "destinationType": "CIDR_BLOCK",
            "networkEntityId": "'$IGW_OCID'"
        }]' \
        --force
    
    # セキュリティリスト更新
    SECURITY_LIST_OCID=$(oci network vcn get \
        --vcn-id "$VCN_OCID" \
        --query 'data."default-security-list-id"' \
        --raw-output)
    
    oci network security-list update \
        --security-list-id "$SECURITY_LIST_OCID" \
        --ingress-security-rules '[
            {
                "source": "0.0.0.0/0",
                "protocol": "6",
                "isStateless": false,
                "tcpOptions": {
                    "destinationPortRange": {
                        "min": 6443,
                        "max": 6443
                    }
                }
            },
            {
                "source": "10.0.0.0/16",
                "protocol": "all",
                "isStateless": false
            }
        ]' \
        --force
    
    # ワーカーノード用サブネット作成
    WORKER_SUBNET_OCID=$(oci network subnet create \
        --compartment-id "$COMPARTMENT_OCID" \
        --vcn-id "$VCN_OCID" \
        --display-name "heracles-worker-subnet" \
        --cidr-block "10.0.1.0/24" \
        --query 'data.id' \
        --raw-output)
    
    # ロードバランサー用サブネット作成
    LB_SUBNET_OCID=$(oci network subnet create \
        --compartment-id "$COMPARTMENT_OCID" \
        --vcn-id "$VCN_OCID" \
        --display-name "heracles-lb-subnet" \
        --cidr-block "10.0.2.0/24" \
        --query 'data.id' \
        --raw-output)
    
    # API Server用サブネット作成
    API_SUBNET_OCID=$(oci network subnet create \
        --compartment-id "$COMPARTMENT_OCID" \
        --vcn-id "$VCN_OCID" \
        --display-name "heracles-api-subnet" \
        --cidr-block "10.0.3.0/24" \
        --query 'data.id' \
        --raw-output)
    
    log_success "VCNとサブネット作成完了"
    export WORKER_SUBNET_OCID LB_SUBNET_OCID API_SUBNET_OCID VCN_OCID
}

# OKEクラスターの作成
create_oke_cluster() {
    log_step "OKEクラスターを作成しています..."
    
    # クラスター作成
    CLUSTER_OCID=$(oci ce cluster create \
        --compartment-id "$COMPARTMENT_OCID" \
        --name "$OKE_CLUSTER_NAME" \
        --vcn-id "$VCN_OCID" \
        --kubernetes-version "$KUBERNETES_VERSION" \
        --service-lb-subnet-ids '["'$LB_SUBNET_OCID'"]' \
        --endpoint-subnet-id "$API_SUBNET_OCID" \
        --endpoint-is-public-ip-enabled true \
        --cluster-pod-network-options '{
            "cniType": "FLANNEL_OVERLAY"
        }' \
        --wait-for-state ACTIVE \
        --query 'data.id' \
        --raw-output)
    
    log_success "OKEクラスター作成完了: $CLUSTER_OCID"
    export CLUSTER_OCID
    
    # ノードプール作成
    log_info "ノードプールを作成しています..."
    
    NODE_POOL_OCID=$(oci ce node-pool create \
        --cluster-id "$CLUSTER_OCID" \
        --compartment-id "$COMPARTMENT_OCID" \
        --name "$OKE_NODE_POOL_NAME" \
        --kubernetes-version "$KUBERNETES_VERSION" \
        --node-image-name "Oracle-Linux-8.8-aarch64-2023.10.24-0" \
        --node-shape "$NODE_SHAPE" \
        --node-shape-config "$NODE_SHAPE_CONFIG" \
        --subnet-ids '["'$WORKER_SUBNET_OCID'"]' \
        --size "$NODE_COUNT" \
        --placement-configs '[{
            "availabilityDomain": "'$(oci iam availability-domain list --compartment-id "$COMPARTMENT_OCID" --query 'data[0].name' --raw-output)'",
            "subnetId": "'$WORKER_SUBNET_OCID'"
        }]' \
        --wait-for-state ACTIVE \
        --query 'data.id' \
        --raw-output)
    
    log_success "ノードプール作成完了: $NODE_POOL_OCID"
}

# kubectl設定
configure_kubectl() {
    log_step "kubectlを設定しています..."
    
    # OKEクラスター用のkubeconfigを取得
    oci ce cluster create-kubeconfig \
        --cluster-id "$CLUSTER_OCID" \
        --file "$HOME/.kube/config" \
        --region "$(oci iam region-subscription list --query 'data[0]."region-name"' --raw-output)" \
        --token-version "2.0.0" \
        --kube-endpoint PRIVATE_ENDPOINT
    
    # クラスター接続テスト
    if kubectl cluster-info &>/dev/null; then
        log_success "kubectl設定完了"
    else
        log_error "kubectl設定に失敗しました"
        exit 1
    fi
    
    # ノード確認
    kubectl get nodes
}

# Terraformによるインフラストラクチャプロビジョニング
deploy_terraform_infrastructure() {
    log_step "Terraformでインフラストラクチャをプロビジョニングしています..."
    
    cd platform/environments/prod
    
    # Terraform初期化
    terraform init
    
    # Terraform実行
    terraform validate
    terraform plan -out=tfplan
    terraform apply tfplan
    
    log_success "Terraformデプロイ完了"
    cd - > /dev/null
}

# ArgoCD初期設定
setup_argocd() {
    log_step "ArgoCDを設定しています..."
    
    # ArgoCD管理者パスワード取得
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "パスワード取得失敗")
    
    log_info "ArgoCD管理者パスワード: $ARGOCD_PASSWORD"
    
    # ArgoCD CLIインストール（必要に応じて）
    if ! command -v argocd &> /dev/null; then
        log_info "ArgoCD CLIをインストールしています..."
        curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
        sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
        rm argocd-linux-amd64
    fi
    
    log_success "ArgoCD設定完了"
    log_info "ArgoCD UI アクセス: kubectl port-forward svc/argocd-server -n argocd 8080:443"
}

# GitOpsリポジトリ設定
setup_gitops_repository() {
    log_step "GitOpsリポジトリを設定しています..."
    
    # ポートフォワード開始
    kubectl port-forward svc/argocd-server -n argocd 8080:443 &
    PORT_FORWARD_PID=$!
    sleep 10
    
    # ArgoCD ログイン
    argocd login localhost:8080 --username admin --password "$ARGOCD_PASSWORD" --insecure
    
    # リポジトリ追加（GitHub認証情報が必要）
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        argocd repo add https://github.com/ryone9re/heracles \
            --username "$(git config user.name)" \
            --password "$GITHUB_TOKEN" \
            --name heracles-repo
        log_success "GitHubリポジトリ追加完了"
    else
        log_warning "GITHUB_TOKEN環境変数が未設定。手動でリポジトリを追加してください"
    fi
    
    # App of Apps デプロイ
    kubectl apply -f gitops/argocd/bootstrap.yaml
    kubectl apply -f gitops/argocd/app-of-apps.yaml
    
    # ポートフォワード終了
    kill $PORT_FORWARD_PID
    
    log_success "GitOpsリポジトリ設定完了"
}

# Vault設定
setup_vault() {
    log_step "Vaultを設定しています..."
    
    # Vaultがデプロイされるまで待機
    kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=vault -n vault --timeout=300s
    
    # Vault初期化
    VAULT_INIT_OUTPUT=$(kubectl exec vault-0 -n vault -- vault operator init -key-shares=5 -key-threshold=3 -format=json)
    
    # キーとトークンを抽出
    VAULT_UNSEAL_KEYS=($(echo "$VAULT_INIT_OUTPUT" | jq -r '.unseal_keys_b64[]'))
    VAULT_ROOT_TOKEN=$(echo "$VAULT_INIT_OUTPUT" | jq -r '.root_token')
    
    # Vaultアンシール
    kubectl exec vault-0 -n vault -- vault operator unseal "${VAULT_UNSEAL_KEYS[0]}"
    kubectl exec vault-0 -n vault -- vault operator unseal "${VAULT_UNSEAL_KEYS[1]}"
    kubectl exec vault-0 -n vault -- vault operator unseal "${VAULT_UNSEAL_KEYS[2]}"
    
    # 認証設定
    kubectl exec vault-0 -n vault -- vault auth enable kubernetes
    
    # キーとトークンを安全に保存
    mkdir -p ~/.heracles
    cat > ~/.heracles/vault-keys.json << EOF
{
    "unseal_keys": [
        "${VAULT_UNSEAL_KEYS[0]}",
        "${VAULT_UNSEAL_KEYS[1]}",
        "${VAULT_UNSEAL_KEYS[2]}",
        "${VAULT_UNSEAL_KEYS[3]}",
        "${VAULT_UNSEAL_KEYS[4]}"
    ],
    "root_token": "$VAULT_ROOT_TOKEN"
}
EOF
    chmod 600 ~/.heracles/vault-keys.json
    
    log_success "Vault設定完了"
    log_warning "Vaultキーとトークンは ~/.heracles/vault-keys.json に保存されました"
}

# デプロイメント検証
verify_deployment() {
    log_step "デプロイメントを検証しています..."
    
    # 名前空間確認
    kubectl get namespaces
    
    # すべてのPod確認
    kubectl get pods --all-namespaces
    
    # ArgoCD Applications確認
    kubectl get applications -n argocd
    
    # サービス確認
    kubectl get services --all-namespaces
    
    log_success "デプロイメント検証完了"
}

# サマリー表示
show_summary() {
    log_step "デプロイメントサマリー"
    
    echo
    echo "=== Heracles OKE環境構築完了 ==="
    echo
    echo "🌐 OKEクラスター: $OKE_CLUSTER_NAME"
    echo "🔗 クラスターOCID: $CLUSTER_OCID"
    echo "📊 構成: コントロールプレーン（無料）+ ワーカー${NODE_COUNT}台（各1 OCPU, 6GB）"
    echo "🎯 リソース合計: ${NODE_COUNT} OCPU, $((NODE_COUNT * 6))GB RAM（無料枠フル活用）"
    echo
    echo "🔐 アクセス情報:"
    echo "  ArgoCD Admin: admin / $ARGOCD_PASSWORD"
    echo "  Vault Keys: ~/.heracles/vault-keys.json"
    echo
    echo "🛠️  便利コマンド:"
    echo "  ArgoCD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"
    echo "  Grafana UI: kubectl port-forward -n observability svc/prometheus-grafana 3000:80"
    echo "  Vault UI: kubectl port-forward -n vault svc/vault 8200:8200"
    echo
    echo "📋 次のステップ:"
    echo "  1. ArgoCD UIでアプリケーション同期確認"
    echo "  2. 監視ダッシュボード確認"
    echo "  3. アプリケーションデプロイテスト"
    echo
    log_success "全ての構築プロセスが完了しました！"
}

# エラーハンドリング
cleanup_on_error() {
    log_error "エラーが発生しました。クリーンアップを実行します..."
    
    # 作成されたリソースの削除（オプション）
    if [[ "${DELETE_ON_ERROR:-false}" == "true" ]]; then
        log_warning "DELETE_ON_ERROR=true のため、作成したリソースを削除します"
        
        # ノードプール削除
        if [[ -n "${NODE_POOL_OCID:-}" ]]; then
            oci ce node-pool delete --node-pool-id "$NODE_POOL_OCID" --force
        fi
        
        # クラスター削除
        if [[ -n "${CLUSTER_OCID:-}" ]]; then
            oci ce cluster delete --cluster-id "$CLUSTER_OCID" --force
        fi
        
        # VCN削除（サブネット、ゲートウェイも含む）
        if [[ -n "${VCN_OCID:-}" ]]; then
            oci network vcn delete --vcn-id "$VCN_OCID" --force
        fi
    fi
    
    exit 1
}

# メイン実行部分
main() {
    log_info "=== Heracles OKE Bootstrap 開始 ==="
    log_info "タイムスタンプ: $(date)"
    
    # エラーハンドリング設定
    trap cleanup_on_error ERR
    
    # 実行ステップ
    check_prerequisites
    create_vcn_resources
    create_oke_cluster
    configure_kubectl
    deploy_terraform_infrastructure
    setup_argocd
    setup_gitops_repository
    setup_vault
    verify_deployment
    show_summary
    
    log_success "=== Heracles OKE Bootstrap 完了 ==="
}

# ヘルプ表示
show_help() {
    cat << EOF
Heracles OKE Bootstrap Script

使用方法:
  $0 [オプション]

オプション:
  --help               このヘルプを表示
  --dry-run           実際の作成は行わず、コマンドのみ表示
  --delete-on-error   エラー時に作成したリソースを自動削除

必要な環境変数:
  OCI_COMPARTMENT_OCID  Oracle Cloud コンパートメントOCID
  GITHUB_TOKEN          GitHub Personal Access Token (オプション)

例:
  export OCI_COMPARTMENT_OCID="ocid1.compartment.oc1..xxx"
  export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
  $0

EOF
}

# コマンドライン引数処理
case "${1:-}" in
    --help|-h)
        show_help
        exit 0
        ;;
    --dry-run)
        log_info "DRY RUN モードで実行します"
        DRY_RUN=true
        export DRY_RUN
        ;;
    --delete-on-error)
        log_warning "DELETE_ON_ERROR モードが有効です"
        DELETE_ON_ERROR=true
        export DELETE_ON_ERROR
        ;;
    "")
        # 引数なしの場合は通常実行
        ;;
    *)
        log_error "不明なオプション: $1"
        show_help
        exit 1
        ;;
esac

# メイン処理実行
main "$@"