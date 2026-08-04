# 本番リリース手順書: DynamoDB → Aurora 移行（GTSS-13 系一括カットオーバー）

作成: 2026-07-25 / 対象 Issue: akichim21/cancel#13（+ #12 #17 #19 #20 #22 #23 #25 #27 #30 #31 #33 #34 #36 #37 #39）

> **このリリースは「Aurora だけ」を出すことができない。**
> dev で稼働中の `develop` は `feature/GTSS-13`（Aurora）の上に GTSS-817 / GTSS-854 / GTSS-836 /
> GTSS-842 / GTSS-858 / GTSS-859 / GTSS-860 が **stacked PR で積み上がっている**（API PR #9←#17←#28←#32←#34、
> infra PR #2←#4←#5←#7←#8）。DB 層だけ切り出す分岐は存在しない。
> フロント3面も `main` から 12〜36 コミット先行しており、API だけ差し替えると画面が壊れる。
> **API + フロント3面 + インフラの全面カットオーバーとして実施する。**

---

## 1. 現状（2026-07-25 実測）

| 対象 | 状態 |
|---|---|
| prod Lambda `cancel-billing-service-prod` | **DynamoDB のまま**（env に `AURORA_*` なし / `DYNAMODB_TABLE_NAME` あり）。最終更新 2026-07-13 |
| prod Terraform state | `module.api_compute` + `aws_codeconnections_connection` の **2 つだけ**（serial 3）。Aurora / KMS / batch / Fargate / CI **未適用** |
| prod DynamoDB データ量 | applications **5 件** / users **3 件** / cancellations **12 件**（合計 ~15KB）→ **データ移行は数秒**。長時間メンテ不要 |
| `.env.production` | `AURORA_*` / `CREDENTIALS_KMS_KEY_ID` / `DECODO_*` / `SALONBOARD_TRANSPORT` / `SENTRY_DSN` / `PAYOUT_NOTIFY_RECIPIENTS` が **すべて欠落** |
| dev | Aurora / batch / Fargate / CI すべて apply 済み（state serial 274）。develop 相当が稼働中 |
| マイグレーション | `src/db/migrations/` に **0000〜0019 の 20 本**。`__drizzle_migrations` 管理で冪等 |

prod Aurora の構成（`prod/main.tf`）:
`cancel-billing-prod` / PostgreSQL 17.7 / **min ACU 0（scale-to-zero）** / max 4 /
VPC 10.41.0.0/16 / `deletion_protection = true` / PITR 14 日 / 最終スナップショット取得あり /
Performance Insights 有効 / DB 名 `cancel_billing` / マスタパスワードは Secrets Manager マネージド。

### リリース元ブランチ: `develop` を使う（PR スタックのマージだけでは不足）

API リポジトリのブランチ関係（2026-07-25 実測）:

| ブランチ | `develop` から見た関係 |
|---|---|
| `feature/GTSS-13`（PR #9） | develop に**内包**（`develop..` = 0） |
| `GTSS-854`（#28） / `GTSS-859`（#32） / `GTSS-858`（#34） | develop に**内包**（同 0） |
| `GTSS-817`（#17） | マージコミット 2 件だけトポロジ差。**内容は develop に入っている** |
| `develop` 側の超過分 | **`origin/GTSS-858` より 11 コミット先行**（5 ファイル） |

**決め手はこの 11 コミット**。中身は `fix(GTSS-858): PII スクラブが stack frame の filename を潰し source map 解決を壊す不具合を修正` /
`fix(GTSS-858): Sentry source map 解決のため build/実行時で release を一致させる` /
`ci(GTSS-858): buildspec-batch.yml 追加` / 一時 debug ルートの削除 で、**いずれも dev で稼働・検証済み**。
PR スタックだけをマージすると**これらが本番に載らない**（Sentry の PII スクラブ不具合が本番に出る）。

したがって:

1. `origin/main` → `develop` をマージ（B-1 の 6 件を取り込む）
2. `develop` → `main` をマージしてリリース
3. PR #9 / #28 / #32 / #34 は head が `develop` の祖先になるため **自動クローズ**される。
   #17（`GTSS-817` → base が `feature/GTSS-13`）だけは base が `main` でないため自動クローズされない。
   内容は取り込み済みなので手動クローズでよい（`develop へ取り込み済み` とコメントを残す）

