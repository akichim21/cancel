---
issue: 62
date: 2026-08-08
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: main
    toBranch: GTSS-896
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: main
    toBranch: GTSS-896
  - repo: user
    repoDir: cancel-billing-service
    baseBranch: main
    toBranch: GTSS-896
  - repo: cancel
    repoDir: .
    baseBranch: main
    toBranch: GTSS-896
---

# レビュー結果: #62

## 概要

**Issue:** #62 請求メール・SMS の本文に予約日時を挿入する（送信方法の推奨バッジ移設を含む）

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 | PR |
|-----------|-------------|------------|----------|------------|----|
| api | `main` | `GTSS-896` | 1 | 10 | GO-TODAY-SHAiRE-SALON/cancel-billing-service-api#47 |
| admin | `main` | `GTSS-896` | 1 | 8 | GO-TODAY-SHAiRE-SALON/cancel-billing-service-admin#19 |
| user | `main` | `GTSS-896` | 1 | 5 | GO-TODAY-SHAiRE-SALON/cancel-billing-service#13 |
| cancel (docs) | `main` | `GTSS-896` | 1 | 3 | akichim21/cancel#63 |

> **ベースブランチについての補足**: Issue 本文は「実装ベースは `develop`（`main` ではない）。`main` には GTSS-886 が未取り込み」としているが、**この記述は既に陳腐化している**。現在の `origin/main` の HEAD は `1501ec2 Merge pull request #41 ... GTSS-886` で GTSS-886 は取り込み済み。3 リポジトリとも `GTSS-896` は `main` の 1 コミット上にあり、`git diff origin/main...origin/GTSS-896` が PR の内容と完全に一致する。manifest の `baseBranch: main` が正しい。

### 検証済み（レビュー時に実行）

| 対象 | 結果 |
|---|---|
| api `npx vitest run`（全件） | ✅ 100 files / 1408 tests |
| admin `npm test`（typecheck + vitest） | ✅ |
| user portal `npm test` | ✅ 17 files / 215 tests |
| admin Playwright `e2e/cancellation.spec.ts -g "T-20"` | ✅ 2 passed |
| user portal Playwright `e2e/invoice.spec.ts` | ✅ 5 passed |
| admin `tsc --noEmit` | ✅ |
| 旧定数 `SUPPORTED_TEMPLATE_VERSION`（単数形）の参照残り | ✅ なし |
| 「回数・間隔・時刻・文面」旧文言の残り（3 リポジトリ横断 grep） | ✅ なし |

AC-9.1（既存回帰 green）は満たしている。

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/utils/appointment-datetime.ts` | +80 | -0 | Added |
| `src/services/notification.service.ts` | +32 | -6 | Modified |
| `src/services/cancellation-send.service.ts` | +3 | -0 | Modified |
| `src/services/billing-reminder.service.ts` | +3 | -0 | Modified |
| `src/__tests__/unit/appointment-datetime.test.ts` | +89 | -0 | Added |
| `src/__tests__/unit/reminder-content.test.ts` | +274 | -15 | Modified |
| `src/__tests__/unit/notification-service.test.js` | +53 | -0 | Modified |
| `src/__tests__/e2e/send-shop-name.test.js` | +107 | -3 | Modified |
| `src/__tests__/e2e/cancellations-invoices.test.js` | +96 | -0 | Modified |
| `src/__tests__/e2e/billing-reminders.test.js` | +62 | -0 | Modified |

### admin

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/utils/appointmentDatetime.ts` | +76 | -0 | Added |
| `src/constants/cancellationNotifications.ts` | +43 | -8 | Modified |
| `src/components/CancellationManagement.tsx` | +3 | -1 | Modified |
| `src/components/ReminderRulePopover.tsx` | +3 | -2 | Modified |
| `src/utils/__tests__/appointmentDatetime.test.ts` | +83 | -0 | Added |
| `src/constants/cancellationNotifications.test.ts` | +196 | -1 | Modified |
| `src/components/__tests__/CancellationManagement.test.tsx` | +11 | -2 | Modified |
| `e2e/cancellation.spec.ts` | +104 | -2 | Modified |

### user

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/components/InvoiceForm.tsx` | +5 | -2 | Modified |
| `src/components/ReminderInfoPopover.tsx` | +3 | -1 | Modified |
| `src/components/__tests__/InvoiceForm.test.tsx` | +38 | -0 | Modified |
| `src/components/__tests__/Dashboard.test.tsx` | +3 | -1 | Modified |
| `e2e/invoice.spec.ts` | +15 | -1 | Modified |

### cancel (docs)

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `docs/product/cancellation-flow.md` | +75 | -6 | Modified |
| `docs/tech/salonboard-import.md` | +6 | -0 | Modified |
| `.claude/worktree-manifests/GTSS-62.json` | +36 | -0 | Added |

## 指摘一覧

### [Code Quality] 手動作成の即時送信だけリクエスト生値で本文を組むため、送信本文と管理画面の再構成が食い違う

- [x] 対応する

**ファイル:** `api/src/services/invoice.service.ts:139`
**重要度:** Medium

**該当コード:**

```ts
// baseBranch 側（変更前）— 予約日時を本文に出していないため、この差は表面化しなかった
const resolvedShopName = selectedShop.shopName || '';
const resolvedShopAddress = selectedShop.shopAddress || '';
// 即時通知（Stripe 明細 / メール / SMS）にも解決済みの店舗名・住所を渡す（REQ-6/7）
const notifyData = { ...invoiceData, shopName: resolvedShopName, shopAddress: resolvedShopAddress };

