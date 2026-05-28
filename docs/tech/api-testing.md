# API テスト方針（cancel-billing-service-api）

> 対象: `cancel-billing-service-api`（Hono / AWS Lambda）。Issue #1 で jest から Vitest へ移行し、
> Hono の `app.request()` によるインプロセステストへ統一した。

## 全体像

`cancel-billing-service-api` は Hono の `app`（`src/lambda.ts`）でルーティングし、Lambda へは
`hono/aws-lambda` の `handle(app)` を `handler` としてエクスポートする。テストは HTTP サーバや
プロセス境界を介さず、Hono の **`app.request(path, init)`** で同一プロセス内のハンドラを直接叩く。

```
┌─ 自動テスト（Vitest, インプロセス） ── app.request(path, init) → app → ハンドラ
│     外部依存はすべてモック（実ネットワーク・実AWS・実Stripe へ到達しない）
│
└─ ローカル結合（手動） ───────────── @hono/node-server（src/dev-server.ts）→ 同一 app
      DynamoDB は dev 共有 / DynamoDB Local、Stripe/Twilio/SES は dev キー or スタブ
```

自動テストとローカルサーバは**同一の `app` を共有**するため二重実装にならない。
一方で、自動テストはローカルサーバ（`@hono/node-server`）を使わない。プロセス境界・ソケット・
孤児プロセス・CI 脆弱性を避け、`vi`/`aws-sdk-client-mock` によるモックを確実に効かせるため、
両者の層を明確に分離する（`serverless-offline` は不採用）。

## ディレクトリ構成

```
cancel-billing-service-api/src/__tests__/
├── setup.js                 # env プリセット + Stripe/Twilio モック実体（globalThis）
├── helpers/
│   ├── auth.js              # JWT トークン生成（user/admin/期限切れ/改ざん）
│   └── external-mocks.js    # Stripe/Twilio の実行時注入（installExternalMocks）
├── unit/                    # 純粋ロジック（外部 I/O なし）
└── e2e/                     # app.request() による HTTP レベル結合
```

## 実行コマンド

```bash
npm test            # 全テスト
npm run test:unit   # unit のみ
npm run test:e2e    # e2e のみ
npm run test:coverage
```

## 外部依存のモック（実 I/O 到達なし）

`src/lambda.ts` は冒頭で Stripe / Twilio クライアントを生成し、DynamoDB / SES クライアントも
モジュールロード時に生成する。テストは次の方針で実通信を遮断する。

| 依存 | 手法 | 理由 |
|------|------|------|
| PostgreSQL (Drizzle) | **実 Postgres**（docker-compose.test.yml の `postgres:17-alpine`） | unit を除く全テストは実 DB に対して動作。globalSetup で Drizzle migration を適用し、各テストは `beforeEach` で `truncateAll()` 隔離する。FK 制約により `TRUNCATE ... CASCADE` で全テーブルをクリアする |
| SES (`sesClient.send`) | `aws-sdk-client-mock`（`mockClient(SESClient)`） | クライアントの `send` を実行時にスタブ。送信引数を `commandCalls` で検証 |
| Stripe | `lambda.__setTestClients` による実行時注入 | node_modules（CJS）の `require('stripe')` は vitest の `vi.mock` で差し替えられない（外部化され実体が解決される）。`aws-sdk-client-mock` と同様に実行時注入する |
| Twilio | `lambda.__setTestClients` による実行時注入 | 同上 |
| Nodemailer (SMTP) | 不要 | `NODE_ENV !== 'prod'` のため SMTP 経路は通らない（SES を使用） |

### Stripe/Twilio 注入シーム

`src/lambda.ts` は `stripe` / `twilioClient` を `let` バインディングで保持し、テスト専用エクスポート
`__setTestClients({ stripe, twilioClient })` で差し替える。各ハンドラはこの変数を参照するため、
注入が即座に反映される。本番コードパスからは呼ばれない。テストは `helpers/external-mocks.js` の
`installExternalMocks()` を `beforeEach` で呼ぶ。

> なぜ `vi.mock('stripe')` を使わないか: vitest の `vi.mock` は ESM `import` 経由には効くが、
> lambda.js 内の CJS `require('stripe')` は外部化され実 Stripe が解決されてしまうため、
> 実通信（`StripeAuthenticationError`）が漏れる。実行時注入で確実に遮断する。

### env プリセット

`setup.js`（`setupFiles`）でモジュール評価前に `JWT_SECRET` / `DATABASE_URL` /
`CORS_ORIGIN` / `STRIPE_SECRET_KEY=sk_test_...` / `NODE_ENV=test` / `TWILIO_*` を設定する。
Stripe/Twilio クライアントはキー未設定だとロード時に例外を投げるため、生成自体は通す。

### FK 制約と TRUNCATE 順（GTSS-17）

REQ-7 で `application_users.application_id` / `cancellations.application_id` /
`monthly_sales.application_id` / `cancellations.created_by_application_user_id` の FK 制約が
追加された。`helpers/db.js` の `truncateAll()` は `TRUNCATE ... RESTART IDENTITY CASCADE` を
使うため親子の順序は不問だが、`application_users` を新規対象テーブルに含めている。

サロン側 JWT が `application_id` クレームを持たない旧トークンには middleware が 401 を返すため、
テスト用 JWT helper（`helpers/auth.js`）は新仕様の `{ sub, application_id, email, role }` を発行する。

## テストレイヤと担保範囲

- **unit**: `validateApplicationData` / `getCorsHeaders` / `formatPhoneNumberForStripe` /
  `verifyToken` / `extractToken` / `hashPassword` / 認証ガード（`requireAdmin` / `requireAuth`）の
  境界値・同値分割。
- **e2e（app.request）**: 実ルート表面の操作＋結果検証。
  - ルーティング横断: 未マッチ 404 `{ error: 'Not Found' }`、`OPTIONS` 200 + CORS、許可外オリジンの
    フォールバック、最上位 catch / 個別ルートの 500（ルート別形状）。
  - applications のステータス遷移（`GTSS審査中`→`Stripe登録待ち`→`オンボーディング待ち`→`利用中`/`却下済み`）、
    approve、send-stripe-link の管理者ガード（401/403）。
  - auth（login / admin-login / me / change|forgot|reset-password）。
  - cancellations（管理者一覧 / 作成 / 個別 / ステータス更新）、invoices（取得 / 作成 + 手数料計算）。
  - stripe webhook（`constructEvent` モックで署名検証分岐、`checkout.session.completed` /
    `account.updated`）、login-link、`pay/:id`、stripe-account-link、stripe-status。
  - Lambda handler（`hono/aws-lambda` の `handle(app)`）が API Gateway プロキシ event を処理し
    `{ statusCode, headers/multiValueHeaders, body }` を返すこと。

## 画面 E2E（Playwright）非対象の理由

本リポジトリは HTTP API のみで画面を持たない。レスポンス契約・ルーティング・認可は
`app.request()` 結合で十分に担保できるため、Playwright は対象外とする（UI を持つ
user portal / admin / lp 側で別途実施）。

## 自動化できない確認（人力スモーク）

- **実 AWS デプロイ後の主要エンドポイント疎通**: `./deploy-api.sh dev` 後に確認（実 AWS のため自動化不可）。
- **`@hono/node-server` ローカル起動 + フロント疎通**: フルスタック手動結合のため自動化不可。