> PR レビュー履歴を `main` の履歴に残したい場合は、逆に PR を下から順に（#9 → #17 → #28 → #32 → #34）
> マージしたうえで、**最後に `develop` を `main` へマージして 11 コミット分を回収する**こと。
> どちらの順序でも「最後に develop を main へ入れる」が必須。

---

## 2. 🚨 着手前に必ず潰すブロッカー（2 件）

### B-1. `main` の本番ホットフィックスがリリース対象ブランチに取り込まれていない（最重要）

`develop..origin/main` = **7 コミット**（うち 1 件は 2026-07-25 に別実装で解消済み → **残り 6 件**）。
このまま出すと**本番機能がデグレする**。

| コミット | 内容 | デグレ時の影響 |
|---|---|---|
| ~~`e6caa45`~~ | ~~SES SMTP 認証情報のハードコード削除（Issue #5）~~ → **2026-07-25 に対応済み**。同等の修正 + 再発防止 grep ガードを `feature/GTSS-13` に入れ、stack 全ブランチと `develop` へ伝播済み（`develop` の `src/clients.ts` は SMTP ブロックが `main` と等価） | 解消済み。`e6caa45` はマージ時に内容重複となる |
| `54aa551` `fe157d2` | `/auth/profile` を PATCH 主・POST 後方互換に | プロフィール更新が本番で `Failed to fetch` |
| `beda3da` | オンボーディングのウェブサイト欄をサロン自身の URL に | Stripe オンボーディングが `cancel.co.jp` 固定に戻る |
| `61e43b8` | カード明細表記（statement descriptor）対応 + backfill スクリプト | 明細が「ゴウトゥデイシェアサロン」に戻る |
| `342a012` `449da4c` | feature/pay_url 関連（`notification.service.ts`） | 支払い URL 通知の修正が消える |

**対応**: `origin/main` → `develop` を先にマージし、コンフリクトを解消してテスト green を確認する。
競合しやすいのは `src/clients.ts` / `src/handlers/auth.handler.ts` / `src/services/application.service.ts` /
`src/services/notification.service.ts` / `src/services/invoice.service.ts`。

同じ問題がフロントにもある:

| リポジトリ | リリース元ブランチ | main のみのコミット |
|---|---|---|
| cancel-billing-service（ユーザーポータル） | `GTSS-817` | **3**（`151c275` `342a017` `a149dd2` = PATCH/POST 往復） |
| cancel-billing-service-lp | `GTSS-842` | **2**（`0fdf2ee` フリガナ入力追加 / `5f18216` 広告用ロゴ SVG） |
| cancel-billing-service-admin | `GTSS-842` | 0（問題なし） |

> ⚠️ LP の `0fdf2ee`（申請フォームのフリガナ入力）は API 側の statement descriptor カナ生成と対になっている。
> 取り込み漏れると新規申込のカナ明細が欠ける。

### B-2. infra リポジトリの作業ツリーが未コミット

`~/infra/cancel-billing-service-infra`（branch `GTSS-859`）:

```
 M dev/codebuild.tf / dev/main.tf / modules/api-compute/main.tf
 M modules/ci-codebuild/main.tf / prod/codebuild.tf
?? modules/ci-batch-image/      ← 未追跡。prod/codebuild.tf が module "ci_batch_image" で参照
```

未追跡モジュールを参照したまま apply すると、別クローン・CI から再現できない。**apply 前にコミットする。**
また `terraform.tfstate` は **gitignore（ローカル管理）** のため、apply は必ずこのローカルクローンで実施する。

### 確認済み: メール送信（SES）はブロッカーではない

2026-07-25 に prod アカウント（145887419870 / ap-northeast-1）で実測:

| 項目 | 実測値 |
|---|---|
| `sesv2 get-account` | `ProductionAccessEnabled: **true**`（サンドボックスではない）/ `SendingEnabled: true` / `EnforcementStatus: HEALTHY` / 上限 50,000通・14通/秒 |
| ドメイン `cancel.co.jp` | `VerifiedForSendingStatus: **true**` / DKIM `SUCCESS`・署名有効（`info@cancel.co.jp` は本ドメイン ID でカバー） |
| `cancel-billing-lambda-role` | `**AmazonSESFullAccess**` アタッチ済み（inline policy なし） |

したがって `e6caa45` の設計どおり、`SMTP_USERNAME` / `SMTP_PASSWORD` 未設定 → `smtpTransporter` を生成せず
**Lambda 実行ロールの権限で `sesClient`（SES SDK）から送信**され、`notifyAdmins()` や入金レポート
（`PAYOUT_MAIL_FROM = info@cancel.co.jp`）も含めて送信できる。SMTP 認証情報を `.env.production` へ入れる必要はない
（`deploy-api.sh` も `SMTP_*` を Lambda env に注入しない）。

> 2026-07-25 に、`src/clients.ts` のハードコード SMTP 認証情報（Issue #5）を stack 全ブランチと `develop` から
> 削除済み（`SMTP_USERNAME` / `SMTP_PASSWORD` 未設定なら SES SDK へフォールバック）。
> `src/__tests__/unit/no-hardcoded-credentials.test.js` で AWS アクセスキー ID の再混入を grep ガードしている。
> **漏洩済みの IAM SES SMTP 認証情報は AWS 側での失効/ローテーションが別途必要**（Issue #5 は未クローズ）。
>
> なお `list-email-identities` は `VerifiedForSendingStatus` を返さない（null になる）ため、検証状態の確認には
> `sesv2 get-email-identity` か `ses get-identity-verification-attributes` を使うこと。

---

## 3. リリース全体像

```
Phase 0  事前準備（ブロッカー解消 / dev リハーサル）        … D-7 〜 D-1
Phase 1  Terraform apply（prod）                            … 当日 T-60min
Phase 2  .env.production 整備                               … 当日 T-45min
Phase 3  スキーマ適用 migrate:prod                    [adhoc] … 当日 T-30min
Phase 4  書き込み凍結 → dump → データ移行             [adhoc] … 当日 T-0（メンテ開始）
Phase 5  API + batch + フロント3面 デプロイ                 … 当日 T+10min
Phase 6  リリース後 adhoc（Stripe webhook / backfill）[adhoc] … 当日 T+30min
Phase 7  動作確認 → 凍結解除（メンテ終了）                  … 当日 T+40min
Phase 8  後追い（batch ECS 切替 / CI-CD / DynamoDB 撤去）   … D+1 〜 D+14
```

メンテナンス枠は **60 分**を確保（実作業はデータ量的に 15 分程度。切り戻し余裕込み）。

---

## Phase 0: 事前準備（D-7 〜 D-1）

1. **B-1 解消**: `origin/main` → `develop`（API）、`origin/main` → `GTSS-817`（user portal）、
   `origin/main` → `GTSS-842`（LP）をマージ。API は `npm test` 全 green を確認する。
2. **B-2 解消**: infra 作業ツリーをコミット（`modules/ci-batch-image/` を `git add`）。
3. **dev で最終リハーサル**: `cd cancel-billing-service-api && ./deploy.sh dev` → 主要フロー疎通。
   > dev Aurora は ACU0 で自動休止する。アイドル後の初回アクセスは `DatabaseResumingException` になるので、
   > 失敗したら再実行する（`migrate` と実行時クエリはリトライ済み。`/health/db` は即時応答仕様）。
4. **Stripe prod webhook を Dashboard で確認**: エンドポイントが「**Connect アカウントのイベントをリッスン**」
   になっているか。`payout.*` は Connect イベントで、この設定がないと購読追加しても配信されない（API から検証不能）。
5. **プロファイル確認**:
   ```bash
   aws sts get-caller-identity --profile cancel-billing-service-prod   # 145887419870
   ```
6. **告知**: サロン向けメンテナンス告知（枠 60 分）。

---

## Phase 1: Terraform apply（prod インフラ）

```bash
cd ~/infra/cancel-billing-service-infra/prod
export AWS_PROFILE=cancel-billing-service-prod

terraform init
terraform plan -out=tfplan-prod-aurora        # ★必ず全文を目視
```

