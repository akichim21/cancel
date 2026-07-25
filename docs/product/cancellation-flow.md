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

> **支払済（`paid`）は Stripe webhook（実決済）でのみ到達**し、`paidAt`（支払日）が設定される。管理画面の手動ステータス
> 更新で扱えるのは `pending`（請求中）/ `failed`（失敗）/ `canceled`（キャンセル済）のみで、**手動「支払済」遷移は廃止**
> （GTSS-836 / #30）。手動で支払済にすると `paidAt` 不在のまま精算用CSV・支払日フィルタから漏れるため。

## ステップ詳細

### 1. キャンセル請求の作成

- 手動: 管理画面 `cancel-billing-service-admin/src/components/CancellationManagement.tsx` /
  サロン向け `cancel-billing-service/src/components/InvoiceForm.tsx`。作成と同時に送信。
  - **店舗は登録済み店舗から select**（GTSS-817 #27）。店舗名・住所のフリーテキスト入力は廃止し、自社の
    登録済み店舗（店舗マスタ）を選んで `shopId` を送る。
  - 店舗が **0 件**のときは入力欄を出さず「店舗を作成してください」の文言と**施設（店舗）管理画面へのリンク**を
    表示し、請求は作成できない。
  - サーバは `shopId` を自社店舗として解決し、`cancellations.shopId` に紐づけたうえで、作成時点の
    **店舗名・住所をスナップショット**（`shop_name` / `shop_address`）として保存する。
  - 旧形式（`shopName` フリーテキストのみ）のリクエストは **400 で拒否**（即時撤去・後方互換なし）。
- 取り込み: `cancel-billing-service-api/src/services/salonboard-import.service.ts` が「送信前（`pre_send`）」で作成。
  取り込み時点では顧客通知を送らない。
  - 作成時点の **店舗名・住所スナップショット**（`shop_name` / `shop_address`）も取り込んだ店舗の値で保存する
    （手動作成と揃え、送信本文の店舗名解決を両経路で同一にする・GTSS-817 #27）。
- 保存先: **Aurora PostgreSQL `cancellations` テーブル**（drizzle。旧 DynamoDB は移行元のみ・ランタイム不参照）。

### 2. 送信（決済リンク送信）

- 「送信前」の請求は一覧の「送信」ボタンから送信する（運営=管理画面 / サロン本人=ポータル。サロンは自社配下のみ）。
  サービスは `cancellation-send.service.ts`。`status='pre_send'` の条件付き更新で二重送信を防止する。
- 手動作成は作成時に同経路で送信する（`invoice.service.ts` の createInvoice）。
- Stripe Checkout Session を作成し、顧客にメール (SES) / SMS (Twilio) で決済リンクを送信。
  通知チャネルは顧客連絡先有無で決定（メール優先、無ければ SMS）。送信後ステータスは請求中(`pending`)。
- **送信時の店舗名／住所（SMS／メール本文・Stripe Checkout の品目説明欄）**: 次の順で解決する（GTSS-817 #27）:
  1. `cancellation.shop_name` / `shop_address`（作成時点のスナップショット。**手動・取り込み両経路で保存**）
  2. `shopId` から解決した店舗（スナップショットが空の旧データのフォールバック）
  3. 会社名（`partnerName` / `businessName`。**住所は会社名フォールバックなし**＝住所が無ければ住所は空）
  これにより手動・取り込みの双方で、本文に出るのが会社名ではなく**発生店舗名**になる（取り込み請求も従来の
  会社名表記から発生店舗名へ変わる＝意図的な変更）。
  > この解決順が効くのは **SMS／メール本文と Checkout の品目説明欄**であり、**カード利用明細ではない**
  > （明細は連結アカウント側に `{法人名}キャンセル料`／カナを静的設定済み）。また後述の**領収書 SUMMARY 欄は
  > 店舗名ではなく事業者名**を出す（意図的な出し分け）。

