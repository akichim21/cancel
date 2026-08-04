---
issue: 57
date: 2026-08-01
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: origin/main
    toBranch: origin/GTSS-886
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: origin/main
    toBranch: origin/GTSS-886
  - repo: user
    repoDir: cancel-billing-service
    baseBranch: origin/main
    toBranch: origin/GTSS-886
---

# レビュー結果: #57

## 概要

**Issue:** #57 未払いキャンセル請求への自動リマインド送信（7日目・14日目 正午）と期限切れ（未回収）・配信進捗の可視化

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 | PR |
|-----------|-------------|------------|----------|------------|-----|
| api | `origin/main` | `origin/GTSS-886` | 1 | 35 (+3120/-226) | [api#41](https://github.com/GO-TODAY-SHAiRE-SALON/cancel-billing-service-api/pull/41) |
| admin | `origin/main` | `origin/GTSS-886` | 1 | 10 (+1613/-44) | [admin#16](https://github.com/GO-TODAY-SHAiRE-SALON/cancel-billing-service-admin/pull/16) |
| user | `origin/main` | `origin/GTSS-886` | 1 | 12 (+594/-54) | [user#12](https://github.com/GO-TODAY-SHAiRE-SALON/cancel-billing-service/pull/12) |

> infra PR #11（EventBridge Scheduler・reminders family）と親リポの docs 更新（未コミット）は本レビューの対象外。

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/services/billing-reminder.service.ts` | +264 | -0 | Added |
| `src/services/checkout-session.service.ts` | +173 | -0 | Added |
| `src/repositories/cancellation-notifications.repository.ts` | +177 | -0 | Added |
| `src/utils/jst-date.ts` | +63 | -0 | Added |
| `src/utils/sms.ts` | +36 | -0 | Added |
| `src/services/invoice.service.ts` | +223 | -109 | Modified |
| `src/services/cancellation-send.service.ts` | +64 | -80 | Modified |
| `src/services/cancellation.service.ts` | +78 | -4 | Modified |
| `src/services/notification.service.ts` | +48 | -10 | Modified |
| `src/services/webhook.service.ts` | +15 | -1 | Modified |
| `src/repositories/cancellations.repository.ts` | +40 | -1 | Modified |
| `src/constants/cancellation-status.ts` | +60 | -0 | Modified |
| `src/db/schema.ts` / `migrations/0023_*.sql` / `meta/_journal.json` | +90 | -0 | Added/Modified |
| `src/batch.ts` | +11 | -0 | Modified |
| `deploy-batch-ecs.sh` | +8 | -2 | Modified |
| `src/__tests__/**`（unit 4 / e2e 6 新規 + 既存更新） | +1691 | -21 | Added/Modified |

### admin

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/constants/cancellationNotifications.ts` | +220 | -0 | Added |
| `src/constants/cancellationNotifications.test.ts` | +270 | -0 | Added |
| `src/components/CancellationManagement.tsx` | +212 | -14 | Modified |
| `src/constants/cancellationStatus.ts` | +90 | -16 | Modified |
| `src/types/Cancellation.ts` | +40 | -0 | Modified |
| `src/utils/datetime.ts` | +2 | -1 | Modified |
| `src/components/__tests__/CancellationManagement.test.tsx` | +356 | -0 | Added |
| `e2e/cancellation.spec.ts` / `e2e/fixtures.ts` | +279 | -13 | Modified |

### user（サロンポータル）

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/components/ReminderInfoPopover.tsx` | +93 | -0 | Added |
| `src/constants/reminder.ts` | +5 | -0 | Added |
| `src/components/Dashboard.tsx` | +52 | -12 | Modified |
| `src/components/InvoiceList.tsx` | +43 | -10 | Modified |
| `src/types/index.ts` | +6 | -0 | Modified |
| `src/components/__tests__/*.test.tsx` / `e2e/*` | +395 | -32 | Modified |

## 指摘一覧

---

### [Code Quality] batch Lambda に TWILIO_* / API_BASE_URL が配備されない（prod 稼働経路が SMS 送信不能・dev のリンクが prod を向く）

- [x] 対応する

**ファイル:** `api/deploy-batch.sh:227`（未変更）／ `api/deploy-batch-ecs.sh:129`（変更あり）
**重要度:** High

**該当コード:**

```bash
# api/deploy-batch-ecs.sh — toBranch 側（変更後）: ECS 経路にだけ Twilio / API_BASE_URL を追加
   CREDENTIALS_KMS_KEY_ID: env.CREDENTIALS_KMS_KEY_ID || "",
   PAYOUT_NOTIFY_RECIPIENTS: env.PAYOUT_NOTIFY_RECIPIENTS || "",
+  // リマインド送信（GTSS-886 / send-billing-reminders）用: SMS（Twilio）と /pay 短縮 URL の生成に使う。
+  TWILIO_ACCOUNT_SID: env.TWILIO_ACCOUNT_SID || "",
+  TWILIO_PHONE_NUMBER: env.TWILIO_PHONE_NUMBER || "",
+  TWILIO_MESSAGING_SERVICE_SID: env.TWILIO_MESSAGING_SERVICE_SID || "",
+  API_BASE_URL: env.API_BASE_URL || "",
   CHROMIUM_EXECUTABLE_PATH: env.CHROMIUM_EXECUTABLE_PATH || "/usr/local/bin/chromium",
```

```bash
# api/deploy-batch.sh:227-250 — base/toBranch とも同一（未変更）。batch Lambda の environment は「全置換」
const vars = {
  NODE_ENV: env.DEPLOY_ENV,
  SENTRY_DSN: env.SENTRY_DSN || "",
  ...
  STRIPE_SECRET_KEY: env.STRIPE_SECRET_KEY || "",
  CREDENTIALS_KMS_KEY_ID: env.CREDENTIALS_KMS_KEY_ID || "",
  PAYOUT_NOTIFY_RECIPIENTS: env.PAYOUT_NOTIFY_RECIPIENTS || "",
  SALONBOARD_TRANSPORT: env.SALONBOARD_TRANSPORT || "http",
  ...
};   // ← TWILIO_ACCOUNT_SID / TWILIO_AUTH_TOKEN / TWILIO_PHONE_NUMBER /
     //   TWILIO_MESSAGING_SERVICE_SID / API_BASE_URL のいずれも無い
```

```bash
# 比較: api/deploy-api.sh:389-393 では API Lambda 側に env 別 API_BASE_URL と Twilio 一式を注入している
  API_BASE_URL: env.API_BASE_URL_ENV || "",     # prod=https://api.cancel.co.jp / dev=https://dev.api.cancel.co.jp
  TWILIO_ACCOUNT_SID: env.TWILIO_ACCOUNT_SID || "",
  TWILIO_AUTH_TOKEN: env.TWILIO_AUTH_TOKEN || "",
  TWILIO_PHONE_NUMBER: env.TWILIO_PHONE_NUMBER || "",
  TWILIO_MESSAGING_SERVICE_SID: env.TWILIO_MESSAGING_SERVICE_SID || "",
```

**問題:**
`send-billing-reminders` は `initClients()` 経由で Twilio クライアントを生成し、`generateReminderSmsContent` / `generateEmailContent` は `apiBaseUrl()` で `/pay` リンクを組み立てる。ところが **prod の定期バッチは現在 Lambda 経路で稼働中**（Issue 前提条件・`docs/tech/batch-jobs.md`）で、その `deploy-batch.sh` は `update-function-configuration --environment`（**全置換**）で上記 5 変数を一切入れない。結果:

1. `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` 不在 → `twilioClient.messages.create` が認証エラー。**SMS リマインドは全件 `failed` 記録のみで送られない**。仕様上「送信失敗のアラート・失敗一覧・絞り込みは設けない」ため、**誰も気づけないまま SMS 経路が丸ごと死ぬ**。
2. `API_BASE_URL` 不在 → `apiBaseUrl()` の既定 `https://api.cancel.co.jp` が使われ、**dev のリマインドメール／SMS が prod の決済リンクを指す**（H-1 の dev 実発火テストが誤った結果になる）。
3. CI（CodeBuild `ci_api`）には `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` / `TWILIO_MESSAGING_SERVICE_SID` が PARAMETER_STORE で既に注入済み（`buildspec.yml:13-15`）なので、`deploy-batch.sh` が受け渡していないだけ。
4. ECS 経路も `API_BASE_URL: env.API_BASE_URL || ""` としているが、CI では `API_BASE_URL` は CodeBuild に定義されていない（`deploy-api.sh` が環境名から自前計算している）。**ECS 経路でも dev のリンクが prod を向く**。

**修正提案:**
- `deploy-batch.sh` の `vars` に `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` / `TWILIO_PHONE_NUMBER` / `TWILIO_MESSAGING_SERVICE_SID` / `API_BASE_URL` を追加する。`API_BASE_URL` は `deploy-api.sh:147-153` と同じく環境名から `dev.api` / `api` を出し分ける（`API_BASE_URL_ENV` 相当の計算を共通化するのが望ましい）。
- `deploy-batch-ecs.sh` も `env.API_BASE_URL` 素通しではなく環境名から計算する。
- prod デプロイ前ガード（AURORA_* と同様）に「Twilio 3 点が空なら中断」を足し、設定欠落で静かに SMS が死ぬのを防ぐ。
- `docs/tech/batch-jobs.md` の「依存」節が ECS 経路のみに言及しているため、Lambda 経路も明記する。

---

### [Security] webhook の `client_reference_id` フォールバックが Connect アカウント・金額・支払状態を照合していない

- [x] 対応する

**ファイル:** `api/src/services/webhook.service.ts:87`
**重要度:** High

**該当コード:**

```javascript
// baseBranch 側（変更前）
      try {
        // セッション ID から請求書を検索
        const invoice = await cancellationsRepo.findByStripeSessionId(session.id);

        if (!invoice) {
          console.log('No invoice found for Stripe session:', session.id);
        } else if ((await applicationsRepo.getById(invoice.applicationId))?.deletedAt) {
```

```javascript
// toBranch 側（変更後）
      try {
        // セッション ID から請求書を検索
        let invoice = await cancellationsRepo.findByStripeSessionId(session.id);

        // GTSS-886 / REQ-4: セッション ID で特定できない場合は client_reference_id（請求 ID）で
        // フォールバック突合する。/pay の失効時再発行が同時アクセスで競合した場合、保存されなかった側の
        // セッションで決済され得るため、その着金を取り逃さない（実在しない ID なら getById が null）。
        if (!invoice && session.client_reference_id) {
          invoice = await cancellationsRepo.getById(session.client_reference_id);
          if (invoice) {
            console.log(
              'checkout.session.completed: matched by client_reference_id:',
              invoice.id,
              '(session:', session.id, ')',
            );
          }
        }
```

**問題:**
署名検証が保証するのは「Stripe が発行した本物のイベントであること」だけで、「そのセッションを **当社が** 発行したこと」ではない。`payout.*` を購読している以上、本エンドポイントには **連結アカウント（サロン）由来の Connect イベント** も届く。突合キーを `client_reference_id` に広げたことで、突合成立の条件が「当社が発番した `cs_...`（推測不能）を知っていること」から「**請求 ID を知っていること**」へ緩和された。請求 ID は `inv_${Date.now()}` / `cancellation_${Date.now()}` と時刻由来で推測可能（Issue 技術的考慮事項 #9 で既知）。

このため、自アカウントで API/ダッシュボードを操作できる連結サロンが `client_reference_id` に他社の請求 ID を入れた Checkout Session を作り、**1 円でも決済すれば**、突合後の処理は `paidAmount: invoice.amount`（＝DB の請求額）で `markPaidIfNotPaid` と `monthly_sales` 加算まで走る。`stripeEvent.account` も `session.amount_total` も `currency` も `payment_status` も見ていない。

**修正提案:**
`client_reference_id` 経路には最低限の整合チェックを付ける（セッション ID 経路にも入れて損はない）:

```javascript
if (!invoice && session.client_reference_id) {
  const candidate = await cancellationsRepo.getById(session.client_reference_id);
  const accountMatches = !stripeEvent.account || stripeEvent.account === candidate?.stripeAccountId;
  const amountMatches = session.amount_total === candidate?.amount && session.currency === 'jpy';
  if (candidate && accountMatches && amountMatches && session.payment_status === 'paid') {
    invoice = candidate;
  } else if (candidate) {
    console.warn('client_reference_id fallback rejected (account/amount/payment_status mismatch)');
  }
}
```

不一致ケース（別アカウント／金額違い／`payment_status !== 'paid'`）の統合テストを追加する。

---

### [Security] 旧 `POST /cancellations` のマスアサインメントで `applicationId` と `firstSentAt` を注入でき、リマインド発火経路になる

- [x] 対応する

**ファイル:** `api/src/services/cancellation.service.ts:314`（該当行自体は未変更）／ `api/src/db/schema.ts:389`（`first_sent_at` 追加）
**重要度:** High

**該当コード:**

```typescript
// baseBranch / toBranch とも同一（この関数は本 PR では未変更）
export const createCancellation = async (event, cancellationData, corsHeaders) => {
  const authCheck = await requireAuth(event, corsHeaders);
  if (authCheck.error) return authCheck.response;
  try {
    const cancellationId = `cancellation_${Date.now().toString()}`;
    const now = new Date();
    const cancellation = {
      id: cancellationId,
      applicationId: authCheck.decoded.application_id,       // ← この後のスプレッドで上書き可能
      createdByApplicationUserId: authCheck.decoded.sub,     // ← 同上
      ...cancellationData,                                    // ← 任意の列を注入できる
      customerName: cancellationData?.customerName || '',
      customerEmail: cancellationData?.customerEmail || '',
      customerPhone: cancellationData?.customerPhone || '',
      status: 'pending',
      createdAt: now.toISOString(),
```

```typescript
// toBranch 側（変更後）— first_sent_at が cancellations の列として追加され、toRow が透過的に保存する
+    // 初回送信の試行日時（GTSS-886 / REQ-3）。成否を問わず送信試行時に記録し、リマインドの起算日に使う。
+    // リリース前に送信済みの請求は NULL のまま＝リマインド対象外（遡及適用なしの実装フック）。
+    firstSentAt: text('first_sent_at'),
```

**問題:**
スプレッドが所有者キーより後ろにあるためマスアサインメント自体は既存の弱点だが、本 PR で `first_sent_at` が追加されたことで **新しい実害** が生まれた。認証済みサロンユーザーが

```json
POST /cancellations
{ "applicationId": "<他社の app id>", "firstSentAt": "<8日前>", "dueDate": "2026-12-31",
  "amount": 50000, "customerPhone": "<任意の番号>", "notificationMethod": "sms" }
```

を送ると、`status: 'pending'` / `first_sent_at` あり / 期日内 の行ができる。これは `findReminderTargets` の抽出条件（`status='pending'` かつ `first_sent_at IS NOT NULL` かつ `due_date >= today`）を満たすため、**翌日の正午バッチが、他社サロン名義で、攻撃者が指定した宛先へ SMS／メールを送る**。Stripe アカウントも `shops` マスタも不要で、1 レコードにつき 2 通。

さらに悪いのは本文で、`billing-reminder.service.ts:163-176` が組み立てる `invoiceData` の `shopName` / `staffName` / `customerName` は**注入された行の値をそのまま使う**ため、`generateReminderSmsContent`（`notification.service.ts:359-380`）の差出人行・宛名に**任意テキストが入る**。「文面は全サロン・全請求で共通・変更不可」という法的建付けの中核が、この経路だけ破れる。

あわせて Issue の技術的考慮事項 #12「レガシー作成経路で作られた請求は first_sent_at NULL のため自然にリマインド対象外となり整合する」という前提が **成立していない**。

**修正提案:**
- UI 未使用の経路なのでルート自体を削除するのが最短。残すなら入力 DTO を allowlist 化し、`id` / `applicationId` / `createdByApplicationUserId` / `status` / `firstSentAt` / `stripe*` / `paidAt` / `external*` はサーバー値のみ（`firstSentAt` は必ず未設定）にする。
- 併せて `toRow` に「クライアント入力から入ってはいけない列」のガードを置くと他経路の再発も防げる。
- 統合テスト: 別 `applicationId` と任意 `firstSentAt` の注入が拒否されること、注入行がリマインド対象に入らないこと。

---

### [Code Quality] `/pay` の失効時再発行に TOCTOU があり、再発行中に支払済／取消済になっても有効セッションへ 302 する

- [x] 対応する

**ファイル:** `api/src/services/invoice.service.ts:465-469, 538-551`
**重要度:** High

**該当コード:**

```typescript
// baseBranch 側（変更前）— 保存済み URL へ無条件 302 するだけ（状態・期日ゲート無し）
export const payRedirect = async (invoiceId, corsHeaders) => {
  ...
    const item = await cancellationsRepo.getById(invoiceId);
    if (!item || !item.stripePaymentUrl) {
      return paySimpleHtml(404, 'お支払いリンクが見つかりません。…');
    }
    return { statusCode: 302, headers: { Location: item.stripePaymentUrl }, body: '' };
```

```typescript
// toBranch 側（変更後）— ゲートは冒頭の 1 回だけ、条件付き更新は旧 sessionId のみを見る
    const now = new Date();
    const status = normalizeCancellationStatus(item.status);
    if (status !== CANCELLATION_STATUS.PENDING || isPastDueJst(item.dueDate, now)) {
      return paySimpleHtml(200, PAY_UNAVAILABLE_MESSAGE);
    }
    ...
    const { session: newSession } = await createCancellationCheckoutSession({ ... });   // ← 最大 8s の外部通信

    // 条件付き更新（先勝ち）: 保存済みセッションが retrieve 時点から変わっていない場合のみ差し替える。
    const updated = await cancellationsRepo.updateSessionIfUnchanged(item.id, item.stripeSessionId, {
      stripeSessionId: newSession.id,
      stripePaymentUrl: newSession.url,
    });
    if (updated) {
      return payRedirect302(newSession.url);
    }
    const latest = await cancellationsRepo.getById(item.id);
    return payRedirect302(latest?.stripePaymentUrl || newSession.url);   // ← 状態を再確認していない
```

**問題:**
ゲート評価から `updateSessionIfUnchanged` までの間に、`retrieve` + `createJaCustomer` + `sessions.create` の外部通信（最大 8s × 3）が入る。この窓の間に

- webhook が `paid` にした → 条件付き更新は `stripeSessionId` しか見ないので成功し、**支払済みの請求に対して有効な決済セッションを発行して 302 する＝二重決済**。2 回目の着金は `markPaidIfNotPaid` が 0 行になるため `paidAt` も `monthly_sales` も更新されず、**記録に残らない入金**になる。
- 管理画面が `canceled` にした（このとき既存セッションは expire されるが、新しく作ったセッションは残る）→ 取消済み請求が決済可能なまま残る。

`!updated` の分岐も最新行の `status` / `dueDate` を再確認せず保存 URL へ 302 している。

**修正提案:**
- `updateSessionIfUnchanged` の `WHERE` に `status = 'pending'`（と可能なら期日条件）を足し、CAS を「セッション ID かつ状態」で行う。
- 更新に失敗したら最新行を取り直して状態・期日ゲートを**再評価**し、決済不可なら新規作成したセッションを best-effort で `expire` して案内 HTML を返す。
- 統合テスト: 再発行中に `paid` / `canceled` へ遷移する競合ケース。

---

### [Code Quality] 管理画面の「送信した文面」再構成が、実送信時のサロン名解決順と一致しない

- [x] 対応する

**ファイル:** `admin/src/constants/cancellationNotifications.ts:130`
**重要度:** High

**該当コード:**

```typescript
// toBranch 側（新規）— admin の再構成が使う解決順
const resolveSalonName = (invoice: Invoice): string =>
  invoice.storeName || invoice.companyName || invoice.shopName || 'サロン';

const resolveCustomerName = (invoice: Invoice): string => invoice.customerName || 'お客様';

const senderLine = (salonName: string, staffName: string): string =>
  staffName ? `${salonName} ${staffName}です。` : `${salonName}です。`;
```

```typescript
// 対比: api/src/services/billing-reminder.service.ts:163-176 — 実送信時の解決順（cancellation のスナップショット最優先）
      const invoiceData = {
        shopName:
          target.shopName ||                    // ← cancellations.shop_name（作成時のスナップショット）
          resolvedShop?.shopName ||             // ← shops マスタ（現在値）
          application?.partnerName ||
          application?.businessName ||
          '',
```

```typescript
// 対比: api/src/repositories/cancellations.repository.ts:53-59 — admin 一覧レスポンスの整形
const toAdminListDomain = (r: any) => {
  const companyName = r.partnerName || r.businessName || '不明';
  return {
    ...toDomain(r.c),
    shopName: companyName,        // ← cancellations.shop_name（スナップショット）を会社名で上書き
    companyName,
    storeName: r.storeName || null,   // ← shops.shop_name（現在値）
```

**問題:**
実送信は **`cancellations.shop_name`（作成時のスナップショット）を最優先**するのに対し、admin の再構成は **`storeName`（`shops` マスタの現在値）を最優先**する。しかも admin 一覧レスポンスでは `shopName` がスナップショットではなく会社名で上書きされるため、**スナップショット値は admin へ一切返っていない**。

- 店舗名を後から変更した／店舗を削除した請求 → 実際には旧名で送っているのに、画面には新名（または会社名）の文面が「送信した文面」として表示される。
- `shopId` 未設定（手動作成の旧データ等）で `shopName` スナップショットだけある請求 → `storeName` が null になり会社名にフォールバックし、送っていない文面が出る。

REQ-3 は「文面は記録されたテンプレートバージョンから再構成して表示する（文面は全請求共通のため再構成で同一性が担保される）」と定めており、この機能の目的は非弁行為リスクに対する**法的証跡**。同一性が担保されないなら証跡としての価値を失う。

**修正提案:**
- admin 一覧・詳細レスポンスに、送信時に使った解決済みサロン名を専用フィールド（例 `notificationSalonName`）として API から返し、再構成はそれだけを使う。最小変更なら `toAdminListDomain` でスナップショットを潰さず `snapshotShopName` として併せて返し、admin 側の `resolveSalonName` を送信側と同じ優先順（スナップショット → storeName → 会社名）に揃える。
- テスト: `cancellations.shop_name` と `shops.shop_name` が異なる請求で、再構成文面がスナップショット側になること。
- あわせてメール本文の空行が 1 行ずれている（API `notification.service.ts:225-228` は `${payUrl}` の次に `${both ? '\n※ SMS…' : ''}` を置くため URL と注記の間に空行が入るが、admin は `lines.push` 連結で空行なし）。証跡の同一性を謳うならテキスト本文ビルダーを API 側へ切り出して共有するのが本筋。

---

### [Code Quality] 新規 repository だけ `normalizeTimestamps` を通しておらず、送信履歴の日時が local/test では `-`・dev/prod では 9 時間ずれる

- [x] 対応する

**ファイル:** `api/src/repositories/cancellation-notifications.repository.ts:14-19, 149-164`
**重要度:** High

**該当コード:**

```typescript
// toBranch 側（新規）— toDomain が生値をそのまま返す。normalizeTimestamps を import すらしていない
import { randomUUID } from 'crypto';
import { eq, inArray, sql } from 'drizzle-orm';
import { getDb } from '../clients';
import { cancellationNotifications } from '../db/schema';

const toDomain = (row: any) => {
  if (!row) return null;
  const out: Record<string, any> = {};
  for (const [k, v] of Object.entries(row)) if (v !== null && v !== undefined) out[k] = v;
  return out;                       // ← 既存 8 repo は return normalizeTimestamps(out, TS);
};
```

```typescript
// 対比: api/src/repositories/shops.repository.ts:30-34（既存の作法）
const TS = timestamptzKeys(shops);
const toDomain = (row: any) => {
  ...
  return normalizeTimestamps(out, TS);
};
```

```typescript
// 対比: api/src/db/timestamps.ts:3-9 — 形式差がリポジトリ内に明文化されている
//   - node-postgres（local/test）: '2026-05-01 00:00:00+00'（オフセット付き）
//   - aws-data-api（dev/prod Lambda）: '2026-05-01 00:00:00'（オフセットなし naive。RDS Data API は
//     セッション TZ=UTC で返す）
export const parseDbTimestamp = (value: string): Date => {
  const s = String(value).trim();
  const iso = /[zZ]$|[+-]\d{2}(:?\d{2})?$/.test(s) ? s : `${s.replace(' ', 'T')}Z`;   // ← オフセット 4 桁は optional
  return new Date(iso);
};
```

```typescript
// 対比: admin/src/utils/datetime.ts:21-35 ／ user/src/utils/datetime.ts:21-33 — 4 桁必須で '…+00' に不一致
  if (/[zZ]$|[+-]\d{2}:?\d{2}$/.test(s)) {          // ← '+00' は 2 桁なのでマッチしない
    const d = new Date(s);
    return Number.isNaN(d.getTime()) ? null : d;
  }
  const m = s.match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[T\s]+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$/);
  if (!m) return null;
  ...
  const iso = `${y}-${p2(mo)}-${p2(day)}T${p2(h)}:${p2(mi)}:${p2(sec)}+09:00`;   // ← オフセット無しは JST 壁時計と解釈
```

**問題:**
`cancellation_notifications` は `sent_at` / `created_at` を timestamptz（`mode:'string'`）で持つ（`schema.ts:496-499`）。リポジトリには **`src/db/timestamps.ts` という専用ヘルパがあり、ドライバごとの生文字列の差までヘッダコメントに明記されている**。timestamptz を持つ既存 8 repository（shops / payout-runs / external-import-runs / external-import-logs / shop-integrations / external-integrations / external-integration-settings / application-deletion-backups）は全て `toDomain` で `normalizeTimestamps` を適用しているが、**本 PR の新規 repository だけ未適用**（`grep -c normalizeTimestamps` = 0）。集約クエリ `aggregatesByCancellationIds`（`:149-164`）の `lastReminderSentAt` は `toDomain` すら通らないので同様。

結果として、フロントの `toJstInstant` に渡る値が環境ごとに壊れる:

| 環境 | 生値 | フロントの解釈 | 表示 |
|---|---|---|---|
| local / test（node-postgres） | `'2026-06-08 03:00:00+00'` | 第 1 分岐は 4 桁必須で不一致 → 第 2 分岐も末尾 `+00` で `$` に届かず → null | **常に `-`**（送信済みでも空欄） |
| dev / prod（aws-data-api） | `'2026-06-08 03:00:00'` | 第 2 分岐にマッチし naive を **JST 壁時計**として +09:00 補完 | **9 時間前倒し**（正午送信が「3:00」）。UTC 15:00 以降の記録は**日付が 1 日ずれる** |

影響先は admin 詳細モーダルの送信履歴タイムライン（`CancellationManagement.tsx:626`）、admin 一覧「リマインド送信日」（`:520`）、admin CSV 22 列目（`cancellationStatus.ts:297`）、portal 一覧「リマインド送信日」（`InvoiceList.tsx:613`）。**送信履歴の日時＝法的証跡そのものが壊れる**。`firstSentAt` は `cancellations` の text 列に `toISOString()` を書くため無事で、新テーブル由来の値だけが壊れるのがわかりにくい。

テストで出ない理由も明確: unit / Playwright fixture が全て正規化済み ISO（admin `CancellationManagement.test.tsx:759-761` / `e2e/cancellation.spec.ts:46-49`、portal `src/test/utils.tsx:106`）で、API 契約テストも `expect(hist.lastReminderSentAt).not.toBeNull()` と**形式を検証していない**（`reminder-response-contract.test.js:90`）。seed 値（`'2026-06-08T03:00:00.000Z'`）は既知なのだから具体値で固定すべき箇所で、`.claude/skills/vitest/lesson.md`「`expect.any(...)` / `toBeDefined()` は使わない（値がわかるなら `.toBe()`）」に照らしても弱い。**全テスト緑のまま dev/prod だけ壊れる**典型。

**修正提案:**
- `cancellation-notifications.repository.ts` の `toDomain` を既存 8 repo と同形にする:
  ```typescript
  import { normalizeTimestamps, timestamptzKeys } from '../db/timestamps';
  const TS = timestamptzKeys(cancellationNotifications);
  const toDomain = (row: any) => { ...; return normalizeTimestamps(out, TS); };
  ```
- `aggregatesByCancellationIds` は `toDomain` を通らないので `parseDbTimestamp(r.lastReminderSentAt).toISOString()` を明示適用する。
- 契約テストを `expect(hist.lastReminderSentAt).toBe('2026-06-08T03:00:00.000Z')` と具体値へ、`notifications[].sentAt` にも `toMatch(/Z$/)` を追加。Data API 形式文字列（naive）の unit を 1 本足す。
- 副次: admin / portal の `toJstInstant` の正規表現を API の `parseDbTimestamp` と揃える（`[+-]\d{2}(:?\d{2})?$`）と防御が二重になる。ただし naive を JST とみなす既存仕様はサロンボード生値に必要なので、**フロント側だけの修正では dev/prod は直らない**（API 側の正規化が本命）。

---

### [Code Quality] `notificationMethod` に whitelist 検証が無く、API から実質的な「個別のリマインド停止」ができる

- [x] 対応する

**ファイル:** `api/src/services/invoice.service.ts:141-150`（未変更）／ `api/src/services/billing-reminder.service.ts:74-88`（新規）
**重要度:** Medium

**該当コード:**

```typescript
// api/src/services/invoice.service.ts:141-150（base / toBranch とも同一）
    let notificationMethod = invoiceData.notificationMethod;   // ← クライアント入力をそのまま採用
    if (!notificationMethod) {
      if (hasEmail && !hasPhone) {
        notificationMethod = 'email';
      } else if (hasPhone && !hasEmail) {
        notificationMethod = 'sms';
      } else {
        notificationMethod = 'both';
      }
    }
```

```typescript
// api/src/services/billing-reminder.service.ts:74-88（新規）— 記録値をそのまま踏襲する
const resolveChannels = (target: any): { notificationMethod: string; channels: string[] } => {
  const customerEmail = (target.customerEmail || '').trim();
  const customerPhone = (target.customerPhone || '').trim();
  const notificationMethod =
    target.notificationMethod ||
    (customerEmail && customerPhone ? 'both' : customerEmail ? 'email' : 'sms');
  const channels: string[] = [];
  if ((notificationMethod === 'email' || notificationMethod === 'both') && customerEmail) channels.push('email');
  if ((notificationMethod === 'sms' || notificationMethod === 'both') && customerPhone) channels.push('sms');
  return { notificationMethod, channels };
};
```

**問題:**
`createInvoice` の入力検証は「メールか電話のどちらかがある」ことだけで、`notificationMethod` の値は検証していない。サロンが

- `{ customerPhone: "090-…", notificationMethod: "email" }`（連絡先と方法が食い違う）
- `{ ..., notificationMethod: "none" }`（enum 外の任意文字列）

を送ると、請求は作成され `firstSentAt` も記録されるが送信チャネルは 0 件。リマインドバッチ側も毎回 `channels.length === 0` で `continue` するため、**初回もリマインドも永久に送られない請求**を作れる。これは Issue が法的建付けの必須要件として掲げる「サロン・運営いずれにも個別の停止機能を設けない（設計上存在しないこと自体が要件）」を API 経由で回避できることを意味する。

**修正提案:**
- `notificationMethod` を `email | sms | both` の whitelist で検証し、選択チャネルに必要な連絡先が無ければ 400 を返す（または連絡先の有無から正規化して入力を信用しない）。同じ検証を `POST /cancellations` 系にも適用する。
- バッチ側の `channels.length === 0` は「起こり得ない状態」として warn ログを出す（黙って continue しない）。
- E2E: 不正値・連絡先不整合の 400、および既存不整合データが warn とともに検知されること。

---

### [Code Quality] `finalize(success)` の DB 失敗が catch に落ち、実際には配信済みの通知が `failed` として記録される

- [x] 対応する

**ファイル:** `api/src/services/billing-reminder.service.ts:190-218`
**重要度:** Medium

**該当コード:**

```typescript
// toBranch 側（新規）
          try {
            const emailContent = generateEmailContent(...);
            const sesResult = await sesClient.send(new SendEmailCommand({ ... }));   // ← 配信は成功
            await cancellationNotificationsRepo.finalize(claim.id, {                 // ← ここで DB 例外が出ると
              status: 'success',
              providerMessageId: sesResult?.MessageId ?? null,
              sentAt: new Date().toISOString(),
            });
            summary.byRound[roundKey].email.success += 1;
            summary.remindersSent += 1;
          } catch (e) {
            console.error('[billing-reminders] SES error:', target.id, sanitizeNotificationError(e));
            await cancellationNotificationsRepo.finalize(claim.id, {                 // ← failed として上書き
              status: 'failed',
              ...sanitizeNotificationError(e),
              sentAt: new Date().toISOString(),
            });
            summary.byRound[roundKey].email.failed += 1;
          }
```

**問題:**
プロバイダ呼び出しと履歴確定が同じ `try` に入っているため、**成功 finalize だけが DB エラーになった場合**（Aurora のオートポーズ復帰中・一時的な接続断など。dev/prod は ACU 0 運用）、catch が同じ `claim.id` を `failed` へ上書きする。実際にはお客様へ配信済みなのに、管理画面の送信履歴・集計ログ・法的証跡は「失敗」と記録される。SMS 側（`src/services/billing-reminder.service.ts:233-251`）も同じ構造。

**修正提案:**
- プロバイダ呼び出しの `try` と履歴確定の `try` を分離し、配信結果（success/failed）を先に確定させてから finalize する。finalize 自体が失敗した場合は `failed` へ倒さず、ログ（+ Sentry）に残して `processing` のまま残す（回単位判定では「試行済み」なので二重送信は起きない）。
- テスト: finalize の DB 例外を注入し、`status` が `failed` にならないこと。

---

### [Performance] リマインド対象抽出が経過日数で絞られず、1 件ごとに追加クエリを投げる（N+1）

- [x] 対応する

**ファイル:** `api/src/repositories/cancellations.repository.ts:293-307`（新規）／ `api/src/services/billing-reminder.service.ts:130-141`（新規）
**重要度:** Medium

**該当コード:**

```typescript
// api/src/repositories/cancellations.repository.ts:293-307（新規）
  findReminderTargets: async (todayJst: string, db: any = getDb()) => {
    const rows = await db
      .select({ c: cancellations, application: applications })
      .from(cancellations)
      .leftJoin(applications, eq(cancellations.applicationId, applications.applicationId))
      .where(
        and(
          eq(cancellations.status, 'pending'),
          isNotNull(cancellations.firstSentAt),
          or(isNull(cancellations.dueDate), gte(cancellations.dueDate, todayJst)),
        ),
      )
      .orderBy(cancellations.firstSentAt, cancellations.id);
    return rows.map((r: any) => ({ ...toDomain(r.c), application: r.application }));
  },
```

```typescript
// api/src/services/billing-reminder.service.ts:130-142（新規）
  for (const target of targets) {
    try {
      if (target.application?.deletedAt) continue;

      const round = decideReminderRound({
        status: target.status,
        firstSentAt: target.firstSentAt,
        dueDate: target.dueDate,
        attemptedRounds: await cancellationNotificationsRepo.findAttemptedRounds(target.id),  // ← 1 件 1 クエリ
        now,
      });
      if (!round) continue;
```

**問題:**
抽出条件に「経過 7 日以上」が入っていないため、**リリース後に送信された未払い・期日内の請求すべて**（＝ほとんどが対象外の 0〜6 日目）を毎日取得し、その全件に対して `findAttemptedRounds` を 1 本ずつ発行する。dev/prod は RDS Data API でクエリ 1 本あたりの往復コストが大きく、件数が伸びるほど無駄が線形に増える。部分インデックス `cancellations_reminder_target_idx (first_sent_at, due_date)` も、`first_sent_at` に範囲述語が無いため先頭列を絞れず走査になる。

**修正提案:**
- `WHERE` に `first_sent_at < (today - 7日)` 相当の範囲条件を足す（インデックス先頭列が効く）。
- `findAttemptedRounds` をループ外へ出し、抽出した ID 群に対する 1 本の `GROUP BY cancellation_id` で取得して Map 化する（`aggregatesByCancellationIds` と同じ形）。

---

### [Performance] 管理画面一覧が全件 ID の `inArray` を 2 本投げる（集約＋履歴明細）

- [x] 対応する

**ファイル:** `api/src/services/cancellation.service.ts:71-89`
**重要度:** Medium

**該当コード:**

```typescript
// baseBranch 側（変更前）
    const cancellationsWithShopInfo = applicationId
      ? await cancellationsRepo.findAllWithShopByApplicationId(applicationId)
      : await cancellationsRepo.findAllWithShop();
    // status SSOT 化（GTSS-817）: 各行に statusLabel を付与し status を canonical 化（sent→pending 等）。
    const serialized = cancellationsWithShopInfo.map((c: any) => serializeCancellation(c));
```

```typescript
// toBranch 側（変更後）
    const withAgg = await withDeliveryAggregates(cancellationsWithShopInfo);        // ← inArray(全件 ID)
    const details = await cancellationNotificationsRepo.findByCancellationIds(
      withAgg.map((c: any) => c.id).filter(Boolean),                                 // ← inArray(全件 ID)
    );
    const detailsById = new Map<string, any[]>();
    for (const n of details) {
      const list = detailsById.get(n.cancellationId) ?? [];
      list.push(n);
      detailsById.set(n.cancellationId, list);
    }
    const serialized = withAgg.map((c: any) => ({
      ...serializeCancellation(c),
      notifications: detailsById.get(c.id) ?? [],
    }));
```

**問題:**
`findAllWithShop()` はページングが無く全件を返す（既存仕様）。そこへ **全件の ID を `IN (...)` に並べたクエリを 2 本**追加し、さらに 1 請求あたり最大 6 行の明細をレスポンスへ載せている。N+1 ではないが、dev/prod は RDS Data API 駆動で **1 クエリの応答サイズ上限が 1 MiB**。件数増加に伴い明細クエリが先に上限へ当たり、**管理画面のキャンセル請求一覧が丸ごと 500 になる**成長パスがある。本機能で `cancellation_notifications` は請求数の最大 6 倍のペースで増えるため、上限到達は加速する。

**修正提案:**
- 履歴明細（`notifications[]`）は詳細 `GET /cancellations/:id` に限定する。admin UI が現在は一覧レスポンスだけを使っているため（[Discovery] コメント参照）、詳細モーダルを開いたときに `GET /cancellations/:id` を叩く形へ寄せるのが本筋。
- 集約値（`deliveryRound` / `lastReminderSentAt`）は `inArray(全件 ID)` をやめ、`cancellations` への `LEFT JOIN`（集約サブクエリ）にして 1 本にまとめる。

---

### [Code Quality] 管理画面の楽観更新が `canceled`/`failed` → `pending` で `isExpired` を更新しない

- [x] 対応する

**ファイル:** `admin/src/components/CancellationManagement.tsx:216-228`
**重要度:** Medium

**該当コード:**

```typescript
// baseBranch 側（変更前）
      const newLabel = getStatusLabel(newStatus)
      setInvoices(prev => prev.map(c => c.id === invoiceId ? { ...c, status: newStatus, statusLabel: newLabel } : c))
      if (selectedInvoice?.id === invoiceId) {
        setSelectedInvoice(prev => prev ? { ...prev, status: newStatus, statusLabel: newLabel } : null)
      }
```

```typescript
// toBranch 側（変更後）
      // 期限切れ（未回収）は「請求中かつ期日超過」の派生値なので、請求中から外れた時点で必ず解除する
      // （取消しても期限切れバッジが残るのを防ぐ。GTSS-886 / AC-6.3）。
      const newLabel = getStatusLabel(newStatus)
      const patch = (c: Invoice): Invoice => ({
        ...c,
        status: newStatus,
        statusLabel: newLabel,
        isExpired: newStatus === 'pending' ? c.isExpired : false,   // ← pending へ「戻す」ケースが漏れる
      })
      setInvoices(prev => prev.map(c => c.id === invoiceId ? patch(c) : c))
```

**問題:**
`pending → canceled/failed`（AC-6.3 が想定する向き）は正しいが、**逆向き**が抜けている。期日超過済みの請求を `canceled`/`failed` から `pending` へ戻すと、サーバーは `isExpired=true` を返すのに画面は `false` のまま残る。バッジ・サマリーカードの排他集計・フィルタ・詳細モーダルの「決済リンク（有効／失効）」がリロードまで食い違う。`ApiService.updateCancellationStatus` はレスポンス（正しい `isExpired` を含む）を受け取っているが `Promise<void>` として捨てている。

**修正提案:**
更新 API のレスポンスをそのままマージする（`statusLabel` / `isExpired` を含む）か、成功後に一覧を再取得する。テスト: 期日超過の `canceled → pending` で期限切れバッジが復活すること。

---

### [Code Quality] 送信履歴タイムラインが、欠番回・確定終了した請求にも「（過去日時）送信予定」を表示する

- [x] 対応する

**ファイル:** `admin/src/constants/cancellationNotifications.ts:94-112`／ `admin/src/components/CancellationManagement.tsx:628-630`
**重要度:** Medium

**該当コード:**

```typescript
// admin/src/constants/cancellationNotifications.ts:94-112（新規）— 回ごとに独立して sent/scheduled を決める
  return NOTIFICATION_ROUNDS.map((round) => {
    const notifications = all
      .filter((n) => n.round === round)
      .sort((a, b) => (CHANNEL_ORDER[a.channel] ?? 99) - (CHANNEL_ORDER[b.channel] ?? 99));
    const sent = notifications.length > 0 || round === 1;
    ...
    return {
      round, label: NOTIFICATION_ROUND_LABELS[round], sent, sentAt,
      scheduledLabel: sent ? null : reminderScheduledLabel(invoice.firstSentAt, offset),   // ← 無条件に予定日を出す
      notifications,
    };
  });
```

```tsx
// admin/src/components/CancellationManagement.tsx:628-630（新規）
                          <span className="text-sm text-gray-600">
                            {entry.sent ? formatJstDateTime(entry.sentAt) : `${entry.scheduledLabel ?? '-'} 送信予定`}
                          </span>
```

```typescript
// 対比: api/src/services/billing-reminder.service.ts:64-69 — 2 通目欠番は仕様として明示的に許容されている
  if (isPastDueJst(dueDate, now)) return null;
  const elapsed = daysBetweenJst(firstSentAt, now);
  const attempted = new Set(attemptedRounds);
  if (elapsed >= 14) return attempted.has(3) ? null : 3;     // ← 2 通目未送信でも 3 通目のみ送る（欠番）
  if (elapsed >= 7) return attempted.has(2) ? null : 2;
```

**問題:**
`scheduledLabel` は `firstSentAt + 7日 / 14日 の正午` を無条件に計算するため、

- **欠番ケース**（REQ-1 が明示的に許容する「2 通目が未送信のままでも 3 通目のみを送る」）: round 2 の行が永久に「2026/6/8 12:00 送信予定」と**過去日時の予定**として残る。実際には二度と送られない。
- **確定終了した請求**（支払済・取消済・期限切れ）: 未送信の回が「送信予定」として表示され続ける。下に「支払済・取消済・期日超過のいずれかに該当した場合は送信されません」の注記はあるが、日時そのものが誤読を招く。

問い合わせ対応で「この日に送る予定です」と案内してしまうと実挙動と食い違う。既存テストは初回のみ送信済みのケースしか無く、欠番は未カバー。

**修正提案:**
- 実績のある最大回より小さい未送信回は「予定」ではなく「送信なし（欠番）」として表示する。
- 請求が `paid` / `canceled` / `isExpired` のときは残りの回を「送信されません」に倒し、予定日時を出さない。
- `buildNotificationTimeline` の unit に、欠番（round 3 のみ記録あり）と支払済のケースを追加する。

---

### [Code Quality] `createInvoice` の支払期日に下限バリデーションが無く、過去日を保存できる

- [x] 対応する

**ファイル:** `api/src/services/invoice.service.ts:185-201`
**重要度:** Medium

**該当コード:**

```typescript
// baseBranch / toBranch とも同一（本 PR は endOfNextMonthJst への差し替えのみ）
    const maxDueDateStr = endOfNextMonthJst(now);
    let dueDate = invoiceData.dueDate || '';
    if (!dueDate) {
      dueDate = maxDueDateStr;
    } else if (dueDate > maxDueDateStr) {          // ← 上限のみ。下限（過去日）は素通し
      return {
        statusCode: 400,
        headers: corsHeaders,
        body: JSON.stringify({
          success: false,
          error: `支払期限日は翌月末日（${maxDueDateStr}）以降には設定できません`
        })
      };
    }
```

**問題:**
本 PR で支払期日が「決済リンクの有効期限」「`/pay` の可否ゲート」「期限切れ（未回収）判定」「リマインド対象判定」をすべて握る値になった。過去日が保存できると、

- 作成直後から `isExpired: true`（顧客が受け取った瞬間に支払不可）。
- `computeSessionExpiresAt` が常に `now + 30分` の下限パスに落ちる（後述の Stripe 最小 30 分の問題を常時踏む）。
- リマインドは `isPastDueJst` で対象外。

という「作った瞬間に死んでいる請求」ができる。従来は期日が表示専用だったので実害が小さかったが、意味が変わった以上ガードを足すのが自然。

**修正提案:**
`dueDate < jstCalendarDate(now)` を 400 で弾く（メッセージは上限側と対称に）。unit で当日 OK / 前日 NG を固定する。

---

### [Code Quality] ⓘ ポップオーバーが開いた後の位置を追従せず、スクロール・リサイズでトリガーから離れる（admin / portal 共通）

- [x] 対応する

**ファイル:** `admin/src/components/CancellationManagement.tsx:103-111`／ `user/src/components/ReminderInfoPopover.tsx:22-52`
**重要度:** Medium

**該当コード:**

```typescript
// user/src/components/ReminderInfoPopover.tsx:22-33（新規）— 開いた瞬間に 1 回だけ実測
  const toggle = () => {
    if (isOpen) { setIsOpen(false); return; }
    const rect = buttonRef.current?.getBoundingClientRect();
    if (rect) {
      const maxLeft = Math.max(8, window.innerWidth - PANEL_WIDTH - 8);
      setPosition({ top: rect.bottom + 8, left: Math.min(Math.max(rect.left, 8), maxLeft) });
    }
    setIsOpen(true);
  };
  // useEffect（36-52行）は mousedown / keydown しか購読していない
```

```tsx
// admin/src/components/CancellationManagement.tsx:103-111（新規）— 同型。さらに Escape も左端クランプも無い
  const toggleRulePopover = () => {
    if (ruleOpen) { setRuleOpen(false); return; }
    const rect = ruleButtonRef.current?.getBoundingClientRect()
    if (rect) setRuleAnchor({ top: rect.bottom + 8, left: rect.left })
    setRuleOpen(true)
  }
```

**問題:**
パネルは `position: fixed`（テーブルの `overflow-x-auto` に切られないための妥当な選択）だが、位置は開いた瞬間の実測値で固定される。開いたままページを縦スクロール／テーブルを横スクロール／ウィンドウをリサイズすると、トリガーだけが動いてパネルが無関係な行の上に浮く。リサイズ時は `window.innerWidth` によるクランプも古いままになる。加えて admin 側は portal にある **Escape での閉止・左端クランプ・`aria-controls`** が無く、2 実装で挙動が揃っていない。縦方向のクランプ（`max-height` + `overflow-y-auto`）は両方とも無いため、画面下部で開くとパネル下部が読めない。

T-26 / T-27 は開いた直後のヒットテストのみなのでこの回帰を検出できない。

**修正提案:**
- `scroll`（`capture: true`）/ `resize` を購読して再配置するか、最低限「閉じる」。
- パネルに `max-height: calc(100vh - …)` + `overflow-y-auto` を付け、実寸から上下反転／クランプする。
- admin 側を portal の `ReminderInfoPopover` と同じ実装（Escape・クランプ・`aria-controls`）へ寄せ、共通コンポーネント化を検討する。
- 小さいビューポートの E2E でパネル全体が画面内に収まる（またはスクロール可能）ことを検証する。

---

### [Code Quality] メールの「リンク生成失敗」フォールバック文言が到達不能になり、リンク未発行でも決済リンクを載せる

- [x] 対応する

**ファイル:** `api/src/services/notification.service.ts:186, 195, 226`
**重要度:** Low

**該当コード:**

```javascript
// baseBranch 側（変更前）— Stripe セッション未発行なら案内文へ分岐した
    ${paymentLink ? `
    <p>▼お支払いはこちら</p>
    <p style="margin: 10px 0;"><a href="${paymentLink}" …>お支払いはこちら</a></p>
    <p style="font-size: 12px; color: #666; word-break: break-all;">${paymentLink}</p>
    ` : `
    <p style="color: #d32f2f;">申し訳ございません。お支払いリンクの生成に問題が発生しました。…</p>
    `}
```

```javascript
// toBranch 側（変更後）— payUrl は invoiceId があれば必ず真になる
  const payUrl = invoiceId ? `${apiBaseUrl()}/pay/${invoiceId}` : paymentLink;
  ...
    ${payUrl ? `
    <p>▼お支払いはこちら</p>
    <p style="margin: 10px 0;"><a href="${payUrl}" …>お支払いはこちら</a></p>
    <p style="font-size: 12px; color: #666; word-break: break-all;">${payUrl}</p>
    ` : `
    <p style="color: #d32f2f;">申し訳ございません。お支払いリンクの生成に問題が発生しました。…</p>
    `}
```

**問題:**
`invoiceId` は常に渡されるため `payUrl` は常に真となり、**else 側の案内文は到達不能**（text 版 `:226` も同じ）。`createInvoice` は Stripe セッション作成失敗時も処理を継続してメールを送る設計なので、その場合お客様は「お支払いはこちら」ボタンを踏んで `/pay/:id` の 404 案内（「お支払いリンクが見つかりません」）に着地する。従来はメール本文でサポート誘導していたので後退。

**修正提案:**
`payUrl` の分岐条件を `paymentLink || item.stripeSessionId` 相当（＝セッションが発行できたか）に変え、未発行時は従来どおりサポート案内を出す。SMS（`generateSmsContent`）も同じ構造なので併せて見直す。

---

### [Code Quality] `expires_at` の最小 30 分がセッション作成前の `now` 基準で、期日末 30 分以内の再発行が Stripe に拒否され得る

- [x] 対応する

**ファイル:** `api/src/services/checkout-session.service.ts:45-54, 96-114`
**重要度:** Low

**該当コード:**

```typescript
// toBranch 側（新規）
export const computeSessionExpiresAt = (dueDate: string | null | undefined, now: Date): number | undefined => {
  if (!dueDate) return undefined;
  const nowSec = Math.floor(now.getTime() / 1000);
  const dueEnd = dueDateEndOfDayJstEpochSeconds(dueDate);
  const clamped = Math.min(nowSec + SESSION_MAX_AGE_SECONDS, dueEnd);
  return Math.max(clamped, nowSec + SESSION_MIN_AGE_SECONDS);   // ← now は呼び出し元で先に採取済み
};
...
  const jaCustomerId = await createJaCustomer({ … });            // ← 外部通信（数百 ms〜数秒）
  ...
  const expiresAt = computeSessionExpiresAt(cancellation.dueDate, now);
  ...
  const session = await stripe.checkout.sessions.create(params, { … });   // ← さらに後
```

**問題:**
`now` は `payRedirect` 冒頭（`invoice.service.ts:465`）で採取され、`createJaCustomer` と `sessions.create` の通信を挟む。Stripe 側の時刻で見ると `expires_at` が「30 分後」を下回り、最小 30 分制約でセッション作成が拒否される可能性がある。発現するのは支払期日当日の 23:30 以降にリンクを開いたときのみで頻度は低いが、そのとき `/pay` は 500 になる。

**修正提案:**
`expires_at` は `sessions.create` の直前に `new Date()` から再計算し、通信・時計差ぶんの安全マージン（例 +60s）を持たせる。テストは期日当日 23:40 を固定時刻で再現する。

---

### [Code Quality] `/pay` の Stripe 例外がお客様のブラウザへ JSON 500 を返す

- [x] 対応する

**ファイル:** `api/src/services/invoice.service.ts:552-559`
**重要度:** Low

**該当コード:**

```javascript
// baseBranch 側（変更前）— Stripe を呼ばないため到達しにくかった
  } catch (error) {
    console.error('Error in payRedirect:', error);
    return { statusCode: 500, headers: corsHeaders, body: JSON.stringify({ error: 'Internal Server Error' }) };
  }
```

```typescript
// toBranch 側（変更後）— retrieve / create の失敗がそのままここへ落ちる
    const session = await stripe.checkout.sessions.retrieve(item.stripeSessionId, { … });
    ...
    const { session: newSession } = await createCancellationCheckoutSession({ … });
    ...
  } catch (error) {
    console.error('Error in payRedirect:', error);
    return {
      statusCode: 500,
      headers: corsHeaders,
      body: JSON.stringify({ error: 'Internal Server Error' })
    };
  }
```

**問題:**
`/pay/:id` はお客様がメール／SMS から直接ブラウザで開く URL。Stripe 側の一時障害・タイムアウト（8s）で、他の分岐がすべて HTML を返すのに対しここだけ生の JSON `{"error":"Internal Server Error"}` が表示される。

**修正提案:**
`paySimpleHtml(503, '現在お支払いページを表示できません。時間をおいて再度お試しください。')` のような HTML を返す（他分岐と体裁を揃える）。

---

### [Code Quality] ステータス更新レスポンスだけ配信集約（`deliveryRound` / `lastReminderSentAt`）が付かない

- [x] 対応する

**ファイル:** `api/src/services/cancellation.service.ts:491`
**重要度:** Low

**該当コード:**

```typescript
// 一覧（cancellation.service.ts:73）・詳細（同 386）は withDeliveryAggregates を通す
    const [withAgg] = await withDeliveryAggregates([item]);
    const body: Record<string, any> = { ...serializeCancellation(withAgg) };
```

```typescript
// toBranch 側（変更後）— 更新レスポンスだけ素の行を serialize する
    const updated = await cancellationsRepo.updateStatus(cancellationId, canonical);
    ...
    return {
      statusCode: 200,
      headers: corsHeaders,
      body: JSON.stringify(serializeCancellation(updated))   // ← deliveryRound / lastReminderSentAt が常に null
    };
```

**問題:**
送信履歴のある請求でも `deliveryRound` / `deliveryProgressLabel` / `lastReminderSentAt` が null で返る。現在の admin は更新レスポンスを使わずローカル patch しているため画面影響は無いが、上記「楽観更新の isExpired」を直してレスポンスをマージする方向にすると、この不整合が配信進捗の消失として顕在化する。

**修正提案:**
更新後の行にも `withDeliveryAggregates([updated])` を適用し、レスポンス契約テストを追加する（3 経路で同一 shape を保証する）。

---

### [Security] CSV 式インジェクションが未対策（既存由来・本 PR の改修対象内）

- [x] 対応する

**ファイル:** `admin/src/constants/cancellationStatus.ts:302-307`
**重要度:** Low

**該当コード:**

```typescript
// baseBranch / toBranch とも同一（本 PR は列追加のみ）
  const csvContent = [CANCELLATION_CSV_HEADERS, ...rows]
    .map((row) => row.map((cell) => `"${String(cell).replace(/"/g, '""')}"`).join(','))
    .join('\n');
  return bom + csvContent;
```

**問題:**
ダブルクォートのエスケープだけでは、Excel / Google スプレッドシートで `=` `+` `-` `@` で始まるセルが数式として評価されるのを防げない。CSV には顧客名・店舗名・担当者名・メールアドレスといった外部入力が含まれ、経理が日常的に開く運用。既存由来だが、本 PR が CSV を 22 列へ拡張し H-6 で経理の実取込確認を行うタイミングなので、同時に手当てするのが自然。

**修正提案:**
セルのエスケープを共通関数化し、先頭（先頭空白・タブを除去した後）が `= + - @` の場合に `'` を前置する。代表 4 文字＋先頭空白のテストを追加する。

---

### [Code Quality] ポータルのモバイルカードだけ支払期限に `createdAt + 30日` のフォールバックが残る（既存由来）

- [x] 対応する

**ファイル:** `user/src/components/InvoiceList.tsx:509-513`
**重要度:** Low

**該当コード:**

```tsx
// baseBranch / toBranch とも同一（モバイルカードは本 PR で未変更）
                          <p>支払期限: {invoice.dueDate ? formatDate(invoice.dueDate) : (() => {
                            const d = new Date(invoice.createdAt);
                            d.setDate(d.getDate() + 30);
                            return formatDate(d.toISOString());
                          })()}</p>
```

```tsx
// toBranch 側（変更後）— PC テーブルに新設した列は推定フォールバックを使わない
                        {/* 支払期日 / リマインド送信日は列では推定フォールバックを使わず、未設定は '-' のまま出す。 */}
                        <td className="px-4 py-4 whitespace-nowrap text-sm text-gray-500">{invoice.dueDate ? formatDate(invoice.dueDate) : '-'}</td>
```

**問題:**
支払期日が決済リンクの有効期限・期限切れ判定の基準になったことで、「期日未設定（＝期限切れ判定しない・リンクは期日ゲートも掛からない）」という状態の意味が重くなった。同じ請求について PC の新列は `-`、モバイルカードは実在しない期限（作成 +30 日）を表示するので、サロンが誤った期限を顧客に伝えかねない。同じ +30 日フォールバックは**詳細モーダルの「支払期限日」**（`user/src/components/InvoiceList.tsx:848-860`）にもある。REQ-6 が admin の初回送信日に「記録値のみ・推定表示しない」を課したのと同じ理由が、こちらにも当てはまる。

**修正提案:**
モバイルカードと詳細モーダルの両方を `invoice.dueDate ? formatDate(invoice.dueDate) : '-'`（または「未設定」）に揃える。`dueDate` 未設定でのモバイル表示テストを追加する。

---

### [Code Quality] ポータルの請求ステータスソートが生 `status` のままで、期限切れと請求中が混在する

- [x] 対応する

**ファイル:** `user/src/components/InvoiceList.tsx:321`
**重要度:** Low

**該当コード:**

```tsx
// toBranch 側（変更後）— 表示は isExpired 優先の仮想ステータスへ変わったが…
  const getStatusLabel = (invoice: Invoice) =>
    invoice.isExpired ? '期限切れ' : (invoice.statusLabel || getStatusText(invoice.status));
```

```tsx
// …ソートキーは生 status のまま（未変更）
        case 'status':
          aValue = a.status;
          bValue = b.status;
          break;
```

**問題:**
「請求ステータス」列でソートすると、`期限切れ` と `請求中` はどちらも `pending` なので同順位に混ざる。表示上のステータスで並べたい利用者の期待と食い違う。admin 側は該当列のソートが無いため影響なし。

**修正提案:**
ソートキーを表示ステータス（`isExpired ? 'expired' : status`）または明示的な順位表に統一し、期限切れ・請求中を混在させたソートテストを追加する。

---

### [Test Coverage] admin の Playwright fixture が実 API の派生ルールと矛盾する日付を持つ

- [x] 対応する

**ファイル:** `admin/e2e/cancellation.spec.ts:196`／ `admin/e2e/fixtures.ts:219-232`
**重要度:** Low

**該当コード:**

```typescript
// toBranch 側（新規）— 未指定なら isExpired=false を埋める
function serializeCancellationForMock(c: E2ECancellation): E2ECancellation {
  ...
  return {
    ...c,
    isExpired: c.isExpired ?? false,
    firstSentAt: c.firstSentAt ?? null,
```

```typescript
// toBranch 側（新規）— 「請求中」行の期日が現在日より前
      storeName: '新宿店', amount: 2000, dueDate: '2026-07-31T00:00:00.000Z',
```

**問題:**
`status: 'pending'` かつ `dueDate: 2026-07-31` の行は、実 API なら 2026-08-01 時点で `isExpired: true` を返す。fixture は `isExpired` を明示していないので `false` が入り、「請求中バッジ」を検証している。mock なのでテスト自体は決定的に通るが、**実 API が返さない組み合わせ**を受け入れテストにしてしまっている（Issue 技術的考慮事項 #10「テストの日付依存」の趣旨に反する）。

**修正提案:**
fixture の日付を固定基準日からの相対で組むか、全ケースで `isExpired` を実 API の導出ルールと一致するよう明示する。リリース前送信分（`firstSentAt: '2026-06-01'`）に送信履歴を持たせている行も、契約上は「履歴なし＝進捗 `-`」なので整合を取る。

---

### [Code Quality] `REMINDER_RELEASE_DATE_LABEL` が仮値のまま 2 リポジトリに重複定義されている

- [x] 対応する

**ファイル:** `admin/src/constants/cancellationStatus.ts:27`／ `user/src/constants/reminder.ts:5`
**重要度:** Low

**該当コード:**

```typescript
// admin/src/constants/cancellationStatus.ts（新規）
// 本機能（自動リマインド）のリリース日。これより前に送信した請求には送信記録が無く、
// 一覧の「初回送信日」「配信進捗」が「-」になる旨をポップオーバーで案内する。
// TODO: 本番リリース日確定時に更新
export const REMINDER_RELEASE_DATE_LABEL = '2026/08/01';
```

```typescript
// user/src/constants/reminder.ts（新規）
// TODO: 本番リリース日確定時に更新
export const REMINDER_RELEASE_DATE_LABEL = '2026/08/01';
```

**問題:**
利用者（運営・サロン）向けのポップオーバーに確定表示される日付が仮値。2 リポジトリに独立して置かれており、片方だけ更新される事故が起きやすい。テストも同じ仮値をハードコードしているため検出できない。

**修正提案:**
リリース手順に「両リポジトリの `REMINDER_RELEASE_DATE_LABEL` を実リリース日へ更新」を必須ゲートとして明記する（`[Completion]` の未対応事項には記載済みだが、コード側にも `TODO` 以上の仕掛けが欲しい）。ビルド時環境変数（`VITE_REMINDER_RELEASE_DATE`）にして未設定なら prod ビルドを失敗させるのが確実。なお更新点は実際には 7 箇所に分散している（portal: `constants/reminder.ts:5` / `InvoiceList.test.tsx:747` / `e2e/invoice.spec.ts:163`、admin: `cancellationStatus.ts:28` / `cancellationStatus.test.ts:163` / `CancellationManagement.test.tsx:623` / `e2e/cancellation.spec.ts:350`）。テストが定数を import すれば repo あたり 1 箇所へ収束する。

---

### [Code Quality] 送信に失敗した回にも「送信した文面を表示」が出る

- [x] 対応する

**ファイル:** `admin/src/components/CancellationManagement.tsx:645-651`／ `admin/src/constants/cancellationNotifications.ts:99`
**重要度:** Low

**該当コード:**

```typescript
// admin/src/constants/cancellationNotifications.ts:99（新規）— sent は「試行あり」であって「配信成功」ではない
    const sent = notifications.length > 0 || round === 1;
```

```tsx
// admin/src/components/CancellationManagement.tsx:645-651（新規）
                        {entry.sent && reconstructSentMessages(selectedInvoice, entry, API_BASE_URL).map((message) => (
                          <details key={`${entry.round}-${message.channel}`} className="mt-2">
                            <summary className="text-sm text-primary-600 cursor-pointer">送信した文面を表示（{message.channelLabel}）</summary>
```

**問題:**
`reconstructSentMessages` は `templateVersion` でしかフィルタしないため、`status: 'failed'` のチャネル（＝お客様には届いていない）でも「**送信した**文面を表示」として提示される。問い合わせ対応で「この文面をお送りしています」と誤って案内し得る。E2E（`e2e/cancellation.spec.ts:177`）が失敗回の文面表示を期待値として固定してしまっている点も含めて見直しが必要。

**修正提案:**
成功チャネルに限定するか、失敗回はラベルを「送信を試みた文面」に変える。

---

### [Code Quality] リマインド対象のスナップショットが実行開始時のみで、直列ループ中に支払われた請求へも送り得る

- [x] 対応する

**ファイル:** `api/src/services/billing-reminder.service.ts:126-154`
**重要度:** Low

**該当コード:**

```typescript
// toBranch 側（新規）
  const todayJst = jstCalendarDate(now);
  const targets = await cancellationsRepo.findReminderTargets(todayJst);   // ← ここで一括取得
  summary.targets = targets.length;

  for (const target of targets) {                                          // ← 以降は直列で数秒/件
    try {
      if (target.application?.deletedAt) continue;
      const round = decideReminderRound({
        status: target.status,                                             // ← 取得時点のスナップショット
        ...
      });
      if (!round) continue;
      ...
      const claimed = await cancellationNotificationsRepo.claimRound(target.id, round, channels, ...);
```

**問題:**
`decideReminderRound` が見る `status` / `dueDate` は抽出時点の値。1 件あたり数秒 × 直列なので、対象が数十件でも実行は数分に及ぶ。その間に webhook が `paid` にした請求へも「お支払いが確認できておりませんため、再度ご案内いたします」を送ってしまう。AC-1.2 の「支払済の請求にはリマインドが送信されない」を厳密には満たさない。

**修正提案:**
claim の直前に対象行を再読み込みして状態を再評価するか、`claimRound` を `WHERE status='pending'` 付きの条件付き insert（`INSERT ... SELECT`）にする。

---

### [Code Quality] `failed → pre_send → 再送` で `first_sent_at` が上書きされる一方、round=1 の履歴は更新されない

- [x] 対応する

**ファイル:** `api/src/services/cancellation-send.service.ts:142-155`／ `api/src/repositories/cancellation-notifications.repository.ts:47-60`
**重要度:** Low

**該当コード:**

```typescript
// api/src/services/cancellation-send.service.ts:142-155（新規）
  await cancellationsRepo.update(cancellation.id, { firstSentAt: new Date().toISOString() });   // ← 常に上書き
  const recordInitial = (channel: 'email' | 'sms', patch: Record<string, any>) =>
    cancellationNotificationsRepo
      .record({ cancellationId: cancellation.id, round: 1, channel, ... } as any)
      .catch((e) => console.error('Failed to record notification history:', e));
```

```typescript
// api/src/repositories/cancellation-notifications.repository.ts:47-59（新規）— 既存行は上書きしない（先勝ち）
  record: async (rec: NotificationRecord, db: any = getDb()) => {
    const rows = await db
      .insert(cancellationNotifications)
      .values({ id: randomUUID(), ...rec })
      .onConflictDoNothing({ target: [ ...cancellationId, round, channel ] })
      .returning();
```

**問題:**
`updateCancellationStatus` は `failed → pre_send` を許す（禁止しているのは `pending`/`paid` からの巻き戻しのみ。`cancellation.service.ts:444-457`）。この経路で再送すると `first_sent_at` は新しい時刻へ**上書き**されるのに、round=1 の履歴は `onConflictDoNothing` で**最初の失敗記録が残ったまま**になる。結果、法的証跡上は「初回は失敗」なのに起算日は再送時刻、という食い違いが残る。すでに round 2/3 を試行済みだった場合は、起算日が後ろにずれても `attemptedRounds` が埋まっているためリマインドは 0 通になる。

**修正提案:**
再送を許すなら `first_sent_at` は「最初の試行時刻」を保持する（未設定時のみ書く）か、履歴側も再送分を新しい行として記録できるよう `attempt` 連番を持たせる。少なくとも現在の非対称性を意図的なものとしてコメント化する。

---

### [Test Coverage] batch dispatch のテストが夜間帯では配線以上を何も検証しない

- [x] 対応する

**ファイル:** `api/src/__tests__/e2e/billing-reminders.test.js:322-329`
**重要度:** Low

**該当コード:**

```javascript
// toBranch 側（新規）
describe('batch dispatch（send-billing-reminders action の配線）', () => {
  it('dispatchBatchAction が action を受けて集計を返す（対象 0 件）', async () => {
    const result = await dispatchBatchAction({ action: 'send-billing-reminders' });
    // now は実時刻のため夜間ガードに当たる時間帯もある。いずれでも ok:true・送信 0 件。
    expect(result).toMatchObject({ ok: true, action: 'send-billing-reminders', remindersSent: 0 });
  });
});
```

**問題:**
`batch.ts:92` が `now: new Date()` を渡すため、JST 21:00〜翌 8:00 に実行されると夜間ガードで即 return し、`findReminderTargets` 以降を一切通らない。対象を 0 件しか置いていないので、どちらの分岐でもアサーションが通る＝**時間帯によっては switch-case が値を返すことしか検証していない**。ロジック本体は他の it が `now` 注入で押さえているので実害は小さいが、「dispatch 経由でも同じ結果になる」ことの担保にはなっていない。

**修正提案:**
`vi.setSystemTime` で正午 JST に固定し、対象を 1 件シードして `byRound['2']` まで検証する。夜間ガードは別 it で `skipped: 'night_guard'` を固定する。

---

### [Code Quality] リマインド抽出 SQL の `status` 生値と service 側の正規化が不一致（現状実害なし）

- [x] 対応する

**ファイル:** `api/src/repositories/cancellations.repository.ts:298-303`／ `api/src/db/migrations/0023_gtss886_billing_reminders.sql`
**重要度:** Low

**該当コード:**

```typescript
// toBranch 側（新規）— SQL は canonical 'pending' 決め打ち
      .where(
        and(
          eq(cancellations.status, 'pending'),
          isNotNull(cancellations.firstSentAt),
          or(isNull(cancellations.dueDate), gte(cancellations.dueDate, todayJst)),
        ),
      )
```

```typescript
// 対比: api/src/services/billing-reminder.service.ts:62 — service は legacy 'sent' も請求中として正規化
  if (normalizeCancellationStatus(status) !== CANCELLATION_STATUS.PENDING) return null;
```

```typescript
// 対比: 既存の同種クエリ（api/src/repositories/cancellations.repository.ts:184）は legacy も拾う
      .where(inArray(cancellations.status, ['sent', 'pending']))
```

**問題:**
3 箇所で「請求中」の定義が揃っていない。unit テスト「legacy `sent` は請求中として扱う」は緑だが、当該行は SQL 側で先に落ちるため E2E では到達不能。migration 0003 で `sent → pending` 移行済みかつ legacy 行は `first_sent_at` が NULL なので**現時点で実害はない**が、`.claude/lessons.md`「ステータスのフィルター条件はドメインのライフサイクル全体を考慮する」の趣旨どおり、同じ条件を持つ関数は横並びで揃えておくのが安全。

**修正提案:**
抽出 SQL と部分インデックス述語を既存クエリと同じ `IN ('sent','pending')` に揃えるか、逆に service 側のコメントで「SQL 段で canonical に絞る」ことを明示する。

---

## 総評

Issue #57 は法的建付け（非弁行為リスク）が仕様の必須要件という、通常より制約の強い機能。その中核である **回判定の純関数化（`decideReminderRound` / `isNightGuardJst`）・回単位 claim による二重送信防止・PII を構造で持たない履歴テーブル・`status`/`statusLabel` を SSOT のまま派生値だけ足す設計** は、要件の意図をよく汲んだ実装になっている。Checkout Session 生成の共通ビルダー化も、手数料・領収書 SUMMARY／T 番号・日本語 Customer という金銭・税務要件の退行を構造で防いでおり、`statement_descriptor_suffix` を経路別に残した判断（[Decision] コメント）も妥当。テストも 31 本の T-* が実質的なアサーション（具体値検証・不在アサーション・実 DB での冪等検証）を持っており、モック過多の空テストは見当たらなかった。

一方で、**リリース前に潰しておきたい High が 6 件**ある。

1. **`deploy-batch.sh` への env 追加漏れ**が最も影響が大きい。prod のバッチは Lambda 経路で稼働中なのに、更新したのは ECS 経路のスクリプトだけで、Twilio 認証情報も `API_BASE_URL` も入らない。仕様上「送信失敗の通知・一覧・絞り込みを設けない」ため、**SMS が全件失敗しても誰も気づけない**。dev では決済リンクが prod を指すので H-1 の実発火テストも誤った結論になる。
2. **webhook の `client_reference_id` フォールバック**は、突合成立の条件を「推測不能なセッション ID」から「推測可能な請求 ID」へ緩めている。Connect アカウント・金額・支払状態の照合を足すだけで塞げる。
3. **旧 `POST /cancellations` のマスアサインメント**は既存の弱点だが、`first_sent_at` の追加によって「他社名義で任意宛先へ SMS を送らせる」経路に変わった。Issue の技術的考慮事項 #12 の前提が崩れているので、ルート削除か allowlist 化が必要。
4. **`/pay` 再発行の TOCTOU** は、二重決済かつ「記録に残らない入金」を生み得る。条件付き更新に `status='pending'` を足すのが最小修正。
5. **admin の文面再構成のサロン名解決順**は、この機能の存在理由である法的証跡の同一性を損なう。送信時に使ったサロン名を API から返すのが筋。
6. **新規 repository だけ `normalizeTimestamps` 未適用**。リポジトリには `src/db/timestamps.ts` という専用ヘルパがあり、ドライバごとの生文字列の差までヘッダに明記され、timestamptz を持つ既存 8 repository すべてが `toDomain` で適用している。本 PR の新規 repo だけ抜けており、**local/test では送信日時が全て `-`、dev/prod では 9 時間ずれ（UTC 15:00 以降は日付も 1 日ずれ）**。fixture が正規化済み ISO、契約テストが `not.toBeNull()` だけなので **全テスト緑のまま本番だけ壊れる**。1 行の import で直る。

Medium 帯では、`notificationMethod` 無検証（法的要件である「個別停止機能を設けない」の抜け穴）、`finalize` 例外で配信済みが `failed` に反転する点、リマインド抽出の N+1 とインデックス不使用、admin 一覧の履歴明細が Data API の 1 MiB 応答上限に向かって育つ点、支払期日の下限バリデーション欠如、タイムラインの「過去日時 送信予定」、ⓘ ポップオーバーの位置追従なしが、いずれもリリース後に静かに効いてくる種類の問題。

**確認して問題なしと判断した観点**（lessons 照合・認可チェックリスト・cross-file 検証を含む）:

- **認可 4 観点**: `handlers/cancellations.handler.ts` と service を横並び確認。sibling ルートの `requireAdmin` 付け忘れなし。`getCancellation` の requireAdmin 先行フォールバックは role='admin' のみ通過するためサロンの認可スコープは不変。`updateCancellationStatus` の patch は全て内部生成値で body 由来なし。
- **レスポンス露出（GTSS-836 の再発）**: 追加された派生値は非機微、履歴明細は admin 経路のみ。`reminder-response-contract.test.js` に `notifications` / `errorDetail` の**不在アサーション**があり、lesson の要求どおり。
- **二重送信防止**: `claimRound` の複数行 `INSERT ... ON CONFLICT DO NOTHING RETURNING` は単一文で、多重起動時は後発が全行 conflict → 0 行 → 送信なし。claim → 送信 → finalize が別 Tx でも失敗側は常に「送らない」へ倒れる。
- **共通ビルダーの退行**: 手数料は保存済み `platformFee` 優先で取り漏れなし。`normalizeCustomerEmail` が空を undefined へ落とすため SMS のみ請求で `receipt_email: ''` になる退行もなし。`statementSuffixFor(source)` の経路推定も、`pre_send` 行が salonboard 取り込み（source あり）のみであることを確認済みで初回と再発行が一致する。
- **PII**: 履歴テーブルに宛先・本文の**列自体が存在しない**ことを `information_schema` テストで固定。`sanitizeNotificationError` は code/name/type/status のみを残し、Twilio の `Invalid To number 090-…` 形式のメッセージは落ちる。
- **JST 計算**: `endOfNextMonthJst` の `Date.UTC(y, m+2, 0)` は桁あふれ正規化で 12 月・うるう年・8/31→9/30 いずれも正しく、unit も境界を押さえている。
- **Playwright の作法**: セル単位検証・フィルタ前後の件数比較・CSV 実ダウンロード＋22 列 deep-equal。`tableText.toContain` 依存・条件付き `test.skip`・ハードコード seed ID 遷移はなし。新規の ⓘ／詳細ボタンも testid と row スコープ済み。
- **マイグレーション**: 0023 手書き SQL ＋ `_journal.json` 手動追記（idx 23）で既存運用と整合。

なお **docs 更新は親リポジトリの working tree に未コミットのまま**（`docs/product/cancellation-flow.md` ほか 6 ファイル）。`docs/tech/batch-jobs.md` の「依存」節が ECS 経路にしか触れていない点は上記 1 と合わせて修正が要る。フロント 2 リポの `REMINDER_RELEASE_DATE_LABEL` 更新と、リマインド文面の弁護士最終承認もリリース前提として残っている。

---

*本レビューは code-reviewer（api / admin / portal）・lessons-reviewer・codex-reviewer（api / admin / portal）の 7 エージェント出力を、メインエージェントが呼び出しチェーン・対比ファイルを自分で読み直して裏取りしたうえで採否を判断した。裏取りできなかった指摘（webhook の `payment_status` 未検証など既存挙動に留まるもの、`jstDateKey` と `jstCalendarDate` の二重実装＝依存ゼロ規約のための意図的な重複）は本文から除外している。*
