---
issue: 34
date: 2026-07-04
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-854
    toBranch: GTSS-854-34
---

# レビュー結果: #34

## 概要

**Issue:** #34 [GTSS-854 差分] 連結アカウント入金: 90日入金期限を GTSS 側で強制スイープ（「Stripe任せ」撤回・balanceTransactions で最古未払い日を算出）

現行の連結アカウント入金（manual + しきい値ゲート）は「JP manual 保留は最大90日で Stripe が自動強制出金する」前提に依存していたが、この前提は誤り（REQ-1 で撤回）。よって GTSS 側のバッチが期限前に available 全額を強制スイープする差分を追加する。`balanceTransactions.list` から `available_on > lastPayoutAt` の charge/payment の `min(created)` を最古未払い決済日として算出し（REQ-2）、しきい値(a) OR 期限(b: age >= FORCE_PAYOUT_AGE_DAYS=75) で判定（REQ-3）。退会サロンも期限(b)のみ対象（REQ-5）。`(stripe_account_id, period='YYYY-MM')` 一意は維持（スキーマ変更なし）。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-854` | `GTSS-854-34` | 1 | 8 |

> **AC-7（docs）は本 API 差分の対象外**。`docs/tech/stripe-connect.md` の書き換えは親リポジトリ `akichim21/cancel` に別コミット（`d5cf420`）で入っており、本レビューの diff（`GTSS-854...GTSS-854-34`）には docs 変更は含まれない。
> **cron の月末→日次化はインフラ側（外部 Terraform `cancel-billing-service-infra`）管轄で本 PR 範囲外**。それまでは月次粒度で期限を追い越すリスクが残る点は Issue 本文でも明記済み。

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/services/payout.service.ts` | +137 | -16 | Modified（中核） |
| `src/repositories/payout-runs.repository.ts` | +22 | -0 | Modified（`findLastPayoutAt` 追加） |
| `src/repositories/applications.repository.ts` | +16 | -0 | Modified（`findWithdrawnWithStripeAccount` 追加） |
| `src/constants/payout.ts` | +12 | -0 | Modified（`FORCE_PAYOUT_AGE_DAYS` / `PAYOUT_LOOKBACK_BUFFER_DAYS`） |
| `src/__tests__/unit/oldest-unpaid-charge.test.js` | +136 | -0 | Added |
| `src/__tests__/e2e/force-payout-sweep.test.js` | +250 | -0 | Added |
| `src/__tests__/setup.js` | +2 | -0 | Modified（`balanceTransactions.list` モック） |
| `src/__tests__/helpers/external-mocks.js` | +1 | -1 | Modified（reset ループに追加） |

## 指摘一覧

- [x] 対応する

### [Correctness / 90日担保] `active` を離脱した残高保有アカウント（rejected/onboarding）がスイープ対象から恒久的に漏れる

**ファイル:** `api/src/services/payout.service.ts:122-142`（列挙）／ `api/src/services/application.service.ts:837-918, 1031-1043`（遷移ガード）
**重要度:** Medium

**該当コード:**
```typescript
// toBranch側（変更後）— runMonthlyPayouts の対象列挙
const activeTargets = apps
  .filter(
    (a) => a.stripeAccountId && normalizeApplicationStatus(a.status) === APPLICATION_STATUS.ACTIVE,
  )
  .map((a) => ({ ...a, __withdrawn: false }));

// REQ-5: 退会（withdrawn + deletedAt）サロンも期限(b)の対象に含める。
const withdrawnTargets = (await applicationsRepo.findWithdrawnWithStripeAccount(applicationId))
  .filter(
    (a) => a.stripeAccountId && normalizeApplicationStatus(a.status) === APPLICATION_STATUS.WITHDRAWN,
  )
  .map((a) => ({ ...a, __withdrawn: true }));

const targets = [...activeTargets, ...withdrawnTargets];
```

