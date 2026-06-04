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
- **スキーマ生成**: prod 未リリース前提で初期マイグレーション `0000_init.sql` と drizzle メタ（`meta/0000_snapshot.json` / `_journal.json`）を再生成して反映する。GIN trigram index に必須の `CREATE EXTENSION IF NOT EXISTS pg_trgm;` は先頭に保持する。

## 関連ドキュメント

- `docs/tech/api-testing.md`: テスト方針（Vitest / `app.request()` / モック戦略）
- `docs/tech/api-build.md`: esbuild バンドル / デプロイ
- `docs/tech/architecture.md`: システム全体構成
