# キャンセル請求フロー

サロンの顧客がドタキャンした際の請求〜回収フロー。請求の作成経路は 2 通り:
- **手動作成**: 運営/サロンが管理画面・ポータルから登録（従来）。作成と同時に送信（決済リンク通知）。
- **サロンボード取り込み**: サロンボードからキャンセル予約を自動取り込み、「送信前」で作成し、確認後に送信（GTSS-817）。
  業務詳細は `docs/product/salonboard-import.md`、技術は `docs/tech/salonboard-import.md`。

## 全体フロー

```
[手動登録] または [サロンボード取り込み（送信前で作成）]
    ↓
[（送信前の場合）一覧の「送信」ボタンで内容確認・キャンセル料調整]
    ↓
[顧客にメール/SMSで決済リンク送信] → ステータス: 請求中(pending)
    ↓
[顧客がStripe Checkoutで決済]
    ↓
[Stripe Webhook (checkout.session.completed) で完了通知] → ステータス: 支払済(paid)
    ↓
[サロンへpayout (Stripe Connect)]
```

## ステータス（SSOT）

DB 保存値は英語 enum、表示は日本語ラベル（`cancel-billing-service-api/src/constants/cancellation-status.ts`）:

| 値 | ラベル | 意味 |
|---|---|---|
| `pre_send` | 送信前 | 取り込みで作成・未送信（GTSS-817） |
| `pending` | 請求中 | 送信済み・未決済（旧 `sent` を統合） |
| `paid` | 支払済 | 決済完了 |
| `canceled` | キャンセル済 | 取消 |
| `failed` | 失敗 | 決済失敗 |

## ステップ詳細

### 1. キャンセル請求の作成

- 手動: 管理画面 `cancel-billing-service-admin/src/components/CancellationManagement.tsx` /
  サロン向け `cancel-billing-service/src/components/InvoiceForm.tsx`。作成と同時に送信。
- 取り込み: `cancel-billing-service-api/src/services/salonboard-import.service.ts` が「送信前（`pre_send`）」で作成。
  取り込み時点では顧客通知を送らない。
- 保存先: **Aurora PostgreSQL `cancellations` テーブル**（drizzle。旧 DynamoDB は移行元のみ・ランタイム不参照）。

### 2. 送信（決済リンク送信）

- 「送信前」の請求は一覧の「送信」ボタンから送信する（運営=管理画面 / サロン本人=ポータル。サロンは自社配下のみ）。
  サービスは `cancellation-send.service.ts`。`status='pre_send'` の条件付き更新で二重送信を防止する。
- 手動作成は作成時に同経路で送信する（`invoice.service.ts` の createInvoice）。
- Stripe Checkout Session を作成し、顧客にメール (SES) / SMS (Twilio) で決済リンクを送信。
  通知チャネルは顧客連絡先有無で決定（メール優先、無ければ SMS）。送信後ステータスは請求中(`pending`)。

### 3. 顧客による決済

- Stripe Checkout ページで決済 → リダイレクト先で結果表示（`cancel-billing-service-lp` の PaymentSuccess / PaymentCancel）。

### 4. Webhook 受信

- Stripe Webhook を `cancel-billing-service-api` で受ける（`checkout.session.completed`, `account.updated`）。
- 必須環境変数 `STRIPE_WEBHOOK_SECRET`。受信後にステータスを `paid` へ遷移（二重計上防止のガード付き）。

### 5. payout

- Stripe Connect の destination charges でサロンの connected account へ入金。

## データモデル（Aurora PostgreSQL）

`cancellations`（`cancel-billing-service-api/src/db/schema.ts`）。主なカラム:
- `id` (PK, UUID) / `applicationId` (FK→applications) / `status`（上表 SSOT）
- `customerName` / `customerNameKana` / `customerEmail` / `customerPhone`（顧客 PII。退会時マスク）
- `amount`（キャンセル料）/ `appointmentAmount`（予約金額）/ `paidAmount` / `platformFee` / `stripeFee`
- `appointmentDate` / `startTime` / `menuName` / `staffName`
- 取り込み（GTSS-817）: `source` / `externalShopId`(FK→external_shops) / `externalReservationId` /
  `reservationStatus` / `cancellationType` / `paymentType` / `cancellationPolicy` / `receivedAt`
- 冪等キー: `(externalShopId, externalReservationId)` 部分ユニーク（手動作成は両 NULL で対象外）

## 関連コード

| ファイル | 役割 |
|---|---|
| `cancel-billing-service-api/src/handlers/cancellations.handler.ts` | 一覧/取り込み/送信/ログ ルート |
| `cancel-billing-service-api/src/services/cancellation.service.ts` | 一覧・手動取り込み・ログ取得 |
| `cancel-billing-service-api/src/services/cancellation-send.service.ts` | 送信アクション（運営/サロン） |
| `cancel-billing-service-api/src/services/salonboard-import.service.ts` | サロンボード取り込み中核 |
| `cancel-billing-service-api/src/services/invoice.service.ts` | 手動作成・支払いリダイレクト |
| `cancel-billing-service-admin/src/components/CancellationManagement.tsx` | 管理画面一覧・取り込み・送信 |
| `cancel-billing-service/src/components/InvoiceList.tsx` | サロン向け一覧・送信 |
| `cancel-billing-service-lp/src/components/PaymentSuccess.jsx` / `PaymentCancel.jsx` | 決済結果画面 |
