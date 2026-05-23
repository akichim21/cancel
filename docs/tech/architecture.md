# アーキテクチャ

## システム全体図

```
┌─────────────────────────────────────────────────────────────────────┐
│                          CloudFront + S3                            │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│  │ cancel.co.jp     │  │ user.cancel.co.jp│  │admin.cancel.co.jp│  │
│  │ (LP/申請フォーム) │  │ (サロンポータル)  │  │ (運営管理画面)    │  │
│  │ cancel-billing-  │  │ cancel-billing-  │  │ cancel-billing-  │  │
│  │ service-lp       │  │ service          │  │ service-admin    │  │
│  └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘  │
└───────────┼─────────────────────┼─────────────────────┼─────────────┘
            │                     │                     │
            └─────────────────────┴─────────────────────┘
                                  │
                                  ▼
                  ┌─────────────────────────────────┐
                  │  API Gateway → AWS Lambda       │
                  │  cancel-billing-service-{env}   │
                  │  (cancel-billing-service-api)   │
                  │  api.cancel.co.jp               │
                  └────────────┬────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
        ┌──────────┐    ┌──────────┐    ┌──────────┐
        │ DynamoDB │    │   SES    │    │  Twilio  │
        │ (3tables)│    │  (mail)  │    │  (SMS)   │
        └──────────┘    └──────────┘    └──────────┘
                               │
                               ▼
                       ┌──────────────┐
                       │   Stripe     │
                       │   Connect    │
                       └──────────────┘
```

## 各レイヤーの責務

### フロントエンド（3アプリ）

- すべて Vite + React。LP のみ JSX（React 18）、他は TS（React 19）
- ホスティング: S3 + CloudFront
- 認証: JWT（localStorage 保存、24 時間有効）
- API 通信は `services/api.ts` 等に集約し、JWT を自動付与
- ビルド時に `.env.{development,production}` から `VITE_*` 変数が埋め込まれる

### バックエンド（API）

- Express ベースを AWS Lambda で実行（`src/lambda.ts`）
- ローカル: `src/index.js` で起動（`npm run dev`、ポート 3000）
- 認証: JWT 発行・検証（`jsonwebtoken`）
- バリデーション: `joi`
- 外部連携: Stripe / SES / Twilio

### データストア

DynamoDB（ap-northeast-1）。テーブル名は環境変数 `DYNAMODB_TABLE_NAME` 等で切り替え。

| テーブル | 用途 |
|---|---|
| `cancel-billing-applications-{env}` | サロン申請情報 |
| `cancel-billing-users-{env}` | サロンユーザー（ログイン情報） |
| `cancel-billing-cancellations-{env}` | キャンセル請求 |

## 環境（dev / prod）

| 種別 | dev | prod |
|---|---|---|
| ドメイン | `*.dev.cancel.co.jp` | `*.cancel.co.jp` |
| Lambda | `cancel-billing-service-dev` | `cancel-billing-service-prod` |
| DynamoDB | `cancel-billing-{kind}-dev` | `cancel-billing-{kind}-prod` |
| Stripe | テストキー (`sk_test_`) | 本番キー (`sk_live_`) |
| AWS プロファイル | `cancel-billing-service-prod`（共通） | 同左 |

dev/prod の AWS アカウントは同一（プロファイル共通）で、リソース名で分離している点に注意。

## 関連ドキュメント

- 認証: `docs/tech/auth.md`
- デプロイ: `docs/tech/deployment.md`
- CORS: `docs/tech/cors.md`
- Stripe Connect: `docs/tech/stripe-connect.md`