### plan で作られるもの（現 state は api_compute + CodeConnections のみ）

| 対象 | 内容 | 今回必須か |
|---|---|---|
| `module.aurora` | Aurora Serverless v2 + Data API + 専用 VPC + Secrets + IAM ポリシー | **必須** |
| `module.credentials_kms` | サロンボード認証情報の暗号鍵 + Lambda ロールへ Encrypt/Decrypt | **必須**（未設定だと `deploy-api.sh prod` が fail-fast） |
| `module.batch_compute` | batch Lambda + EventBridge Scheduler（purge / import / payout） | **必須**（取り込み・入金バッチ） |
| `module.batch_fargate` | ECR / ECS クラスタ / タスク定義 / SG / VPC 10.51.0.0/16 | 基盤のみ先行構築（起動は `batch_execution="lambda"` のまま） |
| `prod/codebuild.tf` 一式 | OIDC provider / CodeBuild 4 本 / SSM SecureString / S3 / Chatbot | **任意**（GTSS-859 / #37。CodeConnections 認可待ちなら後回し可） |

⚠️ **`module.api_compute` にも差分が出る**: 共有ロール `cancel-billing-lambda-role` の信頼ポリシーへ
`ecs-tasks.amazonaws.com` が追加される（GTSS-860、confused-deputy 対策の `aws:SourceAccount` 条件付き）。
既存 Lambda の実行には影響しないが、plan で「IAM ロール変更」が出ることを事前に把握しておく。

### Aurora だけに絞りたい場合（推奨: 段階 apply）

```bash
terraform apply -target=module.aurora -target=module.credentials_kms
terraform apply -target=module.batch_compute
terraform apply                                  # 残り（Fargate / CI）
```

> `-target=module.aurora` でも依存の `module.api_compute`（＝ロール信頼ポリシー変更）は巻き込まれる。
> `module.batch_fargate` は `aws_ssm_parameter.api_secret` を参照するため、単体 target では解決できない。

### apply 後

```bash
terraform apply tfplan-prod-aurora     # または上記の段階 apply
terraform plan                         # ★ no changes になることを確認（冪等性）

terraform output aurora_cluster_arn
terraform output aurora_secret_arn
terraform output aurora_database_name
terraform output credentials_kms_key_arn
terraform output batch_function_name
```

Aurora クラスタの作成には **5〜10 分**かかる。

---

## Phase 2: `.env.production` の整備

`cancel-billing-service-api/.env.production` に以下を追記する（**値は terraform output からコピー。
このファイルはコミットしない / 値をログ・PR・Issue に貼らない**）。

| 変数 | 出所 | 必須 |
|---|---|---|
| `AURORA_RESOURCE_ARN` | `terraform output aurora_cluster_arn` | **必須**（未設定で `deploy-api.sh` が中断） |
| `AURORA_SECRET_ARN` | `terraform output aurora_secret_arn` | **必須**（同上） |
| `AURORA_DATABASE` | `terraform output aurora_database_name`（`cancel_billing`） | **必須**（同上） |
| `CREDENTIALS_KMS_KEY_ID` | `terraform output credentials_kms_key_arn` | **必須**（同上） |
| `DECODO_USERNAME` / `DECODO_PASSWORD` | Decodo プロキシ（`.env.development` と同系） | サロンボード取り込みに必須 |
| `DECODO_PROXY_HOST` / `DECODO_PROXY_PORT` | `gate.decodo.com` / `7000` | 既定あり |
| `SALONBOARD_TRANSPORT` | `playwright`（AWS 直 IP は Akamai 遮断） | 取り込み利用時 |
| `SENTRY_DSN` | Sentry の cancel-billing-service-api prod プロジェクト | 任意（空なら no-op） |
| `PAYOUT_NOTIFY_RECIPIENTS` | 入金失敗通知の宛先上書き | 任意（空なら prod 既定） |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | **不要**（未設定なら Lambda 実行ロールで SES SDK 送信。`deploy-api.sh` も注入しない） | 不要 |

