# API レイヤアーキテクチャ（cancel-billing-service-api）

> 対象: `cancel-billing-service-api`（Hono / AWS Lambda）。Issue #7 で単一ファイル
> （`src/lambda.ts` 約3,500行）に混在していたルーティング・認証・ビジネスロジック・
> DynamoDB アクセス・外部サービス呼び出しを **handler / service / repository** の層へ分離した。
> 挙動は不変（レスポンス契約・送信先/条件を変えない）。

## レイヤ構成

```
リクエスト
  │
  ▼
src/lambda.ts ......... エントリ。Hono app 構築 + ルート登録 + Lambda handler export（約70行）
  │
  ▼
src/handlers/* ........ ルート定義（薄い）。リクエスト解釈 → service 呼び出し → レスポンス整形
  │                      buildEvent / toResponse / corsFromCtx（adapter.ts）で旧 Lambda 互換変換
  ▼
src/services/* ........ ビジネスロジック。認可ガード・分岐・通知トリガを担う
  │                      DynamoDB へは repository 経由でアクセスし、直接 docClient を呼ばない
  ▼
src/repositories/* .... DynamoDB アクセス。テーブル名解決 + docClient(send) を閉じ込める
  ▼
DynamoDB / 外部サービス（Stripe / SES / Nodemailer / Twilio）
```

### 各レイヤの責務

| ディレクトリ | ファイル | 責務 |
|------------|---------|------|
| エントリ | `src/lambda.ts` | Hono `app` 構築、`registerRoutes(app)`、`handle(app)` を `handler` export、テスト用 re-export、`__setTestClients` |
| 基盤 | `src/clients.ts` | Stripe / Twilio / SES / DynamoDB(docClient) / Nodemailer の生成と注入シーム（`setTestClients`） |
| 基盤 | `src/config.ts` | `APPLICATION_STATUS`、テーブル名解決（`tableNames`）、Twilio 送信元設定 |
| 基盤 | `src/utils/*` | 純粋ユーティリティ（`crypto` / `phone` / `cors`） |
| 基盤 | `src/middleware/auth.ts` | 認証ガード（`verifyToken` / `extractToken` / `requireAdmin` / `requireAuth`） |
| repository | `src/repositories/{applications,users,cancellations}.repository.ts` | テーブル別の DynamoDB CRUD。テーブル名所有 |
| repository | `src/repositories/table-setup.ts` | DynamoDB テーブル初期化（旧 `dynamodb-setup.ts`） |
| service | `src/services/*.service.ts` | 業務ロジック（auth / application / cancellation / invoice / stripe / webhook / notification） |
| handler | `src/handlers/*.handler.ts` | ドメイン別ルート登録。`index.ts` の `registerRoutes(app)` で集約 |

## テーブル名解決の集約

旧実装では `process.env.NODE_ENV === 'prod'` による prod/dev 分岐が各関数に散在していた。
本構成では `src/config.ts` の `tableNames` getter に集約し、各 repository がこれを参照する。
getter のため**呼び出し時評価**で、解決結果は旧実装と同一。

| 論理テーブル | 解決ロジック |
|------------|------------|
| applications | `process.env.DYNAMODB_TABLE_NAME` |
| users | `NODE_ENV === 'prod'` → `cancel-billing-users-prod` / それ以外 `cancel-billing-users-dev` |
| cancellations | `NODE_ENV === 'prod'` → `cancel-billing-cancellations-prod` / それ以外 `cancel-billing-cancellations-dev` |

repository メソッドは AWS SDK のレスポンス（`Item` / `Items` / `Attributes`）をそのまま返すため、
service 側の読み出しコードは旧実装から不変。

## 外部サービス境界（注入シーム）

外部クライアントは `src/clients.ts` に集約し、service / repository は名前付き import で参照する。

- **Stripe / Twilio**: `export let` による ESM live binding で公開。`setTestClients()`（テスト時は
  `lambda.__setTestClients`）の再代入が全 import 先へ伝播する。node_modules（CJS）の stripe/twilio は
  `vi.mock` で差し込めないため、この実行時注入を用いる。
- **DynamoDB(docClient) / SES(sesClient)**: `const`。テスト時は `aws-sdk-client-mock` がクラス単位で
  `send` をパッチするため再代入不要。
- **Nodemailer(SMTP)**: `smtpTransporter` は `NODE_ENV === 'prod'` のときのみ生成。メール送信は
  各 service で「prod かつ SMTP あり → SMTP / それ以外 → SES」に分岐する（送信先・条件は不変）。

## 挙動不変の担保

- 外部公開 API の URL / メソッド / ステータス / レスポンス形状（500 の形状差異含む）は変更しない。
- ルーティング登録順（OPTIONS の `/*` を先頭）も旧実装どおり。
- 担保は #1 で構築した `app.request()` E2E スイート（全 green）による（`docs/tech/api-testing.md`）。
  分離した service / repository は unit テストで個別担保する（モック repository 注入、通知送信先/条件）。

