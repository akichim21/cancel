# cancel-billing-service-admin（運営者向け管理画面）

GTSS 運営者がサロン申請の審査やキャンセル請求の管理を行う画面。URL: https://admin.cancel.co.jp/

## 技術スタック

- React 19 + TypeScript + Vite
- Tailwind CSS
- React Router v7
- 状態管理: Zustand / React Query (TanStack)
- フォーム: React Hook Form + Zod
- 認証: JWT（24 時間）

## 画面一覧

| 画面 | コンポーネント | 用途 |
|---|---|---|
| ログイン | `LoginPage.tsx` | 管理者ログイン |
| ダッシュボード | `Dashboard.tsx` | 概況・統計 |
| 申請一覧 | `ApplicationList.tsx` | 申請を絞り込み・並び替え |
| 申請詳細 | `ApplicationDetail.tsx` | 承認 / 却下、Stripe メール再送 |
| キャンセル請求管理 | `CancellationManagement.tsx` | キャンセル請求の登録・進捗管理 |
| Stripe 再オンボーディング | `StripeReauth.tsx` | サロン代理での再リンク発行 |
| Stripe 完了 | `StripeSuccess.tsx` | サロン Stripe 登録結果確認 |
| 共通ヘッダ | `Header.tsx` | ナビゲーション |
| トースト通知 | `Toast.tsx` | 操作結果表示 |

ルーティング: `src/App.tsx`

## API 通信

`src/services/ApiService.ts` に集約。JWT を `Authorization: Bearer` ヘッダで付与。
ベース URL は `VITE_API_BASE_URL`（**`VITE_API_URL` ではない**）。

## ローカル起動

```bash
npm install
npm run dev    # http://localhost:5173 で起動
```

`.env.local`:
```bash
VITE_API_BASE_URL=http://localhost:3000
```

## ビルド & デプロイ

```bash
npm run build:dev
npm run build:prod
./deploy-admin.sh dev    # ※ deploy.sh ではなく deploy-admin.sh
./deploy-admin.sh prod
```

## 初期管理者アカウント（dev 環境）

- ID: `a.hayashida@shairesalon-go.today`
- PW: `TempPassword123!`

新規管理者の追加は API 側 `create-admin-user.js` で実施:
```bash
cd ../cancel-billing-service-api && node create-admin-user.js
```

## テスト

未整備。vitest 推奨（ルート CLAUDE.md 参照）。

## 注意事項

- デプロイスクリプト名が他のリポジトリ (`deploy.sh`) と異なり `deploy-admin.sh`
- API URL 環境変数名が `VITE_API_BASE_URL`（LP は `VITE_API_URL`）

## 関連ドキュメント

- `docs/product/application-flow.md` — 申請審査フロー
- `docs/product/cancellation-flow.md` — キャンセル請求の登録
- `docs/tech/auth.md` — 管理者認証
