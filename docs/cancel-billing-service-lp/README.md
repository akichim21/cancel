# cancel-billing-service-lp（LP・申請フォーム）

サービスの公開 LP およびサロン申請フォーム、決済結果ページ。URL: https://cancel.co.jp/

## 技術スタック

- React 18 + **JSX**（TS ではない）+ Vite
- Tailwind CSS
- Framer Motion（アニメーション）
- React Hook Form + Zod
- ルーティング: **React Router 未使用**。`src/App.jsx` が `window.location.pathname` と `?_page=` クエリを直接読む独自パス分岐。ページ間リンクはすべて通常遷移（フルページロード）で、SPA 内のクライアントサイド画面遷移は存在しない
- Lucide React（アイコン）

## ページ構成

| パス | コンポーネント | 用途 | インデックス |
|---|---|---|---|
| `/` | `src/App.jsx` | メイン LP・申請フォーム | 公開 |
| `/terms-of-service` | `src/pages/TermsOfService.jsx` | 利用規約 | 公開 |
| `/privacy-policy` | `src/pages/PrivacyPolicy.jsx` | プライバシーポリシー | 公開 |
| `/specified-commercial-transaction` | `src/pages/SpecifiedCommercialTransaction.jsx` | 特定商取引法表記 | 公開 |
| `/verify-email` | `src/components/EmailVerify.jsx` | メール認証結果（`?token=` 必須） | noindex |
| `/stripe-success` | `src/components/StripeSuccess.jsx` | Stripe 登録完了判定（`?applicationId=`） | noindex |
| `/stripe-refresh` | `src/components/StripeRefresh.jsx` | Account Link 再発行（`?applicationId=`） | noindex |
| `/payment-success` | `src/components/PaymentSuccess.jsx` | 顧客の決済成功 | noindex |
| `/payment-complete` | 同上 | 決済成功の旧 URL エイリアス | noindex |
| `/payment-cancel` | `src/components/PaymentCancel.jsx` | 顧客の決済キャンセル | noindex |

### `?_page=` クエリによる出し分け

pathname に加えて `?_page=` クエリでも画面を出し分けできる（対応値は `payment-success` / `stripe-success` / `stripe-refresh` / `verify-email` の 4 種のみ。`payment-cancel` / `payment-complete` は非対応）。

- 分岐の評価順: 特商法 → プライバシー → 利用規約 → verify-email → stripe-success → stripe-refresh → payment-success(+complete) → payment-cancel → メインフォーム
- 公開 4 ページのパスでは path 判定が優先され `_page` は無視される（例: `/terms-of-service?_page=stripe-success` は利用規約を描画）
- `_page` が未知の値のときはメインフォームへフォールスルーする
- 上記のいずれにも一致しない未知パス（例 `/foo`）は、CloudFront の 404→200 フォールバックによりトップと同一内容を HTTP 200 で返す（soft-404）

## SEO 設定（#50 / GTSS-887）

LP は S3 + CloudFront 配信の SPA で全 URL に同一の初期 HTML が返るため、**トップ用の title / description / OGP のみ `index.html` に静的設定**し、ページ固有の head は **JS レンダリング時に `src/seo.js` が確定**する（`resolvePageKey()` でページ種別を解決し、`applyPageMeta()` が head を upsert して常に高々 1 件を保証。App.jsx の無条件 useEffect から実行）。Google はレンダリング後 HTML で評価する（Search Console ライブテストで取得確認済み）。

### ページ別 title / description / canonical

| パス | title | canonical |
|---|---|---|
| `/` | 美容室・アイネイル・エステサロン向けキャンセル料請求｜キャンセル請求便 | `https://cancel.co.jp/` |
| `/terms-of-service` | 利用規約｜キャンセル請求便 | `https://cancel.co.jp/terms-of-service` |
| `/privacy-policy` | プライバシーポリシー｜キャンセル請求便 | `https://cancel.co.jp/privacy-policy` |
| `/specified-commercial-transaction` | 特定商取引法に基づく表記｜キャンセル請求便 | `https://cancel.co.jp/specified-commercial-transaction` |

- meta description も 4 ページ固有（文言は `src/seo.js` の `PAGE_META` が正）
- canonical / og:url は環境によらず `https://cancel.co.jp` 固定の絶対 URL・クエリなし（dev がクロールされた場合の重複インデックス抑止を兼ねる）
- OGP: 公開 4 ページで og:title / og:description をページ固有値、og:url を canonical と同一値で出力。`index.html` には og:type=`website` / og:site_name / twitter:card=`summary` も静的設定。**og:image は未設定**（シェア用画像素材が無いため。必要なら画像制作とあわせて別チケット）
- 制約: SNS クローラは JS 非実行のため、下層ページのシェアはサイト共通（トップ用）OGP 表示になる

### noindex

noindex 対象（上表の noindex 行 + `?_page=` 出し分け表示 + 未知パス）には `<meta name="robots" content="noindex" />` を JS で出力する。noindex ページ・未知パスでは description / canonical / og:url を出力しない（初期 HTML 由来の静的 description も削除）。title は「キャンセル請求便」のまま。robots.txt でのクロール拒否はしない（Google が noindex を確認できる状態を保つ）。

### sitemap.xml / robots.txt

- 置き場所: `public/sitemap.xml` / `public/robots.txt`（Vite が `dist/` ルートへコピー → S3 実オブジェクトとして配信されるため SPA フォールバックに食われない。deploy.sh 変更不要）
- sitemap.xml は公開 4 URL のみ掲載。ページ追加時は sitemap.xml と `src/seo.js` の `PAGE_META` / `resolvePageKey` をあわせて更新し、`src/__tests__/seo.test.jsx` / `staticSeoFiles.test.js` に期待値を追加する
- robots.txt は `Allow: /` + Sitemap 行のみ。Disallow は追加しない

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

**Vitest（jsdom + @testing-library/react）** が稼働中（`npm test`。`src/**/*.test.{js,jsx}` 13 ファイル: 申請フォーム / ルーティング / 生年月日 / 代理店コード / GTM / SEO / 静的 SEO ファイル / Stripe / メール認証ほか）。`src/test/renderApp.jsx` が独自ルーティング向けに URL 設定 → `<App/>` render を行う。CI（GitHub Actions）で lint + Vitest を実行。Playwright（E2E）は未導入。

## 関連ドキュメント

- `docs/product/application-flow.md` — 申請〜オンボーディングの全体像
- `docs/product/cancellation-flow.md` — 顧客決済フロー
- `docs/tech/stripe-connect.md` — Stripe Connect の挙動詳細