```typescript
// updateApplicationStatus（変更なし）— withdrawn/unverified 以外への遷移は enum 包含チェックのみで許可
if (status === APPLICATION_STATUS.WITHDRAWN) { /* 400 で拒否 */ }
if (status === APPLICATION_STATUS.UNVERIFIED) { /* 400 で拒否 */ }
if (!APPLICATION_STATUS_VALUES.includes(status)) { /* 400 */ }
// ↑ active → rejected / active → onboarding/approved は素通り。rejected 遷移は
//   deletedAt を NULL のまま・stripeAccountId を保持したまま status='rejected' に更新するだけ。
```

**問題:** 期限強制スイープの対象は `active`（`deletedAt IS NULL`）と `withdrawn`（`deletedAt IS NOT NULL`）の2ステータスのみ。しかし `updateApplicationStatus` は `active → rejected`（および `→ onboarding/approved`）を**ガードしていない**（`withdrawn`/`unverified` のみ拒否）。稼働中に available 残高を貯めた連結アカウントが admin 操作で `rejected` へ遷移すると、`deletedAt` は NULL のまま・`stripeAccountId` も保持されるため、`findWithStripeAccount`（status を active に絞る）にも `findWithdrawnWithStripeAccount`（`deletedAt IS NOT NULL` を要求）にも**列挙されず、GTSS 側の期限スイープから恒久的に漏れる**。本 PR は REQ-1 で「90日は Stripe 任せ」前提を撤回したため、これらの残高を Stripe の自動出金に頼る backstop も設計上失われている（＝PR 自身の主張と矛盾する未カバー領域）。
`active → rejected` が実運用で起きるか（審査却下ではなく稼働サロンの停止として使われるか）に依存するが、起きた場合は顧客から受領した資金が90日超滞留し得る。
（関連: 退会側 `withdrawnTargets` の status 述語も、現状は `maskApplicationPii` が論理削除時に必ず `status='withdrawn'` を設定する（`application.service.ts:1232`）ため安全だが、将来 soft-delete が別 status を残す経路を増やすと同様に漏れる。退会側は `deletedAt IS NOT NULL` のみで対象化し、しきい値非適用は `__withdrawn` フラグで判定する方が堅牢。）

**修正提案:** 「`stripeAccountId` を持ち available 残高が残りうる全ステータス」を列挙観点で洗い出す。`rejected`/`onboarding` に残高が残り得るなら期限(b)の対象に含めるか、含めないなら「なぜ残高ゼロが保証されるか」の根拠をコメントで明示する。あわせて「active で残高を貯めた後 rejected へ遷移した口座」のテストを追加し、スイープ対象になる／意図的に対象外である挙動を固定する。

---

### [Correctness / 90日担保] `PAYOUT_LOOKBACK_BUFFER_DAYS=14` が Stripe の pending 保留窓を下回ると最古未払いを取りこぼす

**ファイル:** `api/src/services/payout.service.ts:91-108`／ 定数 `api/src/constants/payout.ts:26-30`
**重要度:** Medium

**該当コード:**
```typescript
// toBranch側（変更後・新規）
const params = {};
if (lastPayoutSec !== null) {
  params.created = { gt: lastPayoutSec - PAYOUT_LOOKBACK_BUFFER_DAYS * 86400 }; // = lastPayoutAt − 14日
}
const txns = await listAllBalanceTransactions(stripeAccountId, params);

let oldest = null;
for (const t of txns) {
  if (t?.type !== 'charge' && t?.type !== 'payment') continue;
  if (lastPayoutSec !== null && !(Number(t?.available_on) > lastPayoutSec)) continue; // 未払い判定
  const created = Number(t?.created);
  if (!Number.isFinite(created)) continue;
  if (oldest === null || created < oldest) oldest = created;
}
```

