# デプロイ

> **通常デプロイは CI/CD**（`develop`/`main` への push で GitHub Actions → CodeBuild が自動実行）。
> 全体像は `ci-cd.md`、秘密情報は `secrets-management.md`。以下の `deploy*.sh` 手元実行は
> **緊急時・検証用のフォールバック**。

## 前提

- **AWS プロファイル（dev/prod は別アカウント。GTSS-13 で dev を dev アカウントへ移設）**:
  - dev=`cancel-billing-service-dev`（818059182115）
  - prod=`cancel-billing-service-prod`（145887419870）
- リージョン: `ap-northeast-1`
- 認証確認: `aws sts get-caller-identity --profile cancel-billing-service-dev`（dev）

## デプロイ経路

### 通常（CI/CD）

| push 先 | 環境 | 動作 |
|---|---|---|
| `develop` | dev | GitHub Actions（test/lint green）→ OIDC → dev CodeBuild が build/deploy |
| `main` | prod | 同上 + `prod` Environment の**承認**後に prod CodeBuild が build/deploy |

Slack にデプロイ成否が通知される。詳細・セットアップ順序は `ci-cd.md`。

### フォールバック（手元 `deploy*.sh`）

```bash
# API（統合: migrate → API Lambda → batch Lambda を一括実行。実行漏れ防止のため通常はこれ）
cd cancel-billing-service-api && ./deploy.sh dev        # / prod
#   個別: ./deploy-api.sh dev（API のみ）/ ./deploy-batch.sh dev（batch のみ）。単独時は migrate:<env> を自分で流す

# サロンポータル
cd cancel-billing-service && ./deploy.sh dev            # / prod

# 管理画面（注: スクリプト名が deploy-admin.sh）
cd cancel-billing-service-admin && ./deploy-admin.sh dev  # / prod

# LP
cd cancel-billing-service-lp && ./deploy.sh dev         # / prod
```

`prod` を渡すと確認プロンプトが出る。`.claude/settings.json` の `permissions.deny` で `./*.sh prod*` を
ブロックしているため、Claude Code 経由では実行されない。**本番の手元デプロイは人間が実行する想定**
（通常は `main` への CI/CD 経路 + Environment 承認を使う）。

> deploy スクリプトは `CI=true`（CodeBuild）で **CI モード**動作する（AWS プロファイル不使用 / `.env.*` 非参照 /
> 非対話 / user の内蔵 `npm test` を二重実行しない）。手元実行時は従来どおり `--profile` と `.env.*` を使う。

## AWS リソース一覧

### Lambda（api）

| 関数 | ハンドラ | 用途 |
|---|---|---|
| `cancel-billing-service-dev` / `cancel-billing-service-prod` | `src/lambda.handler` | HTTP API |
| `cancel-billing-service-batch-dev` / `cancel-billing-service-batch-prod` | `src/batch.handler` | バッチ（月次入金・purge・サロンボード取り込み） |

デプロイ用 S3（50MB 超 zip の経由）: `cancel-billing-lambda-deploy-<env>-<accountId>`。

### S3 + CloudFront（フロント。dev は dev アカウント資源）

| アプリ | dev S3 / CloudFront（dev acct 818059182115） | prod S3 / CloudFront（prod acct 145887419870） |
|---|---|---|
| LP | `cancel-billing-lp-dev-818059182115` / `E3DBTIIV5TB3IP` | `cancel-billing-lp-prod-app` / `E3AU8H3BJJK35A` |
| サロンポータル | `cancel-billing-user-web-dev-818059182115` / `E3UO0Z1W80IDPV` | `cancel-billing-user-portal-prod-app` / `EKU0PRCYVJUIZ` |
| 管理画面 | `cancel-billing-admin-dev-818059182115` / `E1V9B22113545B` | `cancel-billing-admin-prod-app` / `EZ2JYIS8UOYRB` |

> 参考（撤去対象・旧 prod アカウント同居の dev 資源）: dev S3 `*-dev-145887419870` /
> dev CloudFront lp=`E1OUC1XEZOT7LN` user=`E71P95BIB50NW` admin=`E15K6M6VG5BSZ8`。

### データベース

永続化は **Aurora PostgreSQL（RDS Data API）** に統一済み（`AURORA_RESOURCE_ARN` / `AURORA_SECRET_ARN` /
`AURORA_DATABASE`）。旧 DynamoDB は移行元のみ。詳細は `cancel-billing-service-api/CLAUDE.md`。

### インフラ（Terraform）

`~/infra/cancel-billing-service-infra`（`dev/` = dev アカウント、`prod/` = prod アカウント、`modules/`）。
CI/CD リソースは `dev/codebuild.tf` / `prod/codebuild.tf` / `modules/ci-codebuild`。

## デプロイ後の確認

1. CloudFront キャッシュ反映に数分〜10 分かかる場合あり。
2. Lambda ログ:
   ```bash
   aws logs tail /aws/lambda/cancel-billing-service-dev --follow --profile cancel-billing-service-dev
   ```
3. API ヘルスチェック: `curl https://dev.api.cancel.co.jp/health`。

## ロールバック / リカバリ

- **基本手順は「直前の正常コミットを push し直す」**（CI/CD が再ビルド・再デプロイ）。
- API の migrate は `__drizzle_migrations` で冪等・追加的 DDL・前方互換。「migrate 成功／Lambda 更新失敗」でも
  再 push で収束する。フロントの `s3 sync --delete` の途中失敗も再実行で収束する。
- CodeBuild 失敗は Slack 通知で検知 → 修正 push で再実行（fire-and-forget の補完）。

## トラブルシューティング

**Lambda が API Gateway から呼び出せない (500)**
```bash
aws lambda add-permission \
  --function-name cancel-billing-service-dev \
  --statement-id apigateway-invoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --profile cancel-billing-service-dev   # dev。prod は cancel-billing-service-prod
```

**「API Gateway が見つかりません」**
```bash
aws sts get-caller-identity --profile cancel-billing-service-dev   # dev。prod は cancel-billing-service-prod
```

**フロントの環境変数が反映されない**

- `VITE_*` はビルド時に埋め込まれるためデプロイし直しが必要。
- API URL 変数名: user portal=`VITE_API_BASE_URL` / admin,lp=`VITE_API_URL`（統一は別 Issue）。
