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

## 関連

- 業務挙動: `docs/product/application-flow.md`「申請の削除（論理削除 / 退会化 + 顧客PIIマスク + 90日バックアップ）」
- 技術詳細: `docs/tech/api-architecture.md`「申請削除フローの拡張（GTSS-20）」
- サロンボード取り込み: `docs/tech/salonboard-import.md` / `docs/product/salonboard-import.md`
- テスト方針: `docs/tech/api-testing.md`「バッチ（restore / purge）のテスト方針」