**問題:** 未払い判定は `available_on > lastPayoutAt` で行うが、取得クエリは `created > lastPayoutAt − 14日` で下限を絞っている。この `created` 下限は「pending 窓ぶん遡る」取得件数削減の最適化にすぎないが、下限が Stripe の実 pending 期間より短いと、**「lastPayoutAt 時点で pending・かつ `created` が14日超前」の決済がクエリから丸ごと除外**され、`available_on > lastPayoutAt` の未払いなのに集計に入らず `oldest` が過小（age 過小評価）→ **force スイープ漏れ**になる。これは90日を「追い越す」唯一の方向。
具体例: ¥1,000 単発（しきい値未達）で、新規/高リスク口座のため Stripe が20日間 pending 保持 → `created = D−20, available_on = D+3`（D=lastPayoutAt）。下限 `D−14` により除外され、以後この口座に決済が来ない低頻度サロンだと force が発火せず available に90日超滞留し得る。通常の T+4 営業日フローでは14日で十分だが、リスク保留・準備金(reserve)・新規口座保留は14日を超え得る。
**関連（同根の派生・pathological）:** `(stripe_account_id, period='YYYY-MM')` 一意 × 日次では、既存 `pending/paid` 行があると残高取得前に `skipped`（`payout.service.ts:179-187`）となり「口座×暦月＝最大1入金」。当月に長期 pending だった決済が同月内に75日到達しても次月頭までスイープできず、`75 + 最大約30日` が90を超える余地がある。Issue の「スイープ後は最古未払い資金が数日齢にリセット」という前提は、available 化遅延が本バッファ以内であることとセットでのみ成立する。

**修正提案:** バッファを Stripe の想定最大保留（例: `FORCE_PAYOUT_AGE_DAYS` 相当）に合わせて拡大するか、`created` 下限を撤廃して `available_on` 側のみで判定する（下限は行数削減の最適化であり90日担保より優先しない）。少なくとも「pending ≤ 14日」の前提と超過時の挙動をコメントに明示する。

---

### [Code Quality] 中核ファイルの冒頭コメントが旧「しきい値のみ・月次繰越」記述のままドリフト

**ファイル:** `api/src/services/payout.service.ts:1-6, 110`／ `api/src/batch.ts:60`
**重要度:** Low

**該当コード:**
```typescript
// toBranch側（変更後）— ヘッダは旧仕様のまま（期限強制スイープ(b)・退会サロン・日次実行を反映していない）
// runMonthlyPayouts は … しきい値（PAYOUT_THRESHOLD_JPY 以上）に達している時だけ payouts.create を1件実行する。
//   未達は保留（held）し残高に残る＝翌月以降へ自然に繰り越す。判定・入金額は Stripe の available のみで決める。
...
// 月次入金バッチ本体。   ← 実態は日次実行
```

**問題:** 冒頭コメントが今回追加した (b) 期限トリガー・退会サロン対象・日次実行を一切反映しておらず、中核ファイルの契約説明が実装と矛盾する。`batch.ts:60` のコメントも依然 `当月末日 cron` と記載（本体の cron 変更は外部 Terraform 管轄だが、コメントの整合は取れる）。関数名 `runMonthlyPayouts`・コメント「月次入金バッチ本体」も日次化と乖離（改名は影響大なので据え置き可、コメントは修正可能）。

**修正提案:** 冒頭コメントに (b) 期限トリガー・退会サロンの (a) 非適用・日次化・`(account, period)` 一意との相互作用を追記。`batch.ts:60` の cron 記述も日次へ更新。

---

### [Correctness / Robustness] `listAllBalanceTransactions` の 100 ページ安全上限が「最古」を切り捨てる方向

**ファイル:** `api/src/services/payout.service.ts:53-71`
**重要度:** Low

**該当コード:**
```typescript
// toBranch側（変更後・新規）
for (let page = 0; page < 100; page += 1) {
  const res = await stripe.balanceTransactions.list(
    { limit: 100, ...params, ...(startingAfter ? { starting_after: startingAfter } : {}) },
    { stripeAccount: stripeAccountId },
  );
  const data = res?.data || [];
  all.push(...data);
  if (!res?.has_more || data.length === 0) break;
  startingAfter = data[data.length - 1]?.id;
  if (!startingAfter) break;
}
return all; // ← has_more=true のまま部分結果を正常返却（切り捨てを検知しない）
```

