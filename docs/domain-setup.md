# Cloudflare + Knative ドメイン設定ガイド

このガイドでは Cloudflare 管理下の DNS を用いて、Knative サービスを `<service>.<namespace>.apps.heracles.ryone.dev` 形式のホスト名で公開する手順を説明します。

## 前提条件 (Prerequisites)

This guide explains how to expose Knative services at `<service>.<namespace>.apps.heracles.ryone.dev` using Cloudflare-managed DNS.

- Cloudflare ゾーン: `heracles.ryone.dev` または親ドメイン `ryone.dev` からのサブドメイン委譲
- 権限を持つ API Token: Zone:DNS:Edit, Zone:Read
- ExternalDNS (Cloudflare provider) が対象ゾーン向けにデプロイ済み
- cert-manager の ClusterIssuer (Let’s Encrypt) が利用可能
- Ingress Controller (nginx) のロードバランサーが外部到達可能

## 1. Cloudflare API Token Secret の作成
```bash
kubectl create secret generic cloudflare-api-token \
  -n external-dns \
  --from-literal=api-token="$CF_API_TOKEN"
```
ArgoCD は `gitops/services/dns/external-dns.yaml` に定義された ExternalDNS Application を同期し、このシークレットを参照します。

## 2. ExternalDNS の domainFilters 設定
`external-dns.yaml` 内で以下の指定を確認/変更します:
```yaml
domainFilters:
  - ryone.dev
```
委譲済みサブドメインを利用する場合は `apps.heracles.ryone.dev` を追加してください。

## 3. Knative ドメイン設定
`gitops/services/knative/config-domain.yaml` 現在の例:
```yaml
data:
  ryone.dev: ""
  apps.heracles.ryone.dev: ""
```
`apps.heracles.ryone.dev` のみを強制したい場合は `ryone.dev` 行を削除します。両方残せば二重ホスト名でのアクセスが可能です。

テンプレートで統一したい場合は `knative-serving.yaml` に:
```yaml
domain-template: "{{.Name}}.{{.Namespace}}.apps.heracles.ryone.dev"
```
を設定します。

## 4. TLS 証明書 (DNS-01 / HTTP-01)
HTTP-01 は nginx Ingress を経由して検証されます。ワイルドカードや委譲サブドメインを利用する場合は Cloudflare の DNS-01 を検討します:
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-cloudflare
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef:
      name: letsencrypt-cloudflare
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```
適用後、Ingress アノテーション (例: `cert-manager.io/cluster-issuer`) や Knative 側の証明書統合を調整してください。

## 5. サンプル Knative Service をデプロイ
```bash
kubectl create namespace apps
kubectl apply -k apps/sample-service/base
kubectl get ksvc -n apps sample-service -o jsonpath='{.status.url}'
```
テンプレート設定次第で `http://sample-service.apps.apps.heracles.ryone.dev` のような URL が返されます。

## 6. DNS レコード検証
おおむね 60 秒以内に ExternalDNS が A/AAAA および TXT レコードを作成します:
- `sample-service.apps.apps.heracles.ryone.dev`
- `_externaldns-heracles-*` (レジストリ用 TXT)

## 7. トラブルシュート
| 症状 | 確認ポイント |
|------|--------------|
| DNS レコードが作成されない | ExternalDNS Pod ログ / Token 権限 / `domainFilters` 設定 |
| 証明書が Pending のまま | ClusterIssuer 名 / solver 種別 / ACME レート制限 |
| Ingress で 404 | Host ヘッダ不一致 / Knative URL と DNS の整合性 |
| コールドスタートが遅い | `minScale` と autoscaling `target` を調整 |

## 8. 次の拡張 / 今後の改善
- サービス間 mTLS (Cilium + cert-manager SPIFFE) の導入
- Vault PKI ロール自動化と内部アイデンティティ証明書の発行
- Grafana による合成 (Synthetic) 監視と SLO ダッシュボード追加

既に `gitops/services/cert/wildcard-certificate.yaml` にワイルドカード証明書 (`*.apps.heracles.ryone.dev`) が定義されています。ゾーンが異なる場合は `dnsNames` を変更してください。
