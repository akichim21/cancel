# デプロイ

## 前提

- AWS CLI 認証済み: `aws sts get-caller-identity --profile cancel-billing-service-prod`
- AWS プロファイル名: `cancel-billing-service-prod`（dev/prod 共通）
- リージョン: `ap-northeast-1`

## デプロイコマンド一覧

```bash
# API (Lambda)
cd cancel-billing-service-api && ./deploy-api.sh dev    # / prod

# サロンポータル
cd cancel-billing-service && ./deploy.sh dev            # / prod

# 管理画面（注: スクリプト名が deploy-admin.sh）
cd cancel-billing-service-admin && ./deploy-admin.sh dev  # / prod

# LP
cd cancel-billing-service-lp && ./deploy.sh dev         # / prod
```

`prod` を渡すと確認プロンプトが出る。`.claude/settings.json` の `permissions.deny` で
`./*.sh prod*` をブロックしているため、Claude Code 経由では実行されない。
**本番デプロイは人間が手元で実行する想定。**

## AWS リソース一覧

### Lambda

| 関数 | ハンドラ | デプロイパッケージ |
|---|---|---|
| `cancel-billing-service-dev` | `src/lambda.handler` | `cancel-billing-service-api/lambda-deployment-*.zip` |
| `cancel-billing-service-prod` | 同上 | 同上 |

### S3 + CloudFront

| アプリ | dev S3 / CloudFront | prod S3 / CloudFront |
|---|---|---|
| LP | `cancel-billing-lp-dev-145887419870` / `E1OUC1XEZOT7LN` | `cancel-billing-lp-prod-app` / `E3AU8H3BJJK35A` |
| サロンポータル | `cancel-billing-user-web-dev-145887419870` / `E71P95BIB50NW` | `cancel-billing-user-portal-prod-app` / `EKU0PRCYVJUIZ` |
| 管理画面 | `cancel-billing-admin-dev-145887419870` / `E15K6M6VG5BSZ8` | `cancel-billing-admin-prod-app` / `EZ2JYIS8UOYRB` |

### DynamoDB（ap-northeast-1）

- `cancel-billing-applications-{env}` — 申請
- `cancel-billing-users-{env}` — サロンユーザー
- `cancel-billing-cancellations-{env}` — キャンセル請求

### IAM ポリシー（参考）

- `cancel-billing-service-api/aws-policies/` 配下
- `dynamodb-policy.json`, `lambda-dynamodb-admin-policy.json` 等

## デプロイ後の確認

1. CloudFront キャッシュ反映に数分〜10 分かかる場合あり
2. Lambda は `aws logs tail` で確認:
   ```bash
   aws logs tail /aws/lambda/cancel-billing-service-dev --follow --profile cancel-billing-service-prod
   ```

## Infrastructure as Code (Terraform)

dev のインフラ（Lambda / API Gateway(REST) / IAM 実行ロール）は Terraform で IaC 化を進めている。
リポジトリ: `~/infra/cancel-billing-service-infra`（DynamoDB は #13 の Aurora 移行に委ねるため対象外）。

```
modules/api-compute/      Lambda + API Gateway(REST proxy) + IAM 実行ロール の再利用モジュール
environments/dev-legacy/  現行 dev 資源（prod アカウント 145887419870 同居）を import する環境
environments/dev/         dev アカウント(818059182115) への再構築 雛形（apply は人手）
```

- `deploy-api.sh` がデプロイ時に上書きする **コード / 環境変数 / API GW deployment** は、
  モジュール側で `ignore_changes` にしている（Terraform はインフラの骨格のみ管理）。
- `serverless.yml` は実デプロイ経路ではない（参考宣言）。真実は `deploy-api.sh` + 上記 Terraform。
- state はローカル backend（S3 + DynamoDB ロックの remote backend 化は follow-up）。

```bash
cd ~/infra/cancel-billing-service-infra/environments/dev-legacy
terraform init && terraform plan   # → 14 imported / 再 plan で No changes
```

### dev/prod アカウント分離（移設中）

| 用途 | アカウント ID | AWS プロファイル | 状態 |
|---|---|---|---|
| prod | 145887419870 | `cancel-billing-service-prod` | 稼働中 |
| dev（現状・移設元） | 145887419870 に同居 | `cancel-billing-service-prod` | 稼働中（移設対象） |
| dev（移設先） | 818059182115 | `cancel-billing-service-dev` | 構築雛形（未 apply） |

- ドメイン `dev.api.cancel.co.jp`（REGIONAL）と Route53 ホストゾーン `cancel.co.jp`
  (`Z07157901B9GNXLZJAADK`) は **prod アカウント所在**。dev アカウントにホストゾーンは無い。
  移設時はクロスアカウント DNS かサブドメイン委譲 + ACM 再発行 + Stripe webhook 再登録が必要。
- 詳細は `~/infra/cancel-billing-service-infra/README.md` と Issue akichim21/cancel#14 を参照。

## トラブルシューティング

**Lambda が API Gateway から呼び出せない (500)**
```bash
aws lambda add-permission \
  --function-name cancel-billing-service-dev \
  --statement-id apigateway-invoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --profile cancel-billing-service-prod
```

**「API Gateway が見つかりません」**
```bash
aws sts get-caller-identity --profile cancel-billing-service-prod
# Account/Profile を確認し、必要なら export AWS_PROFILE=cancel-billing-service-prod
```

**フロントの環境変数が反映されない**

- `VITE_*` 変数はビルド時に埋め込まれるため、デプロイし直しが必要
- `cancel-billing-service-admin` は `VITE_API_BASE_URL`、`cancel-billing-service-lp` は `VITE_API_URL` と名称が異なる点に注意