> `deploy-api.sh` の `update-function-configuration --environment` は**環境変数セット全体を置換**する。
> `.env.production` に無い変数は Lambda から消える。既存の `JWT_SECRET` / `STRIPE_*` / `TWILIO_*` /
> `CORS_ORIGIN` が漏れていないか、デプロイ前に現行 Lambda の env と突き合わせること。
>
> ```bash
> aws lambda get-function-configuration --function-name cancel-billing-service-prod \
>   --profile cancel-billing-service-prod --region ap-northeast-1 \
>   --query 'Environment.Variables' | jq 'keys'
> ```
>
> `DYNAMODB_TABLE_NAME` / `SENDGRID_*` は新コードが参照しないため落として構わない（切り戻し時のみ必要）。

---

## Phase 3 【adhoc】スキーマ適用

```bash
cd ~/cancel/cancel-billing-service-api
npm run migrate:prod          # = NODE_ENV=prod tsx scripts/migrate.ts
```

- `NODE_ENV=prod` → `.env.production` を読み、**aws-data-api ドライバ**で 0000〜0019 を順に適用する。
- `__drizzle_migrations` で適用済みを管理するため**冪等**（再実行は no-op）。
- 0000 は `CREATE EXTENSION IF NOT EXISTS pg_trgm` を含む（マスタユーザーの権限で通る）。
- ACU0 からの復帰待ちを最大 ~2 分バックオフ再試行する（`⏳ DB が復帰中のため…` が出たら待つ）。

確認:

```bash
aws rds-data execute-statement --region ap-northeast-1 --profile cancel-billing-service-prod \
  --resource-arn "$AURORA_RESOURCE_ARN" --secret-arn "$AURORA_SECRET_ARN" --database cancel_billing \
  --sql "select count(*) from __drizzle_migrations"     # → 20
```

---

## Phase 4 【adhoc】書き込み凍結 → dump → データ移行（メンテ開始）

### 4-1. 書き込み凍結

DynamoDB への書き込みが走る経路を止める。dump 取得後の更新は移行先に反映されず**消える**。

- LP の申込フォーム（新規 application）
- Stripe webhook（`checkout.session.completed` = 支払い確定、`account.updated`）
- 管理画面からの審査・キャンセル請求作成

> 実務上は「メンテ告知 + 短時間（15 分）で切る」で足りる。データ 20 件規模なので凍結の実装は不要。
> ただし **Stripe webhook は止められない**。メンテ枠中に決済が発生した場合は、
> Stripe Dashboard の該当イベントを**カットオーバー後に再送**して取り込む（後述 Phase 7-4）。

### 4-2. DynamoDB を dump（読み取りのみ）

```bash
cd ~/cancel/cancel-billing-service-api
mkdir -p .migration-dump-prod
for t in applications users cancellations; do
  AWS_PROFILE=cancel-billing-service-prod aws dynamodb scan \
    --table-name cancel-billing-$t-prod --region ap-northeast-1 \
    --output json > .migration-dump-prod/$t.json
done
wc -l .migration-dump-prod/*.json
```

> 🔒 dump には顧客氏名・メール・電話・ハッシュ済みパスワードが含まれる。**`.gitignore` 済みを確認**し、
> 移行完了後に `rm -rf .migration-dump-prod` で削除する。ログ・Issue コメントに中身を貼らない。

### 4-3. 移行実行

```bash
DUMP_DIR=.migration-dump-prod NODE_ENV=prod \
  AWS_PROFILE=cancel-billing-service-prod \
  npx tsx scripts/migrate-dynamodb-to-aurora.ts
```

スクリプトの挙動:

- `applications` 1 件 → `applications` 1 件 + `application_users` 1 件（UUID 採番、認証系カラムを分離）
- `users` 1 件 → `users` 1 件（旧 PK `userId`(=email) を `email` 列へ、id は UUID 採番）
- `cancellations` → `type='monthly_sales'` / `id` が `sales_` 始まりなら `monthly_sales`、他は `cancellations`
  （旧 `userId` を `application_id` にリネーム）
- 投入は本番コードと同じ `repository.create()` を通す（camelCase → snake_case 変換を共有）
- **`auditUnknownColumns` が schema 未定義フィールドを検出したら投入前に中止する**（欠損防止ガード）

