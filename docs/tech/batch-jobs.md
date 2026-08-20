# バッチ実行基盤（cancel-billing-service-api / GTSS-20）

申請削除バックアップ（`application_deletion_backups`）の運用バッチ（restore / purge）の実行基盤と運用手順。

## 構成

- **batch Lambda**（`cancel-billing-service-batch-{dev,prod}`、handler = `src/batch.handler`）
  - HTTP API Lambda（`src/lambda.ts` の `handle(app)`）とは**別エントリ**。esbuild は両方を別出力する
    （`dist/src/lambda.js` / `dist/src/batch.js`、`build.mjs`）。
  - DB は既存どおり `resolveDbDriver()` を共有（dev/prod=aws-data-api、local/test=node-postgres）。
    外部クライアント（Stripe/SES/Twilio）は使わないため `initClients()` は呼ばない。
  - 実行ロールは API と同じ共有ロール `cancel-billing-lambda-role` を再利用（Data API / Secrets 権限済み）。
- **EventBridge Scheduler**（Terraform `batch-compute` モジュール）
  - 毎月 3 日 **JST 00:00** に purge を起動（`cron(0 0 3 * ? *)` + `schedule_expression_timezone = "Asia/Tokyo"`）。
  - restore はスケジュールせず **on-demand**（手動 `aws lambda invoke`）。
- **インフラ**: `~/infra/cancel-billing-service-infra` の `modules/batch-compute`（dev/prod の `main.tf` から呼び出し）。
  apply は人手ゲート。詳細は同リポジトリ README を参照。

> **ECS(Fargate) 直列実行（GTSS-860）**: 月次入金（`run-monthly-payouts`）とサロンボード取り込み
> （`salonboard-import`）は、対象を 1 件ずつ直列処理する構造による Lambda timeout を、**分散処理を持ち込まず**
> **実行時間上限の無い Fargate タスクで既存の直列ループを走らせて**解消する。EventBridge Scheduler の起動先を
> Lambda invoke → **ECS RunTask** に切り替える（`local.batch_execution="ecs"｜"lambda"` で新旧切替・ロールバック）。
> 先行着手した SQS ファンアウト（`GTSS-854-sqs` / 親リポ #35）は分散処理の付随複雑さのため**破棄**した。
> 設計・コンテナ構成・デプロイ/ロールバック・段階移行は [batch-fargate.md](./batch-fargate.md) を参照。
> `purge-expired-backups` は対象外（現行 Lambda + Scheduler のまま）。

## dispatch ペイロード

batch Lambda は `event.action` で処理を振り分ける（未知 action はエラー）:

| action | ペイロード例 | 起動経路 |
|---|---|---|
| `purge-expired-backups` | `{ "action": "purge-expired-backups" }` | EventBridge Scheduler（毎月3日） |
| `restore` | `{ "action": "restore", "applicationId": "app_xxx" }` | 手動 `aws lambda invoke` |
| `salonboard-import` | `{ "action": "salonboard-import" }` | EventBridge Scheduler（毎日 JST 0:10）/ API から非同期委譲 |
| `run-monthly-payouts` | `{ "action": "run-monthly-payouts" }` | EventBridge Scheduler（毎日 JST 6:00） |
| `send-billing-reminders` | `{ "action": "send-billing-reminders" }` | EventBridge Scheduler（毎日 **JST 12:00 正午**・GTSS-886） |
| `send-stripe-onboarding-reminders` | `{ "action": "send-stripe-onboarding-reminders" }` | EventBridge Scheduler（毎日 **JST 10:00**・GTSS-909 / #67） |

## 運用手順

### restore（誤削除の復元・手動）

```bash
aws lambda invoke \
  --function-name cancel-billing-service-batch-prod \
  --payload '{"action":"restore","applicationId":"app_xxxxxxxxxxxx"}' \
  --cli-binary-format raw-in-base64-out \
  --profile cancel-billing-service-prod /dev/stdout
```

- 戻り値 `{ ok: true, restored: true, ... }` で成功。`{ ok: false, error: "BACKUP_NOT_FOUND" | "EMAIL_CONFLICT" }`
  の場合は失効/非存在、または同一 email の別申請が存在する（復元せず無変更）。
- 復元してもログイン（`application_users`）は再作成されない。利用再開はパスワード再発行 / 再オンボーディングを運用で。

