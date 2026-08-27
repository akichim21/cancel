# PayPay 対応可否 調査レポート（キャンセル請求便）

- 作成日: 2026-08-08
- 調査対象: `cancel-billing-service-api`（`origin/main` = 本番 / `origin/develop` = 未リリース分を含む）
- 背景: 2026-08-07、Stripe アカウント「キャンセル請求便」（プラットフォームアカウント）で PayPay の利用が承認された。顧客向け決済ページ（Stripe Checkout）でカードに加えて PayPay を選べるようにしたい。
- 依頼事項: 設定変更のみで対応できるのか、コード修正が必要なのかの調査・判断
- レビュー: Codex CLI によるコードベース記述の事実確認レビュー済み（`origin/main` = `74b1e14`、`origin/develop` = `905488b` 時点）。指摘反映済み

---

## 結論（サマリ）

**設定変更のみでは対応できない。かつコード修正だけでも対応できない。現時点の最大のブロッカーは Stripe への「Connect でのPayPay利用」申請である。**

| # | 作業 | 種別 | 状態 |
|---|---|---|---|
| 1 | Stripe サポートへ Connect（ダイレクト支払い）での PayPay 利用を申請 | **申請** | **ブロッカー・未着手** |
| 2 | ダッシュボード 設定 > Connect > 決済手段 > 連結アカウント で PayPay を「デフォルトで有効」 | 設定 | 1 の承認後 |
| 3 | 手数料見積り式（Stripe 手数料 3.6% 固定）の方針決定 | **要ビジネス判断** → 必要ならコード修正 | 要検討 |
| 4 | `statement_descriptor_suffix` が動的決済手段の絞り込みに影響しないか dev で実測 | 実測 → 必要ならコード修正 | 1 の承認後 |
| 5 | 連結アカウント作成時の `capabilities` に PayPay 用ケイパビリティを追加 | コード修正（2箇所） | 2 でカバーされるなら不要 |
| 6 | 既発行の未払い決済リンクへの反映（GTSS-886 のリリース + 一括失効 + 既発行メール分の再案内） | リリース/コード/運用 | 下記 Q3 参照 |
| 7 | Webhook に `payment_status === 'paid'` ガードを追加（PayPay 起因ではないが動的決済手段を触る前に潰したい） | コード修正 | 推奨 |

---

## 1. コード側は決済手段を固定していない（依頼者の認識は正しい）

`cancel-billing-service-api` の `src` 配下に、以下は **1 箇所も存在しない**（`origin/main` / `origin/develop` の両方で確認）:

- `payment_method_types`
- `automatic_payment_methods`
- `payment_method_configuration`
- `excluded_payment_method_types`

Checkout Session の生成箇所:

| ブランチ | 生成箇所 |
|---|---|
| `origin/main`（本番） | `src/services/cancellation-send.service.ts:129`（送信ボタン経路）<br>`src/services/invoice.service.ts:313`（ポータルの請求書発行経路） |
| `origin/develop` | 共通ビルダー `src/services/checkout-session.service.ts:90`（関数定義）／実際の `sessions.create` は同 `:174`。<br>呼び出しは `cancellation-send.service.ts:109`・`invoice.service.ts:268`（初回2経路）・`invoice.service.ts:557`（`/pay` 再発行経路）の3箇所（GTSS-886） |

→ **コードは決済手段を明示固定・除外しておらず、Stripe 側の動的な決済手段（dynamic payment methods）設定をそのまま利用できる形になっている**。この観点だけならコード修正は不要。
※ ただしコードから確定できるのはここまでで、**連結アカウントで実際にどの決済手段が有効かは Stripe 側の設定**（コード外）であることに注意。

## 2. しかし direct charge のため、プラットフォーム側の承認は顧客画面に反映されない

決済は連結アカウント上の**ダイレクト支払い**（`stripe.checkout.sessions.create(params, { stripeAccount })`）。

Stripe 公式ドキュメント（動的な決済手段）:

> ダイレクト支払いまたは `on_behalf_of` を使用する Stripe Connect を利用する場合、**利用可能な決済手段は連結アカウントの設定によって決まります**。

→ 2026-08-07 に承認された**プラットフォームアカウント側の PayPay 有効化は、顧客の決済画面には一切影響しない**。