> ⛔ 中止された場合は、検出されたフィールドが本当に捨ててよいかを判断し、
> 必要なら schema 追加 → 追加マイグレーション → やり直し。**強行しない。**
> dev の実 dump で先に流して未知フィールドを洗い出しておくこと（Phase 0-4）。

### 4-4. 件数照合

```bash
for tbl in applications application_users users cancellations monthly_sales; do
  aws rds-data execute-statement --region ap-northeast-1 --profile cancel-billing-service-prod \
    --resource-arn "$AURORA_RESOURCE_ARN" --secret-arn "$AURORA_SECRET_ARN" --database cancel_billing \
    --sql "select '$tbl', count(*) from $tbl"
done
```

期待値: applications **5** / application_users **5** / users **3** / cancellations + monthly_sales **合計 12**。

---

## Phase 5: アプリのデプロイ

> `.claude/settings.json` の `permissions.deny` に `./deploy.sh prod*` / `./deploy-api.sh prod*` /
> `./deploy-admin.sh prod*` があるため、**Claude Code からは実行できない。人間が手元で実行する。**

### 5-1. API + batch（統合デプロイ）

```bash
cd ~/cancel/cancel-billing-service-api
./deploy.sh prod            # 確認プロンプトに 'prod' と入力
```

`deploy.sh` は **migrate → API Lambda → batch Lambda** の順に実行する。
Phase 3 で migrate 済みなので 1 番目は no-op（不安なら `SKIP_MIGRATE=1`）。

batch を ECS(Fargate) で走らせる段階になったら（Phase 8-1 以降）:

```bash
DEPLOY_BATCH_ECS=1 ./deploy.sh prod      # deploy-batch-ecs.sh を追加実行（docker / jq が必要）
```

### 5-2. フロント3面

```bash
cd ~/cancel/cancel-billing-service        && ./deploy.sh prod        # ユーザーポータル
cd ~/cancel/cancel-billing-service-admin  && ./deploy-admin.sh prod  # 管理画面（スクリプト名が別）
cd ~/cancel/cancel-billing-service-lp     && ./deploy.sh prod        # LP
```

- `VITE_*` はビルド時に埋め込まれるため、env 変更時は必ず再ビルド・再デプロイ。
- admin は `VITE_API_BASE_URL`、LP は `VITE_API_URL`（**変数名が違う**）。
- CloudFront のキャッシュ反映に数分〜10 分かかる。

---

## Phase 6 【adhoc】リリース後スクリプト

### 6-1. Stripe webhook の購読担保（必須）

```bash
cd ~/cancel/cancel-billing-service-api
npm run webhook:ensure:prod -- --check     # ① 変更せず不足を報告（不足あれば exit 1）
npm run webhook:ensure:prod                # ② 不足分を追加
```

必須イベント: `checkout.session.completed` / `account.updated` / `payout.paid` / `payout.failed`。
`payout.*` は月次入金バッチの記録確定・失敗再試行の起点で、**未購読だと入金失敗が検知できない**。

> - 対象エンドポイントの絞り込みは `STRIPE_WEBHOOK_ENDPOINT_ID`（推奨・完全一致）または
>   `STRIPE_WEBHOOK_ALLOWED_HOSTS` で行う。未設定だと `path=/webhook/stripe` の全 enabled endpoint が対象。
> - Dashboard で作成されたエンドポイントは Stripe の制約で API 更新できない。その場合は手順を表示して exit 1 するので、
>   **Dashboard で手動追加**する。
> - Connect イベント配信可否は API から検証できない。Phase 0-5 の Dashboard 確認とセット。

### 6-2. カード明細表記のバックフィル（B-1 のホットフィックス取り込み後・任意）

```bash
npx tsx scripts/backfill-statement-descriptors.ts prod            # ドライラン
npx tsx scripts/backfill-statement-descriptors.ts prod --apply    # 実行
```

明細表記対応より前にオンボーディング完了した連結アカウントへ、漢字・カナ・英字の明細表記を再設定する。