- **領収書 SUMMARY 欄の発行者名（＋適格請求書登録番号）**: 顧客が決済すると Stripe が領収書メールを自動送信する。
  その「SUMMARY」欄（Checkout Session の `payment_intent_data.description`）には、上記の店舗名ではなく
  **事業者名（発行者名）** を出す（GTSS-851 #44）。解決順は次のとおり:
  1. **屋号**（`applications.business_name`）
  2. **法人名／個人事業主名**（`applications.partner_name`）
  3. 固定文字列『サロン』
  > ⚠️ フィールド名と意味が直感と逆（`business_name` = 屋号 / `partner_name` = 法人名）。なお `business_name` は
  > 現行の入力経路が無く旧移行データにしか値が入らないため、**実運用では `partner_name`（法人名）に解決**され、
  > 領収書ヘッダ（連結アカウントの `business_profile.name`）と一致する。
  - サロンが**適格請求書登録番号（T番号）を登録している場合のみ**、発行者名の後ろへ
    `{発行者名}（適格請求書登録番号: {T番号}）` の形で併記する。未登録なら発行者名のみ（括弧も付かない）。
  - T番号を併記する場合に限り、発行者名が 100 文字を超えるなら 100 文字＋`…` に切り詰めてから連結する
    （末尾の登録番号が欠落しないための防御）。未登録時は切り詰めない。
  - **店舗名を SUMMARY に出さない理由**: 適格請求書の発行者名は T番号 の登録事業者を指すべきで、複数店舗を持つ
    サロンで個々の店舗名を出すと登録事業者と一致しなくなるため。
  - 適用範囲は決済リンクを作る**2経路すべて**（ポータルの請求書発行 `invoice.service.ts` / 送信ボタン経由の
    `cancellation-send.service.ts`）。既存の決済リンクには遡及せず、**リリース後に新規作成される分から**有効。
  - ⚠️ Stripe の領収書メールは `receipt_email`（＝顧客メール）がある場合のみ送信される。**連絡先が電話番号のみの
    請求（SMS 通知）では領収書メール自体が届かない**ため、この表示も届かない（現行仕様）。

- **出力先ごとの対応表（混同注意）**:

  | 出力先 | 出る値 | T番号 |
  |---|---|---|
  | 領収書メールの SUMMARY（`payment_intent_data.description`） | **事業者名**（屋号 → 法人名 → 『サロン』） | **併記する**（登録時） |
  | 決済画面の品目説明（`product_data.description`） | 店舗名 / 住所 / 担当者名 / 予約日 | 併記する（登録時。**領収書には出ない欄**） |
  | 顧客宛メール本文・SMS 本文 | 店舗名（snapshot → shop → 会社名） | 出さない |
  | カード利用明細（`statement_descriptor*`） | 連結アカウントに静的設定した `{法人名}キャンセル料` / カナ | 出さない |
  | 領収書メールのヘッダ（発行元） | 連結アカウントの `business_profile.name`（＝ `partner_name`） | 出さない |

  T番号の登録手段（ユーザーポータルのアカウント設定）は `docs/product/application-flow.md`、
  Stripe 側のどのフィールドが領収書に出るかは `docs/tech/stripe-connect.md` を参照。

### 3. 顧客による決済

- Stripe Checkout ページで決済 → リダイレクト先で結果表示（`cancel-billing-service-lp` の PaymentSuccess / PaymentCancel）。

### 4. Webhook 受信

- Stripe Webhook を `cancel-billing-service-api` で受ける（`checkout.session.completed`, `account.updated`）。
- 必須環境変数 `STRIPE_WEBHOOK_SECRET`。受信後にステータスを `paid` へ遷移（二重計上防止のガード付き）。

### 5. payout

- キャンセル料は **direct charge**（`checkout.sessions.create(params, { stripeAccount })` ＋ `application_fee_amount`）
  で連結アカウント（サロン）上に発生する。GTSS の手数料と Stripe 手数料を引いた net が連結アカウント残高に積まれ、
  月次バッチの `payouts.create` でサロンへ入金される（詳細は `docs/tech/stripe-connect.md`）。

## 精算用CSVの出力（代理店コード・支払日列／支払日期間フィルタ）

運営が月次精算の元データとして、キャンセル請求管理画面（admin）から**CSVを出力**できる（GTSS-836 / #30）。
CSVはクライアント側で生成し、画面の絞り込み結果（`filteredInvoices`）をそのまま書き出す。詳細は
`docs/product/agent-code.md`。

- **追加2列（末尾）**: 既存16列の末尾に **代理店コード**（発生元申込の `agentCode`。未設定は空）と
  **支払日**（支払い完了日時 `paidAt` を JST 表示。未払い行は空）を追加する。既存列順・PII列（お客様名/
  電話/メール）・「ステータス」列は不変。**CSVに口座番号は出力しない**（元々データに存在しない）。5%額・料率・
  還元期間などの計算は含めない（生データのみ）。
