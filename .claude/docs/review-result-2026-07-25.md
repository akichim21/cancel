---
issue: 44
date: 2026-07-25
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: main
    toBranch: GTSS-851
---

# レビュー結果: #44

## 概要

**Issue:** #44 feat: Stripe 領収書に発行者名＋適格請求書登録番号（T番号）を表示（決済リンク生成2経路 / SUMMARY欄）
**PR:** GO-TODAY-SHAiRE-SALON/cancel-billing-service-api#36

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `main` | `GTSS-851` | 1 | 6 |

**検証結果（メインエージェント実施）**

- `npx vitest run`（worktree `.worktrees/GTSS-851`）→ **84 files / 1021 tests 全 green**
- `tsc --noEmit -p tsconfig.json` → エラーなし
- `stripe.checkout.sessions.create` の呼び出しは `invoice.service.ts:268` / `cancellation-send.service.ts:104` の **2箇所のみ**。決済リンク生成経路の取りこぼしなし
- `dispatchPayment` の呼び出し元は `performSend` 経由の `sendCancellationAsAdmin` / `sendCancellationAsSalon` のみ。`applicationsRepo.getById` は列を絞らない `.select()` のため `tRegistrationNumber` は追加クエリなしで載る（PR 本文の主張どおり）
- `invoice.service.ts` の `user` も `applicationsRepo.getById` の戻り値で `cancellation-send.service.ts` の `application` と同一形状 → `resolveReceiptIssuerName` の共用は妥当
- Issue の「Docs Updates」は親リポジトリのコミット `249daf8` で全項目（cancellation-flow / stripe-connect / application-flow / README / CLAUDE.md）対応済み
- 認可面の変更なし（ルート追加・serializer・状態遷移ロック・入力 allow-list いずれも不変。`payment_intent_data.description` は API レスポンスに出ない）

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/services/notification.service.ts` | +41 | -0 | Modified |
| `src/services/cancellation-send.service.ts` | +17 | -3 | Modified |
| `src/services/invoice.service.ts` | +14 | -5 | Modified |
| `src/__tests__/e2e/receipt-issuer.test.js` | +281 | -0 | Added |
| `src/__tests__/unit/notification-service.test.js` | +117 | -0 | Modified |
| `src/__tests__/e2e/cancellations-invoices.test.js` | +17 | -2 | Modified |

## 指摘一覧

### [Security] T番号が無検証のまま顧客の領収書へ到達しうる（公開エンドポイント経由の書き込み経路が非対称）

- [x] 対応する

**ファイル:** `api/src/services/notification.service.ts:247-248`
（関連: `api/src/schemas/application.schema.ts:60`、`api/src/handlers/applications.handler.ts:33`、対比 `api/src/services/auth.service.ts:229`）
**重要度:** Medium

**該当コード:**

```typescript
// main側（変更前）— invoice.service.ts:234。T番号は「品目説明欄」にしか出ていなかった
      const tRegistrationNumber = user.tRegistrationNumber || null;
      const productDescription = tRegistrationNumber
        ? `${stripeDescription}\n適格請求書登録番号: ${tRegistrationNumber}`
        : stripeDescription;

      const stripeCheckoutParams = {
```

```typescript
// GTSS-851側（変更後）— notification.service.ts:242-248
// 適格請求書登録番号（T番号）の正規化（GTSS-851 / #44 / REQ-1）。
// 前後の空白をトリムし、空文字・空白のみは「未登録」として `null` に倒す。
// 領収書 SUMMARY 欄と品目説明欄の双方でこの値を使い、「SUMMARY では未登録扱いなのに品目説明欄には
// 空の『適格請求書登録番号: 』が出る」といった経路間のズレを防ぐ。
export const normalizeTRegistrationNumber = (tRegistrationNumber) =>
  String(tRegistrationNumber ?? '').trim() || null;   // ← trim のみ。形式・長さは検証しない
```

**問題:**
書き込み経路が2つあり、検証が非対称。

| 書き込み経路 | 認可 | T番号の検証 |
|---|---|---|
| `PUT /profile`（ポータルのアカウント設定 / `auth.service.ts:229`） | `requireAuth` | `^T\d{13}$` を強制 |
| `POST /applications`（LP 申込 / `applications.handler.ts:33`） | **無認可（公開）** | **なし** |

`tRegistrationNumber` は `APPLICATION_INPUT_FIELDS`（`application.schema.ts:60`）の allow-list に含まれ、`pickApplicationInput`（同 :79）でそのまま保存される一方、`validateApplicationData` に当該項目のルールが無い（`VALIDATION_MESSAGES` に該当メッセージなし）。同じ allow-list の `agentCode` は `normalizeAgentCode`（trim・64文字上限）で正規化しているのと対照的。

現行 LP フォームはこの項目を送らない（`cancel-billing-service-lp/src` を grep して 0 件）ため今すぐの実害はないが、**本 PR でこの値の到達先が「決済画面の品目説明欄（片方の経路のみ）」から「顧客が受け取る領収書メールの SUMMARY 欄（両経路）」へ広がった**。

また REQ-5 の切り詰めは発行者名側だけで T番号側は無制限のため、防御が片側しか成立していない。長大値では `checkout.sessions.create` が Stripe の description 上限で失敗しうる（**上限値そのものは Issue でも未確認・こちらでも未検証**）。その場合の挙動は2経路で非対称:

- 送信経路: `dispatchPayment` が throw（`cancellation-send.service.ts:143` 「決済リンクの発行に失敗しました」）→ `performSend` が `pre_send` へ巻き戻して 502（`:247-258`）。**送信自体が失敗するので復旧可能**
- 請求書発行経路: catch 後も処理継続（`invoice.service.ts:291-294`）→ **決済リンク無しの通知が顧客へ送られる**

**修正提案:**
正規化と妥当性判定を1関門へ寄せる。形式外は「未登録」扱い＝現行と同一出力になるため後方互換も保たれる。

```typescript
export const normalizeTRegistrationNumber = (tRegistrationNumber) => {
  const v = String(tRegistrationNumber ?? '').trim();
  return /^T\d{13}$/.test(v) ? v : null;
};
```

⚠️ 旧 DynamoDB 移行データに形式外の値が入っている場合、その申込は T番号が領収書に出なくなる（現行は出る）。導入前に `SELECT t_registration_number FROM applications WHERE t_registration_number IS NOT NULL AND t_registration_number !~ '^T[0-9]{13}$'` で実データを確認すること。書き込み側（`POST /applications` に `PUT /profile` と同じ検証を掛ける）は別 Issue で対応でも可。

---

### [Code Quality] 品目説明欄の T番号連結が2経路にベタ書きで重複（REQ-4 が構造として担保されていない）

- [x] 対応する

**ファイル:** `api/src/services/invoice.service.ts:242-245` / `api/src/services/cancellation-send.service.ts:99-103`
**重要度:** Medium

**該当コード:**

```typescript
// main側（変更前）— cancellation-send.service.ts:92-100。送信経路には連結が存在しなかった
  let paymentLink: string;
  try {
    const businessName = application?.businessName || application?.partnerName || 'サロン';
    const stripeDescription = generateStripeDescription(cancellation.id, invoiceData, businessName);
    const session = await stripe.checkout.sessions.create(
      {
        line_items: [
          {
            price_data: {
              currency: 'jpy',
              product_data: { name: 'キャンセル料', description: stripeDescription },
```

```typescript
// GTSS-851側（変更後）— cancellation-send.service.ts:99-103
    const tRegistrationNumber = normalizeTRegistrationNumber(application?.tRegistrationNumber);
    // 決済画面の品目説明欄。createInvoice（ポータルの請求書発行）と同一形式へ揃える（GTSS-851 / #44 / REQ-4）。
    const productDescription = tRegistrationNumber
      ? `${stripeDescription}\n適格請求書登録番号: ${tRegistrationNumber}`
      : stripeDescription;

// GTSS-851側（変更後）— invoice.service.ts:242-245（上と完全に同一の式）
      const tRegistrationNumber = normalizeTRegistrationNumber(user.tRegistrationNumber);
      const productDescription = tRegistrationNumber
        ? `${stripeDescription}\n適格請求書登録番号: ${tRegistrationNumber}`
        : stripeDescription;
```

**問題:**
SUMMARY 欄は `buildReceiptIssuerLabel` へ集約したのに、品目説明欄の連結式は両ファイルにコピーされたまま。**本 Issue の発生原因そのもの（2経路のドリフト＝片方だけ T番号が入っていた）が同じ形で再発しうる**。REQ-4 の「両経路で同一形式」は現状コメント（「createInvoice と同一形式へ揃える」）でしか担保されておらず、片方のラベル文言・改行を変えると静かに desync する。

**修正提案:**
`notification.service.ts` に連結関数を1本追加し、両経路から呼ぶ。

```typescript
export const appendTRegistrationNumber = (stripeDescription, tRegistrationNumber) => {
  const registrationNumber = normalizeTRegistrationNumber(tRegistrationNumber);
  return registrationNumber
    ? `${stripeDescription}\n適格請求書登録番号: ${registrationNumber}`
    : stripeDescription;
};
```

unit テストを1ケース足せば形式ドリフトを検知できる。

---

### [Test Coverage] SUMMARY のアサーションが「店舗名ではなく事業者名」を証明できていない

- [x] 対応する

**ファイル:** `api/src/__tests__/e2e/cancellations-invoices.test.js:396` / `:400`（アサーションは `:412`）
**重要度:** Medium

**該当コード:**

```javascript
// main側（変更前）— 品目説明欄しか見ていなかった（本 Issue の不具合を検知できない構造）
  it('T番号登録済み → product 説明に適格請求書登録番号を付与', async () => {
    const { applicationUser } = await seedApplicationUser({
      applicationId: 'app_user_1',
      application: { stripeAccountId: 'acct_u', businessName: 'サロンA', tRegistrationNumber: 'T1234567890123' },
    });
    stripe.checkout.sessions.create.mockResolvedValue({ id: 'cs_1', url: 'https://pay.stripe/cs_1' });
    const shop = await seedShop({ applicationId: 'app_user_1', shopName: 'サロンA' });
    ...
    expect(params.line_items[0].price_data.product_data.description).toContain('適格請求書登録番号: T1234567890123');
  });
```

```javascript
// GTSS-851側（変更後）— SUMMARY 欄のアサーションを追加（:412）
    application: { stripeAccountId: 'acct_u', businessName: 'サロンA', tRegistrationNumber: 'T1234567890123' },
    ...
    const shop = await seedShop({ applicationId: 'app_user_1', shopName: 'サロンA' });  // ← 事業者名と同名
    ...
    // T-1（#44 / AC-1.1）: 領収書メールの SUMMARY 欄（= payment_intent_data.description）へ
    // 発行者名と T番号 が並んで出る。ここが本 Issue の本体（品目説明欄は領収書に出ない）。
    expect(params.payment_intent_data.description).toBe('サロンA（適格請求書登録番号: T1234567890123）');
    expect(params.line_items[0].price_data.unit_amount).toBe(10000);
    expect(params.payment_intent_data.application_fee_amount).toBe(2104);
```

**問題:**
`application.businessName` と `seedShop({ shopName })` がどちらも `'サロンA'` のため、**実装が誤って店舗名を SUMMARY に使っていてもこのテストは通る**。REQ-1 の核心（「SUMMARY は店舗名ではなく事業者名。複数店舗サロンで登録事業者とズレるため店舗名は出さない」）を担保できていない。`POST /invoices` の正常系（`:313` のケース、seed も `'サロンA'` 同名）も同様。

新規の送信経路テストは `receipt-issuer.test.js:151` で `expect(summary).not.toContain('町田店')` と正しく分離できているので、同じ水準に揃えたい。

**修正提案:**
当該2ケースの `seedShop` の `shopName` を事業者名と別名（例 `'町田店'`）へ変え、`expect(params.payment_intent_data.description).not.toContain('町田店')` を追加する。

---

### [Test Coverage] T-14 のテスト名・コメントが、アサーションの証明範囲を超えて断定している

- [x] 対応する

**ファイル:** `api/src/__tests__/e2e/receipt-issuer.test.js:249-252` / `:273-275`
**重要度:** Medium

**該当コード:**

```javascript
// GTSS-851側（新規追加）— テスト名とコメントは「領収書は届かない」と断定している
describe('receipt_email の設定条件（UC-1 のスコープ制約 / T-14）', () => {
  // 顧客の連絡先が電話番号のみの請求では receipt_email が未設定 → Stripe は領収書メールを送らない。
  // 本 Issue の T番号 表示はこのケースには届かない（現行どおり・意図的）。将来の改修時に気付けるよう固定する。
  it('T-14 顧客メール無し（SMS のみ）→ receipt_email が undefined（T番号設定済みでも領収書は届かない）', async () => {
    ...
    const { receiptEmail, summary, params } = capturedCheckoutParams();
    expect(receiptEmail).toBeUndefined();        // ← 実際に固定しているのはここまで
    expect(params.customer_email).toBeUndefined();
    // SUMMARY 欄自体は T番号 付きで組み立てられている（届かないのは Stripe 側の送信条件による）。
    expect(summary).toBe(`株式会社サンプル（適格請求書登録番号: ${T_NUMBER}）`);
```

（`main` 側には該当ファイルなし＝新規追加）

**問題:**
アサーションが証明しているのは「**API 側が Stripe へメールアドレスを渡していない**」ことだけ。「Stripe が領収書メールを送らない」はモックのパラメータ検証では原理的に証明できず、テスト名・コメントが結論を先取りしている。

さらに前提自体が要確認: Stripe Checkout は `customer_email` 未指定時に決済画面で顧客にメールアドレスを入力させるため、連結アカウント側で自動領収書が有効なら領収書が送られる可能性がある（**Stripe の外部挙動のためリポジトリ内から裏取り不能＝未検証**）。もしそうなら Issue の UC-1 スコープ制約と AC-7.2 の前提（「SMS のみの顧客には領収書自体が届かない」）が誤りということになる。未実施の人力テスト H-1〜H-3 で確定させるべき論点。

**修正提案:**
テスト名・コメントを、実際に固定している事実へ書き換える。

- 案: `T-14 顧客メール無し（SMS のみ）→ checkout params に customer_email / receipt_email を渡さない`
- コメントの「Stripe は領収書メールを送らない」は「API 側からは receipt_email を指定しない（Stripe 側の送信可否は H-1〜H-3 で確認）」へ

「SMS のみの顧客には領収書が届かない」は H-1〜H-3 の結果が出るまで確定事実として扱わない。

---

### [Test Coverage] `POST /invoices` 経路の「空白のみ T番号」の挙動変更が未固定

- [x] 対応する

**ファイル:** `api/src/services/invoice.service.ts:242`（対応テストが `api/src/__tests__/e2e/cancellations-invoices.test.js` に不在）
**重要度:** Low

**該当コード:**

```typescript
// main側（変更前）— invoice.service.ts:234
      const tRegistrationNumber = user.tRegistrationNumber || null;
      const productDescription = tRegistrationNumber
        ? `${stripeDescription}\n適格請求書登録番号: ${tRegistrationNumber}`
        : stripeDescription;
```

```typescript
// GTSS-851側（変更後）— invoice.service.ts:241-245
      // トリム後に空なら未登録扱い（SUMMARY 欄と品目説明欄で判定を揃える。GTSS-851 / #44 / REQ-1）。
      const tRegistrationNumber = normalizeTRegistrationNumber(user.tRegistrationNumber);
      const productDescription = tRegistrationNumber
        ? `${stripeDescription}\n適格請求書登録番号: ${tRegistrationNumber}`
        : stripeDescription;
```

**問題:**
この差し替えで **T番号が空白のみのとき品目説明欄の出力が変わる**（従来は空ラベル `適格請求書登録番号: ` が出ていた → 今後は出ない）。改善方向の変更で妥当だが、`POST /invoices` 経路にはこれを固定するテストが無い。送信経路には `receipt-issuer.test.js:242-261` に対応ケースがあり、片側だけカバレッジが欠けている状態。

**修正提案:**
`cancellations-invoices.test.js` に `tRegistrationNumber: '   '` のケースを1本追加し、SUMMARY・品目説明欄の双方に「適格請求書登録番号」が出ないことを固定する。

---

### [Test Coverage] 送信経路に金額系の回帰アサーションが無い（構造変更したのは送信経路側）

- [x] 対応する

**ファイル:** `api/src/services/cancellation-send.service.ts:104-127`（テストは `api/src/__tests__/e2e/receipt-issuer.test.js` に追加余地）
**重要度:** Low

**該当コード:**

```javascript
// GTSS-851側（変更後）— cancellations-invoices.test.js:414-415。金額回帰は POST /invoices 側にのみ追加された
    expect(params.payment_intent_data.description).toBe('サロンA（適格請求書登録番号: T1234567890123）');
    // T-12（AC-5.1）: 金額系は不変。
    expect(params.line_items[0].price_data.unit_amount).toBe(10000);
    expect(params.payment_intent_data.application_fee_amount).toBe(2104);
```

```javascript
// 送信経路側の既存カバレッジ — salonboard-send.test.js:98-101。unit_amount のみで手数料は未検証
    expect(stripe.checkout.sessions.create).toHaveBeenCalledTimes(1);
    const [stripeParams] = stripe.checkout.sessions.create.mock.calls[0];
    expect(stripeParams.line_items[0].price_data.unit_amount).toBe(7000);
    expect(stripeParams.line_items[0].price_data.currency).toBe('jpy');
```

**問題:**
AC-5.1（金額系の非退行）を担保する T-12 は `POST /invoices` 側にのみ追加されたが、**本 PR が Stripe パラメータオブジェクトを構造変更したのは `dispatchPayment`（送信経路）の方**。テスト全体を grep しても `application_fee_amount` を検証しているのは `cancellations-invoices.test.js:355` / `:415` のみで、送信2ルートでは0件。送信経路の金額担保は `salonboard-send.test.js:100` の `unit_amount` だけ。

**修正提案:**
`receipt-issuer.test.js` の T-3 に `application_fee_amount` と永続化 `stripeFee` / `platformFee` のアサーションを追加する（手数料式は `invoice.service.ts` と同一なので期待値は既知）。

---

### [Code Quality] `resolveReceiptIssuerName` の二重呼び出し

- [x] 対応する

**ファイル:** `api/src/services/cancellation-send.service.ts:79` / `:95`
**重要度:** Low

**該当コード:**

```typescript
// main側（変更前）— 同一式が2箇所に書かれていた（:76 と :92）
  const invoiceData = {
    shopName: resolvedShopName,
    shopAddress: resolvedShopAddress,
    businessName: application?.businessName || application?.partnerName || 'サロン',
    customerName: cancellation.customerName || '',
  ...
  try {
    const businessName = application?.businessName || application?.partnerName || 'サロン';
```

```typescript
// GTSS-851側（変更後）— 関数化されたが呼び出しは2回のまま
  const invoiceData = {
    shopName: resolvedShopName,
    shopAddress: resolvedShopAddress,
    businessName: resolveReceiptIssuerName(application),   // :79
    customerName: cancellation.customerName || '',
  ...
  try {
    const businessName = resolveReceiptIssuerName(application);   // :95
```

**問題:**
同一 `application` に対して同じ純粋関数を2回呼び、同じ値を得ている。実害は無いが、`invoiceData.businessName`（メール/SMS 本文用）と Stripe 用 `businessName` が別々の呼び出しになっているため、将来どちらか片方だけ差し替える事故を招きやすい。

**修正提案:**
`try` の外で1回だけ計算し、両方で使い回す。

```typescript
const issuerName = resolveReceiptIssuerName(application);
const invoiceData = { ..., businessName: issuerName, ... };
// try 内は const businessName = issuerName; を使うか、直接 issuerName を渡す
```

---

### [Code Quality] `resolveReceiptIssuerName` の戻り値は領収書専用ではなく SMS 本文・品目説明のフォールバックにも流れる

- [x] 対応する

**ファイル:** `api/src/services/cancellation-send.service.ts:79`
**重要度:** Low

**該当コード:**

```typescript
// GTSS-851側（変更後）— :79 の戻り値は invoiceData.businessName に入る
  const invoiceData = {
    shopName: resolvedShopName,
    shopAddress: resolvedShopAddress,
    businessName: resolveReceiptIssuerName(application),
    customerName: cancellation.customerName || '',
    customerEmail,
```

```typescript
// 到達先 — notification.service.ts:228（品目説明のフォールバック）と :280（SMS 本文のフォールバック）
  const shopName = invoiceData.shopName || businessName || '';          // generateStripeDescription
  ...
  // 店舗名（shopName優先、なければbusinessName）
  const salonName = invoiceData.shopName || invoiceData.businessName || 'サロン';  // generateSmsContent
```

**問題:**
（前項の「二重呼び出し」とは別論点で、**到達先**の話）関数名が `ReceiptIssuerName` なので「領収書専用」と読めるが、`:79` の戻り値はメール/SMS 本文と品目説明欄のフォールバックにも流れている。Issue の「未解決の質問 4」が発行者名の解決順の見直しを将来課題として挙げているため、**領収書のつもりで解決順を変えると SMS 本文まで変わる**。

実害の窓は狭い（`resolvedShopName` が空になるのは `partnerName`・`businessName` 双方が空のときだけで、そのとき `resolveReceiptIssuerName` も『サロン』へ収束する）ため Low。本 PR による挙動変化も無い（`main` と同一式）。

**修正提案:**
コード変更は不要。`:79` に「この値は SMS 本文・品目説明のフォールバックにも流れる（解決順を変えると領収書以外にも影響）」旨のコメントを1行足すだけで足りる。

---

### [Security] （既存問題・本 PR 対象外）Stripe パラメータ全量の `console.log` に顧客 PII が乗る

- [x] 対応する

**ファイル:** `api/src/services/invoice.service.ts:275`
**重要度:** Low

**該当コード:**

```typescript
// main側 / GTSS-851側とも同一（本 PR では未変更。ログ対象オブジェクトの中身のみ変わった）
          description: buildReceiptIssuerLabel(businessName, tRegistrationNumber),
          receipt_email: invoiceData.customerEmail || undefined // Stripe公式領収書を顧客に送信（本番のみ有効）
        }
      };

      console.log('Stripe checkout params:', JSON.stringify(stripeCheckoutParams, null, 2));

      const session = await stripe.checkout.sessions.create(
```

**問題:**
`customer_email` / `receipt_email`（顧客 PII）が CloudWatch へ平文で残る。ルート `CLAUDE.md` の PII 方針に反する。Issue 本文でも「本Issueとは独立に見直し余地がある（スコープ外・要別Issue）」と明記されており、本 PR で直す必要はないが、**この PR がログ対象オブジェクトの中身を変更している**ため記録しておく。送信経路（`cancellation-send.service.ts`）には同種のログは無い。

**修正提案:**
別 Issue 化し、ログ対象を必要フィールド（金額・`stripeAccount` 等）のみに絞る。

---

## 総評

Issue #44 の REQ-1〜REQ-6 / AC-1.1〜AC-7.2 は実装・テストとも網羅されており、**マージ可能な品質**。特に評価できる点:

- **後方互換の破れなし**（重点確認）: `buildReceiptIssuerLabel` は T番号が falsy なら `issuerName || ''` を素通しし、切り詰めより前に早期 return する。`resolveReceiptIssuerName` は `'サロン'` フォールバックで空文字を返さないため、**T番号未登録時の SUMMARY は `main` と完全同一文字列**。REQ-5 の「T番号を載せる時だけ切り詰める」も構造として守られている。
- **経路の取りこぼしなし**: Checkout Session 生成は2箇所のみで両方対応済み。`dispatchPayment` の呼び出し元も admin / salon 送信の2つのみで、`application` は全列 select 済み＝追加クエリなし（PR 本文の主張をコードで確認）。
- **切り詰めの実装が正しい**: `Array.from` によるコードポイント単位分割で、境界値（99/100/101）・サロゲートペア（絵文字）とも unit テストで固定済み。ZWJ 連結絵文字の grapheme cluster のみ理論上割れるが、事業者名としては非現実的で対応不要。
- **金額系は完全に不変**、認可面の変更なし、`docs/` 更新も親リポジトリ `249daf8` で完了済み。
- テスト方針が丁寧（同値分割・境界値・後方互換の明示的固定・`receipt_email` 未設定という既存制約の固定）。

一方、**残る改善余地は「今回の不具合と同じ再発パターン」と「テストが AC を証明しきれていない箇所」に集中している**:

1. **品目説明欄の連結が2経路にコピーのまま**（Medium）— 本 Issue の原因は「2経路のドリフト」だったので、そこだけ構造化されずコメント頼りになっているのは惜しい
2. **SUMMARY のテストが事業者名と店舗名を同名で seed している**（Medium）— 「SUMMARY は店舗名ではない」という REQ-1 の核心を証明できていない。送信経路側は正しく分離できているので揃えたい
3. **T-14 のテスト名が証明範囲を超えている**（Medium）— アサーションは `receipt_email`/`customer_email` が未設定であることまでしか固定しておらず、「Stripe が領収書を送らない」はモック検証では証明できない。加えてその前提自体が H-1〜H-3 待ちの未確認事項
4. **T番号の形式検証が書き込み経路で非対称**（Medium）— 公開 `POST /applications` 経由の値が無検証で顧客の領収書へ届く到達経路が本 PR で新たに開いた

1・2・3 は本 PR 内で数行の修正、4 は `normalizeTRegistrationNumber` への正規表現追加（＋実データ確認）で対応可能。残る Low 4件（空白のみ T番号のテスト・送信経路の金額回帰・二重呼び出し・フォールバック到達先のコメント）は任意。

**人力テスト（H-1〜H-3）は未実施**のため、dev 環境での領収書メール実表示確認は別途必要。特に (a) H-3(a)（発行者名の折り返し・省略）の結果次第で REQ-5 の 100 文字という閾値の見直しが、(b) 「SMS のみの顧客に領収書が届くか」の実測次第で UC-1 のスコープ制約・AC-7.2 の前提（＝指摘3）の見直しが必要になる。
