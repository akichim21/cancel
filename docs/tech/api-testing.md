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
| DynamoDB (`docClient.send`) | `aws-sdk-client-mock`（`mockClient(DynamoDBDocumentClient)`） | クライアントの `send` を実行時にスタブ。コマンド別に `.on(GetCommand, { TableName }).resolves(...)` で制御 |
| SES (`sesClient.send`) | `aws-sdk-client-mock`（`mockClient(SESClient)`） | 同上。送信引数を `commandCalls` で検証 |
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

`setup.js`（`setupFiles`）でモジュール評価前に `JWT_SECRET` / `DYNAMODB_TABLE_NAME` /
`CORS_ORIGIN` / `STRIPE_SECRET_KEY=sk_test_...` / `NODE_ENV=test` / `TWILIO_*` を設定する。
Stripe/Twilio クライアントはキー未設定だとロード時に例外を投げるため、生成自体は通す。

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

## バッチのテスト方針

バッチ処理は **純粋関数 unit + 実 Postgres 統合の二層**で担保するのが基本形。実行時刻は必ず
`run*({ now })` で注入し、実時間に依存させない。

### 申請削除バックアップ（restore / purge・GTSS-20）

- **純粋関数 unit**（`src/__tests__/unit/application-backup.test.js`）: `buildBackupPayload`
  （`application + cancellations[]` → JSON ペイロード）、`computeExpiresAt`（+90日）、
  `isBackupExpired`（90 日境界: 89=残す / ちょうど90=削除 / 91=削除。`expiresAt <= now`）。DB 非依存で
  境界値を固定する。
- **統合（実 Postgres）**（`src/__tests__/e2e/application-deletion-backup.test.js`）: `app.request()` の
  `DELETE` 操作と、バッチ service（`restoreApplication` / `purgeExpiredBackups`）の直呼びを組み合わせ、
  顧客 PII マスク（`***`）/ バックアップ生成・冪等ガード / restore（PII・status・`deletedAt=NULL` 復元、
  email 一意衝突、login 非再作成）/ purge（期限切れのみ削除・live 無傷）/ `withdrawn` 手動遷移拒否 /
  status ルート認可（401/403/200）を検証する。スキーマの NOT NULL 制約は `schema.test.js`
  （`information_schema` の `is_nullable='NO'` + NULL insert 拒否）で担保。
- **テスト隔離**: `helpers/db.js` の `truncateAll` に `application_deletion_backups` を含める。
- **自動化困難（人力）**: EventBridge スケジュールの実発火・`aws lambda invoke` での restore 運用・
  `terraform plan`（AWS 認証前提）は人力スモーク（下記）/ インフラ側で確認する。

### 外部 API を伴うバッチ（Stripe オンボーディング自動リマインド・GTSS-909 / #67）

外部 API（Stripe）への問い合わせが対象判定に入るバッチは、**三分割**で担保する。判定ロジックを
service 内の純粋関数として切り出しておくことが前提（そうしないと分岐網羅が実 DB テストに寄って重くなる）。

1. **回判定 unit**（`unit/stripe-onboarding-reminder-decision.test.ts`）: `decideOnboardingReminderRound`。
   JST 暦日の経過日数の**境界値**（2/3/6/7/13/14/15 日）、試行済み回の除外、最小間隔（中 3 日）、
   対象外ステータスを DB 非依存で網羅する。
2. **状態判定 unit**（同ファイル）: `evaluateStripeRequirements`。Stripe account オブジェクトを直接渡し、
   判定表の全分岐（`completed` / `blocked` / `not_started` / `action_required` / `waiting_stripe`）と、
   `requirements` が `undefined` / `null` / 非配列でも例外にならないことを固定する。
   文面は別ファイル（`unit/stripe-onboarding-reminder-content.test.ts`）で**完全一致（スナップショット）**
   と禁止文言リストを固定する（必須フレーズの部分一致だけでは段落削除・署名変更を検出できない）。
3. **実 Postgres + モック E2E**（`e2e/stripe-onboarding-reminders.test.js`）: バッチ service を直呼びし、
   UNIQUE 制約 + claim の実挙動（冪等・多重起動）、失敗分離、履歴確定失敗、一次抽出の SQL 側除外条件、
   直列ループ中の状態変化（退会競合）を検証する。`aws-sdk-client-mock` で SES、
   `installExternalMocks()` で Stripe を隔離する。

**外部 API モックの落とし穴**:

- `installExternalMocks()` は Stripe モックの全メソッドを `mockReset()` してから注入する。`beforeEach` では
  **必ず `installExternalMocks()` を呼んだ後に** `mockResolvedValue` / `mockImplementation` を設定する
  （順序を逆にすると設定が消える）。
- `stripe.accounts.retrieve` には**既定実装が無い**。未スタブだと `undefined` が返り、
  `account.requirements` の参照で TypeError になる。
- 複数申込を 1 実行で処理するバッチでは、連結アカウント ID ごとに戻り値を出し分ける
  （`mockImplementation(async (id) => ACCOUNTS[id])`）。
- **実マイグレーション SQL をテストから実行する**: バックフィルのように書式が挙動を左右する SQL は、
  テストへ書き写すのではなく `readFileSync` でマイグレーションファイルを読んで `sql.raw()` で流す。
  書き写すと本番へ流れる SQL の書式ミスを検出できない。
- **新テーブルは `helpers/db.js` の `truncateAll()` へ必ず追加する**（対象を明示列挙しているため、
  列挙漏れはテスト間でデータが残り冪等テストが偽陽性・偽陰性を起こす）。

**静的検査**（`unit/stripe-onboarding-reminder-contract.test.ts`）: 実行時テストでは検出できない配線漏れを
固定する。デプロイスクリプトの env / タスク定義 family 契約、送信履歴テーブルの列（PII 非保存）、
承認経路の本数（経路が増減したら落ちる検知ガード）。

## 画面 E2E（Playwright）非対象の理由

本リポジトリは HTTP API のみで画面を持たない。レスポンス契約・ルーティング・認可は
`app.request()` 結合で十分に担保できるため、Playwright は対象外とする（UI を持つ
user portal / admin / lp 側で別途実施）。

## 自動化できない確認（人力スモーク）

- **実 AWS デプロイ後の主要エンドポイント疎通**: `./deploy-api.sh dev` 後に確認（実 AWS のため自動化不可）。
- **`@hono/node-server` ローカル起動 + フロント疎通**: フルスタック手動結合のため自動化不可。
