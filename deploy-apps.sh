#!/bin/bash

# Heracles Kubernetes Applications Deployment Script
# OKE構築後のアプリケーション展開用スクリプト

set -e

# カラー出力設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
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

log_deploy() {
    echo -e "${CYAN}[DEPLOY]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# 設定
TIMEOUT_SECONDS=600
ARGOCD_NAMESPACE="argocd"
VAULT_NAMESPACE="vault"
MONITORING_NAMESPACE="observability"

# 前提条件チェック
check_prerequisites() {
    log_step "前提条件をチェックしています..."
    
    # kubectl接続確認
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Kubernetesクラスターに接続できません"
        exit 1
    fi
    
    # ArgoCD存在確認
    if ! kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
        log_error "ArgoCD名前空間が存在しません。先にbootstrap-oke.shを実行してください"
        exit 1
    fi
    
    # Helm確認
    if ! command -v helm &> /dev/null; then
        log_error "Helm が見つかりません"
        exit 1
    fi
    
    log_success "前提条件チェック完了"
}

# リソース待機関数
wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local timeout=${3:-$TIMEOUT_SECONDS}
    
    log_info "Deployment $deployment の準備を待機中... (namespace: $namespace)"
    if kubectl wait --for=condition=available --timeout=${timeout}s deployment/$deployment -n $namespace 2>/dev/null; then
        log_success "Deployment $deployment が準備完了"
        return 0
    else
        log_error "Deployment $deployment が${timeout}秒以内に準備できませんでした"
        return 1
    fi
}

wait_for_pods() {
    local namespace=$1
    local selector=$2
    local timeout=${3:-$TIMEOUT_SECONDS}
    
    log_info "Pods の準備を待機中... (namespace: $namespace, selector: $selector)"
    if kubectl wait --for=condition=Ready pods -l "$selector" -n "$namespace" --timeout=${timeout}s 2>/dev/null; then
        log_success "Pods が準備完了"
        return 0
    else
        log_error "Pods が${timeout}秒以内に準備できませんでした"
        return 1
    fi
}

# ArgoCD Applications の同期
sync_argocd_applications() {
    log_step "ArgoCD Applications を同期しています..."
    
    # ArgoCD CLIインストール確認
    if ! command -v argocd &> /dev/null; then
        log_info "ArgoCD CLIをインストールしています..."
        curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
        sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
        rm argocd-linux-amd64
    fi
    
    # ArgoCD パスワード取得
    local argocd_password
    argocd_password=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")
    
    if [[ -z "$argocd_password" ]]; then
        log_error "ArgoCD管理者パスワードを取得できません"
        return 1
    fi
    
    # ポートフォワード開始
    kubectl port-forward svc/argocd-server -n "$ARGOCD_NAMESPACE" 8080:443 &
    local port_forward_pid=$!
    sleep 5
    
    # ArgoCD ログイン
    argocd login localhost:8080 --username admin --password "$argocd_password" --insecure
    
    # 全アプリケーションの同期
    log_deploy "ArgoCD Applications を同期中..."
    
    # 基本的なアプリケーション同期順序
    local apps=(
        "bootstrap"
        "core-services"
        "ingress-nginx" 
        "cert-manager"
        "vault"
        "external-secrets"
        "monitoring-stack"
        "database-operators"
        "harbor"
        "knative"
    )
    
    for app in "${apps[@]}"; do
        log_deploy "アプリケーション '$app' を同期中..."
        if argocd app sync "$app" --timeout 300 2>/dev/null; then
            log_success "アプリケーション '$app' 同期完了"
        else
            log_warning "アプリケーション '$app' の同期に失敗（存在しない可能性があります）"
        fi
    done
    
    # 全アプリケーション状態確認
    argocd app list
    
    # ポートフォワード終了
    kill $port_forward_pid
    
    log_success "ArgoCD Applications 同期完了"
}

# コアサービスの展開待機
wait_for_core_services() {
    log_step "コアサービスの準備を待機しています..."
    
    # Ingress NGINX
    log_deploy "Ingress NGINX の準備を待機中..."
    wait_for_deployment "ingress-nginx" "ingress-nginx-controller" 300
    
    # cert-manager
    log_deploy "cert-manager の準備を待機中..."
    wait_for_deployment "cert-manager" "cert-manager" 300
    wait_for_deployment "cert-manager" "cert-manager-webhook" 300
    wait_for_deployment "cert-manager" "cert-manager-cainjector" 300
    
    log_success "コアサービス準備完了"
}

