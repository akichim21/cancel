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

dev は GTSS-13 で dev アカウント(818059182115)へ移設済み（`*-dev-145887419870` /
`E1OUC1XEZOT7LN` 等の prod アカウント同居の旧資源は撤去対象）。

| アプリ | dev S3 / CloudFront（dev アカウント） | prod S3 / CloudFront |
|---|---|---|
| LP | `cancel-billing-lp-dev-818059182115` / `E3DBTIIV5TB3IP` | `cancel-billing-lp-prod-app` / `E3AU8H3BJJK35A` |
| サロンポータル | `cancel-billing-user-web-dev-818059182115` / `E3UO0Z1W80IDPV` | `cancel-billing-user-portal-prod-app` / `EKU0PRCYVJUIZ` |
| 管理画面 | `cancel-billing-admin-dev-818059182115` / `E1V9B22113545B` | `cancel-billing-admin-prod-app` / `EZ2JYIS8UOYRB` |

dev の 3 サイトは infra リポジトリ `cancel-billing-service-infra/dev`（`modules/static-site`）が
terraform 管理。**prod LP の CloudFront `E3AU8H3BJJK35A` + S3 `cancel-billing-lp-prod-app` も
#56 で `prod/static-site-lp.tf`（prod 専用定義 + import ブロック）により terraform 管理化**
（実構成が dev 共有モジュールと乖離: S3 REST オリジン・OAI なし・未使用 S3-Admin オリジン同居・
403/404 両エラーマッピング）。prod のサロンポータル / 管理画面の CloudFront は terraform 未管理のまま。

### LP デプロイ成果物（#56 / SSG）

LP のビルドは全 URL 共通 HTML ではなく、**既知 11 ルートのページ別 HTML（トップ = index.html +
拡張子なし 10 オブジェクト）+ 404.html + モード別 robots.txt** を生成する
（`cancel-billing-service-lp/vite-plugin-seo-prerender.js`。詳細は
`docs/cancel-billing-service-lp/README.md`）。deploy.sh は「除外なし `s3 sync --delete` →
拡張子なし 10 ファイルを `Content-Type: text/html; charset=utf-8` で個別 `s3 cp` 上書き」の
2 段構え。存在しない URL は CloudFront custom error response が HTTP 404 + /404.html を返す
（dev: 404→404。prod: S3 REST オリジンのため 403/404 の両方→404。
user portal / admin は SPA のため 404→200 フォールバックを維持）。
dev の LP 配信には `X-Robots-Tag: noindex` レスポンスヘッダを付与（prod には付与しない）。

**prod LP の terraform 適用手順（#56 / 人間が prod プロファイルで実施）**:
main マージによる prod デプロイ（404.html 配置）後に、`prod/static-site-lp.tf` ヘッダ記載の
手順どおり `terraform plan -var lp_enable_404_response=false`（import 差分ゼロ確認）→
**lp 4 リソースへの `-target` 付き apply**（403/404→404 変更のみ）→ plan 差分ゼロ確認。
prod state には無関係の既存 drift（batch スケジュール等）があるため **-target なしの全体 apply は禁止**。

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
