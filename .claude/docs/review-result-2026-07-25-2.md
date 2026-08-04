---
issue: 42
date: 2026-07-25
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: main
    toBranch: GTSS-850
---

# レビュー結果: #42

## 概要

**Issue:** #42 feat: Stripe 領収書メールを日本語化（決済リンクに preferred_locales=['ja'] の Customer を連結アカウント上で紐づけ・2実装箇所/3経路）

**PR:** GO-TODAY-SHAiRE-SALON/cancel-billing-service-api#37（base `main`・OPEN）

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `main` (3fb3d3c) | `GTSS-850` (8b534c3) | 1 | 8 |

### メインエージェントによる検証結果

| 項目 | 結果 |
|---|---|
| ブランチ方向 | OK（`main..GTSS-850` = 1 commit / 逆方向 0 commit） |
| `npm run typecheck` | エラーなし |
| `npx vitest run`（全件） | **84 files / 1024 tests passed**（test DB をクリーンにした状態。`[Completion]` の申告と一致） |
| `npx vitest run` 変更3ファイル | 3 files / 66 tests passed |
| 認可（authz 4観点） | 指摘なし（ルート追加・serializer 変更・状態遷移ロック・マスアサインメント面の変更なし） |
| 親リポジトリ docs | 96b443c で main にコミット済み（`stripe-connect.md`「領収書メールの言語」節 / `cancellation-flow.md`） |

> **注**: 初回実行で 169〜287 failed が出たが、ローカル test DB の汚れが原因。`npm run db:test:down` → `db:test:up` 後は全 green。PR の欠陥ではない。

> **サブエージェント出力の訂正（精査で判明）**: code-reviewer / lessons-reviewer はいずれも「GTSS-851 の
> リファクタ（`appendTRegistrationNumber` / `buildReceiptIssuerLabel` / PII 安全ログ / `receipt-issuer.test.js`）が
> **現行 main に既に入っている**」と報告したが、これは誤り。`git grep appendTRegistrationNumber origin/main` は 0 件、
> `git ls-tree origin/main src/__tests__/e2e/` に `receipt-issuer.test.js` は無い。両者は
> リポジトリ元ディレクトリ（`develop` チェックアウト）を main と誤認していた。GTSS-851 は **PR #36 として main に未マージ**で、
> 内容は `develop`（fc6eaf5）にのみ存在する。したがって「1024 green は古い base での結果」という指摘は成立せず、
> **GTSS-850 の green は自身の base main 上で有効**。ただし衝突リスク（指摘1）は別の理由で実在する。

