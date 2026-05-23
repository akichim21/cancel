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