# Vault設定の完了
complete_vault_setup() {
    log_step "Vault設定を完了しています..."
    
    # Vault Podの準備待機
    wait_for_pods "$VAULT_NAMESPACE" "app.kubernetes.io/name=vault" 300
    
    # Vaultキーファイル確認
    if [[ -f ~/.heracles/vault-keys.json ]]; then
        log_info "Vaultキーファイルが存在します"
        
        # Vaultトークンを環境変数に設定
        VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/.heracles/vault-keys.json)
        export VAULT_ROOT_TOKEN
        
        # Kubernetes認証の詳細設定
        kubectl exec vault-0 -n "$VAULT_NAMESPACE" -- vault write auth/kubernetes/config \
            token_reviewer_jwt="$(kubectl get secret --output=jsonpath='{.data.token}' $(kubectl get serviceaccount vault -n "$VAULT_NAMESPACE" -o jsonpath='{.secrets[0].name}') -n "$VAULT_NAMESPACE" | base64 -d)" \
            kubernetes_host="https://kubernetes.default.svc:443" \
            kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        
        # External Secrets Operator用のポリシー作成
        kubectl exec vault-0 -n "$VAULT_NAMESPACE" -- vault policy write external-secrets - <<EOF
path "secret/*" {
  capabilities = ["read", "list"]
}
EOF
        
        # External Secrets Operator用のロール作成
        kubectl exec vault-0 -n "$VAULT_NAMESPACE" -- vault write auth/kubernetes/role/external-secrets \
            bound_service_account_names=external-secrets \
            bound_service_account_namespaces=external-secrets \
            policies=external-secrets \
            ttl=1h
        
        log_success "Vault設定完了"
    else
        log_warning "Vaultキーファイルが見つかりません。手動でVault設定を完了してください"
    fi
}

# 監視スタックの展開
deploy_monitoring_stack() {
    log_step "監視スタックを展開しています..."
    
    # Prometheus Operator CRDs の事前インストール
    log_deploy "Prometheus Operator CRDs をインストール中..."
    kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
    kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
    kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml
    
    # 監視名前空間の作成
    kubectl create namespace "$MONITORING_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # Prometheus Stack の準備待機
    log_deploy "Prometheus Stack の準備を待機中..."
    wait_for_deployment "$MONITORING_NAMESPACE" "prometheus-kube-prometheus-prometheus-operator" 300
    wait_for_deployment "$MONITORING_NAMESPACE" "prometheus-grafana" 300
    
    log_success "監視スタック展開完了"
}

# データベースオペレーターの展開
deploy_database_operators() {
    log_step "データベースオペレーターを展開しています..."
    
    # PostgreSQL Operator
    log_deploy "PostgreSQL Operator の準備を待機中..."
    wait_for_deployment "postgres-operator" "postgres-operator" 300
    
    # Redis Operator
    log_deploy "Redis Operator の準備を待機中..."
    wait_for_deployment "redis-operator" "redis-operator" 300
    
    # MinIO Operator
    log_deploy "MinIO Operator の準備を待機中..."
    wait_for_deployment "minio-operator" "minio-operator" 300
    
    log_success "データベースオペレーター展開完了"
}

# Harbor コンテナレジストリの展開
deploy_harbor() {
    log_step "Harbor コンテナレジストリを展開しています..."
    
    # Harbor Core の準備待機
    log_deploy "Harbor の準備を待機中..."
    wait_for_deployment "harbor" "harbor-core" 600
    wait_for_deployment "harbor" "harbor-registry" 300
    
    # Harbor管理者パスワード取得
    local harbor_password
    harbor_password=$(kubectl get secret -n harbor harbor-core-secret -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d 2>/dev/null || echo "")
    
    if [[ -n "$harbor_password" ]]; then
        log_success "Harbor展開完了"
        log_info "Harbor管理者パスワード: $harbor_password"
    else
        log_warning "Harbor管理者パスワードを取得できませんでした"
    fi
}

# Knativeサーバーレスプラットフォームの展開
deploy_knative() {
    log_step "Knativeサーバーレスプラットフォームを展開しています..."
    
    # Knative Serving
    log_deploy "Knative Serving の準備を待機中..."
    wait_for_deployment "knative-serving" "controller" 300
    wait_for_deployment "knative-serving" "webhook" 300
    
    # Knative Eventing
    log_deploy "Knative Eventing の準備を待機中..."
    wait_for_deployment "knative-eventing" "eventing-controller" 300
    wait_for_deployment "knative-eventing" "eventing-webhook" 300
    
    log_success "Knativeサーバーレスプラットフォーム展開完了"
}

# 全体の検証
verify_all_deployments() {
    log_step "全体のデプロイメントを検証しています..."
    
    # 名前空間一覧
    echo "=== Namespaces ==="
    kubectl get namespaces
    echo
    
    # 全Pod状態
    echo "=== Pod Status ==="
    kubectl get pods --all-namespaces
    echo
    
    # ArgoCD Applications状態
    echo "=== ArgoCD Applications ==="
    kubectl get applications -n "$ARGOCD_NAMESPACE"
    echo
    
    # サービス一覧
    echo "=== Services ==="
    kubectl get services --all-namespaces
    echo
    
    # Ingress一覧
    echo "=== Ingress ==="
    kubectl get ingress --all-namespaces
    echo
    
    # PVC一覧
    echo "=== Persistent Volume Claims ==="
    kubectl get pvc --all-namespaces
    echo
    
    log_success "デプロイメント検証完了"
}