## applications の論理削除と参照整合（GTSS-19）

> データ層は GTSS-13 で Aurora(PostgreSQL) + drizzle repository へ移行済み（本セクションは Aurora 前提）。

- **論理削除（ソフトデリート）**: `applications` に `deletedAt`（text, ISO8601）＋ `applications_deleted_at_idx` を持つ。削除は物理 DELETE せず、PII マスク + `deletedAt` セットの UPDATE（`applicationsRepo.softDelete`）。一覧取得（`getAll`）のみ `deletedAt IS NULL` で除外し、`getById` / `findAllWithShop`（請求の店舗名 JOIN）は削除済みも返す。マスク対象/保持対象カラムは `docs/product/application-flow.md` を参照。
- **`application_id` の NOT NULL 化**: 論理削除化により親 `applications` が物理削除されず孤児が発生しないため、`cancellations.application_id` / `monthly_sales.application_id` を **NOT NULL** とする。FK は `cancellations`=`ON DELETE RESTRICT` / `monthly_sales`=`ON DELETE CASCADE` を維持。新規作成パス（cancellation 作成・月次 `upsertMonthly`）はいずれも `applicationId` 必須のため、NULL を投入し得る業務経路は無い。
- **移行スクリプトの孤児スキップ**: `scripts/migrate-dynamodb-to-aurora.ts` は、親 `applications` に紐づかない孤児 cancellation / monthly_sales を**投入せずスキップ**し `orphans` 統計に計上する（NOT NULL 化に整合）。`userId→applicationId` のリネームは純粋関数 `toCancellationRow`、孤児判定・スキップは投入ループへ集約。
- **スキーマ生成**: 初期マイグレーション `0000_init.sql` と drizzle メタ（`meta/0000_snapshot.json` / `_journal.json`）に全テーブルを集約する（`0000` は再生成方針）。`0000` 適用済み以降は**増分マイグレーション（`0001`〜）**で追加する（再生成しない）。GIN trigram index に必須の `CREATE EXTENSION IF NOT EXISTS pg_trgm;` は `0000` 先頭に保持する。

## 申請削除フローの拡張: 退会化 / 顧客PIIマスク / バックアップ・restore・purge（GTSS-20）

GTSS-19 の論理削除を拡張する。業務挙動の概要は `docs/product/application-flow.md` を参照。技術面の要点:

- **退会（`withdrawn`）ステータス**: `applications.status` の enum に `withdrawn`（ラベル「退会」）を追加し、削除時に
  `maskApplicationPii` の patch へ `status='withdrawn'` を含める（`deletedAt` は技術マーカーとして併存。一覧除外は
  引き続き `deletedAt IS NULL`）。手動遷移禁止は `updateApplicationStatus` の**専用拒否分岐**（指定値が `withdrawn`、
  または現ステータスが `withdrawn` のとき早期 400）で実装する（enum 包含チェックとは別レイヤ）。正規化/ラベルは
  `application-enums.ts` の既存ヘルパーと整合（`退会`⇄`withdrawn`）。
- **顧客 PII マスク（固定文字列）**: `cancellationsRepo.maskCustomerPiiByApplicationId(applicationId, '***')` で当該
  applicationId の全 cancellations の顧客 3 列（`customerName/Email/Phone`）を `***` 上書き（NULL ではなく非 NULL）。
  `cancellations_customer_name_trgm_idx` は `***` を索引するが実害なし。
- **バックアップテーブル `application_deletion_backups`**: `id`(PK) / `application_id`(NOT NULL, index) /
  `payload`(text NOT NULL, `{application, cancellations[]}` のマスク前 JSON) / `created_at`(NOT NULL) /
  `expires_at`(NOT NULL, index, `created_at`+90日) / `restored_at`(NULL)。**FK は張らない**（マスク済み live 行と
  疎結合に保ち purge が live 行に影響しない）。`expires_at` は ISO8601 UTC `Z` で辞書順=時系列順。
- **削除フローの単一トランザクション**: `deleteApplication` は ① 未削除時のみ `createDeletionBackup`（マスク前
  スナップショットを Stripe expire / canceled 化の前に取得）→ ③ `application_users` 物理削除 → ④ applications PII
  マスク + `withdrawn` + `deletedAt` → ⑤ cancellations 顧客 PII マスク、を `getDb().transaction()` で原子化する
  （② Stripe expire は外部副作用で Tx 外・best-effort）。repository は `markPaidIfNotPaid` と同様、末尾に executor
  （`db = getDb()`）を受け取り tx を伝播する。aws-data-api ドライバ非対応時も順序＋冪等 UPDATE で再削除収束する。
