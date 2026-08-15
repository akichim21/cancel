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
   - 承認は `PUT /applications/:id/status`（`updateApplicationStatus`、`status=approved`）に一本化している。
     旧・専用ルート `POST /applications/:id/approve`（`approveApplication`）は呼び出し元が無く削除済み。
   - 作成時に **入金スケジュールを `manual` に設定**する（GTSS-854 / #33）。共有定数
     `src/constants/payout.ts` の `PAYOUT_SCHEDULE = { interval:'manual' }` を
     `updateApplicationStatus` の `settings.payouts.schedule` へ付与する。
     `delay_days` は指定しない（JP 既定＝最短 4 営業日を維持）。入金は月次バッチが制御する（後述「入金（payout）」）。
3. サロンにメール送信（リンク有効期限はデフォルト数分）
4. サロンがリンクを開く → Stripe ホストの本人確認・銀行口座登録フローへ
5. 完了後、`https://cancel.co.jp/stripe-success?applicationId=...` にリダイレクト
6. `StripeSuccess.jsx` が API に `applicationId` を渡して `details_submitted` を確認
   - `true` → ステータス `利用中`、ユーザーポータル誘導
   - `false` → 未完了画面（`/stripe-refresh` で Account Link 再発行）

> **非同期に送るメールには Account Link を直接載せない**（GTSS-909 / #67）。Account Link は
> **単回利用かつ短時間で失効**する（数分〜数時間）。承認直後の初回案内メールは「発行 → 即送信」なので
> リンクを本文に載せているが、**バッチ・スケジューラなど発行から閲覧までに時間が空く経路では、
> 送信時に発行した URL はメールが読まれる頃にほぼ確実に失効している**。
> そうした経路では本文に LP の `{LP}/stripe-refresh?applicationId=…` を載せ、
> **サロンがクリックした時点で新しい Account Link を発行する**こと（`POST /applications/:id/stripe-account-link`。
> 未認証で呼べる公開エンドポイント）。Stripe 登録の自動リマインド（3日後・7日後）はこの方式を採っている。
>
> なお現行の初回案内メール本文にある「※このリンクは24時間のみ有効です。」は**事実と食い違っている**
> （実際の失効は数分〜数時間）。訂正は GTSS-909 のスコープ外で、別 Issue 化を推奨する。

> **`active` への遷移条件は `charges_enabled`**。`details_submitted` は「サロンが提出を終えた」ことを
> 示すだけで Stripe の確認完了を意味しない（`pending_verification` が残りうる）。実際にステータスを
> `active` へ進めているのは下記 `account.updated` webhook の `charges_enabled` 判定であり、
> 自動リマインドの完了判定（送信停止）も同じ `charges_enabled` を使って基準を揃えている。

## Webhook

`cancel-billing-service-api/src/lambda.ts` で受信。

| イベント | 用途 |
|---|---|
| `checkout.session.completed` | キャンセル料決済完了 → DB のステータスを `paid` に更新 |
| `account.updated` | オンボーディング状態の変化検知 |
| `payout.paid`（Connect） | 月次入金の着金 → `payout_runs` を `paid` に更新（GTSS-854 / #33） |
| `payout.failed`（Connect） | 月次入金の失敗 → `payout_runs` を `failed` に更新し運営（`PAYOUT_NOTIFY_RECIPIENTS`）へ通知 |

Stripe ダッシュボードで上記イベントを Webhook エンドポイント（例: `https://api.cancel.co.jp/webhook`）に登録しておくこと。
`payout.*` は **Connect イベント**（連結アカウント上の payout。`event.account` 付き）。既存エンドポイントは
`account.updated`（Connect）を受けているため、購読イベントに `payout.paid` / `payout.failed` を追加するだけで受信できる。

## 決済（キャンセル料請求）

1. 管理画面でキャンセル請求登録
2. API が Stripe Checkout Session を作成（**direct charge**。`checkout.sessions.create(params, { stripeAccount })`
   でサロンの連結アカウント上に発生させ、GTSS の取り分は `application_fee_amount` で受け取る）
3. 顧客に **`{API}/pay/{請求ID}` の短縮 URL** をメール/SMS 送信（GTSS-886 でメールも短縮 URL に統一。
   生の Checkout URL は本文に載せない）
4. 顧客が決済 → `checkout.session.completed` Webhook で完了処理

### Checkout Session の失効と /pay ゲート・再発行（GTSS-886）

