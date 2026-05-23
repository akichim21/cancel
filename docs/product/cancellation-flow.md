# キャンセル請求フロー

サロンの顧客がドタキャンした際の請求〜回収フロー。

## 全体フロー

```
[管理画面でキャンセル請求登録]
    ↓
[顧客にメール/SMSで決済リンク送信]
    ↓
[顧客がStripe Checkoutで決済]
    ↓
[Stripe Webhook (checkout.session.completed) で完了通知]
    ↓
[サロンへpayout (Stripe Connect)]
```

## ステップ詳細

### 1. キャンセル請求登録

- 入口: 管理画面 `cancel-billing-service-admin/src/components/CancellationManagement.tsx`
- 入力: サロン（applicationId）・顧客情報（氏名・連絡先）・金額・キャンセル理由
- 保存先: DynamoDB `cancel-billing-cancellations-{env}`

### 2. 決済リンク送信

- API: Stripe Checkout Session を作成し、顧客にメール (SES) / SMS (Twilio) で送信
- 通知チャネルは顧客の連絡先有無で決定（メール優先、SMS は補完）

### 3. 顧客による決済

- Stripe Checkout ページで決済（カード）
- 決済成功 → リダイレクト先で結果表示（`cancel-billing-service-lp/src/components/PaymentSuccess.jsx`）
- キャンセル時 → `PaymentCancel.jsx`

### 4. Webhook 受信

- Stripe Webhook を `cancel-billing-service-api` で受ける
- 登録イベント: `checkout.session.completed`, `account.updated`
- 必須環境変数: `STRIPE_WEBHOOK_SECRET`
- 受信後: キャンセル請求ステータス更新、サロン通知

### 5. payout

- Stripe Connect の destination charges でサロンの connected account へ自動入金
- サロン側 Stripe ダッシュボードで売上確認可能

## DynamoDB スキーマ（概略）

`cancel-billing-cancellations-{env}`:
- `id` (PK)
- `applicationId` (GSI) — サロンID
- `customerName`, `customerEmail`, `customerPhone`
- `amount` — キャンセル料金額（円）
- `reason` — キャンセル理由
- `status` — `pending` / `paid` / `cancelled` / `failed`
- `stripeCheckoutSessionId`
- `paidAt`, `createdAt`, `updatedAt`

## 関連コード

| ファイル | 役割 |
|---|---|
| `cancel-billing-service-admin/src/components/CancellationManagement.tsx` | 管理画面 |
| `cancel-billing-service-api/src/lambda.ts` | API・Webhook ハンドラ |
| `cancel-billing-service-lp/src/components/PaymentSuccess.jsx` | 決済成功画面 |
| `cancel-billing-service-lp/src/components/PaymentCancel.jsx` | 決済キャンセル画面 |
| `cancel-billing-service/src/components/InvoiceList.tsx` | サロン向けキャンセル請求一覧 |
| `cancel-billing-service/src/components/InvoiceForm.tsx` | サロンから請求登録（あれば） |