> **codex-reviewer について**: 初回は Codex CLI が 3 回とも 503（`biscuit_baker_service_me_circuit_open`
> = OpenAI 側のサーキットブレーカー。`wss://chatgpt.com/backend-api/codex/responses` が WebSocket 5 回・
> HTTPS フォールバック 5 回とも失敗）で応答せず、返却された指摘はサブエージェント自身の diff 検証結果だった。
> **その後 Codex が復旧したためメインエージェントが再実行し完走（`gpt-5.6-sol` / 193,918 tokens）**。
> Codex の指摘は **1 件のみ**で、内容は下記「`receipt_email` だけ未 trim」＋「T-4b が空振り」と完全一致
> （独立到達）。他 5 観点（連結アカウント指定の一致 / `customer`・`customer_email` の排他 / `receipt_email` との併存 /
> フォールバック / 冪等キー / DB ID 一致 / Sentry 記録 / 共有モック / PII 既決定事項）は「重大な追加指摘なし」。
> 出力: `scratchpad/codex-review-rerun.txt`

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/services/stripe-customer.service.ts` | +80 | -0 | Added |
| `src/services/invoice.service.ts` | +17 | -1 | Modified |
| `src/services/cancellation-send.service.ts` | +13 | -1 | Modified |
| `src/__tests__/setup.js` | +3 | -0 | Modified |
| `src/__tests__/helpers/external-mocks.js` | +5 | -1 | Modified |
| `src/__tests__/unit/stripe-customer-service.test.js` | +111 | -0 | Added |
| `src/__tests__/e2e/cancellations-invoices.test.js` | +190 | -3 | Modified |
| `src/__tests__/e2e/salonboard-send.test.js` | +197 | -0 | Modified |

## 指摘一覧

---

- [x] 対応する

### [Code Quality] `createJaCustomer` を `markSentIfPreSend` 後・try 前に置いたため、Lambda タイムアウトで請求が `pending` のまま復旧不能になる窓が広がる

**ファイル:** `api/src/services/cancellation-send.service.ts:91-99`
**重要度:** High

**該当コード:**

```typescript
// baseBranch側（変更前）— cancellation-send.service.ts
  // 決済リンクは通知の前提。Stripe アカウント未設定なら発行不能 → throw（リンク無し通知を防ぐ）。
  if (!stripeAccountId) {
    throw new Error('Stripe アカウントが未設定のため決済リンクを発行できません');
  }

  let paymentLink: string;
  try {
    const businessName = application?.businessName || application?.partnerName || 'サロン';
```

```typescript
// toBranch側（変更後）— cancellation-send.service.ts
  if (!stripeAccountId) {
    throw new Error('Stripe アカウントが未設定のため決済リンクを発行できません');
  }

  // GTSS-850 / REQ-1: 領収書メールを日本語化するため、連結アカウント上へ preferred_locales:['ja'] の
  // Customer を作って Checkout Session へ紐づける（customerEmail は上で trim 済み。未登録でも作成する）。
  // 失敗しても null が返るだけで決済リンク発行は止めない（REQ-2）。
  const jaCustomerId = await createJaCustomer({
    email: customerEmail,
    stripeAccountId,
    cancellationId: cancellation.id,
  });

  let paymentLink: string;
  try {
```

**問題:**

`stripe.customers.create` は Stripe SDK の既定設定で走る。実測で確認した既定値と Lambda 予算:

| 設定 | 値 | 出典 |
|---|---|---|
| Stripe SDK `timeout` | **80,000ms** | `node_modules/stripe/cjs/stripe.core.js:17` `DEFAULT_TIMEOUT = 80000` |
| Stripe SDK `maxNetworkRetries` | **2** | 同 `:72` |
| API Lambda `timeout` | **30s** | `serverless.yml:67` / `deploy-api.sh:270,281` `--timeout 30` |

`performSend` の呼び出し順は `markSentIfPreSend`（pre_send → pending へ原子的に遷移）→ `dispatchPayment` で、
`dispatchPayment` は先頭で `createJaCustomer` を await する（try の**外**）。ここで Stripe が停滞して
Lambda が 30s でハード タイムアウトすると、`performSend` の catch（`cancellation-send.service.ts:246-259`）が
**一切実行されない**ため `revertToPreSendIfPending` が走らない。結果:

- 該当請求は `status='pending'` かつ `stripePaymentUrl=null` で固着する
- 再送は `performSend` 冒頭のガードで `alreadySent: true`（200）となり弾かれる
- 管理画面のステータス更新も `cancellation.service.ts:404` で「`pending`/`paid` → `pre_send` の巻き戻しを禁止」しているため戻せない
- `revertToPreSendIfPending` の呼び出し箇所は `cancellation-send.service.ts:257` の **1 箇所のみ**（grep 済み）

これは既存コードのコメントが明示的に警戒している状態そのものである:

```typescript
// ここで戻さないと「リンク無し・status=pending」で固着し、再送は alreadySent で弾かれて復旧不能になる。
```

変更前はこの窓に**決済リンク発行という必須呼び出ししか無かった**。本 PR は「領収書の言語という表示上の改善」
＝ REQ-2 が明示的に「失敗しても止めない」と宣言している**任意呼び出し**を、同じ復旧不能窓の中へ、
しかも予算未設定（最大 80s × リトライ 2）で追加している。REQ-2 の意図がタイムアウト経路で守られていない。

`POST /invoices`（手動作成）側も同様の露出がある。`createJaCustomer` は
`cancellationsRepo.create(invoice)`（`invoice.service.ts:217`）の**後**に呼ばれ、`invoiceId` は
`inv_${Date.now()}`（同 `:158`）で採番されるため、タイムアウト後にクライアントが再実行すると
**別 ID の請求行が二重に登録される**。

**修正提案:**

任意呼び出しであることをコードに反映し、per-request RequestOptions で予算を切る（失敗は既存の catch で
`null` に倒れ、REQ-2 のフォールバックがそのまま働く）。

```typescript
// src/services/stripe-customer.service.ts
{
  stripeAccount: stripeAccountId,
  idempotencyKey: `customer_${cancellationId}`,
  // 領収書の言語は表示上の改善であり、決済リンク発行を止めてはならない（REQ-2）。
  // SDK 既定（timeout 80s / retry 2）は Lambda の 30s 予算を超えるため、この呼び出しだけ予算を切る。
  timeout: 5000,
  maxNetworkRetries: 0,
}
```

---

- [x] 対応する

### [Code Quality] PR #36（GTSS-851）と `invoice.service.ts` の同一ブロックで衝突し、解決を誤ると領収書のT番号対応と PII 安全ログを巻き戻す

**ファイル:** `api/src/services/invoice.service.ts:237-275` / `api/src/__tests__/e2e/cancellations-invoices.test.js`
**重要度:** High

**該当コード:**

```typescript
// baseBranch側（main = 3fb3d3c）— invoice.service.ts
      const tRegistrationNumber = user.tRegistrationNumber || null;
      const productDescription = tRegistrationNumber
        ? `${stripeDescription}\n適格請求書登録番号: ${tRegistrationNumber}`
        : stripeDescription;

      const stripeCheckoutParams = {
        ...
        customer_email: invoiceData.customerEmail || undefined,
```

```typescript
// toBranch側（GTSS-850）— invoice.service.ts
      const tRegistrationNumber = user.tRegistrationNumber || null;
      const productDescription = tRegistrationNumber
        ? `${stripeDescription}\n適格請求書登録番号: ${tRegistrationNumber}`
        : stripeDescription;

      // GTSS-850 / REQ-1: 領収書メールを日本語化するため、連結アカウント上へ …
      const normalizedCustomerEmail = normalizeCustomerEmail(invoiceData.customerEmail);
      const jaCustomerId = await createJaCustomer({ email: normalizedCustomerEmail, stripeAccountId, cancellationId: invoiceId });

      const stripeCheckoutParams = {
        ...
        ...(jaCustomerId ? { customer: jaCustomerId } : { customer_email: normalizedCustomerEmail }),
```

```typescript
// PR #36 (GTSS-851) 側 — 同じブロックを書き換えている（現在 develop = fc6eaf5 にのみ存在）
      const tRegistrationNumber = normalizeTRegistrationNumber(user.tRegistrationNumber);
      const productDescription = appendTRegistrationNumber(stripeDescription, tRegistrationNumber);
      ...
        customer_email: invoiceData.customerEmail || undefined,
        ...
          description: buildReceiptIssuerLabel(businessName, tRegistrationNumber),
          receipt_email: invoiceData.customerEmail || undefined
      };

      // ⚠️ stripeCheckoutParams を丸ごとログしない: customer_email / receipt_email（顧客 PII）が
      // CloudWatch へ平文で残る（ルート CLAUDE.md の PII 方針違反）。デバッグに必要な非 PII 項目だけ出す。
      console.log('Stripe checkout params:', JSON.stringify({
        unit_amount: ..., hasReceiptEmail: Boolean(...), stripeAccount: stripeAccountId,
      }));
```

**問題:**

PR #37（GTSS-850）と PR #36（GTSS-851）は**どちらも base `main` で OPEN**、かつ `invoice.service.ts` の
同一ブロックを書き換えている。実測で衝突を確認済み:

```
$ git merge-tree --write-tree --name-only GTSS-850 origin/GTSS-851
src/__tests__/e2e/cancellations-invoices.test.js
src/services/invoice.service.ts

CONFLICT (content): Merge conflict in src/__tests__/e2e/cancellations-invoices.test.js
CONFLICT (content): Merge conflict in src/services/invoice.service.ts
```

GTSS-850 の追加行は GTSS-851 が書き換えた行の**直後**（import 行の直後・T番号連結ブロックの直後・
`customer_email` 行そのもの）に入るため、3-way merge が確実に衝突する。GTSS-850 側を素朴に採用すると:

1. `buildReceiptIssuerLabel` / `appendTRegistrationNumber` への集約が消え、**顧客が受け取る領収書の
   発行者名・適格請求書登録番号（T番号）の記載が壊れる**（GTSS-851 / #44 の実装 revert）
2. `console.log('Stripe checkout params:', JSON.stringify(stripeCheckoutParams, null, 2))` が残り、
   **`receipt_email`（顧客 PII）が CloudWatch へ平文で残る**（ルート CLAUDE.md の PII 方針違反。
   GTSS-851 が是正した内容の巻き戻し）

なお PR #38（GTSS-852）は base `develop`、PR #36 / #37 は base `main` と**ベース方針が不統一**で、
GTSS-851 の内容は既に `develop` にマージ済み（fc6eaf5）。どちらを統合ブランチにするかの取り決めが無いと
同種の衝突が繰り返される。

**修正提案:**

1. #36 / #37 のマージ順を決め、**後にマージする側で `git merge origin/main`（または rebase）してから
   `npx vitest run` 全件 ＋ `npm run typecheck` を再実行**する
2. 解決後、以下がすべて成立していることを確認する
   - `product_data.description` = `appendTRegistrationNumber(stripeDescription, tRegistrationNumber)`
   - `payment_intent_data.description` = `buildReceiptIssuerLabel(businessName, tRegistrationNumber)`
   - `console.log('Stripe checkout params:', …)` は **PII を含まない部分ログ版**
   - `...(jaCustomerId ? { customer } : { customer_email })` の条件付きスプレッド
3. api リポジトリの統合ブランチ（`main` か `develop` か）を明文化する

> テスト側は解消が容易な見込み: T-15 の `description: 'サロンA'` は `buildReceiptIssuerLabel('サロンA', null)`
> が名前をそのまま返す（`notification.service.ts:288`）ため成立し、`develop` 側の `receipt-issuer.test.js` は
> `customer_email` の undefined のみを見るため `customer` 付与でも成立する。

---

- [x] 対応する

### [Codex] AC-4.2（決済画面メール欄の挙動が不変）は Stripe 公式ドキュメントの記述上、満たされない見込み — 顧客がメールを訂正できなくなる

**ファイル:** `api/src/services/invoice.service.ts:265-268` / `api/src/services/cancellation-send.service.ts:117-119`
**重要度:** High

**該当コード:**

```typescript
// baseBranch側（変更前）
        customer_email: invoiceData.customerEmail || undefined,
```

```typescript
// toBranch側（変更後）
        ...(jaCustomerId
          ? { customer: jaCustomerId }
          : { customer_email: normalizedCustomerEmail }),
```

**問題:**

Codex が Stripe Checkout API リファレンスを根拠に H-4 の要確認を挙げたため、公式ドキュメント
（`https://docs.stripe.com/api/checkout/sessions/create.md`）の当該記述を取得して裏取りした。**原文**:

| パラメータ | ドキュメント記述（抜粋・原文） |
|---|---|
| `customer` | "If the Customer already has a valid `email` set, **the email will be prefilled and not editable in Checkout**. If the Customer does not have a valid `email`, Checkout will set the email entered during the session on the Customer." |
| `customer_email` | "If provided, this value will be used when the Customer object is created. If not provided, customers will be asked to enter their email address. **Use this parameter to prefill customer data** if you already have an email on file."（編集可否への言及なし） |

Stripe は **`customer` に対してのみ明示的に「編集不可（not editable）」と記述**しており、`customer_email` には
プリフィルの記述しかない。したがって本 PR の切り替え（`customer_email` → `customer`）は、
**メールアドレスありのケースで決済画面のメール欄を「編集可能」から「編集不可」へ変える**可能性が高い。

これは AC-4.2「決済画面（Stripe Checkout）のメールアドレス入力欄の挙動（プリフィル有無・編集可否）が
従来と変わらない (REQ-3)」に**正面から反する**。Issue 本文の REQ-3 も
「変化していた場合は、本 Issue の想定外の副作用として別途判断する」としており、**判断が必要な事項**である。

業務影響: 顧客メールはサロン担当者が手入力する（`POST /invoices`）か、サロンボードから取り込む値。
誤入力・旧アドレスだった場合、従来は顧客が決済画面で自分のアドレスへ訂正できたが、変更後は訂正できない。
`receipt_email` は入力値のまま固定されるため、**領収書が誤ったアドレスへ送られ、顧客側に回復手段が無くなる**。

> **副次的な収穫（[Discovery] の未確定事項が一部解消）**: 同ドキュメントは
> 「Customer に有効な `email` が無い場合、Checkout はセッション中に入力されたメールを Customer へ設定する」
> と明記している。したがって SMS のみ経路（メール未登録）でも、顧客が決済画面で入力したアドレスが
> `preferred_locales: ['ja']` を持つ Customer に載るため、**日本語ロケールは効く**。
> Issue 概要の訂正表の主張を裏付ける内容。ただし「`receipt_email` 未指定でも領収書が実際に送信されるか」は
> このページでは解決せず、H-1 / H-4 待ちのまま。

**修正提案:**

1. **H-4 を最優先で実施し、実画面で編集可否を確認する**（メールあり／メール無しの両パターン）
2. 編集不可になっていた場合、以下のいずれかを選ぶ判断をユーザー（プロダクト側）に上げる
   - **許容する**: 「サロンが登録したアドレスへ領収書を送る」を仕様として確定させ、AC-4.2 を修正する
   - **編集可能を維持する**: メールありのケースは従来どおり `customer_email` を使い、Customer は
     メールを持たせずに（`preferred_locales` のみで）作って `customer` と併用する — ただし
     `customer` と `customer_email` は排他のため**この併用は不可**。実質的には
     「メールなし Customer ＋ `receipt_email`」構成（Checkout で顧客がメールを入力・編集できる）へ
     倒す形になる。Customer に email を渡さないだけで済むため変更は小さい
3. 選んだ結論を Issue の REQ-3 / AC-4.2 と `docs/product/cancellation-flow.md` へ反映する

> `stripe docs` CLI（`stripe:stripe-docs` skill 推奨経路）は `stripe login` の対話認証を要求したため、
> 非対話で完結する WebFetch で公式ドキュメントを取得した。

---

- [x] 対応する

### [Codex] `receipt_email` だけ未 trim のため AC-1.3 が実 Stripe では成立せず、空白のみメールで「リンク無しの請求通知」が顧客へ届く

**ファイル:** `api/src/services/invoice.service.ts:262`（変更後 `:278`）
**重要度:** Medium

> **Codex（`gpt-5.6-sol`）の唯一の指摘（P1）と一致。** Codex は Stripe Checkout API リファレンスを根拠に
> 「`receipt_email` は Stripe がメールアドレスを要求するフィールドであり、`'   '` では Checkout Session
> 作成が拒否され得る」「T-4b は Stripe モックが不正パラメータでも成功するため空振り」「**前後空白付きの
> 有効メール（`' cust@y.com '`）も同じ問題を持つ**」と指摘した。メインエージェントの独立検証と一致。

**該当コード:**

```typescript
// baseBranch側（変更前）
        mode: 'payment',
        customer_email: invoiceData.customerEmail || undefined,
        success_url: `${checkoutResultBaseUrl()}/payment-complete`,
        cancel_url: `${checkoutResultBaseUrl()}/payment-cancel`,
        payment_intent_data: {
          application_fee_amount: platformFeeAmount,
          description: businessName,
          receipt_email: invoiceData.customerEmail || undefined // Stripe公式領収書を顧客に送信（本番のみ有効）
        }
```

```typescript
// toBranch側（変更後）
        mode: 'payment',
        // customer と customer_email は Stripe 側で排他。…
        ...(jaCustomerId
          ? { customer: jaCustomerId }
          : { customer_email: normalizedCustomerEmail }),   // ← trim 済み
        success_url: `${checkoutResultBaseUrl()}/payment-complete`,
        cancel_url: `${checkoutResultBaseUrl()}/payment-cancel`,
        payment_intent_data: {
          application_fee_amount: platformFeeAmount,
          description: businessName,
          receipt_email: invoiceData.customerEmail || undefined // ← 未 trim のまま
        }
```

**問題:**

REQ-1 は「顧客メールアドレスの有無は前後の空白を除去した値で判定し、**Stripe へ渡す値も同じ除去後の値とする**」
と定めているが、`receipt_email` も Stripe へ渡す値であり、ここは生値のまま残っている。
`[Completion]` コメントは影響を「Customer 側 = trim 済み / `receipt_email` = 空白付き」という表記差として
説明しているが、実際の帰結はより重い。`POST /invoices` に `customerEmail: '   '` ＋ `customerPhone` を渡した場合:

1. `invoice.service.ts:74` の `hasEmail` は trim 判定なので false → バリデーション通過・`notificationMethod='sms'`
2. `normalizedCustomerEmail` は `undefined` → email 無し ja Customer を作成し `customer` を指定（ここは正しい）
3. しかし `receipt_email: '   '` が残り、不正メールが Stripe へ渡る
4. Stripe が形式で弾くと `checkout.sessions.create` ごと失敗 → `invoice.service.ts` の catch が握って `paymentLink = null`
5. **201 が返るが決済リンクが無い**。顧客には壊れた通知が届く:
   - SMS: `generateSmsContent` は `invoiceId` があれば常に `${apiBaseUrl()}/pay/${invoiceId}` を積む
     （`notification.service.ts:263`）→ `payRedirect` が `stripePaymentUrl` 無しで
     **404「お支払いリンクが見つかりません」**（`invoice.service.ts:425-431`）
   - メール: 「申し訳ございません。お支払いリンクの生成に問題が発生しました。」（`notification.service.ts:211`）

変更前も `customer_email: '   '` で同様に失敗していたため**回帰ではない**が、AC-1.3 は Issue 上
「✅ 完了」とチェックされており、実 Stripe では手動作成経路で未達である。送信経路
（`cancellation-send.service.ts:133`）は上流で trim 済みの値を `receipt_email` へ渡しているため、
**2 経路で挙動が非対称**になった点も整合していない。

REQ-3 の「`receipt_email` の指定内容は不変」は「領収書の**送信先**を変えない」という要件であり、
空白の保持を保証するものではない。trim は Stripe が受け付ける全入力に対して送信先を変えないため
REQ-3 に反しない。

> `[未検証]` Stripe が `receipt_email` の前後空白を内部で trim するか／空白のみを invalid として拒否するかは
> 実 API 未確認（メールバリデーション仕様からの推論）。ただし「Stripe へ渡す値が Customer と `receipt_email` で
> 食い違い、REQ-1 の文言に反する」点は Stripe の挙動に関わらず成立する。

**修正提案:**

```typescript
          receipt_email: normalizedCustomerEmail // Stripe公式領収書を顧客に送信（本番のみ有効）
```

DB 保存値（`invoice.service.ts:192` `customerEmail: invoiceData.customerEmail || ''`）と SES 宛先
（同 `:316`）も未 trim だが、こちらは本 PR のスコープ外として別 Issue が妥当。

---

- [x] 対応する

### [Test Coverage] T-4b が checkout params を検証しないため、AC-1.3 の修正対象そのものが担保されていない

**ファイル:** `api/src/__tests__/e2e/cancellations-invoices.test.js:489-499`
**重要度:** Medium

**該当コード:**

```javascript
// toBranch側（新規追加）
  it('T-4b メールが空白のみ → 未登録として扱い email 無しの Customer を作る (AC-1.3)', async () => {
    const { applicationUser, shop } = await setup();
    stripe.customers.create.mockResolvedValue({ id: 'cus_blank' });
    twilio.messages.create.mockResolvedValue({ sid: 'sm_1' });

    const res = await postInvoice(applicationUser, {
      shopId: shop.id, amount: 10000, customerEmail: '   ', customerPhone: '09000000001',
    });
    expect(res.status).toBe(201);
    expect(stripe.customers.create.mock.calls[0][0]).not.toHaveProperty('email');
  });
```

**問題:**

`[CodeReview]` コメントは invoice 経路に `normalizeCustomerEmail` を入れた目的を
「従来は `customer_email` に未 trim の値を渡していたため、空白のみの入力でフォールバックが壊れていた」
と説明している。しかし T-4b は `customers.create` の第1引数だけを見ており、**修正対象である
`stripeCheckoutParams` の `customer_email` / `customer` / `receipt_email` を一切検証していない**。

- `customer` 成功時は `customer_email` キー自体が生えないため、`'   '` が `undefined` へ正規化されて
  渡ることを固定するテストが存在しない（T-12 はメールキーが無いケース、unit の `normalizeCustomerEmail` は関数単体）
- Stripe モックは形式検証をしないため、`receipt_email: '   '` が渡っても 201 で緑になる
  → 「空白のみ → 未登録として扱う」が end-to-end で成立しているように読めてしまい、
  上記「`receipt_email` 未 trim」指摘を検知できない

**修正提案:**

T-4b に checkout params のアサーションを追加し、加えて「空白のみ ＋ Customer 作成失敗」の
フォールバックケースを足す。

```javascript
    const params = stripe.checkout.sessions.create.mock.calls[0][0];
    expect(params.customer).toBe('cus_blank');
    expect(params.customer_email).toBeUndefined();
    expect(params.payment_intent_data.receipt_email).toBeUndefined(); // ← trim 統一後に green になる
    // 決済リンクが実際に発行されていること（モックが不正パラメータを通すため 201 だけでは不十分）
    expect((await res.json()).data.stripePaymentUrl).toBe('https://pay.stripe/cs_1');

    // 追加テスト: 空白のみ ＋ Customer 作成失敗 → customer / customer_email いずれも無指定
    stripe.customers.create.mockRejectedValue(new Error('stripe down'));
```

**さらに Codex が指摘した未カバーケース**: 「前後空白付きの有効メール」（`' cust@y.com '`）の統合テストが
存在しない。unit の T-7 は `normalizeCustomerEmail` 単体までで、`stripeCheckoutParams` 全体の整合
（`customer` に紐づく Customer は trim 済み ／ `receipt_email` は空白付き、という現在の不整合）を
end-to-end で固定するテストが無い。

```javascript
  it('メール前後に空白 → Customer / receipt_email いずれも trim 済みの値を渡す (AC-1.3)', async () => {
    // customerEmail: ' cust@y.com ' で POST
    expect(stripe.customers.create.mock.calls[0][0].email).toBe('cust@y.com');
    expect(params.payment_intent_data.receipt_email).toBe('cust@y.com'); // ← 現状は '  cust@y.com ' で fail
  });
```

---

- [x] 対応する

### [Security] `console.error` に Stripe エラーオブジェクトをそのまま渡しており、顧客メールが CloudWatch へ平文で残り得る

**ファイル:** `api/src/services/stripe-customer.service.ts:74-79`
**重要度:** Low

**該当コード:**

```typescript
// toBranch側（新規）
  } catch (e) {
    // 領収書の日本語化に失敗するだけで決済リンクは発行できる（REQ-2）。握り潰さず監視へは送る。
    console.error('createJaCustomer: Stripe customers.create error:', e);
    Sentry.captureException(e, { tags: { 'stripe.operation': 'customers.create' } });
    return null;
  }
```

**問題:**

Sentry 側は `beforeSend` → `scrubEventPii` → `redactPiiText`（`src/observability/sentry.ts:61,95-120`）で
例外メッセージ中のメールを `EMAIL_RE` によりマスクするため外部送信前に安全化される。一方 `console.error` は
**素通りで CloudWatch に残る**。`customers.create` は引数に顧客メールを取るため、形式不正系のエラー
（`email_invalid` 等）ではメッセージにアドレスが載り得る。`POST /invoices` はメール形式を検証せず
`invoice.service.ts:74` の非空チェックのみなので、不正形式は API を通過する。

同種のログ（`cancellation-send.service.ts:149`）が既存するため新規違反ではないが、この呼び出しは
PII 起因エラーの当事者であり、`develop` 側（GTSS-851）で同ファイルの PII ログ方針が明文化された直後の追加でもある。

**修正提案:**

```typescript
    console.error('createJaCustomer failed:', { type: (e as any)?.type, code: (e as any)?.code, requestId: (e as any)?.requestId });
    Sentry.captureException(e, { tags: { 'stripe.operation': 'customers.create' } });
```

`src/observability/sentry.ts` は `redactPiiText` も export しているため、メッセージを残したい場合は
`redactPiiText(e?.message)` を通す選択肢もある。

---

- [x] 対応する

### [Code Quality] `webhook.service.ts` のログが常に null 化する。follow-up 案（`customer_details.email`）は PII 方針に反するので削除方向で起票すべき

**ファイル:** `api/src/services/webhook.service.ts:72`
**重要度:** Low

**該当コード:**

```typescript
// 変更なし（本 PR では未タッチ）
    if (stripeEvent.type === 'checkout.session.completed') {
      const session = stripeEvent.data.object;
      console.log('Checkout session completed:', session.id, 'customer_email:', session.customer_email);

      try {
        // セッション ID から請求書を検索
        const invoice = await cancellationsRepo.findByStripeSessionId(session.id);
```

**問題:**

`customer` 指定へ変わることで `session.customer_email` は今後常に null になる。機能依存が無いことは
確認済み（非テストソース中の `session.customer_email` 参照はこの 1 箇所のみ、請求特定は
`findByStripeSessionId(session.id)`）。`[Completion]` の自己申告は正確で、本 PR で触らない判断も妥当。

ただし `[Completion]` の follow-up 案「`session.customer_details?.email` への切り替え」は
**顧客メールを CloudWatch へ平文で残す方向**であり、ルート CLAUDE.md の PII 方針および
GTSS-851 で同リポジトリに明文化された方針（「`customer_email` / `receipt_email` を丸ごとログしない。
有無は boolean で記録」）に反する。

**修正提案:**

別 Issue にするなら「ログから顧客メールを削除する（`session.id` のみ、必要なら
`hasCustomerEmail: Boolean(session.customer_details?.email)`）」の方向で起票する。null 化する本 PR に
合わせて落とすのが最も安い。

---

- [x] 対応する

### [Code Quality] 冪等キーが params に追随しないため、メール修正後の再送で毎回 idempotency error → 英語領収書へ黙って劣化＋Sentry ノイズ

**ファイル:** `api/src/services/stripe-customer.service.ts:64-68`
**重要度:** Low

**該当コード:**

```typescript
// toBranch側（新規）
      {
        stripeAccount: stripeAccountId,
        // ネットワーク再送・Lambda リトライでの重複作成を防ぐ（同一請求の再試行は同じ Customer が返る）。
        idempotencyKey: `customer_${cancellationId}`,
      },
```

**問題:**

「Checkout 失敗 → `pre_send` へ差し戻し（`cancellation-send.service.ts:257`）→ 顧客メールを修正 → 再送」は
運用上ふつうに起きる復旧手順。冪等キーは 24h 有効で params に追随しないため、この順序では
同一キー・異パラメータになり Stripe が idempotency error を返す。`createJaCustomer` が握って
`customer_email` フォールバックへ倒れるため REQ-2 の範囲で安全に劣化するが、

- 領収書が黙って従来言語（ブラウザ言語）へ戻る
- **予測可能な条件で毎回 `Sentry.captureException` が飛ぶ**（監視ノイズ）

金額のみの修正では Customer の params が変わらないためキャッシュ済み Customer が返り、この事象は起きない
（メール修正時のみ）。`[Completion]` が実害を「領収書が従来言語になることのみ」と評価しているのは妥当だが、
回避手段が安価なのに受け入れている点が気になる。テストも未追加。

> `[未検証]` 同一キー・異パラメータで Stripe が返すエラー種別（`idempotency_error`）は公式ドキュメント知識
> ベースで、実 API 未確認。

**修正提案:**

キーを params に追随させる。

```typescript
        idempotencyKey: `customer_${cancellationId}_${sha256(normalizedEmail ?? '').slice(0, 8)}`,
```

採らない場合でも、`e?.type === 'idempotency_error'` は `captureException` せず `console.warn` に落として
監視ノイズを避ける。

---

- [x] 対応する

### [Code Quality] `createJaCustomer` の呼び出し位置が 2 サービスで非対称（invoice 側は try の内側）

**ファイル:** `api/src/services/invoice.service.ts:245`（対比: `api/src/services/cancellation-send.service.ts:94`）
**重要度:** Low

**該当コード:**

```typescript
// toBranch側 — invoice.service.ts（try の内側）
    let paymentLink = null;
    try {
      console.log('Creating Stripe checkout session for account:', stripeAccountId);
      ...
      const normalizedCustomerEmail = normalizeCustomerEmail(invoiceData.customerEmail);
      const jaCustomerId = await createJaCustomer({ ... });   // ← try の中
      ...
    } catch (stripeError) {
      console.error('Error creating Stripe checkout session:', stripeError);
      // Stripe エラーの場合でも処理継続
    }
```

```typescript
// toBranch側 — cancellation-send.service.ts（try の外側）
  const jaCustomerId = await createJaCustomer({ ... });   // ← try の外

  let paymentLink: string;
  try {
    ...
  } catch (e) {
    console.error('send: Stripe checkout error:', e);
    throw new Error('決済リンクの発行に失敗しました');
  }
```

**問題:**

`[CodeReview]` コメントは「`createJaCustomer` の呼び出しを checkout の try ブロック**外**に置いた」と
説明しているが、これが当てはまるのは `dispatchPayment` のみで、`invoice.service.ts` は try の内側にある。
現状 `createJaCustomer` は全例外を捕まえて `null` を返すため挙動差は無いが、将来同ヘルパが throw するように
なると `POST /invoices` は黙って「リンク無しの請求」を作り、送信経路は 502 になるという分岐が生まれる。

なお同コメントの理由付け（「中に入れると『決済リンクの発行に失敗しました』＋`pre_send` 差し戻し（502）へ化ける」）は
半分不正確で、`performSend` の catch はどちらの位置でも差し戻し＋502 を行い、差はエラーメッセージのみ。
コード上の欠陥ではない。

**修正提案:**

`invoice.service.ts` の `createJaCustomer` 呼び出しを `try {` より前へ移し、両サービスで同じパターンに揃える
（指摘1のタイムアウト対策と併せて対応するのが自然）。

---

- [x] 対応する

### [Test Coverage] T-4 の SMS 本文アサーションが弱く、REQ-3「SMS 本文の非変更」を担保できていない

**ファイル:** `api/src/__tests__/e2e/cancellations-invoices.test.js:485`
**重要度:** Low

**該当コード:**

```javascript
// toBranch側（新規追加）
    // SMS の宛先・本文は非変更（REQ-3）。メールは無いので SES は呼ばれない。
    expect(twilio.messages.create).toHaveBeenCalledTimes(1);
    const [smsParams] = twilio.messages.create.mock.calls[0];
    expect(smsParams.to).toBe(formatPhoneNumberForStripe('09000000001'));
    expect(smsParams.body).toContain('/pay/');
    expect(sesMock.commandCalls(SendEmailCommand)).toHaveLength(0);
```

**問題:**

`.claude/skills/vitest/lesson.md`「メール/SMS 通知の本文は定数キーではなく実際のテキストを検証する」に照らすと
`toContain('/pay/')` は弱すぎる。実体は `generateSmsContent` が積む `${apiBaseUrl()}/pay/${invoiceId}`
（`notification.service.ts:263`）で、請求 ID も末尾の「※本SMSは通知専用です。」も未検証のため、
本文が変わっても緑になる。

**修正提案:**

```javascript
    const body = await res.json();
    expect(smsParams.body).toContain(`/pay/${body.data.id}`);
    expect(smsParams.body).toContain('※本SMSは通知専用です。');
```

---

- [x] 対応する

### [Code Quality] REQ-2 のフォールバック発生率が運用から見えない（任意対応）

**ファイル:** `api/src/services/invoice.service.ts` / `api/src/services/cancellation-send.service.ts`
**重要度:** Low

**問題:**

REQ-2 のフォールバックは「黙って英語領収書に戻る」劣化であり、`Sentry.captureException` は例外時のみ・
送信経路には該当する構造化ログが無いため、劣化率が運用から追えない。Issue 自身が Stripe 呼び出しの増加を
「要監視」としているが、監視の材料が無い。

**修正提案:**

既存の checkout ログへ `jaCustomerLinked: Boolean(jaCustomerId)` を 1 行追加し、CloudWatch だけで
フォールバック率を追えるようにする。

> **前提の訂正**: サブエージェントは「既存の構造化ログ（`hasReceiptEmail` を boolean で出す設計）へ追加せよ」と
> 提案したが、その構造化ログは `develop`（GTSS-851）にのみ存在し、`main` / `GTSS-850` は
> `console.log('Stripe checkout params:', JSON.stringify(stripeCheckoutParams, null, 2))` の全ダンプ版である。
> したがって本対応は**指摘1のマージ解決（PII 安全ログの取り込み）後**に行うのが順序として正しい。

---

## マージ前のブロッカー

1. **AC-4.2 の仕様判断** — Stripe 公式ドキュメントの記述上、`customer` 切り替えで決済画面のメール欄が
   **編集不可**になる見込み。H-4 を最優先で実施し、「サロン登録アドレス固定を許容する」か
   「Customer に email を渡さず編集可能を維持する」かをプロダクト判断として確定させる
2. **Lambda タイムアウト × 復旧不能** — 任意呼び出しに per-request の `timeout` / `maxNetworkRetries` を設定する（1 行）
3. **PR #36 との衝突** — マージ順を決め、後にマージする側で main 取り込み → `npx vitest run` 全件 ＋ `npm run typecheck` を再実行。T番号対応と PII 安全ログが残っていることを確認
4. **人力テスト H-1〜H-4 が未実施** — Issue 自身が「結合レベルの担保は実質 H-1 単独」「マージ前に必ず実施」と宣言しており、AC-3.1 / AC-3.2 / AC-4.1 / AC-4.2 は未クローズ

## 良かった点（維持推奨）

- **`...(jaCustomerId ? { customer } : { customer_email })` の条件付きスプレッド** — Stripe の排他制約を
  コードの形で表現しており、後続実装者が「両方指定」へ戻せない
- **`createJaCustomer` を非 throw 設計にした判断** — 呼び出しチェーンを追跡し、`performSend` の catch による
  502 ／ `pre_send` 差し戻しへ化けないことを確認済み。`customer.id` 欠落レスポンスも失敗扱いにして
  不正 ID を Checkout へ渡さない防御が入っている
- **`external-mocks.js` の既定 resolve 値 `{ id: 'cus_default' }`** — 主張どおり回帰検知力を保つ。
  checkout を通る全テストファイル（send-shop-name / branches / salonboard-import / invoice-shop-select /
  isolation / salonboard-send / cancellations-invoices）が `installExternalMocks()` を `beforeEach` で
  呼んでおり（`beforeAll` 使用は 0 件）、既定値が漏れる経路も無いことを確認
- **`stripe-customer.service.ts` の冒頭コメント** — 領収書言語の決定順・direct charge ゆえの
  連結アカウント制約・`customer_creation:'always'` が使えない理由まで残しており、同じ罠を踏む再発を防いでいる
- **`metadata.cancellation_id` と冪等キーの ID が DB の PK と一致** — `invoiceId`（`:158`）→ `invoice.id`（`:188`）→
  `cancellationsRepo.create`（`:217`）を追跡して確認。事後追跡（D-1 / D-4）が実際に機能する

## 総評

実装本体の品質は高い。REQ-1 の 2 箇所 / 3 経路はすべて改修されており（`checkout.sessions.create` を
grep で全走査し 2 箇所のみであることを確認）、`stripeAccount` の一致・`customer` と `customer_email` の排他・
非 throw 設計・`metadata` と冪等キーの ID 整合はいずれも裏取りできた。認可面の新規リスクは無く、
テストは 3 経路 ×（メール有無 × Customer 成功/失敗）を実質的に網羅している。共有テストインフラの
既定 resolve 値という判断も、回帰検知力を落とさないための正しい選択。docs も親リポジトリへ反映済み。

一方で、**マージ前に落としたい項目が 2 つ**ある。1 つは Stripe SDK の既定タイムアウト（80s × リトライ 2）が
Lambda の 30s 予算を超える点で、REQ-2 が「止めない」と宣言した任意呼び出しを、`markSentIfPreSend` 後の
復旧不能窓へ予算なしで置いてしまっている。1 行の RequestOptions で塞げる。もう 1 つは PR #36（GTSS-851）との
衝突で、解決を誤ると顧客が受け取る領収書のT番号記載と PII 安全ログの両方を revert し得る。

`receipt_email` の trim は「REQ-1 と REQ-3 の衝突」として実装者が判断を仰いでいる論点だが、REQ-3 が守っているのは
**送信先**であって空白の保持ではないため、揃える（`normalizedCustomerEmail` へ差し替える）ほうが Issue の
意図に沿うと考える。現状は AC-1.3 が「✅ 完了」でありながら手動作成経路では実 Stripe で未達で、
T-4b もモック前提で緑になるためこれを検知できない。

そして最も重い論点は **AC-4.2** である。Codex の指摘を起点に Stripe 公式ドキュメントを取得したところ、
`customer` には「Customer に有効な email があればメール欄は**プリフィルされ編集不可**」と明記されており、
`customer_email` にはその記述が無い。つまり本 PR は「領収書の言語」という表示上の改善のために、
**顧客が決済画面で自分のメールアドレスを訂正する手段を奪う**可能性が高い。サロン担当者の手入力・
サロンボード取り込みが誤アドレスだった場合、顧客側の回復手段が無くなり領収書が届かない。
Issue の REQ-3 自身が「変化していた場合は想定外の副作用として別途判断する」としているとおり、
H-4 の実施とプロダクト判断がマージ前に必要。なお Customer へ email を渡さない構成にすれば
（言語は `preferred_locales` が決め、送信先は `receipt_email` と Checkout 入力が決めるため）
日本語化を維持したまま編集可能を保てる見込みで、変更量も小さい。

本 Issue は自ら「結合レベルの担保は実質 H-1 単独」「マージ前に必ず実施」と宣言している。
自動テストは十分だが、**H-1〜H-4 の人力確認が唯一の結合担保**である点は変わらない。
