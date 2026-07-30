# cancel-billing-service-lp（LP・申請フォーム）

サービスの公開 LP およびサロン申請フォーム、決済結果ページ。URL: https://cancel.co.jp/

## 技術スタック

- React 18 + **JSX**（TS ではない）+ Vite
- Tailwind CSS
- Framer Motion（アニメーション）
- React Hook Form + Zod
- 独自ルーティング（`window.location.pathname` を App.jsx で判定して分岐。
  `react-router-dom` は package.json に残っているが **src では未使用**）
- Lucide React（アイコン）

## ページ構成

| パス | コンポーネント | 用途 |
|---|---|---|
| `/` | `src/App.jsx` | メイン LP・申請フォーム |
| `/verify-email-sent` | `src/components/VerifyEmailSent.jsx` | 申込送信成功時の認証メール送信のご案内（表示中のみ noindex 動的適用。GTSS-883） |
| `/verify-email` | `src/components/EmailVerify.jsx` | メール認証結果（認証完了/期限切れ/認証済み/無効リンク。GTSS-842） |
| `/stripe-success` | `src/components/StripeSuccess.jsx` | Stripe 登録完了判定 |
| `/stripe-refresh` | `src/components/StripeRefresh.jsx` | Account Link 再発行 |
| `/payment-success`（`/payment-complete` エイリアス） | `src/components/PaymentSuccess.jsx` | 顧客の決済成功 |
| `/payment-cancel` | `src/components/PaymentCancel.jsx` | 顧客の決済キャンセル |
| `/privacy-policy` | `src/pages/PrivacyPolicy.jsx` | プライバシーポリシー |
| `/terms-of-service` | `src/pages/TermsOfService.jsx` | 利用規約 |
| `/specified-commercial-transaction` | `src/pages/SpecifiedCommercialTransaction.jsx` | 特定商取引法表記 |

ヘッダー/フッターは `src/components/SiteHeader.jsx` / `SiteFooter.jsx` に共通化されており、
LP トップと `/verify-email-sent` で共用する（ナビリンクは `/#features` 形式。GTSS-883）。

**申込フォームの送信成功時**（新規・未認証再申込のいずれも）は `/verify-email-sent` へ
full page load で遷移する（`src/utils/navigation.js` の `goToVerifyEmailSent`。
成功時 alert・フォーム直下の成功カードは GTSS-883 で廃止）。409 重複・エラー時は遷移しない。
詳細は `docs/product/application-flow.md`「1. LP 申請」を参照。

## 重要コンポーネント

### `StripeSuccess.jsx`

- `applicationId` クエリパラメータを受け取る
- API で `details_submitted` を確認 → 成功 / 未完了画面に分岐
- 未完了時は `/stripe-refresh` への誘導リンクを表示

### `StripeRefresh.jsx`

- Stripe Account Link が期限切れになった場合に再発行
- API: `POST /stripe/onboarding-link` を呼び出して新しいリンクを取得

### `PricingSection.jsx`

- LP 内の料金プラン表示セクション

## API 通信

ベース URL は **`VITE_API_URL`**（admin は `VITE_API_BASE_URL` なので注意）。

| 環境 | `VITE_API_URL` |
|---|---|
| ローカル | `http://localhost:3000` |
| dev | `https://dev.api.cancel.co.jp` |
| prod | `https://api.cancel.co.jp` |

## プライバシーポリシー

外部 URL（`https://www.shairesalon-go.today/privacy-policy-text/`）から fetch して表示。
表示エラー時は外部サイトの CORS ヘッダ（`Access-Control-Allow-Origin: *`）を要確認。

## ローカル起動

```bash
npm install
npm run dev    # http://localhost:5173
```

## ビルド & デプロイ

```bash
npm run build:dev
npm run build:prod
./deploy.sh dev
./deploy.sh prod
```

## セキュリティ修正履歴

`SECURITY_FIXES.md` 参照。過去のセキュリティ対応内容を記録している。

## テスト

**Vitest**（jsdom + @testing-library/react）導入済み（`npm test`。`src/__tests__/*.test.jsx` /
`src/components/__tests__/*.test.jsx`）。申請フォーム・ルーティング・認証結果画面・
ご案内ページ等を担保する。Playwright（実ブラウザ E2E）は未導入のため、実ブラウザでの
遷移・実メール受信を含む結合確認は人力テストで補完する。

## 関連ドキュメント

- `docs/product/application-flow.md` — 申請〜オンボーディングの全体像
- `docs/product/cancellation-flow.md` — 顧客決済フロー
- `docs/tech/stripe-connect.md` — Stripe Connect の挙動詳細