# アクセス情報の表示
show_access_info() {
    log_step "アクセス情報を表示しています..."
    
    # ArgoCD
    local argocd_password
    argocd_password=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "取得失敗")
    
    # Grafana
    local grafana_password
    grafana_password=$(kubectl get secret -n "$MONITORING_NAMESPACE" prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d 2>/dev/null || echo "取得失敗")
    
    # Harbor
    local harbor_password
    harbor_password=$(kubectl get secret -n harbor harbor-core-secret -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d 2>/dev/null || echo "取得失敗")
    
    cat << EOF

🎉 ========================================
   Heracles アプリケーション展開完了！
========================================

🔐 アクセス情報:
   ArgoCD:
     - URL: kubectl port-forward svc/argocd-server -n argocd 8080:443
     - User: admin
     - Pass: $argocd_password
   
   Grafana:
     - URL: kubectl port-forward -n observability svc/prometheus-grafana 3000:80
     - User: admin
     - Pass: $grafana_password
   
   Harbor:
     - URL: kubectl port-forward -n harbor svc/harbor-core 8080:80
     - User: admin
     - Pass: $harbor_password
   
   Vault:
     - URL: kubectl port-forward -n vault svc/vault 8200:8200
     - Keys: ~/.heracles/vault-keys.json

🛠️  便利コマンド:
   kubectl get pods --all-namespaces
   kubectl get applications -n argocd
   kubectl logs -f deployment/argocd-server -n argocd

📋 次のステップ:
   1. ArgoCD UIで全アプリケーションの同期確認
   2. Grafana UIで監視ダッシュボード確認
   3. Harbor UIでコンテナレジストリ確認
   4. 各アプリケーションのカスタマイズ

🚀 デプロイメント成功！
EOF
    
    log_success "アプリケーション展開が完了しました！"
}

# エラーハンドリング
handle_error() {
    log_error "アプリケーション展開中にエラーが発生しました"
    log_info "デバッグ情報:"
    
    # ArgoCD Applications状態確認
    kubectl get applications -n "$ARGOCD_NAMESPACE" || true
    
    # 失敗したPod確認
    kubectl get pods --all-namespaces --field-selector=status.phase!=Running || true
    
    exit 1
}

# メイン実行部分
main() {
    log_info "=== Heracles アプリケーション展開開始 ==="
    log_info "タイムスタンプ: $(date)"
    
    # エラーハンドリング設定
    trap handle_error ERR
    
    # 実行ステップ
    check_prerequisites
    sync_argocd_applications
    wait_for_core_services
    complete_vault_setup
    deploy_monitoring_stack
    deploy_database_operators
    deploy_harbor
    deploy_knative
    verify_all_deployments
    show_access_info
    
    log_success "=== Heracles アプリケーション展開完了 ==="
}

# ヘルプ表示
show_help() {
    cat << EOF
Heracles Kubernetes Applications Deployment Script

使用方法:
  $0 [オプション]

オプション:
  --help                このヘルプを表示
  --sync-only          ArgoCD Applications の同期のみ実行
  --verify-only        デプロイメントの検証のみ実行
  --timeout SECONDS    タイムアウト時間を設定（デフォルト: 600秒）

前提条件:
  - OKEクラスターが構築済み（bootstrap-oke.sh実行済み）
  - kubectlがクラスターに接続可能
  - ArgoCD、Terraformが事前にデプロイ済み

例:
  $0                          # 全体の展開
  $0 --sync-only             # ArgoCD同期のみ
  $0 --verify-only           # 検証のみ
  $0 --timeout 900           # タイムアウト15分

EOF
}

# コマンドライン引数処理
SYNC_ONLY=false
VERIFY_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_help
            exit 0
            ;;
        --sync-only)
            SYNC_ONLY=true
            shift
            ;;
        --verify-only)
            VERIFY_ONLY=true
            shift
            ;;
        --timeout)
            if [[ -n "$2" ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
                TIMEOUT_SECONDS="$2"
                shift 2
            else
                log_error "無効なタイムアウト値: $2"
                exit 1
            fi
            ;;
        *)
            log_error "不明なオプション: $1"
            show_help
            exit 1
            ;;
    esac
done

# 実行モードに応じた処理
if [[ "$SYNC_ONLY" == "true" ]]; then
    log_info "ArgoCD同期モードで実行"
    check_prerequisites
    sync_argocd_applications
elif [[ "$VERIFY_ONLY" == "true" ]]; then
    log_info "検証モードで実行"
    check_prerequisites
    verify_all_deployments
    show_access_info
else
    # 通常実行
    main "$@"
fi