**問題:** Stripe list は既定で **created 降順（新しい順）**、`starting_after` は古い方へ辿る。上限（100ページ×100＝1万件）到達で打ち切ると、収集済みは**新しい側1万件**で、知りたい `min(created)`（最古）が落ちる → age 過小評価 → force 漏れ（切り捨て方向が不安全）。`lastPayoutAt≠null` なら窓が狭く現実的に到達しないが、**`lastPayoutAt=null`（初回/cutover 未実施）では `created` 下限が付かず全履歴が対象**（`payout.service.ts:93` の分岐）なので、長期・高頻度サロンの初回に限り到達し得る。しかも force しなければ `lastPayoutAt` は null のままで、毎回同じ切り捨てを繰り返し持続的に漏れる。

**修正提案:** 上限到達（`page===99 && has_more===true`）を黙って切り捨てず、`MONITOR` ログを出す／防御的に force 扱いにする等で運用検知可能にする。REQ-6 の cutover full sweep（`lastPayoutAt` を seed する運用）を必須手順として明文化する。

---

### [Code Quality / Observability] 新規 result フィールドがレポート/CSV に露出せず、`held` ラベルが不正確

**ファイル:** `api/src/services/payout.service.ts:172-174`（付与）／ `api/src/services/payout-report.service.ts:18, 53-98`（未露出）
**重要度:** Low

**該当コード:**
```typescript
// payout.service.ts（変更後）— result に積むが…
withdrawn: isWithdrawn,
oldestUnpaidChargeAt: null,
forcedByAge: false,
```
```typescript
// payout-report.service.ts — 本文にも CSV にもこれらを出さない（grep 0 件）。
STATUS_LABEL.held = 'しきい値未達で保留'; // 退会サロン/期限未達の held では意味が誤り
```

**問題:** `processOne` は `forcedByAge` / `withdrawn` / `oldestUnpaidChargeAt` を result に積むのに、`buildPayoutReport` はこれらを本文にも CSV にも出さない。運営はレポートから「なぜしきい値未満なのに入金されたのか（期限強制か）」「退会サロン分か」を判別できない。加えて `held` ラベル「しきい値未達で保留」は、退会サロン（しきい値非適用）や「期限未達で保留」のケースでは文言が誤り。

**修正提案:** CSV/明細に `期限強制(forcedByAge)`・`退会(withdrawn)`・`最古未払い日` 列を追加し、`held` ラベルを「保留（繰越）」等の中立表現へ。

---

### [Performance] 退会サロンが恒久的に毎日列挙され、残高0でも `balance.retrieve` を叩き続ける

**ファイル:** `api/src/repositories/applications.repository.ts:107-115`／ `api/src/services/payout.service.ts:133-140`
**重要度:** Low

**該当コード:**
```typescript
// 変更後・新規
findWithdrawnWithStripeAccount: async (applicationId) => {
  const conds = [isNotNull(applications.deletedAt), isNotNull(applications.stripeAccountId)];
  if (applicationId) conds.push(eq(applications.applicationId, applicationId));
  const rows = await getDb().select().from(applications).where(and(...conds));
  return rows.map(toDomain);
},
```

**問題:** 退会サロンは残高を払い切った後も条件（`deletedAt IS NOT NULL AND stripe_account_id IS NOT NULL`）に残るため、日次バッチが**全退会サロンについて毎日 `findByAccountAndPeriod` + `balance.retrieve`** を実行し続ける（残高>0 の日はさらに `balanceTransactions.list` ページング）。退会サロンが年々蓄積するとバッチの Stripe API 呼び出し・実行時間が単調増加する（退会フローは Connect アカウントを deauthorize せず `stripeAccountId` を保持するため `balance.retrieve` 自体は成功する）。

**修正提案:** 残高が恒久的に枯れた退会サロンを対象から外す仕組み（直近スイープ後 `available=0` が一定期間続いたら除外、または「未払い決済が残っている退会サロンのみ」に絞る述語）を検討する。

---

### [Code Quality] 未払い種別フィルタが「直接チャージ」モデル前提に暗黙結合

**ファイル:** `api/src/services/payout.service.ts:100`
**重要度:** Low（情報）

**該当コード:**
```typescript
if (t?.type !== 'charge' && t?.type !== 'payment') continue; // 決済種別のみ
```

