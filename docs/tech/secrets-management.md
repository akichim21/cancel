# 秘密情報の管理（SSM Parameter Store）

> GTSS-859 で導入。従来 `.env.development` / `.env.production` に平文で置き `deploy-api.sh` が Lambda 環境変数へ
> 注入していた API の秘密情報を、**AWS SSM Parameter Store（SecureString）** へ移設した。CodeBuild が build/deploy
> 時に復号取得して Lambda env へ注入する。CI/CD 全体像は `ci-cd.md`。

## 命名規約

`/cancel/<app>/<key>`（小文字）。例: `/cancel/api/stripe_secret_key`。
dev/prod は**別アカウント**なので同名でよい（アカウント＝環境）。

## SSM に置くもの（真の秘密）

`STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET` / `JWT_SECRET` / `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` /
`TWILIO_MESSAGING_SERVICE_SID` / `DECODO_USERNAME` / `DECODO_PASSWORD` /（必要なら `SENDGRID_API_KEY`）。

CodeBuild の環境変数として `type = PARAMETER_STORE` で復号注入され（value = SSM パラメータ名）、
`deploy-api.sh` / `deploy-batch.sh` が CI モードでそれを読んで Lambda env に設定する。

## SSM に置かないもの

- **非秘密の設定**: `NODE_ENV` / `AWS_REGION` / `CORS_ORIGIN` / `SALONBOARD_*` / `DECODO_PROXY_HOST` /
  `DECODO_PROXY_PORT` / `CREDENTIALS_KMS_KEY_ID`（KMS キー ID は秘匿不要）等 → CodeBuild の平文環境変数。
- **Aurora 接続情報**: `AURORA_RESOURCE_ARN` / `AURORA_SECRET_ARN` / `AURORA_DATABASE` はリソース識別子。DB 認証情報は
  既存 Secrets Manager（`AURORA_SECRET_ARN` が指す）に集約済み → CodeBuild の平文環境変数として供給。
- **`CREDENTIALS_MASTER_KEY`（重要）**: サロンボード連携パスワードの暗号鍵。**dev/prod では KMS CMK**
  （`credentials-kms` モジュール、`CREDENTIALS_KMS_KEY_ID`）で保護され、`src/utils/crypto.ts` の `useKms()` が true。
  `CREDENTIALS_MASTER_KEY` は **local/test 専用**で dev/prod へは配布しない（SSM/CI のスコープ外）。dev/prod で必要なのは
  (a) 非秘密の `CREDENTIALS_KMS_KEY_ID`（平文）と (b) Lambda 実行ロールの `kms:Encrypt/Decrypt`（対象 CMK 限定）のみ。
  → 関連: `salonboard-import.md`（DECODO プロキシ運用）。
- **フロントの `VITE_*`**: すべて公開値（`VITE_STRIPE_PUBLISHABLE_KEY` も pk_ の公開鍵）。commit 済みの
  `.env.development` / `.env.production`（`vite build --mode` が読む）で供給。user portal の prod Stripe 公開鍵のみ
  git 衛生目的で SSM SecureString 化しても良い（`deploy.sh` が `VITE_STRIPE_PUBLISHABLE_KEY` env を上書きに使う。任意）。

## リソース定義と値の分離

- SSM パラメータ**リソース**（プレースホルダ値・`type=SecureString`・`lifecycle { ignore_changes = [value] }`）は
  Terraform（`~/infra/cancel-billing-service-infra` の `dev/codebuild.tf` / `prod/codebuild.tf`、`ci_api_secret_keys`）で管理。
- **実値は Terraform state に載せず CLI で直接投入**する（`ignore_changes` により apply で上書きされない）。

## 実値の直 push runbook

`terraform apply` の後、各アカウントで実値を投入する。**値はシェル履歴・端末ログに残さないため
`read -rsp` で環境変数に入れて渡す**（コマンド行に直書きしない）:

```bash
# 投入対象キー（真の秘密のみ。credentials_master_key は dev/prod では KMS のため対象外）
KEYS="stripe_secret_key stripe_webhook_secret jwt_secret \
twilio_account_sid twilio_auth_token twilio_messaging_service_sid \
decodo_username decodo_password"   # 必要に応じ sendgrid_api_key を追加

# 対象アカウントのプロファイルを選ぶ（dev / prod で 2 回実行する）
PROFILE=cancel-billing-service-dev    # prod は cancel-billing-service-prod
REGION=ap-northeast-1

for KEY in $KEYS; do
  # -s で画面非表示、履歴に値が残らない。空入力ならスキップ
  read -rsp "value for /cancel/api/${KEY} (empty=skip): " VAL; echo
  [ -z "$VAL" ] && { echo "skip ${KEY}"; continue; }
  aws ssm put-parameter --overwrite --type SecureString \
    --name "/cancel/api/${KEY}" --value "$VAL" \
    --profile "$PROFILE" --region "$REGION" >/dev/null && echo "put ${KEY}"
  unset VAL
done

# 確認（値は表示せず名前だけ / セキュア値は WithDecryption を付けない）
aws ssm get-parameters-by-path --path /cancel/api --recursive \
  --query 'Parameters[].Name' --output text \
  --profile "$PROFILE" --region "$REGION"
```

- dev は `sk_test_` / `whsec_`(test)、prod は `sk_live_` / `whsec_`(live) の値を投入する。
- **apply 直後に必ず投入**する（未投入のまま API を develop/main デプロイすると Lambda が秘密欠落で起動失敗する）。
- `read -rsp` を使えない CI/自動化からは、KMS 暗号化した一時ファイル経由など履歴に残さない手段を用いる。

## 露出防止

- SSM 実値・Lambda env を **CI ログ・PR/Issue コメント・buildspec の echo に一切出さない**。
- `deploy-api.sh` / `deploy-batch.sh` は env JSON を `JSON.stringify` でファイルに書き、`update-function-configuration`
  へ `file://` で渡す（値を echo しない現行実装を踏襲）。