### purge（90日経過バックアップ削除・通常は自動）

手動起動する場合:

```bash
aws lambda invoke \
  --function-name cancel-billing-service-batch-prod \
  --payload '{"action":"purge-expired-backups"}' \
  --cli-binary-format raw-in-base64-out \
  --profile cancel-billing-service-prod /dev/stdout
```

### ローカル実行（tsx ラッパー）

```bash
npm run batch:purge:local              # purgeExpiredBackups()
npm run batch:restore:local -- app_xxx # restoreApplication('app_xxx')
```

## コード配備

`batch-compute` モジュールは placeholder zip のみ作成する（`filename` / `source_code_hash` / `environment` /
`runtime` は `ignore_changes`）。実コードと環境変数（`NODE_ENV` / `AURORA_*`）は Terraform apply 後に
`./deploy-batch.sh {dev,prod}` が配備する。

## サロンボード取り込み（`salonboard-import`・GTSS-817）

`src/batch.ts` の `case 'salonboard-import'` で、共有サービス `runSalonboardImport()`（手動取り込み HTTP
`POST /cancellations/import` と同一ロジック）を起動する。連携済み会社の全ヘアサロンからキャンセル予約を
取り込み、「送信前」でキャンセル請求を作成する（通知は出さない＝送信は別経路）。

```bash
# 手動起動（dev）。実発火（JST 0:10）の疎通確認にも使う。
aws lambda invoke \
  --function-name cancel-billing-service-batch-dev \
  --payload '{"action":"salonboard-import"}' \
  --cli-binary-format raw-in-base64-out \
  --profile cancel-billing-service-dev /dev/stdout
```

- **スケジュール**: EventBridge Scheduler `cron(10 0 * * ? *)` + `schedule_expression_timezone="Asia/Tokyo"`
  （JST 0:10）。infra `~/infra/cancel-billing-service-infra` の `batch-compute` モジュール
  `aws_scheduler_schedule.salonboard_import`（`enable_import_schedule`）。
- **権限/環境**: 取り込みは通知を出さないため `initClients()` 不要だが、**サロンボードへの外部 HTTP egress** と
  **認証情報復号の KMS 権限**（`kms:Encrypt/Decrypt` を単一鍵 ARN に限定）+ 環境変数 `CREDENTIALS_KMS_KEY_ID` が必要。
  共有ロール（`cancel-billing-lambda-role`）に付与すること。VPC 内実行時は egress 経路（NAT 等）を要確認。
- 詳細: `docs/tech/salonboard-import.md`。

## 自動リマインド送信（`send-billing-reminders`・GTSS-886）

`src/batch.ts` の `case 'send-billing-reminders'` が `runBillingReminders({ now })`
（`src/services/billing-reminder.service.ts`）を起動する。未払い（請求中・初回送信記録あり・期日内）の
キャンセル請求へ、初回送信日から 7 日目に 2 通目・14 日目に 3 通目のリマインドを初回と同じ通知方法で送る。
業務仕様（法的建付け・回判定・文面）は `docs/product/cancellation-flow.md`「自動リマインド送信」を参照。

- **スケジュール**: EventBridge Scheduler `cron(0 12 * * ? *)` + `schedule_expression_timezone="Asia/Tokyo"`
  （毎日正午）。infra は `~/infra/cancel-billing-service-infra`（`batch_execution` に応じ Lambda invoke /
  ECS RunTask。ECS 経路はタスク定義 family `cancel-billing-batch-{env}-reminders`）。
- **夜間ガード**: 実行時刻が JST 21:00〜翌 8:00 なら送信せず終了（`skipped:'night_guard'`）。
- **冪等**: `cancellation_notifications` の UNIQUE `(cancellation_id, round, channel)` ＋ 回単位 claim
  （processing 先行 insert → 配信 → finalize）。タスク丸ごと再実行・多重起動が安全。回単位判定のため
  片チャネルの記録が残った回は残チャネルも再送しない。