const methodError = validateNotificationMethod(invoiceData.notificationMethod, hasEmail, hasPhone);
```

```ts
// toBranch 側（変更後）— 同じ行だが、notifyData.appointmentDate が本文へ出るようになった
const resolvedShopName = selectedShop.shopName || '';
const resolvedShopAddress = selectedShop.shopAddress || '';
// 即時通知（Stripe 明細 / メール / SMS）にも解決済みの店舗名・住所を渡す（REQ-6/7）
const notifyData = { ...invoiceData, shopName: resolvedShopName, shopAddress: resolvedShopAddress };
//                    ^^^^^^^^^^^ リクエストの生値。DB へは 249 行で保存され Postgres が date 型へ正規化する
const methodError = validateNotificationMethod(invoiceData.notificationMethod, hasEmail, hasPhone);
```

**問題:**
`POST /invoices`（作成と同時に送信する経路）だけは、本文組み立てへ**リクエストの生値**を渡す（他の 2 経路は DB の保存値を読む）。`appointmentDate` は検証されず、Postgres の `date` 型が非正準な表記を黙って正規化するため、**送信した本文と、管理画面が `v2` として再構成する証跡が食い違う**。

実測（`POST /invoices` → 送信 → Twilio 本文と保存値を突き合わせ）:

```
INPUT      | PERSISTED    | 実際に送信された 4 行目
2026-7-7   | "2026-07-07" | ご予約に関しまして、当店キャンセルポリシーに基づき…      ← 日付が出ない
2026/07/07 | "2026-07-07" | ご予約に関しまして、当店キャンセルポリシーに基づき…      ← 日付が出ない
2026-07-07 | "2026-07-07" | 2026年7月7日のご予約に関しまして、当店キャンセル…
```

上 2 行では、顧客は日付なしの本文を受け取るのに、管理画面の「送信した文面」は `2026年7月7日の…` と表示する。REQ-7 が担保しようとしている法的証跡の同一性が、まさにその 1 経路で崩れる。

到達性は限定的（ポータルのフォームは `<input type="date">` なので常に `YYYY-MM-DD`。API 直叩きのみ）だが、Issue 本文が「保存値と同一」と明記している前提そのものが成り立っていない箇所であり、`POST /cancellations` は作成のみで送信しないためこの 1 経路に限られる。

**修正提案:**
`notifyData` を保存後の行（`cancellationsRepo.create` の入力オブジェクト、または `getById` の結果）から組み立てて、他の 2 経路と同じ「保存値を読む」形に揃える。最小の修正なら `notifyData` の `appointmentDate` / `startTime` だけを保存用に正規化した値で上書きする。あるいは境界で `appointmentDate` の形式を検証して非正準な値を 400 で弾く。

---

### [Code Quality] 版分岐が fail-open。対応版を 1 つ足すだけで新版が v2 文面として証跡表示される

- [x] 対応する

**ファイル:** `admin/src/constants/cancellationNotifications.ts:237`
**重要度:** Medium

**該当コード:**

```ts
// baseBranch 側（変更前）— 版分岐そのものが無く、文面はリテラル 1 本だった
export const SUPPORTED_TEMPLATE_VERSION = 'v1';