> ⚠️ このスクリプトは **DynamoDB を読む実装のまま**（`ScanCommand` / `cancel-billing-applications-prod`）。
> Aurora カットオーバー後に流すなら Aurora 読み取りへ改修が必要。
> **DynamoDB 撤去（Phase 8-3）より前に実行する**か、改修してから実行すること。

---

## Phase 7: 動作確認 → 凍結解除

1. **DB 疎通**: `curl https://api.cancel.co.jp/health/db` → ok（ACU0 復帰トリガも兼ねる。初回は resume 中で
   落ちても、数十秒後に再度叩いて ok になれば正常）
2. **参照系**: 管理画面ログイン → 申請一覧 / キャンセル請求一覧 / CSV 出力 が Phase 4-4 の件数と一致
3. **更新系**: サロンポータルでログイン → プロフィール更新（`/auth/profile` PATCH が通ること = B-1 の確認）
4. **決済系**: キャンセル請求を 1 件作成 → Stripe 決済リンク → テスト決済 →
   webhook で `paid` 反映 + `monthly_sales` 加算を確認。
   メンテ中に発生した決済があれば **Stripe Dashboard から該当イベントを再送**して取り込む。
5. **メール**: 申込通知 / 認証メール（GTSS-842）が届く。運営宛通知（`notifyAdmins()`）が
   **Lambda 実行ロール経由の SES SDK** で送れていること（`smtpTransporter` が生成されていない = B-1 マージ済みの裏取りにもなる）
6. **Sentry**: prod プロジェクトにイベントが流れる / リリース（git SHA）が紐づく
7. **batch 手動実行**:
   ```bash
   aws lambda invoke --function-name cancel-billing-service-batch-prod \
     --payload '{"action":"run-monthly-payouts"}' --cli-binary-format raw-in-base64-out \
     --profile cancel-billing-service-prod --region ap-northeast-1 /tmp/out.json && cat /tmp/out.json
   ```
   利用可能な action: `purge-expired-backups` / `restore`(+`applicationId`) /
   `salonboard-import` / `run-monthly-payouts`
8. **CloudWatch Logs**: `aws logs tail /aws/lambda/cancel-billing-service-prod --follow --profile cancel-billing-service-prod`
9. 問題なければ**書き込み凍結を解除・メンテ終了を告知**

---

## Phase 8: 後追い（D+1 〜 D+14）

### 8-1. batch を ECS(Fargate) へ切替（GTSS-860 / #36）

Lambda 15 分制限を超える取り込み・入金バッチのため。**段階 apply（無停止カットオーバー）**:

```bash
cd ~/infra/cancel-billing-service-infra/prod
# 1) 基盤は Phase 1 で作成済み。イメージを push しタスク定義を register
cd ~/cancel/cancel-billing-service-api && ./deploy-batch-ecs.sh prod

# 2) 実タスクで検証（RunTask 手動起動）後、起動先を ECS へ確定
cd ~/infra/cancel-billing-service-infra/prod
terraform apply -var 'batch_execution=ecs'
```

ロールバックは `-var 'batch_execution=lambda'` に戻すだけ。
両スケジュール有効な短時間は payout の claim + idempotencyKey / import の part-unique で二重処理を防ぐ。

### 8-2. CI/CD go-live（GTSS-859 / #37）

prod の CodeConnections は state にあるが **GitHub 認可が未完了**（GitHub の権限保持者による作業が必要）。
認可後に `terraform apply` で CodeBuild / OIDC / Chatbot を有効化し、SSM SecureString へ実値を CLI 直 push する
（`/cancel/api/<key>`。実値は state に載せない）。

### 8-3. DynamoDB の撤去

**最低 2 週間は残す**（切り戻し用）。撤去時は先に最終バックアップ（PITR / on-demand backup）を取り、
`cancel-billing-{applications,users,cancellations}-prod` を削除。あわせて
`aws-policies/dynamodb-policy.json` などのデッドコードと Lambda ロールの DynamoDB 権限も縮小する（Issue #40 と併せて）。

### 8-4. PR のマージ（記録の整合）

stacked PR を下から順にマージし、`main` を実リリース内容に一致させる:

- infra: #2 → #4 → #5 → #7（#8 はマージ済み）
- api: #9 → #17 → #28 → #32 → #34
- フロント: 各リリースブランチ → `main`

