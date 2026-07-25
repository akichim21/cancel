# cancel-billing-service（サロン向けユーザーポータル）

サロンが本サービスを利用するためのポータル。URL: https://user.cancel.co.jp/

## 技術スタック

- React 19 + TypeScript + Vite
- Tailwind CSS
- React Router v7
- 認証: JWT（Context API: `src/contexts/AuthContext.tsx`）

## 画面一覧

| 画面 | コンポーネント | パス（例） |
|---|---|---|
| ログイン | `LoginPage.tsx` | `/login` |
| パスワード忘れ | `ForgotPasswordPage.tsx` | `/forgot-password` |
| パスワードリセット | `ResetPasswordPage.tsx` | `/reset-password` |
| パスワード変更 | `ChangePasswordPage.tsx` | `/change-password` |
| ダッシュボード | `Dashboard.tsx` | `/` |
| キャンセル請求一覧 | `InvoiceList.tsx` | `/invoices` |
| キャンセル請求登録 | `InvoiceForm.tsx` | `/invoices/new` |
| アカウント設定 | `SettingsPage.tsx` | `/settings` |
| Stripe 再オンボーディング | `StripeReauth.tsx` | `/stripe/reauth` |
| Stripe 完了 | `StripeSuccess.tsx` | `/stripe/success` |
| ヘッダ（共通） | `Header.tsx` | — |

最終的なルーティングは `src/App.tsx` 参照。

## API 通信

`src/services/api.ts` に集約。`AuthContext` の JWT を `Authorization: Bearer` ヘッダで自動付与。
ベース URL は `VITE_API_BASE_URL`（`.env.development` / `.env.production`）。

## ローカル起動

```bash
npm install
npm run dev    # http://localhost:5173 で起動
```

`.env.local`（gitignore）を作成:

```bash
VITE_API_BASE_URL=http://localhost:3000
VITE_STRIPE_PUBLISHABLE_KEY=pk_test_xxxx
VITE_APP_ENV=development
```

## ビルド & デプロイ

```bash
npm run build:dev   # dev 向けビルド
npm run build:prod  # prod 向けビルド
./deploy.sh dev     # dev デプロイ（S3 + CloudFront invalidation）
./deploy.sh prod    # 本番デプロイ
```

`deploy.sh` がビルド前に `.env.local` を `.env.{env}` から自動生成するため、手動編集不要。

## テスト

**Vitest（コンポーネント単体）＋ Playwright（e2e）を導入済み**。

```bash
npm test            # typecheck:test（tsconfig.vitest.json）+ vitest run
npm run test:watch  # ウォッチモード
npm run test:coverage
npm run test:e2e    # Playwright（e2e/ 配下）
```

- Vitest: `src/components/__tests__/*.test.tsx`（`SettingsPage` / `InvoiceForm` / `InvoiceList` /
  `Dashboard` / `LoginPage` / `StoreManagement` ほか）
- Playwright: `e2e/*.spec.ts`（ログイン・請求登録・店舗管理などの画面フロー）
- `predeploy` で `lint` と `npm test` が走るため、デプロイ前に必ずテストが実行される

## 関連ドキュメント

- `docs/tech/auth.md` — JWT 認証フロー
- `docs/product/application-flow.md` — サロン側のオンボーディング
- `docs/product/cancellation-flow.md` — キャンセル請求の流れ
