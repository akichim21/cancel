# cancel-billing-service-api

バックエンドAPI（Express + AWS Lambda）。

## エンドポイント

ハンドラ: `cancel-billing-service-api/src/lambda.js`（モノリス的に全エンドポイントを1ファイルで管理）

主なエンドポイント:

| メソッド | パス | 用途 |
|---|---|---|
| POST | `/applications` | LP からの申請作成 |
| GET | `/applications` | 管理画面: 申請一覧 |
| GET | `/applications/:id` | 申請詳細 |
| PUT | `/applications/:id/status` | 申請ステータス更新（承認/却下） |
| POST | `/stripe/onboarding-link` | Stripe Connect Account Link 発行 |
| GET | `/stripe/status/:applicationId` | `details_submitted` 確認 |
| POST | `/login` | サロンユーザーログイン |
| POST | `/admin/login` | 管理者ログイン |
| POST | `/forgot-password` | パスワードリセット要求 |
| POST | `/reset-password` | パスワードリセット実行 |
| POST | `/change-password` | パスワード変更（要認証） |
| POST | `/cancellations` | キャンセル請求作成 |
| GET | `/cancellations` | キャンセル請求一覧 |
| POST | `/webhook` | Stripe Webhook 受信 |

実装の正としては `src/lambda.js` を直接読むこと。

## DynamoDB テーブル

| テーブル | 用途 | キー |
|---|---|---|
| `cancel-billing-applications-{env}` | サロン申請 | `id` (PK) |
| `cancel-billing-users-{env}` | サロンユーザー | `id` (PK), `email` (GSI) |
| `cancel-billing-cancellations-{env}` | キャンセル請求 | `id` (PK), `applicationId` (GSI) |

テーブル作成スクリプト: `src/dynamodb-setup.js`（初回起動時に `tableInitialized` フラグで一度だけ実行）

## 環境変数

| 変数 | 用途 |
|---|---|
| `STRIPE_SECRET_KEY` | Stripe API 鍵（必須） |
| `STRIPE_WEBHOOK_SECRET` | Webhook 署名検証（必須） |
| `JWT_SECRET` | JWT 署名 |
| `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_PHONE_NUMBER`, `TWILIO_MESSAGING_SERVICE_SID` | SMS 送信 |
| `TWILIO_SENDER_ID` | 顧客宛 SMS の送信元表示に使う英字送信者名（`Cancel Pay`。GTSS-920）。11 文字以内・英数字と半角スペースのみ・英字を 1 文字以上。未設定なら海外番号のまま |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | prod のみ。SES SMTP 認証 |
| `CORS_ORIGIN` | カンマ区切り許可オリジン |
| `DYNAMODB_TABLE_NAME` | 申請テーブル名（dev/prod 切替） |
| `NODE_ENV` | `dev` / `prod` |

詳細: ルート `CLAUDE.md` の「環境変数の置き場所」セクション

## ローカル起動

```bash
npm install
npm run dev    # http://localhost:3000 で起動
```

## テスト

```bash
npm test       # jest
```

テストファイル: `tests/` 配下。**ロジック修正時はテスト追加が必須**（ルート CLAUDE.md 参照）。

## デプロイ

```bash
./deploy-api.sh dev    # dev Lambda 更新
./deploy-api.sh prod   # 本番（確認プロンプトあり）
```

`create-zip.sh` で `lambda-deployment-{env}-{timestamp}.zip` を作成 → `aws lambda update-function-code` で反映。

## 補助スクリプト

| ファイル | 用途 |
|---|---|
| `create-admin-user.js` | 初期管理者ユーザー作成 |
| `create-users-table.js` | ユーザーテーブル手動作成 |
| `check-twilio-config.js` | Twilio 設定の疎通確認 |
| `setup-api-gateway.sh` | API Gateway 初期構築 |
| `setup-dev-infra.sh` | dev 環境一括構築 |
| `update-stripe-key.sh` | Stripe キーを Lambda 環境変数に反映 |

## 関連ドキュメント

- `docs/product/application-flow.md` — 申請フロー
- `docs/product/cancellation-flow.md` — キャンセル請求フロー
- `docs/tech/stripe-connect.md` — Stripe Connect 詳細
- `docs/tech/auth.md` — JWT 認証
- `docs/tech/cors.md` — CORS 設定
- `docs/tech/deployment.md` — デプロイ詳細