- **支払日期間フィルタ**: 絞り込みバーに支払日の開始日・終了日の日付ピッカーを追加。指定すると、支払日が
  その範囲（JST 暦日・両端含む）に含まれる請求のみが**一覧表示・CSV出力の対象**になる。範囲外および**未払い
  （支払日なし）請求は除外**。未指定のときは全件（支払日の有無に関わらず）が対象。期間指定は一覧と CSV の
  双方に効く（`filteredInvoices` が CSV 出力元のため）。
- **元データ（API）**: `GET /cancellations`（**管理者専用 = `requireAdmin`**）の各行に発生元申込の
  `agentCode` を付与する（会社スコープ `?applicationId=`・グローバル一覧の双方で同一形状）。支払日 `paidAt` は
  既にレスポンスに含まれる。CSVおよびこの元データは admin 限定であり、代理店へ共有する非PIIデータは運営が
  スプレッドシートへ手転記して生成する（顧客PIIを代理店へ渡さない）。

> 実装: `cancel-billing-service-admin/src/constants/cancellationStatus.ts`（CSVヘッダ/行・`filterCancellations`
> の `paidFrom`/`paidTo`）/ `src/components/CancellationManagement.tsx`（支払日ピッカー）/
> `cancel-billing-service-api/src/repositories/cancellations.repository.ts`（一覧へ `agentCode` 付与）。

## データモデル（Aurora PostgreSQL）

`cancellations`（`cancel-billing-service-api/src/db/schema.ts`）。主なカラム:
- `id` (PK, UUID) / `applicationId` (FK→applications) / `status`（上表 SSOT）
- `customerName` / `customerNameKana` / `customerEmail` / `customerPhone`（顧客 PII。退会時マスク）
- `amount`（キャンセル料）/ `appointmentAmount`（予約金額）/ `paidAmount` / `platformFee` / `stripeFee`
- `appointmentDate` / `startTime` / `menuName` / `staffName`
- 発生店舗: `shopId`(FK→`shops.id`、当サービスの店舗マスタ) / `shopName` / `shopAddress`
  - **表示**（一覧・詳細）は `shopId` から解決した店舗マスタ名・住所（`storeName` / `storeAddress`）を使う。
    店舗は**論理削除のみ**（`deletedAt`）で物理削除しないため `shopId` は保持され、削除後も JOIN で解決できる
    （DB の FK は安全弁として `ON DELETE SET NULL` だが通常フローでは発火しない・GTSS-817 #27）。
  - `shopName` / `shopAddress`（`cancellations` 列）は**送信本文の凍結用スナップショット**で、手動・取り込み
    両経路で作成時点の値を保存する。詳細表示には使わない（`storeName`/`storeAddress` と二重表示しない）。
- 取り込み（GTSS-817）: `source` / `externalReservationId` /
  `reservationStatus` / `cancellationType` / `paymentType` / `cancellationPolicy` / `receivedAt`
- 冪等キー: `(shopId, externalReservationId)` 部分ユニーク（手動作成は `externalReservationId` NULL で対象外）

## 関連コード

| ファイル | 役割 |
|---|---|
| `cancel-billing-service-api/src/handlers/cancellations.handler.ts` | 一覧/取り込み/送信/ログ ルート |
| `cancel-billing-service-api/src/services/cancellation.service.ts` | 一覧・手動取り込み・ログ取得 |
| `cancel-billing-service-api/src/services/cancellation-send.service.ts` | 送信アクション（運営/サロン） |
| `cancel-billing-service-api/src/services/salonboard-import.service.ts` | サロンボード取り込み中核 |
| `cancel-billing-service-api/src/services/invoice.service.ts` | 手動作成（shopId 解決＋店舗名/住所スナップショット）・支払いリダイレクト |
| `cancel-billing-service-admin/src/components/CancellationManagement.tsx` | 管理画面一覧・取り込み・送信・**店舗 select** |
| `cancel-billing-service/src/components/InvoiceForm.tsx` / `InvoiceList.tsx` | サロン向け作成（店舗 select）・一覧・送信 |
| サロンポータル施設（店舗）管理 + `GET/POST/PUT/DELETE /shops` | サロン本人の連携なし店舗 CRUD（店舗 0 件時の導線。`docs/product/salonboard-import.md` 参照） |
| `cancel-billing-service-lp/src/components/PaymentSuccess.jsx` / `PaymentCancel.jsx` | 決済結果画面 |
