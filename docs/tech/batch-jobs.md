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

## 関連

- 業務挙動: `docs/product/application-flow.md`「申請の削除（論理削除 / 退会化 + 顧客PIIマスク + 90日バックアップ）」
- 技術詳細: `docs/tech/api-architecture.md`「申請削除フローの拡張（GTSS-20）」
- テスト方針: `docs/tech/api-testing.md`「バッチ（restore / purge）のテスト方針」