## 3. 決定的な制約: PayPay は Connect が一般提供されていない

| 出典 | 記載内容 |
|---|---|
| [PayPay 決済ページ](https://docs.stripe.com/payments/paypay)（決済手段プロパティ） | **Connect のサポート: いいえ**（英語版も `Connect support: No`） |
| [決済手段のサポート](https://docs.stripe.com/payments/payment-methods/payment-method-support)（ウォレット製品サポート表） | PayPay の Connect 列は ✓ だが**脚注8「Connect を使用するには、招待をリクエストできます」** |
| [アカウント機能と設定](https://docs.stripe.com/connect/account-capabilities)（決済手段ケイパビリティ一覧） | **PayPay / `paypay_payments` の記載が無い**（Express 等の非フルダッシュボードアカウントに対してリクエストする正規手段がドキュメント上存在しない） |
| [プラットフォームとマーケットプレイスの決済手段のサポート](https://docs.stripe.com/payments/payment-methods/payment-method-connect-support) | **PayPay のセクションが存在しない**（Alipay / WeChat Pay はプライベートプレビュー、PayPal はダイレクト支払い非対応として明記されている中で、PayPay は記載なし） |
| [Stripe サポート記事](https://support.stripe.com/questions/accepting-paypay-payments-for-japan-based-stripe-accounts) | 「**プラットフォーム事業者**（および海外法人・日本非居住の代表者を持つ事業者）は**サポートチームへ直接連絡**が必要」「**Connect プラットフォームは対応するが審査に時間がかかる**」 |

**→ 次にやるべきことは Stripe サポートへの「Connect（ダイレクト支払い）での PayPay 利用」申請。これが通らない限り、ダッシュボード設定でもコード修正でも PayPay は表示できない。**

---

## 確認依頼事項への回答

### Q1. 連結アカウント（Express）側でも PayPay の有効化・追加申請が必要か

**必要。かつ現時点では有効化する手段自体が存在しない。**

Stripe の承認後に必要になる作業:

1. **ダッシュボード作業（コード不要・推奨経路）**
   設定 > Connect > 決済手段 > [連結アカウント] で PayPay を「**デフォルトで有効**」に設定する。
   これにより Stripe が**対象となる既存・新規すべての連結アカウント**のケイパビリティを自動リクエストする。
   > 更新内容を確認して確定すると、Stripe は `対象` のすべての連結アカウントで、選択した決済手段を有効にし、対応するケイパビリティを自動的にリクエストします。（Stripe ドキュメント）

2. **サロン側では有効化できない**
   サロンは Express アカウント（`src/services/application.service.ts:358` および `:947` — 承認2経路とも `type: 'express'`）でフル Stripe ダッシュボードを持たないため、決済手段の有効化はプラットフォーム側の作業になる。

3. **コード修正の要否（保留）**
   `src/services/application.service.ts:362` と `:951` の `capabilities` は現在 `card_payments` / `transfers` のみ。
   上記 1 のデフォルト設定でカバーされるなら追加不要。明示リクエストする実装にするなら 2 箇所の修正が必要。
   **Stripe から付与されるケイパビリティ名（`paypay_payments` 相当）が確定してから判断するのが安全**（現状ドキュメントに存在しないため名前を推測で書かない）。

### Q2. Webhook / プラットフォーム手数料25% / 入金 / 領収書メールはカードと同等に動くか

| 項目 | 判定 | 根拠・備考 |
|---|---|---|
| **Webhook（支払い完了の反映）** | ✅ PayPay のためだけなら変更不要（ただし下記の潜在バグあり） | PayPay は「**決済の成否はリアルタイムで通知されます**」＝同期型（通知遅延型ではない）。`checkout.session.completed` がそのまま発火し、既存の `src/services/webhook.service.ts:70-237` で paid 遷移・月次売上加算・サロン通知メール・顧客SMSが動作する。コンビニ決済等と違い `checkout.session.async_payment_succeeded` の追加購読は不要。**ただし後述の `payment_status` 未検証の問題がある** |
| **入金（payout）** | ✅ 変更不要 | PayPay の入金サイクルは「標準」。direct charge の net が連結アカウント残高に積まれる構造は同じで、manual payout + しきい値ゲート + 期限前強制スイープ（`src/services/payout.service.ts`）はそのまま動作する |
| **領収書メール** | ✅ 変更不要（要実測） | `payment_intent_data.receipt_email` は決済手段によらず charge に対して送信される。direct charge のため差出人・ブランディング・公開情報は連結アカウント設定に従う点も同じ。GTSS-850 の日本語 Customer（`preferred_locales:['ja']`）紐づけも同様に効く。dev では従来どおりメールは届かないため `charge.receipt_url` で確認する（`docs/tech/stripe-connect.md` 参照） |
| **プラットフォーム手数料 25%** | ⚠️ **要対応（本調査の最重要事項）** | 下記 |
| **返金 / チャージバック** | ⚠️ 仕様差あり | PayPay は**不審請求の申し立て（チャージバック）非対応**。返金は全額・一部とも対応、購入後 **365日**以内、**即時完了**。返金の最終ステータスは `refund.updated` / `refund.failed` で通知されるが、これらは**コード管理の必須購読リスト（`scripts/ensure-stripe-webhook.ts:35-40` は4イベントのみ）に含まれず、受信ハンドラも存在しない**。実環境の購読状況は Stripe ダッシュボード側の確認が必要 |

#### ⚠️ Webhook: `payment_status` を検証していない（PayPay 起因ではないが、動的決済手段を触る前に潰すべき）

`checkout.session.completed` の通常経路（セッションID一致）は、`session.payment_status` を確認せずに paid 化している。

- `origin/main`: `src/services/webhook.service.ts:123-141` — `payment_status` を一度も参照しない
- `origin/develop`: `payment_status === 'paid'` を確認するのは `client_reference_id` フォールバック経路のみ（`webhook.service.ts:97-113`）。通常経路は未検証のまま

PayPay は同期型なので**今回の対応で問題は起きない**が、動的な決済手段の設定次第で将来
**通知遅延型（コンビニ決済・銀行振込等）が有効になると、未払いの `checkout.session.completed` を paid 化してしまう**。
PayPay 対応と同時に `payment_status === 'paid'` のガードを入れておくのが望ましい。
（`origin/develop` の通常経路は、加えてイベントの連結アカウント・金額・通貨も検証していない）

#### ⚠️ 手数料 25% の取り漏れリスク

**該当コード**

| ブランチ | 箇所 |
|---|---|
| `origin/main` | `src/services/cancellation-send.service.ts:57-61`、`src/services/invoice.service.ts:189-193`（同一式が重複） |
| `origin/develop` | `src/services/checkout-session.service.ts:30-37` `computeCancellationFees()` に集約 |

```ts
const totalTargetFee = Math.floor(amount * 0.25);
const estimatedStripeFee = Math.round(amount * 0.036);   // ← カード 3.6% 固定
const estimatedStripeTax = Math.round(estimatedStripeFee * 0.1);
const stripeFee = estimatedStripeFee + estimatedStripeTax;
const platformFee = Math.max(0, totalTargetFee - stripeFee);
```

- `application_fee_amount = 25% − 3.96%`（カード前提）を**Checkout Session 作成時に確定**している
- **PayPay の Stripe 手数料は 3.98%**（[現地の支払い方法の料金体系](https://stripe.com/jp/pricing/local-payment-methods)。カードは 3.6%）。同様に消費税を乗せると約 **4.38%** となり、見積り 3.96% との差は **約 0.42pt**
- 結果: **プラットフォーム取り分（≒21.04%）は変わらないが、サロンの手取りが 75% を割る**。「Stripe手数料 + プラットフォーム手数料 = 回収額 × 25%」という設計上の不変条件が PayPay 決済時に崩れる
- さらに、**決済手段は顧客が支払い画面で選ぶため、セッション作成時点では確定できない**（`application_fee_amount` は事前に固定するしかない）

**対応方針の選択肢（ビジネス判断が必要）**

| 案 | 内容 | 影響 |
|---|---|---|
| (a) 現行式のまま許容 | 何もしない | PayPay 決済時のみサロン net が約 0.4pt 目減り |
| (b) 見積りを保守側（PayPay 相当）に寄せる | `0.036` → PayPay 相当へ引き上げ | カード決済時にプラットフォーム取り分が約 0.4pt 増える |
| (c) 事後補正 | 決済後に balance transaction で実額突合し差額を調整 | `application_fee_amount` は PaymentIntent 確定後に変更不可のため、別途 transfer / 請求が必要＝実装コスト大 |

判断の分かれ目は「サロン契約上の 25% が『顧客からの徴収額』の定義なのか『サロン手取り 75%』の保証なのか」。**ビジネスサイドへの確認が必要。**

#### ⚠️ `statement_descriptor_suffix` の影響（要実測）

送信ボタン経路のみ `payment_intent_data.statement_descriptor_suffix: 'Cancel Fee'` を付けている。

- `origin/main`: `cancellation-send.service.ts:149`
- `origin/develop`: 条件付き付与が `checkout-session.service.ts:152-153`、値 `'Cancel Fee'` の指定は初回送信が `cancellation-send.service.ts:125`、`/pay` 再発行用の出し分けヘルパーが `checkout-session.service.ts:184-185`（`statementSuffixFor()`）

これはカード利用明細用のパラメータで PayPay には無関係だが、動的な決済手段には
**「非対応の API パラメータを指定すると、その決済手段が自動的に除外される」**という既知挙動がある
（Stripe ドキュメントでは `setup_future_usage` / `capture_method: manual` が明記されている）。
`statement_descriptor_suffix` が同様の除外条件に該当するかはドキュメントに記載がないため、
**Connect 承認後にサンドボックスで「送信ボタン経路の決済画面に PayPay が出るか」を実測して確認する。**
除外されるようなら経路別 suffix を落とす小修正が必要（`createInvoice` 経路は元々 suffix なしのため影響を受けない）。

### Q3. 既に発行済み（未払い）の決済リンクに PayPay は表示されるようになるか

**表示されない。新規発行分からになる。** ただし本番（`main`）と `develop` で挙動が異なる。

#### 本番（`origin/main` = 現行リリース）

- 顧客への案内は、**メール = 生の Stripe Checkout URL**（`notification.service.ts` `generateEmailContent`）、**SMS = `{API}/pay/{請求ID}` 短縮 URL**
- `/pay/{id}` は保存済みの生 URL へ **302 リダイレクトするだけ**（`invoice.service.ts:463-465`）。セッションの状態確認も再発行も行わない
- → **既発行の未払いリンクには PayPay は永久に表示されない**。そのセッションは作成時点の決済手段構成のまま
- 補足: Checkout Session は作成から最大 24 時間で失効するため、そもそも 24h を超えた未払いリンクは支払い自体ができない（GTSS-886 で解消予定の既知課題）

#### `origin/develop`（GTSS-886。**未リリース**）

- メール・SMS とも `resolvePayUrl()` により **`/pay/{請求ID}` 短縮 URL** に統一される（`notification.service.ts:171-175, 203, 215-220, 360-364`）
- `/pay/{id}` が保存済みセッションを `sessions.retrieve` し、状態で分岐する（`invoice.service.ts:527-575`）
  - `open` → **そのまま 302。古いセッションなので PayPay は出ない**（`:533-536`）
  - `complete` → 支払不可の案内（`:537-540`）
  - **上記以外（通常は `expired`）** → 共通ビルダーで**再発行** → **新セッションなので PayPay が出る**（`:542-575`）
    ※ コード上 `session.status === 'expired'` の明示判定はしておらず、`open`/`complete` 以外を再発行へ流す実装
- 旧データ（`stripe_session_id` 未保存で URL のみ）は従来どおり 302 のみで再発行されない（`invoice.service.ts:514-516`）
- 補足: `expires_at` は「作成から24h」と「支払期日 23:59:59 JST」の早い方だが、Stripe の最小30分制約＋安全マージンにより**期日末尾では最大約32分の食み出しを許容**する（`checkout-session.service.ts:39-60`）。ただし `/pay` 自体が期日超過を遮断する（`invoice.service.ts:507-510`）

#### 「発行済み分にも即座に出したい」場合（⚠️ リンクの配布経路で挙動が分かれる）

| 既発行リンクの種類 | GTSS-886 リリース後の挙動 |
|---|---|
| **リリース前に送信済みの SMS**（`/pay/{id}`） | ✅ 失効後のアクセスで再発行される → PayPay が出る |
| **リリース前に送信済みのメール**（生 Stripe URL） | ❌ `/pay` を経由しないため**再発行処理を通らない**。24h で失効して支払い不能のまま |
| リリース後に新規送信するメール・SMS | ✅ どちらも `/pay/{id}` になるため再発行される |

したがって、未払い請求の Checkout Session を一括で `sessions.expire` しても、
**旧メールリンクは単に失効するだけで PayPay 対応版に置き換わらない**。
既発行メール分にも反映したいなら、**`/pay/{id}` での再案内（リマインド再送）が別途必要**。
いずれも **GTSS-886 のリリースが前提**で、一括失効スクリプトはコード追加が必要。

---

## 付随して見つかった論点（PayPay 導入時に併せて検討すべき既存の課題）

いずれも今回の PayPay 対応の必須要件ではないが、**PayPay を入れると顕在化する**ため記録しておく。

1. **決済手段・実手数料を保存していない**
   `cancellations` テーブルには Session ID / PaymentIntent ID / **事前見積りの `stripe_fee`** しか無い（`src/db/schema.ts:363-386`）。
   カード決済だったか PayPay 決済だったかも、実際に引かれた Stripe 手数料も記録されない。
   → **PayPay の利用率も、手数料差による実損も観測できない。** 上記 (c) 案（事後補正）を採るなら
   PaymentIntent / Charge / Balance Transaction の取得・保存が前提になる。
2. **`stripe_fee` が見積り値のまま API レスポンスに載る**
   3.6% 固定の推定値であり実額ではない。PayPay 導入後は名称と実態の乖離が大きくなる。
3. **返金時の状態・集計の巻き戻し処理が無い**
   返金しても DB の `status = paid` / `paid_amount` / 月次売上（`monthly_sales`）は戻らない。
   PayPay はチャージバック非対応で**返金が唯一の救済手段**になるため、返金運用の比重が上がる。
   `refund.*` の購読だけでなく、返金後の状態・集計・通知方針の設計が必要。
4. **Webhook の検証が弱い**（上記 Q2 の `payment_status` 未検証と同根）
   `origin/develop` の通常経路は連結アカウント・金額・通貨も検証していない。

---

## 補足: Stripe 側の制約（依頼文の記載の裏取り結果）

| 依頼文の記載 | 裏取り結果 |
|---|---|
| 対応通貨は JPY のみ | ✅ 正しい（`jpy` のみ）。本サービスは全請求 JPY のため問題なし。ただし **Checkout の全 line_items が同一通貨である必要**がある（現状 1 明細のみなので問題なし） |
| 支払いモードのみ対応（サブスク不可） | ✅ 正しい。**セットアップモードも非対応**。本サービスは `mode: 'payment'` のみのため問題なし |
| チャージバック非対応、返金はサポートあり | ✅ 正しい。返金は 365 日以内・即時完了 |
| （追加）金額制限 | **最小 50 JPY / 最大 1,000,000 JPY**。キャンセル料が 100 万円を超えると PayPay は表示されない（実運用ではまず起きないが仕様として記録） |
| （追加）手動キャプチャ非対応 | 本サービスは自動キャプチャのみのため問題なし |

---

## 参考リンク

- [PayPay 決済 | Stripe ドキュメント](https://docs.stripe.com/payments/paypay)
- [PayPay で決済を受け付ける（Checkout） | Stripe ドキュメント](https://docs.stripe.com/payments/paypay/accept-a-payment?payment-ui=checkout)
- [決済手段のサポート | Stripe ドキュメント](https://docs.stripe.com/payments/payment-methods/payment-method-support)
- [連結アカウントの支払い方法を有効にする | Stripe ドキュメント](https://docs.stripe.com/connect/payment-methods)
- [アカウント機能と設定 | Stripe ドキュメント](https://docs.stripe.com/connect/account-capabilities)
- [動的な支払い方法 | Stripe ドキュメント](https://docs.stripe.com/payments/payment-methods/dynamic-payment-methods)
- [動的な決済手段を使用するために更新する（Connect） | Stripe ドキュメント](https://docs.stripe.com/connect/dynamic-payment-methods)
- [Accepting PayPay payments for Japan-based Stripe accounts | Stripe Support](https://support.stripe.com/questions/accepting-paypay-payments-for-japan-based-stripe-accounts)
- [現地の支払い方法の料金体系 | Stripe](https://stripe.com/jp/pricing/local-payment-methods)
- 社内: `docs/tech/stripe-connect.md`