- **依存**: SES（メール）+ Twilio（SMS）を使うため分岐内で `initClients()` を呼ぶ。
  **Lambda 経路・ECS 経路の両方**に `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` / `TWILIO_PHONE_NUMBER`
  または `TWILIO_MESSAGING_SERVICE_SID` と、`API_BASE_URL`（/pay 短縮 URL 生成）の注入が必要:
  - Lambda（**prod の定期バッチは現在こちらで稼働**）: `deploy-batch.sh`。`update-function-configuration
    --environment` は**全置換**のため、スクリプトの env JSON に含めないとデプロイのたびに消える。
    `API_BASE_URL` は環境名から出し分ける（prod=`https://api.cancel.co.jp` / それ以外=`https://dev.api.cancel.co.jp`）。
  - ECS（`deploy-batch-ecs.sh`）: 同じ env を task definition へ注入する。`TWILIO_AUTH_TOKEN` のみ
    実秘密のため environment ではなく SSM（ECS secrets = `valueFrom`）経由。
  - 設定漏れは**静かに SMS が全件失敗する**（仕様上「送信失敗のアラート・失敗一覧・絞り込みを設けない」ため
    誰も気づけない）。Lambda 側（`deploy-batch.sh`）は Twilio 認証情報が欠けていればデプロイ前ガードで中断する。
  - **ECS 経路の未完了事項（GTSS-886 TODO）**: batch イメージの CodeBuild（`cancel-batch-image-<env>`）には
    まだ `TWILIO_*` が注入されていない（infra の `plain_env_vars` 未追加）。そのため `deploy-batch-ecs.sh` は
    CI では中断せず警告に留めている（ここで落とすと develop / main push のたびに batch イメージのビルドが
    止まり、サロンボード取り込みのデプロイまで巻き込むため）。**ECS 経路でリマインドを動かす前に**
    infra へ `TWILIO_ACCOUNT_SID` / `TWILIO_MESSAGING_SERVICE_SID` を追加し、スクリプトの警告を
    ハードガードへ戻すこと（`buildspec-batch.yml` の env 契約も併せて更新）。
- **送信元表示（GTSS-920）**: リマインド SMS の送信元は環境変数 `TWILIO_SENDER_ID`（英字送信者名
  `Cancel Pay`）で決まり、初回請求 SMS・支払い完了 SMS と同じ `utils/sms.ts` の `buildSmsParams` を通る。
  **未注入なら送信元だけが従来の海外番号（`+1`）へ静かに戻る**（送信は成功するので失敗記録に残らない）。
  Lambda / ECS の両経路とも他の `TWILIO_*` と同じ場所へ注入すること。書式違反の値は
  `scripts/twilio-sender-id-guard.sh` がデプロイ時に検査して中断する。
- **ログ**: 実行ごとに `[billing-reminders] summary:`（対象件数・回別・チャネル別成否）を構造化出力。

```bash
# 手動起動（dev）。夜間ガード時間帯は送信されない点に注意。
aws lambda invoke \
  --function-name cancel-billing-service-batch-dev \
  --payload '{"action":"send-billing-reminders"}' \
  --cli-binary-format raw-in-base64-out \
  --profile cancel-billing-service-dev /dev/stdout
```

## Stripe オンボーディング自動リマインド送信（`send-stripe-onboarding-reminders`・GTSS-909 / #67）

`src/batch.ts` の `case 'send-stripe-onboarding-reminders'` が `runStripeOnboardingReminders({ now })`
（`src/services/stripe-onboarding-reminder.service.ts`）を起動する。Stripe 登録が未完了のまま
「Stripe登録待ち」「オンボーディング待ち」で滞留しているサロンへ、初回案内メールの送信日を起点に
3 日後・7 日後の各 1 回リマインドを送る。業務仕様（回判定・対象判定・文面）は
`docs/product/application-flow.md`「Stripe 登録の自動リマインド（3日後・7日後）」を参照。

- **スケジュール**: EventBridge Scheduler `cron(0 10 * * ? *)` + `schedule_expression_timezone="Asia/Tokyo"`
  （毎日 JST 10:00）。infra は `~/infra/cancel-billing-service-infra`（`batch_execution` に応じ Lambda invoke /
  ECS RunTask。ECS 経路はタスク定義 family `cancel-billing-batch-{env}-stripe_reminders`）。
  請求リマインド（正午）とは**独立したスケジュール・独立した停止スイッチ**
  （`batch_stripe_onboarding_reminders_schedule_state`）。dev / prod とも ENABLED。