- **restore / purge サービス**（`application-backup.service.ts`、純粋関数 + 実 Postgres 統合の二層）:
  `buildBackupPayload`（純）/ `computeExpiresAt`・`isBackupExpired`（90日境界・純）/ `createDeletionBackup` /
  `restoreApplication(applicationId)`（未失効バックアップから PII・status・顧客 PII を復元し `deletedAt=NULL`。
  email 一意衝突は Tx ロールバックで無変更・明示エラー。login は再作成しない）/ `purgeExpiredBackups(now)`
  （`expiresAt <= now` のバックアップのみ物理削除）。
- **batch Lambda**（`src/batch.ts`、HTTP の `handle(app)` とは別エクスポート）: `event.action` で
  `purge-expired-backups` / `restore`（`applicationId` 指定）を dispatch。EventBridge Scheduler が毎月 3 日
  JST 00:00 に purge を起動、restore は手動 `aws lambda invoke`。実行基盤は Terraform（`~/infra/cancel-billing-service-infra`
  の `batch-compute` モジュール）。esbuild は `src/lambda.ts`→`dist/src/lambda.js` と `src/batch.ts`→`dist/src/batch.js`
  を別出力する。
- **NOT NULL 制約強化（REQ-9）**: 「全 insert 経路が値を入れ NULL シグナルを持たない列」に限定して NOT NULL 化:
  `cancellations.customer_name/email/phone`（`***` マスク・`default('')` 併用）/ `applications.status` /
  `application_users.must_change_password`（`default(false)`）。マスクで NULL 化する申請 PII（`email` は UNIQUE の
  ため固定文字列マスク不可）・状態シグナル列・移行で NULL があり得る `created_at`/`updated_at` 等は対象外。
- **増分マイグレーション `0001`**: バックアップテーブル追加 + 上記 NOT NULL 化。`ALTER COLUMN ... SET NOT NULL` は
  既存 NULL があると失敗するため、drizzle-kit が生成しない**バックフィル UPDATE**（`customer_*`→`''` / `status`→
  `'pending'` / `must_change_password`→`false`）を生成後 SQL に**手動で前置**する。aws-data-api（dev/prod）では
  適用前に本番データの NULL 実在を確認する。

## サロンボード取り込みの拡張（GTSS-817）

- **キャンセル status の SSOT 化**: `src/constants/cancellation-status.ts` を新設（`application-enums.ts` と同方針・
  依存ゼロ・フロント共有可）。`pre_send`/`pending`/`paid`/`canceled`/`failed` と日本語ラベル・正規化（legacy `sent`→
  `pending`）を集約。admin/user フロントの型・ラベルもこれに整合。一覧/詳細レスポンスは `serializeCancellation`
  で `status` 正規化 + `statusLabel` を付与する。
- **新テーブル**: `external_shops`（会社→店舗 1:N）/ `external_integrations`（会社×連携元の認証情報。
  パスワードは AES-256-GCM envelope で `encrypted_secret` に保管）/ `external_import_logs`（対象外/スキップの
  監査ログ・予約単位 upsert）。`cancellations` に取り込み用カラム + `(externalShopId, externalReservationId)`
  部分ユニーク（冪等キー。手動作成は両 NULL で対象外）。migration `0003`（`sent`→`pending` バックフィル含む）。
- **`createInvoice` の保存/送信分割**: 取り込みは「保存のみ」（`cancellationsRepo.createImported` で `pre_send` 作成・
  通知なし）、送信は `cancellation-send.service.ts`（運営=`requireAdmin` / サロン=`requireAuth`+所有者チェックの
  2 系統。`status='pre_send'` 条件付き更新で冪等＝二重送信防止）。手動取り込みは `POST /cancellations/import`、
  日次は batch `action='salonboard-import'`（共有サービス）。
- **可逆暗号 + KMS**: `utils/crypto.ts` に envelope 暗号（データ鍵を dev/prod は KMS、local/test は env マスター鍵で
  保護）。`clients.ts` は KMS を lazy require。`config.isProdEnv()` を export し非 prod PII マスクの出し分けに使う。
- **一覧の店舗名分離**: `findAllWithShop` は会社名（`companyName`/後方互換 `shopName`）と発生店舗名（`storeName`=
  `external_shops` JOIN）を別フィールドで返す。サロン向け一覧は `findByApplicationIdWithShop`。
- 詳細: `docs/tech/salonboard-import.md` / `docs/product/salonboard-import.md`。

## 関連ドキュメント

- `docs/tech/api-testing.md`: テスト方針（Vitest / `app.request()` / モック戦略）
- `docs/tech/api-build.md`: esbuild バンドル / デプロイ
- `docs/tech/salonboard-import.md`: サロンボード取り込みの技術仕様
- `docs/tech/architecture.md`: システム全体構成
