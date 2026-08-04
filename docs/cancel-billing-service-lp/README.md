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
| `/verify-email-sent` | `src/components/VerifyEmailSent.jsx` | 申込送信成功時の認証メール送信のご案内（noindex, nofollow + 固有 title。GTSS-883） |
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

## SEO / SSG（ビルド時プリレンダリング）

SEO 値（ページ別 title / description / canonical / robots / OGP）の単一ソースは
`src/seo.js` の `PAGE_META`。適用は**初期 HTML（ビルド時プリレンダ）+ JS の二重適用**（#56）:

- **ビルド時**: `vite-plugin-seo-prerender.js` が closeBundle で dist/index.html を元に
  既知 11 ルートそれぞれの初期 HTML を生成する（`buildPageHeadTags` が PAGE_META から
  head タグ化）。`index.html` の `<!-- seo:prerender:start/end -->` マーカー領域を
  ページ別に置換する。トップは index.html 差し替え、残り 10 ルートは **S3 の拡張子なし
  オブジェクトキーに合わせた拡張子なしファイル名**で出力
- **JS レンダリング時**: `src/seo.js` の `resolvePageKey` / `applyPageMeta` が従来どおり
  head を確定する（SSG 済みページでは同値の冪等な再適用。`npm run dev` と `/?_page=` 経路では
  トップ用初期 HTML から確定）
- **head を触るのは seo.js のみ**（各ページコンポーネントで document.title / meta を書き換えない）

生成ルート・生成物（URL 一覧の単一ソースは `vite-plugin-seo-prerender.js` の `PRERENDER_ROUTES`）:

| 生成物 | 内容 |
|---|---|
| 公開 4 ページ（`/`・`/terms-of-service`・`/privacy-policy`・`/specified-commercial-transaction`） | ページ別 title / description / canonical / og:title / og:description / og:url。canonical / og:url は**ビルド環境によらず prod ドメイン固定** |
| noindex 7 ルート（`/verify-email`・`/verify-email-sent`・`/stripe-success`・`/stripe-refresh`・`/payment-success`・`/payment-complete`(エイリアス)・`/payment-cancel`） | meta robots（`/verify-email-sent` のみ専用 title + `noindex, nofollow`、他はサイト名 title + `noindex`）。description / canonical / og:url は**含めない**（og:title / og:description はサイト共通静的値のまま） |
| `404.html` | 存在しない URL 用の独立静的ページ（サービス名・トップへ戻るリンク・noindex・**アプリ起動スクリプトなし**） |
| `robots.txt` | モード別生成: dev ビルド = `Disallow: /`（Sitemap 行なし）/ prod ビルド = `Allow: /` + Sitemap 行。`public/robots.txt` は削除済み |

`public/sitemap.xml` は静的配信のまま（公開 4 URL・prod 絶対 URL）。

### 存在しない URL の 404 応答

CloudFront の custom error response で **HTTP 404 + /404.html** を返す（infra 管理。
dev は `modules/static-site` のパラメータ、prod は `prod/static-site-lp.tf`。
prod はオリジンが S3 REST エンドポイントのため 403/404 の両方を 404 へマッピング）。
既知 11 ルート・静的アセットは 200。トレイリングスラッシュ付き・大文字違い・
未知パス + `?_page=` 付き URL は 404（`?_page=` での出し分けが効くのはパスが `/` の場合のみ）。
user portal / admin は SPA のため従来の 404→200 フォールバックを維持。
dev 配信には `X-Robots-Tag: noindex` ヘッダも付与される（prod には付与しない）。

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
npm run build:dev     # dev 用（robots.txt = Disallow: /）
npm run build:prod    # prod 用（robots.txt = Allow + Sitemap。GTM 注入あり）
./deploy.sh dev
./deploy.sh prod
```

通常は CI/CD（develop/main push → GitHub Actions（lint + Vitest）→ CodeBuild が
CI モードで deploy.sh を実行）。deploy.sh は 2 段構え（#56）:
(1) dist/ 全体を除外なしで `s3 sync --delete` →
(2) プリレンダ生成の**拡張子なし 10 ファイル**を `Content-Type: text/html; charset=utf-8` +
現行同等の Cache-Control で個別 `s3 cp` 上書き（一覧は `PRERENDER_ROUTES` から取得。
生成物が欠けているとデプロイは失敗する）。

## セキュリティ修正履歴

`SECURITY_FIXES.md` 参照。過去のセキュリティ対応内容を記録している。

## テスト

**Vitest**（jsdom + @testing-library/react）導入済み（`npm test`。`src/__tests__/*.test.{js,jsx}` /
`src/components/__tests__/*.test.jsx`）。申請フォーム・ルーティング・認証結果画面・
ご案内ページ等に加え、SSG まわりは `prerender.test.js`（プリレンダ head / 404.html / 生成網羅 /
マーカー整合）・`seo.test.jsx`（JS 側 head 確定・SSG 済み head からの冪等性・プリレンダ⇔JS 同値性）・
`staticSeoFiles.test.js`（robots.txt モード別生成・sitemap）・`buildIntegration.test.js`
（build:dev / build:prod の実 dist/ 検証）で担保する。Playwright（実ブラウザ E2E）は未導入のため、
実ブラウザでの遷移・実メール受信・実配信環境の HTTP ステータス確認は人力テストで補完する。

## 関連ドキュメント

- `docs/product/application-flow.md` — 申請〜オンボーディングの全体像
- `docs/product/cancellation-flow.md` — 顧客決済フロー
- `docs/tech/stripe-connect.md` — Stripe Connect の挙動詳細
