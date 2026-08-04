---
issue: 32,33
date: 2026-07-02
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-842
    toBranch: GTSS-854
---

# レビュー結果: #32 / #33（GTSS-854 統合実装）

## 概要

**Issue:**
- #32 feat: 新規連結アカウントの入金スケジュールを月次(末日)化 + Stripe 残高取得/入金実行/manual運用の調査（→ #33 に統合、manual で実装）
- #33 feat: 連結アカウント入金を manual + 月次バッチ化し、しきい値ゲート（¥4,000未満は保留）で入金手数料を削減 [#32 Phase 2]

[Decision]（#32 コメント）どおり、入金スケジュールは monthly/anchor31 ではなく **manual** で作成し、末日タイミング・しきい値ゲートは月次バッチ `runMonthlyPayouts` が担う。コードと Issue の統合判断に不一致なし（codex 仕様確認済み）。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-842` | `GTSS-854` | 1 | 18 |

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/services/payout.service.ts` | +146 | -0 | Added |
| `src/services/payout-report.service.ts` | +194 | -0 | Added |
| `src/repositories/payout-runs.repository.ts` | +100 | -0 | Added |
| `src/constants/payout.ts` | +31 | -0 | Added |
| `src/db/migrations/0018_gtss854_payout_runs.sql` | +27 | -0 | Added |
| `src/db/schema.ts` | +47 | -0 | Modified |
| `src/db/migrations/meta/_journal.json` | +7 | -0 | Modified |
| `src/services/webhook.service.ts` | +39 | -0 | Modified |
| `src/services/application.service.ts` | +11 | -2 | Modified |
| `src/repositories/applications.repository.ts` | +15 | -1 | Modified |
| `src/batch.ts` | +19 | -1 | Modified |
| `src/__tests__/e2e/monthly-payouts.test.js` | +278 | -0 | Added |
| `src/__tests__/e2e/branches.test.js` | +47 | -0 | Modified |
| `src/__tests__/e2e/applications.test.js` | +2 | -0 | Modified |
| `src/__tests__/e2e/schema.test.js` | +2 | -1 | Modified |
| `src/__tests__/setup.js` | +3 | -0 | Modified |
| `src/__tests__/helpers/db.js` | +1 | -1 | Modified |
| `src/__tests__/helpers/external-mocks.js` | +1 | -1 | Modified |

## 指摘一覧

- [x] 対応する

### [Codex] deploy-batch.sh が STRIPE_SECRET_KEY を投入せず、run-monthly-payouts が dev/prod で起動不能

**ファイル:** `api/src/batch.ts:64` ＋ `api/deploy-batch.sh:198-216`（差分外・未更新）
**重要度:** High

**該当コード:**
```typescript
// toBranch側（batch.ts 新規分岐）— run-monthly-payouts は initClients() を呼ぶ
    case 'run-monthly-payouts': {
      // 当 action のみ Stripe（balance/payouts）と SES（レポート）を使うため initClients() を呼ぶ。
      initClients();
      const result = await runMonthlyPayouts({
        now: new Date(),
        dryRun: event?.dryRun === true,
        applicationId: event?.applicationId,
      });
```

```bash
# deploy-batch.sh（変更前=変更後・本 PR で未更新）— batch Lambda の env は allowlist 全置換
const vars = {
  NODE_ENV: env.DEPLOY_ENV,
  AURORA_RESOURCE_ARN: env.AURORA_RESOURCE_ARN || "",
  AURORA_SECRET_ARN: env.AURORA_SECRET_ARN || "",
  AURORA_DATABASE: env.AURORA_DATABASE || "",
  CREDENTIALS_KMS_KEY_ID: env.CREDENTIALS_KMS_KEY_ID || "",
  SALONBOARD_TRANSPORT: env.SALONBOARD_TRANSPORT || "http",
  // …DECODO_* / SALONBOARD_* のみ。STRIPE_SECRET_KEY が無い
};
```

**問題:** `initClients()` は `new Stripe(process.env.STRIPE_SECRET_KEY)` を実行するが、`deploy-batch.sh` が batch Lambda に投入する環境変数 allowlist に `STRIPE_SECRET_KEY` が含まれない（`update-function-configuration --environment` は全置換のため、手動追加してもデプロイのたびに消える）。Stripe SDK は key 未設定で throw する（"Neither apiKey nor config.authenticator provided"）ため、**dev/prod では月次入金バッチが 1 回も実行できない**。テストは `__setTestClients` 注入のため検知不能。
**修正提案:** `deploy-batch.sh` の env JSON に `STRIPE_SECRET_KEY` を追加し、`deploy-api.sh` と同様に必須検証（REQUIRED_VARS 相当）に含める。あわせてデプロイチェックリスト（総評参照）: batch Lambda の IAM ロールに `ses:SendRawEmail`/`ses:SendEmail`（従来 batch は SES 不使用のため権限が無い可能性）、EventBridge 末日 cron（外部 Terraform）、Stripe ダッシュボードの Connect Webhook 購読に `payout.paid`/`payout.failed` 追加。

---

### [Code Quality] payout 作成と payout_runs 記録が非アトミックで、記録と実入金が乖離し得る

**ファイル:** `api/src/services/payout.service.ts:91-135` ＋ `api/src/repositories/payout-runs.repository.ts:36-58`
**重要度:** Medium

**該当コード:**
```typescript
// toBranch側（payout.service.ts 新規）— create 成功後に upsert、失敗はログのみ
            const payout = await stripe.payouts.create(/* … */);
            result.status = 'pending';
            result.stripePayoutId = payout?.id ?? null;
    // …
    if (record && !dryRun) {
      try {
        await payoutRunsRepo.upsert({ /* … */ });
      } catch (recErr) {
        // 記録失敗もバッチ全体は止めない（次回バッチで再評価される）。
        console.error(`[payout] failed to record payout_run ${stripeAccountId} ${period}:`, recErr);
      }
    }
```

```typescript
// toBranch側（payout-runs.repository.ts 新規）— onConflictDoUpdate は無条件上書き
      .onConflictDoUpdate({
        target: [payoutRuns.stripeAccountId, payoutRuns.period],
        set: {
          stripePayoutId: row.stripePayoutId ?? null,
          status: row.status,
          // …
        },
      })
```

**問題:** 2 つの経路で `payout_runs` の記録が実態と乖離する。
1. **作成成功→記録失敗**: `payouts.create` 成功後に `upsert` が失敗するとログのみで記録ゼロ。webhook（`payout.paid`/`payout.failed`）は `updateByStripePayoutId` で行が見つからず warn 止まり。次回同 period 実行では残高が payout で減っているため `held` が記録され、「実際は入金済みなのに記録は held」で固定化する（金銭被害はないが監査・突合が欠落）。
2. **並行実行レース**: Scheduler リトライと手動実行が並行すると、両方が `findByAccountAndPeriod` チェックを通過。同一 idempotencyKey により Stripe 側の二重 payout は防がれる（409/replay）が、負けた側が idempotency_error を `failed` として upsert し、勝った側の `pending`（payout ID 付き）を後勝ち上書き → 実在する payout が webhook 突合不能になる。
**修正提案:** 「先に `(stripeAccountId, period)` 行を claim（`onConflictDoNothing` で insert し、取れた実行だけが Stripe を呼ぶ）→ 成功後に payout ID を更新」の 2 段階にする。`upsert` は `pending`/`paid` からのダウングレードを許さない条件付き更新にする。少なくとも「payout 作成済みなのに記録失敗」はエラーログを監視対象にする。

---

### [Code Quality] failed 後の同一 period 再実行が idempotencyKey 再利用により 24 時間は成功しない（失敗通知メールが「再実行」を促すのと矛盾）

**ファイル:** `api/src/services/payout.service.ts:71-99` ＋ `api/src/services/payout-report.service.ts:165`
**重要度:** Medium

**該当コード:**
```typescript
// toBranch側（payout.service.ts 新規）— skip は pending/paid のみ。failed は再実行対象になる
      const existing = await payoutRunsRepo.findByAccountAndPeriod(stripeAccountId, period);
      if (existing && (existing.status === 'pending' || existing.status === 'paid')) {
        result.status = 'skipped';
        // …
      } else {
        // …
            const payout = await stripe.payouts.create(
              { amount: available, currency: PAYOUT_CURRENCY, /* … */ },
              {
                stripeAccount: stripeAccountId,
                idempotencyKey: `payout_${stripeAccountId}_${period}`,  // period 内で固定
              },
            );
```

```typescript
// toBranch側（payout-report.service.ts 新規）— 失敗通知は再実行を促す
    const body = [
      '連結アカウントへの入金（payout）が失敗しました。原因調査・再実行をご検討ください。',
```

**問題:** Stripe の idempotency key は最初のリクエストの結果（**エラー応答を含む**）を約 24 時間保存・再生する。`balance_insufficient` 等で `failed` になった後、同一 period 内（24h 以内）に運営が手動再実行すると、(a) params が同一なら保存済みエラーがそのまま再生されて再び失敗、(b) 残高が変わって amount が異なれば `idempotency_error`（параms 不一致）で失敗する。つまり**失敗通知メールが促す「再実行」は 24h 以内には決して成功しない**（24h 経過後は key 失効で成功、翌月は別 key で自然回復するため、金銭ロスや永久スタックはない）。
**修正提案:** リトライを成立させるなら idempotencyKey に試行識別子を含める（例: `payout_runs` に attempt 列を追加して `payout_${account}_${period}_${attempt}`。前指摘の claim 方式と併せて設計）。リトライ不要なら「同一 period の failed は翌日以降 or 翌月バッチで繰越回収」を仕様として確定し、失敗通知の文言とコードコメントに明記する。

---

### [Code Quality] payout webhook が DB 更新失敗を 200 で握り Stripe 再配信に乗らない ＋ payout.failed 重複配信で通知メールが毎回再送

**ファイル:** `api/src/services/webhook.service.ts:330-361`
**重要度:** Medium

**該当コード:**
```typescript
// toBranch側（新規分岐）— 失敗しても 200、通知は遷移ガードなし
      try {
        const updated = await payoutRunsRepo.updateByStripePayoutId(payout.id, {
          status: isPaid ? 'paid' : 'failed',
          // …
        });
        // …
        if (!isPaid) {
          await sendPayoutFailureNotification({ payout, connectedAccountId, run: updated });
        }
      } catch (payoutError) {
        // webhook は常に 200 を返す方針のため、突合失敗もログのみ（Stripe の再配信 or 次回バッチで吸収）。
        console.error('Error processing payout webhook:', payoutError);
      }
```

```typescript
// 既存の前例（webhook.service.ts:218-227・変更なし）— 金銭系イベントは 500 で再配信させる
      } catch (checkoutError) {
        console.error('Error processing checkout.session.completed event:', checkoutError);
        // paid 遷移＋売上集計はトランザクションでロールバック済み。500 を返して Stripe に
        // 再配信させ、次回 markPaidIfNotPaid で正しく paid 化＋再計上する（過少計上の固定化防止）。
        return { statusCode: 500, /* … */ };
      }
```

**問題:** (1) `updateByStripePayoutId` が DB 障害等で失敗しても 200 を返すため Stripe の再配信に乗らず、`payout_runs` が `pending` のまま固定化する。コメントの「常に 200 方針」は同ファイルの金銭系イベント `checkout.session.completed` では既に破られており（DB 失敗時は 500 で再配信）、payout 突合も金銭状態のため前例と不整合。(2) `payout.failed` は Stripe の重複配信のたびに `sendPayoutFailureNotification` が再送され、運営宛メールが重複する（既存 checkout 分岐は「既に paid ならスキップ」の重複ガードあり）。
**修正提案:** DB 更新の失敗時は checkout 前例に合わせて 500 を返し再配信させる。通知は「status が failed **へ遷移した時のみ**」送る（既に failed なら送らない）。

---

### [Security] 添付 CSV に数式インジェクション（CSV injection）対策がない

**ファイル:** `api/src/services/payout-report.service.ts:38,61-75`
**重要度:** Medium

**該当コード:**
```typescript
// toBranch側（新規）— 引用符二重化のみで、先頭文字ガードなし
const csvCell = (v: any) => `"${String(v ?? '').replace(/"/g, '""')}"`;
// …
  const csvRows = results.map((r) =>
    [
      r.shopName || '',          // ← applications.partner_name（LP 申請フォーム由来のユーザー入力）
      r.stripeAccountId || '',
      r.available ?? '',
      STATUS_LABEL[r.status] || r.status || '',
```

**問題:** `shopName` の実体は `applications.partnerName` で、LP 申請フォームからの**ユーザー入力**。CSV は BOM 付き＝Excel で開く運用前提であり、セル値が `=` `+` `-` `@` 始まりだと引用符囲みでも Excel が数式として評価する古典的ベクター（例: `=HYPERLINK(...)` を含むサロン名で運営端末に被害）。`failureReason`（Stripe 由来の外部文字列）も同様。
**修正提案:** `csvCell` で先頭が `=` `+` `-` `@`（およびタブ/CR）の場合にシングルクオート `'` を前置してから囲む。

---

### [Code Quality] SES Raw MIME の base64 本文/添付が未折返し（998 octets 上限超過リスク）＋ Subject encoded-word が長すぎる

**ファイル:** `api/src/services/payout-report.service.ts:90,112-132`
**重要度:** Medium

**該当コード:**
```typescript
// toBranch側（新規）— base64 が 1 行のまま MIME に埋め込まれる
const b64 = (s: string) => Buffer.from(s, 'utf-8').toString('base64');
// …
      `Subject: =?UTF-8?B?${b64(subject)}?=`,   // 日本語件名で 1 語 ≈116 字（RFC 2047 は 75 字上限）
      // …
      b64(body),        // 本文 base64 が 1 行
      // …
      b64(csvWithBom),  // CSV base64 が 1 行（明細 8〜10 行程度で 1,000 字超）
```

**問題:** 本文・CSV の base64 を改行なし 1 行で埋め込んでおり、サロン数が増えると SMTP の行長制限（998 octets, RFC 5322）を超え、送信失敗や受信側 MTA での改変・本文破損のリスクがある（RFC 2045 は base64 を 76 字折返しと規定）。テストは sesMock のため検知できない。Subject の encoded-word も 1 語 75 字超で RFC 2047 違反（多くの MUA は許容するが、折返し対応時に一緒に分割推奨）。
**修正提案:** `b64(s).match(/.{1,76}/g).join('\r\n')` のように 76 字で折り返す helper を挟む。テスト T-11/T-12 の base64 突合も折返し込みへ更新する。

---

### [Test Coverage] 運用上重要な分岐のテスト欠落（dryRun / applicationId / 非 active 除外 / period 境界）

**ファイル:** `api/src/__tests__/e2e/monthly-payouts.test.js`（T-2〜T-13 は網羅済み）
**重要度:** Medium

**問題:** 主要経路（しきい値・繰越・冪等・エラー継続・webhook・レポート）はカバーされている一方、以下が未検証:
1. `dryRun=true` で payout 未作成・`payout_runs` 未記録・レポート未送信（ここが壊れると「dry run のつもりが実入金」になるため固定必須）
2. `applicationId` 指定時に当該会社のみ処理される（指定が無視される regression は全社実行になる）
3. `stripeAccountId` を持つが active 以外（onboarding 等）の申請が除外される（`findWithStripeAccount` は SQL で status を絞らず JS 側の `normalizeApplicationStatus` フィルタ依存のため、ここが仕様の要）
4. `toPayoutPeriod` の JST 月境界 unit テスト（例: `'2026-07-31T14:59:00Z'→'2026-07'`、`'2026-06-30T15:00:00Z'→'2026-07'`。period は冪等キーに直結）
**修正提案:** 上記 4 分岐のテストを `monthly-payouts.test.js`（4 は unit でも可）へ追加する。

---

### [Lessons] T-8 の stripePayoutId が `toBeTruthy()` の弱アサーション

**ファイル:** `api/src/__tests__/e2e/monthly-payouts.test.js:170`
**重要度:** Low

**該当コード:**
```javascript
// toBranch側（新規・T-8）
    const run = await payoutRunsRepo.findByAccountAndPeriod('acct_a', PERIOD_JUL);
    expect(run).toMatchObject({ status: 'pending', amount: 8000, currency: 'jpy', period: PERIOD_JUL });
    expect(run.stripePayoutId).toBeTruthy();   // ← 弱い
```

**問題:** beforeEach の既定モックは `po_${account}_${period}` を返すため値は決定的（`po_acct_a_2026-07`）。同ファイル T-2 では同じ値を `.toBe('po_acct_a_2026-07')` で厳密検証しており、T-8 だけ弱い。vitest lesson「重要カラム（payout ID を含む）は具体値で検証する」に反する。
**修正提案:** `expect(run.stripePayoutId).toBe('po_acct_a_2026-07');` に変更。

---

### [Lessons] 退会（withdrawn）サロンの残高はバッチ対象外＝Stripe の 90 日強制出金任せになるが、その旨が未文書化

**ファイル:** `api/src/services/payout.service.ts:39-42` ＋ `api/src/repositories/applications.repository.ts:91-97`
**重要度:** Low

**該当コード:**
```typescript
// toBranch側（新規）— 対象は「未削除 かつ active」のみ
  findWithStripeAccount: async (applicationId?: string) => {
    const conds = [isNull(applications.deletedAt), isNotNull(applications.stripeAccountId)];
// …
  const targets = apps.filter(
    (a: any) =>
      a.stripeAccountId && normalizeApplicationStatus(a.status) === APPLICATION_STATUS.ACTIVE,
  );
```

**問題:** 退会（GTSS-20）は `status='withdrawn'` + `deletedAt` セットで両条件によりバッチ対象外になり、退会時に Stripe アカウントを削除/精算する処理も存在しない（`accounts.del|reject` は src に 0 件）。manual 化後の残高は #33 の設計どおり **Stripe の 90 日強制出金**が安全網となり払い出される（恒久的な取り残しはない）ため実害は限定的だが、退会サロンだけしきい値ゲート外・最大 90 日遅延という挙動がコードにもドキュメントにも明記されておらず、テストも全ケース `active` seed のみ。
**修正提案:** 「退会サロンの残高は 90 日以内に Stripe が強制出金する（しきい値ゲート適用外）」を `payout.service.ts` のフィルタ箇所コメントと `docs/tech/stripe-connect.md` に明記する。退会時に即精算したい場合は退会フローへの残高精算（手動 payout）追加を別 Issue 化する。

---

### [Code Quality] payout_runs が applications 物理削除で CASCADE 消滅し、削除バックアップにも含まれない（金銭監査記録）

**ファイル:** `api/src/db/migrations/0018_gtss854_payout_runs.sql:21` ＋ `api/src/services/application-backup.service.ts`（差分外）
**重要度:** Low

**該当コード:**
```sql
-- toBranch側（新規 migration）
ALTER TABLE "payout_runs" ADD CONSTRAINT "payout_runs_application_id_fk"
  FOREIGN KEY ("application_id") REFERENCES "applications"("application_id") ON DELETE cascade;
```

**問題:** 削除バックアップの payload は application + cancellations のみ（`buildBackupPayload`）で payout_runs は含まれず、物理削除（24h 経過後の人手削除運用）で入金実行記録が復元不能に消える。金銭監査記録としては消えてほしくない類のデータ。
**修正提案:** FK を `RESTRICT` にする、またはバックアップ payload へ payout_runs を同梱する（どちらかを選択）。

---

### [Code Quality] 通知宛先・From のコード直書き（dev バッチ実行でも実メール送信）＋ BOM 不可視リテラル

**ファイル:** `api/src/constants/payout.ts:25-31` ＋ `api/src/services/payout-report.service.ts:110`
**重要度:** Low

**問題:** (1) `PAYOUT_NOTIFY_RECIPIENTS`/`PAYOUT_MAIL_FROM` が定数直書きのため、dev でのバッチ実行・webhook テストでも実在アドレスへ実メールが飛ぶ（Issue の定数一元管理方針には準拠しているが、env で dev はダミー宛先に上書きできるとより安全）。2 人目宛先の TODO も追跡が必要。(2) `` `﻿${csv}` `` の BOM がソース中の不可視リテラルで、エディタ/フォーマッタで消えても気づけない。`'﻿' + csv` のような可視表記へ。

## 総評

**設計・実装の質は高い。** #32→#33 の統合判断（manual 一本化）はコード・テスト・Issue [Decision] が一致しており、しきい値ゲート・繰越（残高で自然成立）・冪等の二重防御（idempotencyKey + unique index）・アカウント単位の失敗分離・レポート送信失敗の握り、といった Issue の設計がそのまま実装されている。テスト（T-1〜T-13、835 passed）も主要経路を決定的に検証できている。認可 4 観点は問題なし（新規 HTTP ルートなし・batch は Lambda invoke/IAM 経由のみ・payout webhook は既存の署名検証の内側・新規レスポンス露出/マスアサインメント経路なし。3 レビュアー一致）。

**マージ前に必須なのは High の 1 件**（deploy-batch.sh の `STRIPE_SECRET_KEY`。現状のままでは dev/prod でバッチが一度も起動しない）。Medium 群は「記録整合性（claim 方式への変更）」「webhook 500 再配信への統一」「CSV injection ガード」「base64 折返し」「テスト 4 分岐追加」で、いずれも修正コストは小さい。

**デプロイ前チェックリスト（コード外・Issue 記載の運用作業と合わせて）:**
1. `deploy-batch.sh` へ `STRIPE_SECRET_KEY` 追加（High 指摘）
2. batch Lambda IAM ロールの `ses:SendRawEmail`/`ses:SendEmail` 権限確認（従来 batch は SES 不使用）
3. EventBridge Scheduler 末日 cron（外部 Terraform `cancel-billing-service-infra`）
4. Stripe ダッシュボード: Connect Webhook 購読へ `payout.paid`/`payout.failed` 追加（未設定だと REQ-4 が silent に無効。api の CLAUDE.md/docs の登録イベント一覧も更新推奨）
5. プラットフォーム設定でサロン自己変更の不可化（#32 REQ-2）

**差分外（別 Issue 推奨）:** `src/clients.ts` の SMTP フォールバックに SES の資格情報がハードコードされている（本 PR 由来ではない）。資格情報のローテーションと env 必須化を別 Issue で対応すること。

**レビュアー間の裏取りメモ（Step 6.5）:** code-reviewer の High「failed 後再実行で pending 永久スタック」は、失敗リクエストの idempotency replay は**エラー応答の再生**であり payout ID は返らないためメカニズムが不正確 → codex の再検証（idempotency_error / 24h 失効）と統合し Medium へ調整。lessons-reviewer の「退会サロン残高が恒久的に取り残される」は Stripe の 90 日強制出金（#33 設計の安全網）と矛盾するため「未文書化」の Low へ再構成。codex 指摘は全件実ファイルで裏取り済み（セッション混入なし）。