const buildSmsBody = (invoice: Invoice, round: NotificationRound, apiBaseUrl: string, salonName: string): string => {
  const staffName = invoice.staffName || '';
  const lines = [
    `${resolveCustomerName(invoice)}様`,
    '',
    senderLine(salonName, staffName),
    'ご予約に関しまして、当店キャンセルポリシーに基づきキャンセル料が発生しております。',
  ];
```

```ts
// toBranch 側（変更後）
export const SUPPORTED_TEMPLATE_VERSIONS = ['v1', 'v2'] as const;
export type SupportedTemplateVersion = (typeof SUPPORTED_TEMPLATE_VERSIONS)[number];

const APPOINTMENT_SENTENCE =
  'ご予約に関しまして、当店キャンセルポリシーに基づきキャンセル料が発生しております。';

const appointmentSentence = (invoice: Invoice, version: SupportedTemplateVersion): string => {
  if (version === 'v1') return APPOINTMENT_SENTENCE;
  return `${appointmentSentencePrefix(invoice.appointmentDate, invoice.startTime)}${APPOINTMENT_SENTENCE}`;
};
```

**問題:**
`v1` だけを明示し、**それ以外の対応版はすべて v2 扱い**になる。現状 `v3` は `SUPPORTED_TEMPLATE_VERSIONS` に無いので無害だが、同ファイル 189 行の doc コメントが「API の `NOTIFICATION_TEMPLATE_VERSION` を上げたら**ここへ新しい版を追加**すること」と指示している。**指示どおり配列へ `'v3'` を足すだけで、型エラーもテスト失敗も出ないまま v3 の記録が v2 の文面として法的証跡に表示される。** ドキュメント化された手順自体が静かな証跡汚染を招く形になっている。

この PR が守ろうとしている性質（未知版は再構成しない＝誤った文面を証跡として見せない）が、次に版を上げた人の手で無言で破られる。

**修正提案:**
版 → ビルダーの網羅マップにして、版を足したらコンパイルエラーになる形にする。

```ts
const APPOINTMENT_SENTENCE_BY_VERSION: Record<SupportedTemplateVersion, (i: Invoice) => string> = {
  v1: () => APPOINTMENT_SENTENCE,
  v2: (i) => `${appointmentSentencePrefix(i.appointmentDate, i.startTime)}${APPOINTMENT_SENTENCE}`,
}
```

---

### [Docs] 「領収書は従来どおり日付のみ」が誤り。領収書には予約日が一切出ない

- [x] 対応する

**ファイル:** `cancel/docs/product/cancellation-flow.md:99`
**重要度:** Medium

**該当コード:**

```markdown
<!-- baseBranch 側（変更前）— この記述自体が存在しない（PR で新規追加された行） -->
  - **サロンポータルの請求作成フォームには来店時刻の入力欄が無い**ため、手動作成の請求は**日付のみ**になる。
    実運用で時刻まで出るのはサロンボード取り込みの請求（API を直接叩いて `startTime` を渡した場合も出る）。
```

```markdown
<!-- toBranch 側（変更後） -->
  - **サロンポータルの請求作成フォームには来店時刻の入力欄が無い**ため、手動作成の請求は**日付のみ**になる。
    実運用で時刻まで出るのはサロンボード取り込みの請求（API を直接叩いて `startTime` を渡した場合も出る）。
  - ⚠️ **決済画面の品目説明欄・領収書は対象外**（従来どおり日付のみ）。「メール／SMS は分まで・決済画面は
    日付まで」という**2 つの書式が併存する**（意図的な非対称。実装も別関数のまま）。
```

**問題:**
「決済画面の品目説明欄**・領収書**は対象外（従来どおり日付のみ）」は、**領収書にも日付が出ているように読める**が、実装では領収書 SUMMARY（`payment_intent_data.description`）は `buildReceiptIssuerLabel(issuerName, tRegistrationNumber)` ＝ **事業者名 + T 番号だけで、予約日は一切入らない**（`api/src/services/checkout-session.service.ts:156`）。予約日が入るのは `product_data.description`（決済画面の品目説明）のみ（同 133 行）。

同じ文書の 60 行下にある「出力先ごとの対応表」は正しく書けており（`領収書メールの SUMMARY … 事業者名`）、**同一文書内で矛盾している**。証跡・顧客問い合わせ対応で参照される節なので、誤読すると「領収書に日付が載っているはず」と案内してしまう。

**修正提案:**
出力先を分けて書く。

```markdown
  - ⚠️ **決済画面の品目説明欄は対象外**（従来どおり日付のみ）。**領収書には予約日・予約時刻とも出ない**
    （SUMMARY は事業者名 + T 番号のみ。下記「出力先ごとの対応表」参照）。「メール／SMS は分まで・
    決済画面は日付まで」という 2 つの書式が併存する（意図的な非対称。実装も別関数のまま）。
```

---

### [Code Quality] 再送すると「送った本文は v2・履歴は v1」になり、証跡が食い違う

- [x] 対応する

**ファイル:** `api/src/services/cancellation-send.service.ts:158`（先勝ち実装は `api/src/repositories/cancellation-notifications.repository.ts:61`）
**重要度:** Medium

**該当コード:**

```ts
// baseBranch 側（変更前）— テンプレートが 1 種（v1）しか無いので、版が古いまま残っても無害だった
  // ⚠️ 既知の非対称（意図的に据え置き。GTSS-886 レビュー）: この再送経路では **2 回目以降の配信成否が
  // 履歴に残らない**（round=1 の行は先勝ちで最初の記録のまま）。…
  await cancellationsRepo.setFirstSentAtIfUnset(cancellation.id, new Date().toISOString());
  const recordInitial = (channel: 'email' | 'sms', patch: Record<string, any>) =>
    cancellationNotificationsRepo
      .record({ cancellationId: cancellation.id, round: 1, channel,
        templateVersion: NOTIFICATION_TEMPLATE_VERSION,  // ← 当時は常に 'v1'
```

```ts
// toBranch 側（変更後）— NOTIFICATION_TEMPLATE_VERSION が 'v2' になり、先勝ちの害が顕在化した
  // 未設定のときだけ書く: updateCancellationStatus は failed → pre_send を許すため本経路は再送され得るが、
  // round=1 の送信履歴は onConflictDoNothing で最初の試行が残る。…
  await cancellationsRepo.setFirstSentAtIfUnset(cancellation.id, new Date().toISOString());
  const recordInitial = (channel: 'email' | 'sms', patch: Record<string, any>) =>
    cancellationNotificationsRepo
      .record({ cancellationId: cancellation.id, round: 1, channel,
        templateVersion: NOTIFICATION_TEMPLATE_VERSION,  // ← 'v2' だが、既存行があれば書き込まれない
```

**問題:**
`record()` は UNIQUE `(cancellation_id, round, channel)` に対し `onConflictDoNothing`＝**先勝ち**。一方ステータス遷移ロック（`cancellation.service.ts:544`）が禁止しているのは `pending` / `paid` → `pre_send` だけで、**`failed`（決済失敗）→ `pre_send` の巻き戻しは通る**。コード自身のコメントも「本経路は再送され得る」と明記している。

したがって次の経路で証跡が壊れる:

1. リリース**前**に round=1 を送信 → 履歴に `templateVersion='v1'` が残る
2. 決済失敗で `failed` → 運用が `pre_send` へ巻き戻す
3. リリース**後**に再送 → **本文は v2（予約日時入り）で顧客へ届く**が、履歴行は先勝ちで `v1` のまま
4. 管理画面は `v1` として**予約日時なしで再構成** → 実際に送った文面と食い違う

GTSS-886 の既知非対称コメントは「2 回目以降の**配信成否**が残らない」ことしか書いておらず、**版の陳腐化には触れていない**。版が 1 種しか無かった当時は無害だったものが、版を 2 つにしたことで有害化した＝**この PR が新たに作った害**。`docs/product/cancellation-flow.md` の「再構成のズレ」の節も、原因を「送信後の来店予定日・来店時刻の書き換え」だけに限定していてこの経路を拾えていない。

**修正提案:**
`record()` を `onConflictDoUpdate` にして **`templateVersion` だけ**最新化する（`status` / `sentAt` / `firstSentAt` の先勝ちは維持）。表示は 1 行＝「最後に送った文面」を表すべきなので意味的にも整合する。仕様判断を伴うため本 PR で直さない場合は、最低限 `cancellation-send.service.ts:151` の既知事項コメントと docs の当該節へ「**再送では版も先勝ちで残るため、リリースを跨いだ再送は証跡がズレる**」を追記し、運用を「リリース前に失敗した請求は再送でなく新規作成」へ寄せること。

---

### [Code Quality] 予約日時もサーバー解決値を 1 フィールドで返す設計へ寄せたい（上記 2 件の根治策）

- [x] 対応する

**ファイル:** `admin/src/constants/cancellationNotifications.ts:237`（前例は `api/src/repositories/cancellations.repository.ts:76`）
**重要度:** Medium（設計提案）

**該当コード:**

```ts
// 前例（既存・baseBranch にもある）— サロン名は「フロントで再導出させない」方針が明文化されている
// admin の「送信した文面」再構成が別の順（storeName 優先）で組み立てると法的証跡としての同一性が崩れる
// ため、解決済みの値をサーバーから 1 フィールドで返し、フロントは再解決しない。
export const resolveNotificationSalonName = (row: {...}): string =>
  row.snapshotShopName || row.storeName || row.partnerName || row.businessName || 'サロン';
```

```ts
// toBranch 側（変更後）— 予約日時はその逆で、admin が生値を別実装で再解釈している
const appointmentSentence = (invoice: Invoice, version: SupportedTemplateVersion): string => {
  if (version === 'v1') return APPOINTMENT_SENTENCE;
  return `${appointmentSentencePrefix(invoice.appointmentDate, invoice.startTime)}${APPOINTMENT_SENTENCE}`;
};
```

**問題:**
GTSS-886 はサロン名について「フロントで再導出させず、送信経路と同じ解決結果をサーバーが 1 フィールド（`notificationSalonName`）で返す」と決め、その理由をリポジトリのコメントに残している。予約日時はこの前例に反して、**admin が生値（`appointmentDate` / `startTime`）を別実装で再解釈する**形になっている。

上で挙げた「非正準な日付でのズレ」「二重実装のドリフト」「下記の `Date` 型による無言縮退」は、いずれも**同じ値を 2 箇所で別々に解釈している**という 1 つの原因から派生している。

**修正提案:**
admin 向けレスポンスへ `notificationAppointmentPrefix`（＝送信時に使う接頭辞そのもの。`appointmentSentencePrefix(row.appointmentDate, row.startTime)` の結果）を追加し、admin 側は次の 1 行にする。

```ts
version === 'v1' ? APPOINTMENT_SENTENCE : `${invoice.notificationAppointmentPrefix ?? ''}${APPOINTMENT_SENTENCE}`
```

`admin/src/utils/appointmentDatetime.ts` とその unit テストは削除でき、版分岐の fail-open も分岐が減って扱いやすくなる。本 PR に含めない場合は、`appointmentDatetime.ts` 冒頭の「対の実装。必ず両方直すこと」というコメントへ「**暫定。将来はサーバー解決値へ寄せる方針**」と方向性を書き添えること。

---

### [Test Coverage] `v1 × リマインド(round 2) SMS × 予約日時あり` の回帰が無い

- [x] 対応する

**ファイル:** `admin/src/constants/cancellationNotifications.test.ts:476`
**重要度:** Low

**該当コード:**

```ts
// baseBranch 側（変更前）— 版別再構成が無いため、この観点のテスト自体が存在しない
```

```ts
// toBranch 側（変更後）— 予約日時を持つ請求での v1 固定は round 1 SMS だけ
  // T-18（AC-7.2）: v1 の記録は、請求が来店予定日を持っていても予約日時を含まない。
  // ここが崩れると「リリース前に送った文面」の証跡が後から書き換わる。
  it('T-18 v1 × 予約日時を持つ請求 → 予約日時なしの現行文面（過去の証跡が変わらない）', () => {
    const body = smsBodyOf({}, { round: 1, templateVersion: 'v1' })
    expect(body).toBe(
      [
        '田中 太郎様',
        '',
        '渋谷店 担当ハナコです。',
        SENTENCE,
```

**問題:**
予約日時を持つ請求（`baseInvoice` は `appointmentDate: '2026-07-07'` / `startTime: '17:00'`）での `v1` 固定は、**初回 SMS（T-18・完全一致）とメール（T-26・`not.toContain('2026年7月7日')` の否定アサーションのみ）まで**。**リマインド（round 2）SMS の `v1` は一切カバーが無い**。

既存の round 2 テストは `makeInvoice` の既定（`appointmentDate` を持たない）を使うため、リマインド SMS が誤って v2 経路へ流れても本文が変わらず素通りする。AC-7.2 はチャネル・回を限定していないので、担保に穴がある。上の「版分岐が fail-open」の事故も、この穴があるぶん検知が遅れる。

**修正提案:**
T-18 と対になる round 2 の完全一致ケースを 1 本追加する。

```ts
it('T-18 v1 × リマインド SMS（round 2）→ 予約日時なしの現行文面', () => {
  expect(smsBodyOf({}, { round: 2, templateVersion: 'v1', sentAt: '2026-06-08T03:00:00.000Z' }, 1)).toBe(
    [
      '田中 太郎様', '', '渋谷店 担当ハナコです。', SENTENCE,
      'お支払いが確認できておりませんため、再度ご案内いたします。お支払い済みの場合はご容赦ください。',
      '', '▼お支払いはこちら', 'https://api.example.com/pay/inv-1', '※本SMSは通知専用です。',
    ].join('\n')
  )
})
```

あわせて `v1 × メール` も `not.toContain` から完全一致へ格上げすると、版分岐の fail-open も検知できるようになる。

---

### [Docs] SMS 上限「335 文字（5 セグメント）」に前提条件が書かれていない

- [x] 対応する

**ファイル:** `cancel/docs/product/cancellation-flow.md:232`
**重要度:** Low

**該当コード:**

```markdown
<!-- baseBranch 側（変更前） -->
/pay 短縮 URL。SMS は 268 文字（4 セグメント）以内を自動テストで検証。
```

```markdown
<!-- toBranch 側（変更後） -->
/pay 短縮 URL。**リマインド SMS の冒頭にも初回と同じ予約日時が入る**（GTSS-896。上記「2. 送信」参照）。

**SMS 長**: **335 文字（5 セグメント）以内**を自動テストで検証する（GTSS-896 で 268 文字／4 セグメントから改定）。
予約日時の差し込みで本文は 15〜18 文字増える。来店時刻を持つのはサロンボード取り込みの請求だけで、
```

**問題:**
「335 文字（5 セグメント）以内」が**実装上の上限のように読める**が、これを検証しているテストは「店舗名 40 字・担当 10 字・顧客 10 字」という固定 fixture に限定されている。実際のフォームは店舗名・担当者名・顧客名をそれぞれ **100 文字まで許容**し（`user/src/components/InvoiceForm.tsx:336,384,596`、`StoreManagement.tsx:165`）、通知生成時の切り詰めも無い。したがって 335 文字はハード上限ではなく「想定条件でのテスト上限」。

Issue 本文には「上記『想定最大』は既存テストが置いている現実的な上限であり、**サーバー側の強制ではない**」という補足があるが、**docs 側に落ちていない**。旧記述（268 文字）も同じ曖昧さを持っていたので新規の退行ではないが、上限を改定する今が明記の機会。

**修正提案:**
前提を明記する。

```markdown
**SMS 長**: 想定条件（店舗名 40 字／担当 10 字／顧客 10 字）で **335 文字（5 セグメント）以内**であることを
自動テストで検証する（GTSS-896 で 268 文字／4 セグメントから改定）。**サーバー側の文字数制限・切り詰めは無く**、
入力欄は各 100 字まで許容するため、これはハード上限ではない。
```

---

### [Docs] 「来店時刻を持つのは取り込み請求だけ」が同一文書内で矛盾

- [x] 対応する

**ファイル:** `cancel/docs/product/cancellation-flow.md:233`
**重要度:** Low

**該当コード:**

```markdown
<!-- 同一文書 98 行目（この PR で追加。正しい） -->
    実運用で時刻まで出るのはサロンボード取り込みの請求（API を直接叩いて `startTime` を渡した場合も出る）。
```

```markdown
<!-- 同一文書 233 行目（この PR で追加。断定しすぎ） -->
予約日時の差し込みで本文は 15〜18 文字増える。来店時刻を持つのはサロンボード取り込みの請求だけで、
その請求 ID は `imp_` + UUID の **40 文字**（手動作成の `inv_` + エポックms は 17 文字）——
```

**問題:**
`POST /invoices` は渡された `startTime` をそのまま保存し本文にも反映する（`api/src/services/invoice.service.ts:249`。E2E `cancellations-invoices.test.js` でも明示的に検証済み）。98 行目は正しく例外を書いているのに、233 行目は「取り込みの請求だけ」と断定していて**文書内で食い違う**。

なお SMS 長の結論（最悪値は 40 文字の取り込み ID で決まる）自体は正しい — 手動作成 ID は 17 文字なので、時刻が付いても取り込みケースを超えない。

**修正提案:**
「通常の UI 運用で来店時刻を持つのは取り込み請求（API 直叩きなら手動作成でも設定可）。SMS 長の最悪値は 40 文字の取り込み ID 側で決まる」と書き分ける。

---

### [Code Quality] `font-medium` がバッジと一緒に移動し、SMS ラベルが通常ウェイトになる

- [x] 対応する

**ファイル:** `user/src/components/InvoiceForm.tsx:535`
**重要度:** Low

**該当コード:**

```tsx
// baseBranch 側（変更前）
                          className="text-primary-600 focus:ring-primary-500"
                        />
                        <span className="text-sm text-gray-700">
                          {method === 'sms' && <><span className="font-medium">SMS</span><span className="ml-1 text-xs text-white bg-green-500 rounded px-1.5 py-0.5">推奨</span></>}
                          {method === 'email' && 'メール'}
                          {method === 'both' && 'SMSとメール'}
                        </span>
                      </label>
```

```tsx
// toBranch 側（変更後）
                          className="text-primary-600 focus:ring-primary-500"
                        />
                        <span className="text-sm text-gray-700">
                          {/* GTSS-896 / REQ-8: 「推奨」バッジは SMS から「SMSとメール」へ移設した。… */}
                          {method === 'sms' && 'SMS'}
                          {method === 'email' && 'メール'}
                          {method === 'both' && <><span className="font-medium">SMSとメール</span><span className="ml-1 text-xs text-white bg-green-500 rounded px-1.5 py-0.5">推奨</span></>}
                        </span>
                      </label>
```

**問題:**
バッジ自体（文言・配色・サイズ・余白）は現行と同一のものが移設されているが、**バッジ外の `font-medium` まで一緒に移動**している。結果として SMS ラベルは太字 → 通常ウェイト、「SMSとメール」は通常 → 太字になる見た目変更が生じる。REQ-8 は「バッジの文言・配色・サイズ・余白は現行と同一のものを移設する」としか書いておらず、ラベルのウェイトには触れていない。

追加された T-22 / T-23 は文字列しか検証しないため、この差分を検知できない。

「推奨オプションを強調する」という意図なら一貫した変更であり、そのままで良い（その場合はコメントに意図を 1 行足すのが望ましい）。意図していないなら SMS の `font-medium` を残す。**どちらが意図かの確認だけお願いしたい。**

**修正提案（ウェイト維持の場合）:**

```tsx
{method === 'sms' && <span className="font-medium">SMS</span>}
{method === 'email' && 'メール'}
{method === 'both' && (
  <>
    <span className="font-medium">SMSとメール</span>
    <span className="ml-1 text-xs text-white bg-green-500 rounded px-1.5 py-0.5">推奨</span>
  </>
)}
```

---

### [Code Quality] 型述語でない filter の直後にキャストがあり、ガードが型で守られていない

- [x] 対応する

**ファイル:** `admin/src/constants/cancellationNotifications.ts:317`
**重要度:** Low

**該当コード:**

```ts
// baseBranch 側（変更前）— 単一値との比較でキャスト不要だった
  return entry.notifications
    .filter((n) => n.templateVersion === SUPPORTED_TEMPLATE_VERSION)
    .map((n) => {
      const delivered = n.status === 'success';
```

```ts
// toBranch 側（変更後）
  return entry.notifications
    .filter((n) => isSupportedTemplateVersion(n.templateVersion))
    .map((n) => {
      // 版は**通知レコード単位**で見る（請求単位で決め打ちしない）。…
      const version = n.templateVersion as SupportedTemplateVersion;
      const delivered = n.status === 'success';
```

**問題:**
`isSupportedTemplateVersion` は `value is SupportedTemplateVersion` の型述語として書かれているが、`filter((n) => ...)` のラムダの戻り値型は `boolean` で、**`n` 自体の絞り込みには伝播しない**。そのため直後に `as SupportedTemplateVersion` のキャストが必要になっている。この `as` があるかぎり、将来 filter の条件を緩めても型は何も警告しない（上の fail-open 指摘と同じ穴を別角度で開けている）。

**修正提案:**
版マップ化（上の Medium 指摘）と同時に、`n` に対する型述語へ寄せてキャストを消す。

```ts
type SupportedNotification = CancellationNotification & { templateVersion: SupportedTemplateVersion }
const isSupported = (n: CancellationNotification): n is SupportedNotification =>
  isSupportedTemplateVersion(n.templateVersion)
// …
.filter(isSupported).map((n) => { /* n.templateVersion は SupportedTemplateVersion */ })
```

---

### [Code Quality] REQ-9 の言い換えが API 側のコメント 2 箇所に未反映

- [x] 対応する

**ファイル:** `api/src/services/billing-reminder.service.ts:8` / `api/src/services/cancellation.service.ts:301`
**重要度:** Low

**該当コード:**

```ts
// baseBranch 側（変更前）= toBranch 側（変更後）— どちらも未変更のまま
// billing-reminder.service.ts:8
//   「通知主体はサロン名義」。回数・間隔・時刻・文面は全サロン・全請求で共通・変更不可であり、

// cancellation.service.ts:301
// 任意テキストが入り、「文面は全請求で共通・変更不可」という法的建付けもこの経路だけ破れる）。
```

**問題:**
REQ-9 は「文面」→「文面テンプレート」への言い換えを 3 つの**画面文言**と docs に適用したが、**同じ法的建付けを述べている API 側の開発者向けコメント 2 箇所が旧表現のまま**残っている。UI 文言ではないため「旧文言の残りなし」の grep 確認からも漏れやすい（実際、画面文言の grep では検出されなかった）。

法的建付けの根拠としてコードに書かれている記述なので、ここだけ「文面は変更不可」と読めると、**将来これを根拠に予約日時の差し込みが誤って撤去される**余地が残る。

**修正提案:**
両方を「文面テンプレート（差し込まれるのは請求レコードに保存済みの事実値のみ）」の趣旨へ揃える。

---

### [Test Coverage] ケース表の「共有」が実体はコピーで、ドリフトを検知できない

- [x] 対応する

**ファイル:** `api/src/__tests__/unit/appointment-datetime.test.ts:17` / `admin/src/utils/__tests__/appointmentDatetime.test.ts:13`
**重要度:** Low

**該当コード:**

```ts
// toBranch 側（変更後）— 両ファイルのヘッダコメント
// ⚠️ **管理画面と対のテスト**。同じケース表・同じ期待文字列を … が持つ。
//    片方だけ変えたら必ずどちらかが落ちる状態を保つこと（下の APPOINTMENT_CASES を両方で共有する）。

export const APPOINTMENT_CASES: Array<[string | null | undefined, string | null | undefined, string]> = [
  ['2026-07-07', '17:00', '2026年7月7日17時00分'],
  // …（22 ベクトル。admin 側は export なしで同一内容をコピー）
];
```

**問題:**
現時点で 22 ベクトルが完全一致していることは確認済みだが、「共有」ではなく**手でコピーした 2 本の独立した配列**なので、**実装とその repo のケース表を一緒に変更すれば、もう片方は緑のまま**通る。ヘッダコメントの「片方だけ変えたら必ずどちらかが落ちる」が成立するのは「実装だけを変えた場合」に限られ、コメントが実態より強い保証を約束している。

加えて api 側の `export` はどこからも import されておらず、共有の意図だけが残った未使用 export になっている。

**修正提案:**
親リポジトリにゴールデンベクタ（例 `docs/fixtures/appointment-datetime-cases.json`）を 1 本置いて両 repo が読み込む。重ければ最低限、(a) 未使用の `export` を外す、(b) コメントを「**コピーなので両方を手で直すこと**」と実態どおりに直す。

---

### [Code Quality] `Date` 型が渡ると無言で予約日時が消える（API 側だけ発生し得る）

- [x] 対応する

**ファイル:** `api/src/utils/appointment-datetime.ts:45`
**重要度:** Low

**該当コード:**

```ts
// toBranch 側（変更後）
export const formatAppointmentDateTime = (
  appointmentDate?: string | null,
  startTime?: string | null,
): string => {
  const dateSource = typeof appointmentDate === 'string' ? appointmentDate.trim() : '';
  if (!dateSource) return '';   // ← Date インスタンスもここで無言で '' に落ちる
```

**問題:**
`typeof appointmentDate === 'string'` でない値（`Date` インスタンス等）は、例外もログも無く `''`＝「来店予定日なし」に縮退する。**この経路に入り得るのは API 側だけ**（admin は JSON 経由なので必ず文字列）なので、万一発生すると「**送信本文には日時が無いのに管理画面には出る**」という食い違いになる。

現行ドライバでは未発現: drizzle の `date()` は `mode: 'string'` 既定で `'YYYY-MM-DD'` を返し、local/test の node-postgres 経由は DB ラウンドトリップを通る E2E で担保済み。ただし **dev/prod の RDS Data API ドライバは自動テストを通らない**。なお既存の `utils/jst-date.ts:17` の `jstCalendarDate` は `Date | string` を受ける防御的な型で、本モジュールだけ非対称。

**修正提案:**
H-1（dev 実機 SMS 確認）で**取り込み請求（来店時刻あり）を 1 件実送信し、本文に `…時…分` が出ること**を必ず確認項目に含める（この 1 点は dev 確認でしか埋まらない）。あわせて `Date` を受けた場合は `jstCalendarDate()` で正規化してから解析するか、最低限 `console.warn` を出して無言縮退にしないこと。

---

## リリース前に残っている作業（コードではないが完了条件）

- [ ] **AC-10.1 / H-4 — 法務（顧問弁護士）確認が未完了。** リマインド SMS へ請求ごとに異なる値を差し込むため、Issue が**リリース前の必須ゲート**と定めている。NG の場合は REQ-4 を落とす（＝リマインドメールと初回メールの本文共用も分離が必要）判断になるので、**api のリリース前に確認結果を Issue へコメントすること**。
- [ ] **リリース順序 = マージ順序。同時マージ不可。** **admin（#19）を先にマージ → CodeBuild 完了を確認 → api（#47）をマージ**。逆順だと `v2` の履歴を admin が再構成できず「送信した文面」が表示されない期間が生じる。切り戻しは逆順（api → admin）。
  - ⚠️ **機構的な強制が無い点に注意。** 3 リポジトリとも `.github/workflows/*.yml` が `on: push: branches: [develop, main]` で、`main` への push（＝リリース PR のマージ）で **prod へ自動デプロイ**する設定（`api/.github/workflows/deploy.yml:58`）。4 本の PR をまとめてマージすると api が admin より先に本番へ出得る。影響は「その間に送信した `v2` 記録の文面が一時的に表示されない」＝ admin 反映後に復旧する非恒久欠損だが、法的証跡の表示欠落なので順序は人手で守ること。**PR 説明とマージ手順に明記推奨。**
- [ ] **api のデプロイは `./deploy.sh <env>`（migrate → API → batch 一括）で行う。** リマインド（REQ-4）は batch 成果物で動くため、`deploy-api.sh` 単独だとリマインドだけ旧文面を送り続ける。
- [ ] **人力テスト H-1 / H-2 / H-3 が未実施。** 実機 SMS のセグメント分割・メールクライアントの HTML 表示・`v1`／`v2`／版混在の再構成と実受信本文の突き合わせ。
- [ ] user portal（#13）と docs（#63）は他と独立にリリース可。

## 補足（指摘に含めなかったもの）

- **`.claude/worktree-manifests/GTSS-62.json` が docs PR に含まれている点**: ローカル絶対パス・ポートを含む作業状態ファイルで、`worktree-cleanup` スキルは作業終了時に削除する契約になっている。ただし `main` には既に 34 件の manifest が追跡済みで、gitignore もされていない＝**この PR が始めた話ではなく既存の運用実態**。本 PR の修正対象とはせず、`.claude/worktree-manifests/` の gitignore 化として別途扱うのが妥当。
- **決済リンク未発行時に admin が「送っていない文面」を証跡表示する件**: API は Stripe セッション未発行時に `PAYMENT_LINK_UNAVAILABLE_TEXT`（サポート案内）へ倒すが、admin の `buildSmsBody` / `buildEmailBody` は分岐を持たず常に決済リンク入りの本文を組む。本 PR はその分岐にも予約日時が入ることを新たにテストで固定した（T-7 / T-8）ため片側だけ厚くなったが、**Issue が「既知の未修正課題（本 Issue では直さない・ユーザー確定）」と明記している**ため指摘には含めない。follow-up Issue の候補。
- **メール HTML の未エスケープ差し込み**: 今回追加した `appointmentPrefix` は正規表現で数字と `:` のみを通し `Number()` ＋捕捉群で組み立てるため**新たな注入面は無い**。ただし同テンプレート内の `customerName` / `shopName` / `staffName` は従来どおり未エスケープ。既存・スコープ外につき別 Issue 推奨。
- **パフォーマンス / 並行性 / 認可**: いずれも指摘なし。フォーマッタの正規表現は module スコープ定数で per-call コンパイルなし、DB の追加クエリなし（`findReminderTargets` は元から全列 select）。リマインドの `claimRound` は挿入できた行だけを配信対象にするため多重起動でも版と本文は食い違わない。差分にルート追加・serializer 変更・状態遷移の変更は無く、`startTime` は既に `CLIENT_CANCELLATION_FIELDS` allowlist 内。公開エンドポイントへの新規フィールド露出も無し。
- **lessons 照合**: `.claude/lessons.md` および `.claude/skills/{vitest,playwright,issue,authz}/lesson.md` に記録されたパターンへの違反は**ヒットなし**。
- **レビュー環境の事故**: 並行して走っていた別セッション（GTSS-817-qa）のレビューが、`review-pr` スキルが使う固定パス `/tmp/review-diff-api.txt` / `/tmp/review-diff-admin.txt` を上書きしていた。サブエージェント 2 体は自力で気づいて再生成し、残り 2 体はセッション固有パスの正しい差分で再実行した。上記の指摘はすべて**正しい差分に対するもの**であることを確認済み。
  - 再実行によって、汚染された差分から拾われていた指摘（admin `ImportRunList.tsx` の `key={i}`）が **GTSS-817-qa 側のもの**と判明し取り下げられた。**GTSS-817-qa の PR をレビューする際に拾うこと。**

## 総評

**品質は高い。ブロッキングな不具合は無く、マージ可能な状態。**

- **設計**: 予約日時の整形を純関数へ切り出し、**日時型へ変換せず文字列のまま解析**して TZ 依存を避けている判断が良い。既存の `generateStripeDescription` が `new Date()` 経由で実行環境 TZ 次第に 1 日ずれる作りになっていることを踏まえた上で、意図的に轍を踏まない実装にし、その理由をコードコメントに残している。助詞「の」を関数へ集約して API/admin で組み立て方が割れないようにした点も、法的証跡の 1 バイト一致という要件に正しく効いている。
- **テスト**: 特筆して良い。Issue が「既存テストはほとんど落ちないので『落ちたテストを直す』運用だと新挙動が未検証のまま通る」と警告していたとおりの設計になっており、**日時あり／日付のみ／日付なし × 4 テンプレートの 12 パターン完全一致**、**「予約日時なしなら現行と 1 バイトも変わらない」回帰**、**セグメント境界を 0〜40 字で振る差分検証**、**SMS 上限 fixture の取り込み ID（40 文字）への差し替え**まで入っている。API と admin が同一の `APPOINTMENT_CASES` ケース表を持ち、相互参照コメントで対になっていることも確認した。
- **セキュリティ/PII**: 予約日時は正規表現でマッチした数字と固定区切りのみへ正規化されるため、メール HTML への差し込みで新たなインジェクション経路は生じない。送信履歴に本文を保存しない方針も維持されている。
- **残る課題**: Medium 5 件のうち 3 件（手動作成経路の生値・版分岐の fail-open・再送時の版の陳腐化）は**すべて「実際に送った文面と、管理画面が再構成する証跡が食い違う」という同じ 1 つの失敗モード**に収束する。REQ-7 が存在する理由そのものなので、リリース前に方針だけでも決めておきたい。
  - **最も優先度が高いのは「再送で v2 本文 × v1 履歴」**。他の 2 件が API 直叩き・将来の版追加という条件付きなのに対し、これは**通常の運用操作（決済失敗 → 巻き戻し → 再送）だけで、リリースを跨いだ瞬間に成立する**。
  - **admin の版分岐 fail-open** は、コード自身のコメントが指示する手順どおりに操作すると証跡が汚染される点が悪質。次に版を上げる前に潰しておきたい。
  - 3 件をまとめて根治するなら、**サーバーが解決済みの接頭辞を 1 フィールドで返す**設計（`notificationSalonName` の前例に揃える）が効く。admin 側の二重実装とその unit テストごと消せる。
- **運用**: リリース順序（admin → api）が **`main` へのマージ＝prod 自動デプロイ**という CI/CD の実態と噛み合っていない。順序を守れるのは人手のマージ操作だけなので、PR 説明・マージ手順への明記が要る。docs の領収書の記述は誤読を生むため修正推奨。
