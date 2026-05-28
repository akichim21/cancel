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
| repository | `src/repositories/{applications,application-users,users,cancellations,monthly-sales}.repository.ts` | テーブル別の PostgreSQL CRUD（Drizzle 経由）。各メソッドは camelCase ドメインオブジェクトを返す |
| service | `src/services/*.service.ts` | 業務ロジック（auth / application / cancellation / invoice / stripe / webhook / notification） |
| handler | `src/handlers/*.handler.ts` | ドメイン別ルート登録。`index.ts` の `registerRoutes(app)` で集約 |

## DB スキーマ命名規約（REQ-3 / GTSS-17）

外部キー命名は参照先テーブルに応じて以下に統一する:

- `user_id` カラム → **users.id を参照する場合のみ**（管理者ユーザー参照）
- `application_id` カラム → **applications.application_id を参照**（サロン参照）
- `application_user_id` カラム → **application_users.id を参照**（サロン側ログインユーザー参照）

主要テーブルの外部キー:

| 子テーブル.カラム | 参照先 | ON DELETE |
|---|---|---|
| `application_users.application_id` | `applications.application_id` | CASCADE |
| `cancellations.application_id` | `applications.application_id` | RESTRICT |
| `cancellations.created_by_application_user_id` | `application_users.id` | SET NULL |
| `monthly_sales.application_id` | `applications.application_id` | CASCADE |

PK 採番方針:
- `applications.application_id`: アプリ層生成（`app_${Date.now()}`）
- `application_users.id`: アプリ層 `randomUUID()`（UUID v4）
- `users.id`: アプリ層 `randomUUID()`（UUID v4）。旧 PK の email は別カラム + UNIQUE
- `cancellations.id`: アプリ層生成（`cancellation_${Date.now()}` / `inv_${Date.now()}`）
- `monthly_sales.id`: アプリ層生成（`sales_${applicationId}_${monthYear}`）

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

## 関連ドキュメント

- `docs/tech/api-testing.md`: テスト方針（Vitest / `app.request()` / モック戦略）
- `docs/tech/api-build.md`: esbuild バンドル / デプロイ
- `docs/tech/architecture.md`: システム全体構成