**Checkout Session は作成から最大 24 時間で失効する**（外部仕様）。従来は生 URL を配っていたため実質
24 時間しか支払えていなかった。現在は次の建付けで**支払期日（`due_date`）まで**の支払い可能性を担保する:

- **セッション生成は共通ビルダー `src/services/checkout-session.service.ts` に集約**。初回 2 経路
  （`createInvoice` / `dispatchPayment`）と /pay の再発行経路の 3 経路が共用し、direct charge の手数料
  （`application_fee_amount`）・領収書 SUMMARY（発行者名＋T番号）・日本語 Customer・`receipt_email` を含む
  全パラメータのドリフトを構造的に防ぐ。**Checkout まわりを触るときは必ずこのビルダーを経由すること**
  （最小パラメータでの再生成は手数料取り漏れ・英語領収書化の静かな退行になる）。
  ※ `statement_descriptor_suffix` のみ経路別（送信ボタン経路='Cancel Fee' / createInvoice=なし）の
  従来挙動を維持（オプション引数）。
- **`expires_at`**: 「作成から 24h」と「支払期日 23:59:59 JST」の早い方にクランプ。外部仕様の最小 30 分
  制約により、期日末尾 30 分以内の発行では最大 30 分の食み出しを許容（その決済は通常どおり支払済にする）。
- **`client_reference_id`**: 請求 ID を全セッションに設定。webhook はセッション ID 突合が外れた場合に
  これでフォールバック突合する（/pay 再発行の同時アクセス競合で保存外セッションで決済されても着金を拾う）。
- **/pay ゲート**: 認証不要 GET。状態（請求中のみ）と期日（JST 当日まで）を検査し、保存済みセッションを
  `sessions.retrieve` で確認 → open ならそのまま 302 / expired なら共通ビルダーで再発行（保存は
  `stripe_session_id` の条件付き更新＝先勝ち）/ 不可状態は案内 HTML。**per-request 予算必須**
  （`timeout: 8000, maxNetworkRetries: 0`。SDK 既定 80s は API Gateway 29s を超える）。
- **取消時の失効**: 請求の取消（canceled 遷移）時に `sessions.expire` をベストエフォートで呼ぶ
  （失敗しても取消は成立させる）。

### Checkout のどのフィールドがどこに出るか（GTSS-851 / #44）

「T番号を品目の説明欄へ入れたのに顧客の領収書に出ない」という不具合の原因が、この対応関係の誤解だった。
**領収書メールに出したいテキストは `payment_intent_data.description` に入れること。**

| フィールド | 出る場所 | 領収書メール |
|---|---|---|
| `payment_intent_data.description` | 領収書の **SUMMARY 欄** | **出る** |
| `line_items[].price_data.product_data.description` | Checkout **決済画面**の品目説明 | 出ない |
| `line_items[].price_data.product_data.name` | 決済画面の品目名・領収書の明細行 | 出る |
| `payment_intent_data.statement_descriptor(_suffix)` | **カード利用明細** | 出ない |
| 連結アカウントの `business_profile.name` | 領収書の**ヘッダ（発行元）** | 出る |
| `payment_intent_data.receipt_email` | 領収書メールの**送信先** | — |
| `customer`（Customer の `preferred_locales`） | 領収書メールの**言語**（下記） | — |

- direct charge のため、領収書の差出人・ブランディング・公開情報は**連結アカウント（サロン）側の設定**に従う
  （プラットフォーム側の設定は反映されない）。適格簡易請求書の発行者がサロンである建て付けと整合する。
- 適格請求書登録番号（T番号）は、この SUMMARY 欄に `{発行者名}（適格請求書登録番号: T…）` の形で併記する。
  仕様は `docs/product/cancellation-flow.md`「2. 送信」を参照。
- 税率ごとの内訳を含む**厳密な適格請求書 PDF** が必要になった場合は、Checkout の `invoice_creation` を
  有効化する対応が別途必要（現状は未対応）。

#### dev では領収書メールが届かない（確認は `receipt_url` で行う）

**dev で領収書メールを受け取って確認することはできない。** 理由は2つ:

1. **テストモードの制約**: Stripe は、顧客のメールアドレスが「Stripe アカウントのサンドボックス権限を持つ
   認証済みメールアドレス」に属している場合**のみ**テスト決済の領収書を自動送信する（[docs](https://docs.stripe.com/receipts)）。
   dev の顧客メールは通常この条件を満たさない。
2. **direct charge**: 領収書のメール設定は**連結アカウント側**に従うため、プラットフォーム側で
   「支払い成功時のメール」を有効化しても効かない。

代わりに **`charge.receipt_url`（ホスト型領収書ページ）** を開いて実表示を確認する。メール送信の可否と
無関係に必ず生成され、`Receipt From` / `Amount Paid` / `Date Paid` / `Payment Method` / **`Summary`** の
セクションを持つ（SUMMARY 欄の実表示・折り返しをそのまま目視できる）。

```bash
cd cancel-billing-service-api
npm run receipt:url:dev -- <cancellationId>                       # DB から session/連結アカウントを解決
npm run receipt:url:dev -- --session cs_xxx --account acct_xxx    # 直接指定
```

- 実装: `scripts/print-receipt-url.ts`。charge は連結アカウント上にあるため `{ stripeAccount }` の指定が必須。
- **`receipt_url` へのリンクは 30 日で失効する**（領収書自体は失効しない）。確認は決済直後に行うこと。
- メール本文の体裁そのものを確認したい場合は、Dashboard の 取引 > 支払い > 領収書の履歴 > ⋯ > 領収書を送信
  から任意アドレスへ手動送信する。

### 領収書メールの言語（GTSS-850 / #42）

領収書メールのテンプレート言語（見出し・項目名）は**顧客に紐づく Customer の言語設定**で決まる。
Stripe の判定順は次のとおりで、Customer を紐づけないと最終フォールバックまで落ちて**英語**になる。

| 順位 | 条件 | 使われる言語 |
|---|---|---|
| 1 | Customer が紐づき `preferred_locales` あり | `preferred_locales` の言語 |
| 2 | Customer は紐づくが locale 情報なし | ダッシュボード「顧客へのメール」の既定言語 |
| 3 | Customer が紐づかない | 決済セッション URL を開いた**ブラウザのロケール** |

そのため決済リンク生成の直前に `preferred_locales: ['ja']` の Customer を作って Checkout Session の
`customer` へ渡す（`src/services/stripe-customer.service.ts` の `createJaCustomer`）。**将来 Checkout
まわりを触る実装者が同じ罠を踏まないよう、以下の制約に注意すること。**

- **Customer は必ず連結アカウント上に作る**: 決済は direct charge のため、`customers.create` の第 2 引数に
  Checkout Session と**同じ `{ stripeAccount }`** を渡す。プラットフォーム側で作った Customer ID を
  連結アカウントの Session へ渡すと `No such customer` で**決済リンク発行自体が失敗する**。
- **`customer` と `customer_email` は排他**: 両方を指定すると Stripe がエラーを返す。`customer` へ
  切り替える際は `customer_email` を必ず落とす。
- **`customer_creation: 'always'` では言語指定できない**: `mode:'payment'` で Customer が作られるのは
  決済完了時であり、`preferred_locales` を事前に指定できない。領収書は決済直後に送られるため後追い更新は
  間に合わない。→ **事前作成が必須**。
- **メール未登録（SMS 通知のみ）でも Customer を作る**: 言語は Customer が決め、送信先は別途
  `receipt_email` / Checkout で収集したメールが決めるため、メールを持たない Customer でも日本語化は効く。
- **Customer は請求ごとに新規作成**（再利用・DB 保存なし）。冪等キーは
  **`customer_<cancellationId>_<sha256(正規化メール) 先頭8桁>`** で、同一請求・同一メールの再試行による
  重複作成を防ぎ、`metadata.cancellation_id` で事後追跡する。**キーに請求 ID だけを使ってはいけない**:
  冪等キーは params に追随しないため、「Checkout 失敗 → `pre_send` へ差し戻し → 顧客メールを修正 → 再送」
  という通常の復旧手順で 24h 以内なら同一キー・異パラメータになり、Stripe が idempotency error を返す
  （＝黙って従来言語の領収書へ劣化し、予測可能な条件で毎回 Sentry へ飛ぶ）。
- **per-request の予算を必ず切る**: Stripe SDK の既定は `timeout` 80,000ms / `maxNetworkRetries` 2 で、
  API Lambda の 30s を大きく超える。`createJaCustomer` は `markSentIfPreSend`（`pre_send`→`pending`）の
  **後・catch の外**で呼ばれるため、ここで Lambda がハードタイムアウトすると `revertToPreSendIfPending` が
  走らず「リンク無し・`status=pending`」で固着し、再送は `alreadySent` で弾かれて**復旧不能**になる。
  領収書の言語は表示上の改善＝任意呼び出しなので、`{ timeout: 5000, maxNetworkRetries: 0 }` で見切る。
- **失敗しても決済リンクは止めない**: `customers.create` が失敗したら Sentry へ記録して従来どおり
  `customer_email` 指定（メール無しなら無指定）で Session を作る。その決済の領収書は従来の言語になる。
  フォールバック率は checkout ログの **`jaCustomerLinked`**（boolean）で CloudWatch から追える。
- **Stripe へ渡すメールは trim 後の値で統一する**: `customer`（Customer の `email`）と
  `payment_intent_data.receipt_email` の両方に正規化後の値を渡す。`receipt_email` だけ生値を渡すと
  空白のみの入力（`'   '`）が Stripe へ素通りし、形式不正で **Checkout Session 作成ごと失敗**して
  「決済リンク無しの請求通知」が顧客へ届く。
- **ログに顧客メールを出さない**: checkout params を丸ごと `JSON.stringify` すると `customer_email` /
  `receipt_email` が CloudWatch へ平文で残る。`hasReceiptEmail` のように boolean へ落とす。
  `customers.create` の例外も同様（引数にメールを取るため `email_invalid` 等でメッセージに載り得る）で、
  `type` / `code` / `statusCode` / `requestId` のみを出す。Sentry は `scrubEventPii` を通るが console は
  素通りする。`checkout.session.completed` の webhook ログも `hasCustomerEmail` のみ。
- **決済画面のメール欄は「編集不可」に変わる（判断済み・許容する）**: `customer` に有効な `email` がある
  Customer を渡すと、Checkout のメール欄は**プリフィルされ編集不可**になる（`customer_email` には
  この記述が無い。`customer_update` に `email` は無く編集可へ戻す手段は存在しない）。ただし領収書の
  **送信先は `payment_intent_data.receipt_email` で固定**されるため、顧客が決済画面でメールを書き換えても
  領収書の宛先は変わらない（変更前も同じ）。＝実害は「書き換えられない」ことだけで、送信先の挙動は不変。
  むしろ「書き換えれば宛先が変わる」という従来の誤解を招く UI が解消される。→ Issue #42 AC-4.2 で許容。
- **`session.customer_email` は今後常に null**: `customer` 指定に切り替えたため。収集済みのメールは
  `session.customer_details?.email` に入る（ログへ平文で出さないこと）。請求の特定は
  `findByStripeSessionId(session.id)` で行うため機能依存は無い。
- 決済ページ（Checkout 画面）の `locale` は領収書メールの言語とは**別物**で、現状は未指定（`auto`）のまま。

## 入金（payout）— manual + 日次バッチ + しきい値ゲート + 期限前強制スイープ（GTSS-854 / #33・#34）

低稼働サロンで固定 Stripe 手数料（アクティブアカウント料 ¥200/店・入金手数料 ¥250/回, 各＋税）が
GTSS の application_fee 収入（≒回収額の 21%）を上回り、プラットフォーム残高がマイナス化する問題を緩和する。
Stripe 既定の自動入金を止め、**入金を `manual` にして月次バッチが「しきい値ゲート付き」で `payouts.create` を実行**する。

- **決済モデル**: キャンセル料は direct charge（`checkout.sessions.create(params, { stripeAccount })` ＋
  `application_fee_amount`）で連結アカウント上に発生。GTSS の application_fee と Stripe 手数料を引いた
  **net（≒回収 gross の 75%）** が連結アカウント残高に積まれ、これが payout 対象になる。
- **しきい値ゲート**: `stripe.balance.retrieve({ stripeAccount })` の **`available`（JPY, net）が
  `PAYOUT_THRESHOLD_JPY = ¥3,000`（回収 gross 約 ¥4,000 相当）以上のときだけ**入金する。未達は保留（`held`）し
  残高に残る＝翌日以降へ**自然に繰り越す**（ただし期限到達分は下記「期限前強制スイープ」で払い出す）。判定・入金額は
  Stripe の `available` のみで決める（DB 集計は使わない。保留中/返金引当で DB とずれるため）。Stripe「最低残高
  （minimum balance）」機能は「超過分だけ入金」する逆挙動のため代替不可。
- **バッチ**: `src/services/payout.service.ts` の `runMonthlyPayouts({ now, dryRun?, applicationId? })`。
  対象は `applications`（`stripeAccountId` あり・`active`・未削除）＋**退会サロン**（`withdrawn`+`deletedAt`、
  期限強制スイープ(b)のみ）。`src/batch.ts` の action `run-monthly-payouts`（当分岐でのみ `initClients()`）から
  呼ぶ。実行基盤は外部 Terraform `cancel-billing-service-infra`（EventBridge Scheduler）が管理し、期限判定を
  取りこぼさないよう **日次 cron**（Asia/Tokyo）で実行する（#34 で月末 cron から変更）。
  `dryRun=true` は判定のみ（`payouts.create`・`payout_runs` 記録・レポート送信をしない）。
- **記録整合性（claim → create → finalize）**: payout 作成は 2 段階。`payoutRunsRepo.claim` が
  `(stripe_account_id, period)` 行を `processing` として原子的に確保し、**確保できた実行だけ**が
  `payouts.create` を呼ぶ。成功後 `finalize` が `processing` を `pending`（＋payout ID）へ確定する。
  これにより Scheduler リトライ×手動実行の同時実行でも二重 payout・後勝ち上書きが起きない。
- **冪等性 / 再実行**: `idempotencyKey = payout_${stripeAccountId}_${period}_${attempt}`（`period`=締め年月 `YYYY-MM`、
  `attempt`=`payout_runs.attempt`）＋ `payout_runs (stripe_account_id, period)` ユニークで二重入金・二重記録を防ぐ。
  同一 period に既に `pending`/`paid` があればスキップ。`failed` 後の同一 period 手動再実行は `claim` で
  `attempt` が +1 されるため **新しい idempotencyKey** になり Stripe に新規リクエストとして受理される
  （固定 key だと 24h は保存済みエラー再生／`idempotency_error` で成功しなかった）。
- **失敗ハンドリング**: アカウント単位 try/catch で 1 件の失敗が他を止めない。`payouts.create` の残高不足は
  `StripeInvalidRequestError` / `code:'balance_insufficient'` / HTTP 400 として捕捉し `failed` 記録・後続継続
  （残高が乗る次回バッチ、または手動再実行で attempt を上げて再試行）。
- **突合**: 手動入金は作成時「未着金」。`payout.paid` / `payout.failed`（Connect Webhook, `event.account` 付き）で
  `payout_runs` を `stripe_payout_id` から更新する。DB 更新が障害で失敗した場合は **500 を返して Stripe に
  再配信させる**（`checkout.session.completed` 前例に統一。200 で握ると `pending` のまま固定化するため）。
  `payout.failed` は `failed` へ**遷移した時のみ**運営（`PAYOUT_NOTIFY_RECIPIENTS`）へ通知する（重複配信で
  既に `failed` なら再送しない）。
- **期限前強制スイープは GTSS 側で行う（GTSS-854 差分 / #34。「Stripe 任せ」は撤回）**: JP の manual 保留は
  最大 90 日だが、**Stripe が 90 日で自動強制出金することは保証されない**（`balance_transactions?payout=` /
  balance report `automatic_payout_id` は auto payout 専用で manual を突合できない）。しきい値未達のまま滞留した
  残高は 90 日規制（顧客から受領した資金を長期に保持しない）に違反し得るため、**バッチが期限前に全額を強制
  スイープする**。判定は `available > 0` かつ **(a) `available >= しきい値` または (b) 最古未払い決済が
  `FORCE_PAYOUT_AGE_DAYS = 75 日` 経過**（`90 − 日次実行間隔 1 − バッファ`）。(a)(b) いずれも満たさなければ保留。
  - **最古未払い決済日（`oldestUnpaidChargeAt`）**: manual payout は「決済→payout」を紐付ける API が無いため、
    **常に available 全額を払い出す不変条件**（部分 payout 禁止）を使い、直近スイープ時刻 `lastPayoutAt`
    （`payout_runs` の直近 `pending`/`paid` 行の `created_at`）より **`available_on` が後の決済だけが未払い**と
    みなす。`balanceTransactions.list`（`created > lastPayoutAt − PAYOUT_LOOKBACK_BUFFER_DAYS(14日)`）を
    auto-paging し、`available_on > lastPayoutAt` の `charge`/`payment` の `min(created)` を最古未払い日とする
    （返金・dispute は決済ではないため `min(created)` に影響しない＝金額のみ）。未払いが無ければ判定不要。
  - **部分 payout 禁止**: 入金額は常に `available` 全額（金額指定の部分 payout はしない）。上記不変条件の前提。
  - **cutover（自動入金→manual 切替時）**: 各連結アカウントで 1 回 full sweep して available を 0 にし、その
    `payout_runs` 行が `lastPayoutAt` の基点となる。これにより切替前の決済は「払い出し済み」とみなされ、
    `available_on > lastPayoutAt` 判定が切替以降で正しく成立する。
  - **実行頻度 / レポート間引き**: 期限を追い越さないよう **日次 cron**（外部 Terraform `cancel-billing-service-infra`
    の EventBridge Scheduler）で実行する。`(stripe_account_id, period='YYYY-MM')` 一意は維持（スイープ後は最古
    未払い資金が数日齢にリセットされ同一暦月に2回目の強制入金は起きないため、日次でも「アカウント×月＝最大1入金」）。
    日次のノイズ抑制のため、レポートは **入金/失敗が 1 件以上発生した実行のみ**送信する（no-op 日は送らない）。
- **退会サロンの残高**: 退会（GTSS-20: `status='withdrawn'` + `deletedAt`）は通常対象条件（`active`・未削除）から
  外れるが、**期限強制スイープ(b)の対象に含める**（`applicationsRepo.findWithdrawnWithStripeAccount` で別途列挙。
  退会マスクは `stripe_account_id` を保持する）。退会サロンには**しきい値ゲート(a)を適用しない**（繰り越す意味が
  ないため、期限到達(b)で確実に払い出す）。これにより退会後の残高が恒久的に取り残されない（退会時に即精算したい
  場合は退会フローへの残高精算＝手動 payout 追加を別 Issue 化する）。
- **着金日はピン留め不可**: JP は Instant Payout 非対応（`available_payout_methods:["standard"]`）。`payouts.create` の
  実行日と着金日（`arrival_date`）は一致せず、土日祝で翌営業日にずれる。
- **実行レポート**: 実行後、対象サロン別の記録（サロン名・連結アカウントID・`available`・判定結果・入金額・payout ID・
  失敗理由）とサマリを **本文＋CSV 添付**で `PAYOUT_NOTIFY_RECIPIENTS` へメール送信（`payout-report.service.ts`）。
  CSV 添付のため SES は `SendRawEmailCommand`（MIME 自前構築・UTF-8 BOM 付与）を使う。レポート送信失敗は握る
  （入金処理本体の成否に影響させない）。
- **サロン自己変更の不可化**: プラットフォーム設定（Connect 入金スケジュール）で「連結アカウントによる管理」を
  無効化しておく（運営作業・コード対象外）。有効なままだとサロンが自動入金へ戻せて本方式が破綻する。
- **テーブル**: `payout_runs`（`id / application_id / stripe_account_id / period / amount / currency /
  stripe_payout_id / status(held\|processing\|pending\|paid\|failed\|skipped) / failure_reason / attempt /
  created_at / updated_at`、`(stripe_account_id, period)` ユニーク。`application_id` FK は金銭監査記録のため
  **ON DELETE RESTRICT**（applications の物理削除で連鎖消滅させない）。migration `0018_gtss854_payout_runs`
  ＋ `0019_gtss854_payout_runs_attempt`）。`processing` は claim 中の一時状態、`attempt` は再実行の試行識別子。

## テスト

dev 環境は **必ずテストキー** (`sk_test_`) を使うこと。
本番カードを誤って使わないよう、Stripe ダッシュボードで Test mode に切り替えてから確認する。

## トラブルシュート

**Stripe リンクが切れている**

- Account Link は**単回利用かつ有効期限が短い**（数分〜数時間）。メール本文の「24時間有効」表記は
  実態と食い違っているため信用しないこと
- `/stripe-refresh?applicationId=…` で再発行（`StripeRefresh.jsx`。ボタン押下時に
  `POST /applications/:id/stripe-account-link` を叩いて新しいリンクを発行し Stripe へ遷移する）
- サロンへ案内する URL は**この再開ページ**を渡す（Account Link の URL をコピーして渡さない。
  渡した時点で失効している可能性が高く、単回利用のため一度誰かが開いたら二度目は使えない）
- Stripe 登録の自動リマインドメール（GTSS-909 / #67・3日後/7日後）も同じ再開ページへ誘導している

**Webhook 署名検証エラー**

- `STRIPE_WEBHOOK_SECRET` が誤っていないか確認
- Stripe ダッシュボードの Webhook 設定で endpoint signing secret をコピーし直す
