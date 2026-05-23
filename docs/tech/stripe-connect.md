# Stripe Connect

## 概要

サロンへの売上 payout は Stripe Connect（Express アカウント）で行う。
本サービスはプラットフォーム、サロンが connected account となる。

## 必要な環境変数

| 変数 | 用途 | 例 |
|---|---|---|
| `STRIPE_SECRET_KEY` | API 鍵（秘密鍵） | `sk_test_...` / `sk_live_...` |
| `STRIPE_WEBHOOK_SECRET` | Webhook 署名検証 | `whsec_...` |

**`STRIPE_SECRET_KEY` には公開鍵 (`pk_`) を絶対に設定しない。**

フロント側で公開鍵を使う場合は `VITE_STRIPE_PUBLISHABLE_KEY`（サロンポータルのみ）。

## オンボーディングフロー

1. 運営者が管理画面で申請を承認
2. API が Stripe Connect で Express account を作成 → Account Link を発行
3. サロンにメール送信（リンク有効期限はデフォルト数分）
4. サロンがリンクを開く → Stripe ホストの本人確認・銀行口座登録フローへ
5. 完了後、`https://cancel.co.jp/stripe-success?applicationId=...` にリダイレクト
6. `StripeSuccess.jsx` が API に `applicationId` を渡して `details_submitted` を確認
   - `true` → ステータス `利用中`、ユーザーポータル誘導
   - `false` → 未完了画面（`/stripe-refresh` で Account Link 再発行）

## Webhook

`cancel-billing-service-api/src/lambda.ts` で受信。

| イベント | 用途 |
|---|---|
| `checkout.session.completed` | キャンセル料決済完了 → DB のステータスを `paid` に更新 |
| `account.updated` | オンボーディング状態の変化検知 |

Stripe ダッシュボードで上記イベントを Webhook エンドポイント（例: `https://api.cancel.co.jp/webhook`）に登録しておくこと。

## 決済（キャンセル料請求）

1. 管理画面でキャンセル請求登録
2. API が Stripe Checkout Session を作成（destination charge でサロン connected account を指定）
3. 顧客に Checkout URL をメール/SMS 送信
4. 顧客が決済 → `checkout.session.completed` Webhook で完了処理

## テスト

dev 環境は **必ずテストキー** (`sk_test_`) を使うこと。
本番カードを誤って使わないよう、Stripe ダッシュボードで Test mode に切り替えてから確認する。

## トラブルシュート

**Stripe リンクが切れている**

- Account Link は有効期限が短い（数分〜数時間）
- `/stripe-refresh` で再発行（`StripeRefresh.jsx`）

**Webhook 署名検証エラー**

- `STRIPE_WEBHOOK_SECRET` が誤っていないか確認
- Stripe ダッシュボードの Webhook 設定で endpoint signing secret をコピーし直す