**問題:** 本コードベースは `checkout.sessions.create(..., { stripeAccount })`（`invoice.service.ts:267-272`）＝connected account 上の**直接チャージ**なので、入金は connected account 側で `charge` 種別の balance transaction として現れ、現状のフィルタは正しい。ただし将来チャージ方式を destination charge / separate transfers に変えると、connected account 側の入金は `transfer` 種別になり本フィルタで取りこぼす（→ age 過小・force 漏れ）。

**修正提案:** この結合（直接チャージ前提）を1行コメントで明示しておく。

---

### [Test Coverage] 送金 ID 未検証 & 90日担保の中核シナリオ（複数月キャリー等）が未カバー

**ファイル:** `api/src/__tests__/e2e/force-payout-sweep.test.js:87-249`／ `api/src/__tests__/unit/oldest-unpaid-charge.test.js:116-135`
**重要度:** Low

**該当コード:**
```javascript
// force-payout-sweep.test.js — amount/status/forcedByAge は具体値で検証するが stripePayoutId は未検証
expect(results[0].status).toBe('pending');
expect(results[0].forcedByAge).toBe(true);
// beforeEach で payouts.create が決定的 id（po_${account}_${period}）を返すのに result/DB の stripePayoutId を assert しない
```

**問題:**
1. `.claude/skills/vitest/lesson.md`「送金の重要カラム（`amount, stripePayoutId, status`）は網羅的に expect する」に対し、強制スイープ成立ケースで `stripePayoutId` を検証していない（finalize による payout ID 記録が壊れても緑になる）。
2. 指摘（lookback / 100ページ上限 / 月跨ぎ）に対応する回帰テストが無い。特に **月Mでしきい値入金→pending 資金が翌月 M+1 に持ち越され force される複数月キャリー**（`now` を月跨ぎで2回進める e2e）は、本 PR の「同一暦月最大1入金 × force」の相互作用そのもので、追加価値が高い。

**修正提案:** 強制スイープ成立ケースに `expect(results[0].stripePayoutId).toBe('po_acct_a_2026-07')`（および `run.stripePayoutId` / `payouts.create` の `metadata`）を追加。複数月キャリー・pending窓>バッファ・100ページ上限到達の e2e/unit を各1本追加する。

---

## 総評

中核ロジックは概ね健全。「payout は常に available 全額をスイープする」不変条件により、あるスイープ後に残るのは `available_on > lastPayoutAt`（＝スイープ時 pending）の資金だけ、という設計は正しく、claim/finalize・`idempotencyKey`(attempt 込み)・`(account, period)` 一意・no-downgrade upsert の冪等基盤も #33 から無改変で踏襲されている。退会/アクティブ列挙は `deletedAt` で厳密に disjoint（二重処理なし）、レポート間引き（`executedCount>0 || failedCount>0` のみ送信）も既存 `monthly-payouts.test.js`（T-11/T-12/T-13 は入金を含む・T-12b は builder 直呼び・T-14 は dryRun）を壊さないことを確認した。新規テストは境界(=75日)・ページング・cutover・退会共存を良く押さえ、弱アサーション・モック汚染も見当たらない。

**検討したが defect ではないと確認した点:** `findLastPayoutAt` が `created_at`（held 行の初回 insert 時刻）を基点にする件は、`created_at ≤ 実入金時刻` が常に成り立つため未払いを**過大**計上＝force が**早まる**（安全側）方向で、90日超過には繋がらない。精度・保守性の情報提供に留まる。

**最重要:** 指摘はいずれも「90日規制を確実に担保できるか」という**保守側の縁**（対象ステータスの網羅・lookback 窓・pagination 上限・period 粒度）に集中している。通常の Stripe T+4 フローでは顕在化しないが、**① `active` を離脱した残高保有アカウント（rejected 等）** と **② 14日超の pending/リスク保留** の2つは late-payout（90日超過）に繋がり得るため、対象列挙の網羅とバッファ/上限の保守化（または前提の明文化と運用検知）を優先で対応することを推奨する。cron の日次化（インフラ側）が入るまでは月次粒度の追い越しリスクも併存する点に留意。

**保存先:** `.claude/docs/review-result-2026-07-04.md`
