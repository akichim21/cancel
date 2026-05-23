# CORS 設定

## 概要

API (`cancel-billing-service-api/src/lambda.ts`) は環境変数 `CORS_ORIGIN`（カンマ区切り）で許可オリジンを管理する。
リクエストの `Origin` ヘッダが許可リストに含まれていれば echo back、含まれていなければ先頭のオリジンを返す。

## 許可オリジン

| 環境 | オリジン |
|---|---|
| dev | `https://dev.cancel.co.jp`, `https://dev.user.cancel.co.jp`, `https://dev.admin.cancel.co.jp`, `http://localhost:5173` |
| prod | `https://cancel.co.jp`, `https://user.cancel.co.jp`, `https://admin.cancel.co.jp` |

設定値: `cancel-billing-service-api/.env.development` / `.env.production` の `CORS_ORIGIN`

## レスポンスヘッダ

`getCorsHeaders(origin)` が以下を返す:

```
Access-Control-Allow-Origin: <許可されたoriginまたは先頭>
Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS
Access-Control-Allow-Headers: Content-Type, Authorization
Access-Control-Allow-Credentials: true
```

## ローカル開発時

フロントは `http://localhost:5173`（Vite デフォルト）で起動するため、
`.env.development` の `CORS_ORIGIN` に含めておくこと。
API は `http://localhost:3000` で起動。

## 新しいドメインを追加する場合

1. `cancel-billing-service-api/.env.{development,production}` の `CORS_ORIGIN` にカンマ区切りで追加
2. API を再デプロイ（`./deploy-api.sh {env}`）
3. フロント側からのリクエストで `Access-Control-Allow-Origin` ヘッダが返ることをブラウザ DevTools で確認