> `develop` 運用と `main` 運用が二重化しているのが B-1 の根本原因。
> このリリースを機に「`main` = 本番」へ一本化し、ホットフィックスも `develop` 経由に統一することを推奨。

---

## 9. ロールバック

| 事象 | 対応 |
|---|---|
| Phase 3（migrate）で失敗 | Aurora は未使用のため**影響なし**。原因を潰して再実行（冪等） |
| Phase 4（データ移行）で中止 | Aurora のみ汚れる。`truncate` して再実行、または Aurora を作り直す。DynamoDB は無傷 |
| Phase 5 後にアプリ不具合 | **`.env.production` を DynamoDB 構成へ戻し**（`AURORA_*` を外し `DYNAMODB_TABLE_NAME` を復活）、`origin/main` を checkout して `./deploy-api.sh prod` → フロントも `main` から再デプロイ |
| 切り戻し後のデータ差分 | 切り戻し中に Aurora へ入った書き込みは DynamoDB に無い。**メンテ枠中に切り戻し判断すること**（枠を出たら差分手当てが必要） |
| batch が ECS で不調 | `terraform apply -var 'batch_execution=lambda'` で Lambda 経路へ即時復帰 |

Aurora 側は `deletion_protection = true` / `skip_final_snapshot = false` / PITR 14 日のため、
誤操作しても復旧できる。**Terraform で Aurora を destroy しない**（保護が効いて失敗する想定だが試みないこと）。

---

## 10. adhoc 実行コマンド 早見表

| # | 目的 | コマンド | Phase |
|---|---|---|---|
| 1 | スキーマ適用（冪等） | `npm run migrate:prod` | 3 |
| 2 | DynamoDB dump | `aws dynamodb scan --table-name cancel-billing-<t>-prod --output json > …` | 4-2 |
| 3 | データ移行 | `DUMP_DIR=.migration-dump-prod NODE_ENV=prod npx tsx scripts/migrate-dynamodb-to-aurora.ts` | 4-3 |
| 4 | 件数照合 / 任意 SQL | `aws rds-data execute-statement --resource-arn … --secret-arn … --database cancel_billing --sql "…"`（`.claude/skills/db-update` 参照） | 4-4 |
| 5 | Stripe webhook 検査 | `npm run webhook:ensure:prod -- --check` | 6-1 |
| 6 | Stripe webhook 追加 | `npm run webhook:ensure:prod` | 6-1 |
| 7 | 明細表記バックフィル | `npx tsx scripts/backfill-statement-descriptors.ts prod [--apply]` | 6-2 |
| 8 | 入金バッチ手動実行 | `aws lambda invoke --function-name cancel-billing-service-batch-prod --payload '{"action":"run-monthly-payouts"}' …` | 7-7 |
| 9 | サロンボード取り込み手動実行 | 同上 `--payload '{"action":"salonboard-import"}'` | 7-7 |
| 10 | 申請 restore | 同上 `--payload '{"action":"restore","applicationId":"app_xxx"}'` | 随時 |
| 11 | バックアップ purge | 同上 `--payload '{"action":"purge-expired-backups"}'` | 随時（毎月3日に自動） |
| 12 | batch ECS デプロイ | `./deploy-batch-ecs.sh prod` | 8-1 |
| 13 | dump 削除（PII） | `rm -rf .migration-dump-prod` | 4 完了後 |

すべて `AWS_PROFILE=cancel-billing-service-prod` / `--region ap-northeast-1` で実行する。

---

## 11. 関連

- `docs/tech/deployment.md` — デプロイスクリプト一覧（DynamoDB 前提の記述が残るため、本リリース後に更新）
- `docs/tech/batch-jobs.md` / `docs/tech/batch-fargate.md` — バッチ実行基盤
- `docs/tech/salonboard-import.md` — Decodo プロキシ / transport 設定
- `docs/tech/sentry.md` — Sentry 運用
- `.claude/skills/db-update/SKILL.md` — RDS Data API で直接 SELECT/UPDATE する手順
- infra: `~/infra/cancel-billing-service-infra`（`prod/main.tf` / `modules/aurora-data-api`）
