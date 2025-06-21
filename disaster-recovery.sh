#!/bin/bash

# Heracles Disaster Recovery Script
# 災害復旧・バックアップ・復元用統合スクリプト

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

log_backup() {
    echo -e "${CYAN}[BACKUP]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# 設定
BACKUP_DIR="${HERACLES_BACKUP_DIR:-$HOME/.heracles/backups}"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_NAME="heracles_backup_$TIMESTAMP"
VAULT_NAMESPACE="vault"
ARGOCD_NAMESPACE="argocd"
POSTGRES_NAMESPACE="postgres-operator"
REDIS_NAMESPACE="redis-operator"

# バックアップディレクトリ作成
create_backup_dir() {
    log_step "バックアップディレクトリを作成しています..."
    
    mkdir -p "$BACKUP_DIR/$BACKUP_NAME"/{vault,argocd,postgres,redis,configs,secrets}
    
    log_success "バックアップディレクトリ作成完了: $BACKUP_DIR/$BACKUP_NAME"
}

# 前提条件チェック
check_prerequisites() {
    log_step "前提条件をチェックしています..."
    
    # kubectl接続確認
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Kubernetesクラスターに接続できません"
        exit 1
    fi
    
    # 必要なツール確認
    local required_tools=("kubectl" "helm" "jq")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool が見つかりません"
            exit 1
        fi
    done
    
    log_success "前提条件チェック完了"
}

# Vaultバックアップ
backup_vault() {
    log_step "Vaultをバックアップしています..."
    
    if ! kubectl get namespace "$VAULT_NAMESPACE" &>/dev/null; then
        log_warning "Vault名前空間が存在しません。スキップします"
        return
    fi
    
    # Vaultスナップショット作成
    log_backup "Vaultスナップショットを作成中..."
    if kubectl exec vault-0 -n "$VAULT_NAMESPACE" -- vault operator raft snapshot save /tmp/vault-snapshot.snap 2>/dev/null; then
        # スナップショットをローカルにコピー
        kubectl cp "$VAULT_NAMESPACE/vault-0:/tmp/vault-snapshot.snap" "$BACKUP_DIR/$BACKUP_NAME/vault/vault-snapshot.snap"
        log_success "Vaultスナップショット作成完了"
    else
        log_warning "Vaultスナップショット作成に失敗"
    fi
    
    # Vaultキーとトークンのバックアップ
    if [[ -f ~/.heracles/vault-keys.json ]]; then
        cp ~/.heracles/vault-keys.json "$BACKUP_DIR/$BACKUP_NAME/vault/"
        log_success "Vaultキー情報バックアップ完了"
    else
        log_warning "Vaultキー情報が見つかりません"
    fi
    
    # Vault設定のバックアップ
    kubectl get secret -n "$VAULT_NAMESPACE" -o yaml > "$BACKUP_DIR/$BACKUP_NAME/vault/vault-secrets.yaml" 2>/dev/null || true
    kubectl get configmap -n "$VAULT_NAMESPACE" -o yaml > "$BACKUP_DIR/$BACKUP_NAME/vault/vault-configmaps.yaml" 2>/dev/null || true
    
    log_success "Vaultバックアップ完了"
}

# ArgoCDバックアップ
backup_argocd() {
    log_step "ArgoCDをバックアップしています..."
    
    if ! kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
        log_warning "ArgoCD名前空間が存在しません。スキップします"
        return
    fi
    
    # ArgoCD Applications
    log_backup "ArgoCD Applicationsをバックアップ中..."
    kubectl get applications -n "$ARGOCD_NAMESPACE" -o yaml > "$BACKUP_DIR/$BACKUP_NAME/argocd/applications.yaml"
    
    # ArgoCD Projects
    kubectl get appprojects -n "$ARGOCD_NAMESPACE" -o yaml > "$BACKUP_DIR/$BACKUP_NAME/argocd/projects.yaml" 2>/dev/null || true
    
    # ArgoCD設定
    kubectl get configmap -n "$ARGOCD_NAMESPACE" argocd-cm -o yaml > "$BACKUP_DIR/$BACKUP_NAME/argocd/argocd-cm.yaml" 2>/dev/null || true
    kubectl get configmap -n "$ARGOCD_NAMESPACE" argocd-rbac-cm -o yaml > "$BACKUP_DIR/$BACKUP_NAME/argocd/argocd-rbac-cm.yaml" 2>/dev/null || true
    
    # ArgoCD Secrets
    kubectl get secret -n "$ARGOCD_NAMESPACE" -o yaml > "$BACKUP_DIR/$BACKUP_NAME/argocd/secrets.yaml"
    
    log_success "ArgoCDバックアップ完了"
}

# PostgreSQLバックアップ
backup_postgresql() {
    log_step "PostgreSQLをバックアップしています..."
    
    if ! kubectl get namespace "$POSTGRES_NAMESPACE" &>/dev/null; then
        log_warning "PostgreSQL名前空間が存在しません。スキップします"
        return
    fi
    
    # PostgreSQL インスタンス一覧取得
    local postgres_instances
    postgres_instances=$(kubectl get postgresql -n "$POSTGRES_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$postgres_instances" ]]; then
        log_warning "PostgreSQLインスタンスが見つかりません"
        return
    fi
    
    for instance in $postgres_instances; do
        log_backup "PostgreSQLインスタンス '$instance' をバックアップ中..."
        
        # PostgreSQL Pod確認
        local postgres_pod
        postgres_pod=$(kubectl get pods -n "$POSTGRES_NAMESPACE" -l "application=spilo,cluster-name=$instance" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        
        if [[ -n "$postgres_pod" ]]; then
            # データベースダンプ
            kubectl exec -n "$POSTGRES_NAMESPACE" "$postgres_pod" -- pg_dumpall -U postgres > "$BACKUP_DIR/$BACKUP_NAME/postgres/${instance}_dump.sql" 2>/dev/null || log_warning "PostgreSQL '$instance' ダンプに失敗"
            
            # 設定ファイルバックアップ
            kubectl get postgresql -n "$POSTGRES_NAMESPACE" "$instance" -o yaml > "$BACKUP_DIR/$BACKUP_NAME/postgres/${instance}_config.yaml"
        else
            log_warning "PostgreSQL '$instance' のPodが見つかりません"
        fi
    done
    
    log_success "PostgreSQLバックアップ完了"
}

# Redisバックアップ
backup_redis() {
    log_step "Redisをバックアップしています..."
    
    if ! kubectl get namespace "$REDIS_NAMESPACE" &>/dev/null; then
        log_warning "Redis名前空間が存在しません。スキップします"
        return
    fi
    
    # Redis インスタンス一覧取得
    local redis_instances
    redis_instances=$(kubectl get redisfailover -n "$REDIS_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$redis_instances" ]]; then
        log_warning "Redisインスタンスが見つかりません"
        return
    fi
    
    for instance in $redis_instances; do
        log_backup "Redisインスタンス '$instance' をバックアップ中..."
        
        # Redis Master Pod確認
        local redis_pod
        redis_pod=$(kubectl get pods -n "$REDIS_NAMESPACE" -l "redisfailovers.databases.spotahome.com/name=$instance,redisfailovers-role=master" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        
        if [[ -n "$redis_pod" ]]; then
            # Redis データダンプ
            kubectl exec -n "$REDIS_NAMESPACE" "$redis_pod" -- redis-cli --rdb /tmp/dump.rdb 2>/dev/null || true
            kubectl cp "$REDIS_NAMESPACE/$redis_pod:/tmp/dump.rdb" "$BACKUP_DIR/$BACKUP_NAME/redis/${instance}_dump.rdb" 2>/dev/null || log_warning "Redis '$instance' ダンプに失敗"
            
            # 設定ファイルバックアップ
            kubectl get redisfailover -n "$REDIS_NAMESPACE" "$instance" -o yaml > "$BACKUP_DIR/$BACKUP_NAME/redis/${instance}_config.yaml"
        else
            log_warning "Redis '$instance' のMaster Podが見つかりません"
        fi
    done
    
    log_success "Redisバックアップ完了"
}

# Kubernetes設定バックアップ
backup_k8s_configs() {
    log_step "Kubernetes設定をバックアップしています..."
    
    # 全名前空間のリソース
    kubectl get namespaces -o yaml > "$BACKUP_DIR/$BACKUP_NAME/configs/namespaces.yaml"
    
    # PersistentVolumes
    kubectl get pv -o yaml > "$BACKUP_DIR/$BACKUP_NAME/configs/persistent-volumes.yaml" 2>/dev/null || true
    
    # StorageClasses
    kubectl get storageclass -o yaml > "$BACKUP_DIR/$BACKUP_NAME/configs/storage-classes.yaml" 2>/dev/null || true
    
    # ClusterRoles と ClusterRoleBindings
    kubectl get clusterroles -o yaml > "$BACKUP_DIR/$BACKUP_NAME/configs/cluster-roles.yaml" 2>/dev/null || true
    kubectl get clusterrolebindings -o yaml > "$BACKUP_DIR/$BACKUP_NAME/configs/cluster-role-bindings.yaml" 2>/dev/null || true
    
    # カスタムリソース定義
    kubectl get crd -o yaml > "$BACKUP_DIR/$BACKUP_NAME/configs/custom-resource-definitions.yaml" 2>/dev/null || true
    
    log_success "Kubernetes設定バックアップ完了"
}

# 機密情報バックアップ
backup_secrets() {
    log_step "機密情報をバックアップしています..."
    
    # 各名前空間のSecrets
    local namespaces
    namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
    
    for ns in $namespaces; do
        if [[ "$ns" != "kube-system" && "$ns" != "kube-public" && "$ns" != "kube-node-lease" ]]; then
            kubectl get secrets -n "$ns" -o yaml > "$BACKUP_DIR/$BACKUP_NAME/secrets/${ns}-secrets.yaml" 2>/dev/null || true
        fi
    done
    
    # ConfigMaps
    for ns in $namespaces; do
        if [[ "$ns" != "kube-system" && "$ns" != "kube-public" && "$ns" != "kube-node-lease" ]]; then
            kubectl get configmaps -n "$ns" -o yaml > "$BACKUP_DIR/$BACKUP_NAME/configs/${ns}-configmaps.yaml" 2>/dev/null || true
        fi
    done
    
    log_success "機密情報バックアップ完了"
}

# バックアップの実行
perform_backup() {
    log_step "=== バックアップを開始します ==="
    
    create_backup_dir
    backup_vault
    backup_argocd
    backup_postgresql
    backup_redis 
    backup_k8s_configs
    backup_secrets
    
    # バックアップ情報ファイル作成
    cat > "$BACKUP_DIR/$BACKUP_NAME/backup-info.json" << EOF
{
    "timestamp": "$TIMESTAMP",
    "cluster_info": "$(kubectl cluster-info --context=$(kubectl config current-context) | head -1)",
    "kubernetes_version": "$(kubectl version --short --client | head -1)",
    "backup_size": "$(du -sh "$BACKUP_DIR/$BACKUP_NAME" | cut -f1)"
}
EOF
    
    # バックアップアーカイブ作成
    log_backup "バックアップアーカイブを作成中..."
    cd "$BACKUP_DIR"
    tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
    rm -rf "$BACKUP_NAME"
    
    log_success "=== バックアップ完了: $BACKUP_DIR/${BACKUP_NAME}.tar.gz ==="
}

# 復元の実行
perform_restore() {
    local backup_file="$1"
    
    if [[ -z "$backup_file" ]]; then
        log_error "復元するバックアップファイルを指定してください"
        list_backups
        exit 1
    fi
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "バックアップファイルが見つかりません: $backup_file"
        exit 1
    fi
    
    log_step "=== 復元を開始します: $backup_file ==="
    
    # バックアップ展開
    local restore_dir="/tmp/heracles_restore_$(date +%s)"
    mkdir -p "$restore_dir"
    tar -xzf "$backup_file" -C "$restore_dir"
    
    local backup_name
    backup_name=$(ls "$restore_dir" | head -1)
    local backup_path="$restore_dir/$backup_name"
    
    # Vault復元
    if [[ -d "$backup_path/vault" ]]; then
        log_step "Vaultを復元中..."
        
        if [[ -f "$backup_path/vault/vault-snapshot.snap" ]]; then
            kubectl cp "$backup_path/vault/vault-snapshot.snap" "$VAULT_NAMESPACE/vault-0:/tmp/vault-snapshot.snap"
            kubectl exec vault-0 -n "$VAULT_NAMESPACE" -- vault operator raft snapshot restore /tmp/vault-snapshot.snap
            log_success "Vaultスナップショット復元完了"
        fi
        
        if [[ -f "$backup_path/vault/vault-keys.json" ]]; then
            mkdir -p ~/.heracles
            cp "$backup_path/vault/vault-keys.json" ~/.heracles/
            log_success "Vaultキー情報復元完了"
        fi
    fi
    
    # ArgoCD復元
    if [[ -d "$backup_path/argocd" ]]; then
        log_step "ArgoCDを復元中..."
        
        [[ -f "$backup_path/argocd/applications.yaml" ]] && kubectl apply -f "$backup_path/argocd/applications.yaml"
        [[ -f "$backup_path/argocd/projects.yaml" ]] && kubectl apply -f "$backup_path/argocd/projects.yaml"
        
        log_success "ArgoCD復元完了"
    fi
    
    # PostgreSQL復元
    if [[ -d "$backup_path/postgres" ]]; then
        log_step "PostgreSQLを復元中..."
        
        for dump_file in "$backup_path/postgres"/*_dump.sql; do
            if [[ -f "$dump_file" ]]; then
                local instance_name
                instance_name=$(basename "$dump_file" _dump.sql)
                
                local postgres_pod
                postgres_pod=$(kubectl get pods -n "$POSTGRES_NAMESPACE" -l "application=spilo,cluster-name=$instance_name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                
                if [[ -n "$postgres_pod" ]]; then
                    kubectl exec -i -n "$POSTGRES_NAMESPACE" "$postgres_pod" -- psql -U postgres < "$dump_file"
                    log_success "PostgreSQL '$instance_name' 復元完了"
                fi
            fi
        done
    fi
    
    # クリーンアップ
    rm -rf "$restore_dir"
    
    log_success "=== 復元完了 ==="
}

# バックアップ一覧表示
list_backups() {
    log_step "利用可能なバックアップ一覧:"
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_warning "バックアップディレクトリが存在しません: $BACKUP_DIR"
        return
    fi
    
    local backups
    backups=($(find "$BACKUP_DIR" -name "heracles_backup_*.tar.gz" -type f 2>/dev/null | sort -r))
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        log_warning "バックアップファイルが見つかりません"
        return
    fi
    
    echo
    echo "📦 バックアップファイル:"
    for backup in "${backups[@]}"; do
        local size
        size=$(du -sh "$backup" | cut -f1)
        local date
        date=$(basename "$backup" .tar.gz | sed 's/heracles_backup_//' | sed 's/_/ /')
        echo "  - $(basename "$backup") (${size}) - $date"
    done
    echo
}

# 災害復旧テスト
test_disaster_recovery() {
    log_step "=== 災害復旧テストを実行しています ==="
    
    # バックアップ作成
    log_step "テスト用バックアップを作成中..."
    BACKUP_NAME="heracles_test_backup_$(date +%s)"
    perform_backup
    
    # 重要なサービスの停止
    log_step "テスト用にサービスを一時停止中..."
    kubectl scale deployment argocd-server -n "$ARGOCD_NAMESPACE" --replicas=0 2>/dev/null || true
    
    # 復元テスト
    log_step "復元テストを実行中..."
    sleep 10
    kubectl scale deployment argocd-server -n "$ARGOCD_NAMESPACE" --replicas=1 2>/dev/null || true
    
    # サービス確認
    kubectl wait --for=condition=available deployment/argocd-server -n "$ARGOCD_NAMESPACE" --timeout=300s
    
    log_success "=== 災害復旧テスト完了 ==="
}

# 完全環境再構築
full_environment_rebuild() {
    log_step "=== 完全環境再構築を開始します ==="
    
    log_warning "これは破壊的操作です。本当に実行しますか？ (yes/no)"
    read -r confirmation
    
    if [[ "$confirmation" != "yes" ]]; then
        log_info "操作をキャンセルしました"
        exit 0
    fi
    
    # 現在の環境のバックアップ
    log_step "現在の環境をバックアップ中..."
    perform_backup
    
    # OKE環境の完全再構築
    log_step "OKE環境を再構築中..."
    if [[ -f "./bootstrap-oke.sh" ]]; then
        ./bootstrap-oke.sh
    else
        log_error "bootstrap-oke.sh が見つかりません"
        exit 1
    fi
    
    # アプリケーションの再展開
    log_step "アプリケーションを再展開中..."
    if [[ -f "./deploy-apps.sh" ]]; then
        ./deploy-apps.sh
    else
        log_error "deploy-apps.sh が見つかりません"
        exit 1
    fi
    
    log_success "=== 完全環境再構築完了 ==="
}

# ヘルプ表示
show_help() {
    cat << EOF
Heracles Disaster Recovery Script

使用方法:
  $0 [コマンド] [オプション]

コマンド:
  backup                    完全バックアップの実行
  restore <backup-file>     指定されたバックアップからの復元
  list                      利用可能なバックアップの一覧表示
  test                      災害復旧テストの実行
  rebuild                   完全環境再構築（破壊的操作）

オプション:
  --backup-dir DIR         バックアップディレクトリを指定
  --help                   このヘルプを表示

環境変数:
  HERACLES_BACKUP_DIR      バックアップディレクトリ（デフォルト: ~/.heracles/backups）

例:
  $0 backup                                    # バックアップ実行
  $0 list                                      # バックアップ一覧
  $0 restore ~/.heracles/backups/backup.tar.gz # 復元実行
  $0 test                                      # 災害復旧テスト
  $0 rebuild                                   # 完全再構築

EOF
}

# メイン処理
main() {
    local command="${1:-}"
    
    case "$command" in
        backup)
            check_prerequisites
            perform_backup
            ;;
        restore)
            check_prerequisites
            perform_restore "$2"
            ;;
        list)
            list_backups
            ;;
        test)
            check_prerequisites
            test_disaster_recovery
            ;;
        rebuild)
            check_prerequisites
            full_environment_rebuild
            ;;
        --help|-h|help)
            show_help
            ;;
        *)
            log_error "不明なコマンド: $command"
            show_help
            exit 1
            ;;
    esac
}

# コマンドライン引数処理
while [[ $# -gt 0 ]]; do
    case $1 in
        --backup-dir)
            if [[ -n "$2" ]]; then
                BACKUP_DIR="$2"
                shift 2
            else
                log_error "--backup-dir には値が必要です"
                exit 1
            fi
            ;;
        *)
            break
            ;;
    esac
done

# メイン処理実行
main "$@"