- **夜間ガードは無い**。GTSS-886 の夜間ガードは未払い債権の督促に対する時間帯規制に準じたもので、
  サロン（取引先）向けのオンボーディング案内には適用されない。
- **冪等**: `application_notifications` の UNIQUE `(application_id, kind, round)` ＋ 回単位 claim
  （processing 先行 insert → 配信 → finalize）。タスク丸ごと再実行・多重起動が安全。claim 後に
  クラッシュして `processing` のまま残った行も**試行済みとして扱い再送しない**（二重送信の絶対回避を優先）。
  配信は成功したが finalize だけ失敗した場合は `processing` のまま残す（届いたメールを failed にしない）。
- **一次抽出**: `applicationsRepo.findStripeReminderTargets(todayJst)`。経過日数の窓（3 日以上 14 日未満）を
  **SQL 側に落とす**。窓が無いと打ち止め済みの滞留申込が毎日フル件数で抽出され、summary の抽出件数が
  意味を失う。部分インデックス `applications_stripe_reminder_target_idx` の述語と WHERE 句を一致させること。
  `status` の `IN` 句には**旧日本語値**（`'Stripe登録待ち'` / `'オンボーディング待ち'`）も併記している
  （生 SQL では `normalizeApplicationStatus` を通せず、取りこぼすと最も長く滞留している申込にだけ
  1 通も届かないという静かな失敗になる）。
- **依存**: Stripe（`accounts.retrieve`）と SES を使うため分岐内で `initClients()` を呼ぶ。
  `accounts.retrieve` には **per-request 予算 `{ timeout: 5000, maxNetworkRetries: 0 }`** を必ず渡す
  （SDK 既定は 80,000ms / retry 2 で Lambda の実行時間上限を超える）。
  - `STRIPE_SECRET_KEY` の注入経路は経路ごとに異なる:
    **Lambda = environment**（`deploy-batch.sh`。`update-function-configuration --environment` は全置換の
    ため、スクリプトの env JSON に含めないとデプロイのたびに消える）/
    **ECS = secrets（`valueFrom` = SSM Parameter Store）**（`deploy-batch-ecs.sh` は register 前に
    environment への平文混入を弾く。実値は Terraform の `container_secrets` が全 family へ配線する）。
  - メール本文の LP ドメインは `lpBaseUrl()` が **`NODE_ENV` から導出**する
    （prod=`https://cancel.co.jp` / それ以外=`https://dev.cancel.co.jp`）。`LP_BASE_URL` はローカル上書き専用。
    `NODE_ENV` が欠けると dev から prod ドメインのリンクを送る事故になる（静的テストで固定済み）。
  - ECS 経路では `deploy-batch-ecs.sh` の `FAMILIES` 配列にも `${PREFIX}-stripe_reminders` が必要。
    ここに無い family は register ループの対象外になり、**イメージが永久に bootstrap のまま**になる。
- **ログ**: 実行ごとに `[stripe-onboarding-reminders] summary:`（抽出件数・Stripe 問い合わせ件数・
  回別成否・判定値別件数・確定失敗数）を構造化出力。判定値は `completed` / `blocked` / `not_started` /
  `action_required` / `waiting_stripe` / `stripe_error` の 6 種で、`not_started` と `action_required` を
  分けて数えることで滞留の主因が「未着手」か「追加要求で詰まった」かを事後に判別できる。
  送信失敗のアラート・失敗一覧・管理画面表示は設けない（再送手段を持たないため。GTSS-886 と同方針）。

```bash
# 手動起動（dev）
aws lambda invoke \
  --function-name cancel-billing-service-batch-dev \
  --payload '{"action":"send-stripe-onboarding-reminders"}' \
  --cli-binary-format raw-in-base64-out \
  --profile cancel-billing-service-dev /dev/stdout
```

## 関連

- 業務挙動: `docs/product/application-flow.md`「申請の削除（論理削除 / 退会化 + 顧客PIIマスク + 90日バックアップ）」
- 技術詳細: `docs/tech/api-architecture.md`「申請削除フローの拡張（GTSS-20）」
- サロンボード取り込み: `docs/tech/salonboard-import.md` / `docs/product/salonboard-import.md`
- テスト方針: `docs/tech/api-testing.md`「バッチ（restore / purge）のテスト方針」
