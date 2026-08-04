---
issue: GTSS-854 (PR #30 / api)
date: 2026-07-04
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-854-34
    toBranch: GTSS-854-payout-safeguards
---

# レビュー結果: GTSS-854 PR #30（連結アカウント入金の90日担保を強化）

## 概要

**PR:** [#30](https://github.com/GO-TODAY-SHAiRE-SALON/cancel-billing-service-api/pull/30) feat(GTSS-854) 連結アカウント入金の90日担保を強化（例外検知スイープ・滞留アラート・webhook購読・stale回復）

（GTSS-854 は GitHub Issue ではなくチケットID。仕様は PR 本文を根拠にレビュー。base は前段の #34＝`GTSS-854-34`）

`GTSS-854-34`（連結アカウント入金の90日期限強制スイープ）の運用堅牢化。dev 検証中に見つかった「90日規制を破り得る抜け穴」を塞ぐ差分:

- **例外検知スイープ (b')**: 直近入金（`lastPayoutAt`）があるのに `available>0` を説明する未払い決済が 0 件なら「見えない資金」（reserve 解放 / dispute 返戻 / payout 失敗の資金戻り / 取得窓漏れの古い決済）とみなし、当該アカウントだけ即スイープ。
- **滞留アラート**: `available>0` のまま直近入金から `PAYOUT_STALE_ALERT_DAYS`(80) 超で保留された口座を MONITOR ログで通知（スイープしない）。
- **webhook 購読の仕組み化**: `scripts/ensure-stripe-webhook.ts` で `/webhook/stripe` の必須イベント不足を確認・追加。
- **stale processing 自動回復**: `updated_at` が `STALE_PROCESSING_RECLAIM_MINUTES`(120分) 超の `processing` 行を `claim` で再確保（attempt 据え置き＝同一 idempotencyKey）。
- 観測ログ・レポート列（例外検知 / 滞留警告）追加。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-854-34` | `GTSS-854-payout-safeguards` | 1 | 9 |

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `scripts/ensure-stripe-webhook.ts` | +118 | -0 | Added |
| `src/services/payout.service.ts` | +75 | -3 | Modified |
| `src/repositories/payout-runs.repository.ts` | +25 | -6 | Modified |
| `src/constants/payout.ts` | +16 | -0 | Modified |
| `src/services/payout-report.service.ts` | +8 | -2 | Modified |
| `src/__tests__/e2e/force-payout-sweep.test.js` | +97 | -0 | Modified |
| `src/__tests__/e2e/payout-stale-processing.test.js` | +73 | -0 | Added |
| `src/__tests__/unit/ensure-stripe-webhook.test.js` | +60 | -0 | Added |
| `package.json` | +3 | -1 | Modified |

## 総評（先に）

全体として設計意図が明快でコメント・テストとも密度が高く、レビューで確認した**核心ロジックは正しい**:

- `claim` の `onConflictDoUpdate` の `setWhere`/`attempt` CASE は、ON CONFLICT が既存行の `status`/`updatedAt`/`attempt` を参照する前提が正しく、stale reclaim 時のみ attempt 据え置き・held/failed は attempt+1 という意図どおりに動く。
- `lt(payoutRuns.updatedAt, staleBefore)` は `updated_at` が `timestamptz(mode:'string')`・`staleBefore` が `…Z` 付き ISO 文字列のため、Postgres 側で timestamptz 比較として成立する（文字列比較にならない）。同一パターンが既存 repository で dev/prod(aws-data-api) 稼働実績あり。
- 例外検知 (b') の発火条件 `oldest===null && lastPayoutAt!=null` は、正常アカウントの `available>0` を生む charge が `available_on>lastPayoutSec` を満たし `oldest` に載るため誤検知せず、未入金口座は門番で除外され、truncation 時も構造上誤発火しない。
- webhook スクリプトの必須イベント4種は `webhook.service.ts` が実処理する4種と完全一致。レポート CSV の header/row は 13 列で整合。lessons 照合は一致なし。

以下は**注目すべき指摘のみ**。最重要は指摘1（stale reclaim が「対策3が守るはずの当のケース」を回復できない、かつ安全論が cron 周期に依存）。

---

## 指摘一覧

- [x] 対応する

### [Code Quality] stale processing 自動回復（対策3）の到達性と安全論が cron 周期に依存し、主要ケースを回復できない

**ファイル:** `api/src/services/payout.service.ts:280` / `:365`、`api/src/repositories/payout-runs.repository.ts:83-96`、`api/src/services/webhook.service.ts:351-355`、`api/src/constants/payout.ts:415`
**重要度:** Medium（財務移動・90日担保自体は壊れないが、対策3が謳う自己回復が主要ケースで不成立＋安全コメントが現構成で不正確）

**該当コード（変更後・payout.service.ts）:**
```typescript
      // 残高が無ければ入金しようがないので保留（従来 available<threshold の一部・回帰維持）。
      if (available <= 0) return recordHeld();          // ← :280 早期 return
      ...
      // (account, period) を processing で確保。取れた実行だけが Stripe を呼ぶ（レビュー #2/#3）。
      const claimed = await payoutRunsRepo.claim({       // ← :365 stale reclaim はここでしか起きない
        applicationId: app.applicationId,
        stripeAccountId,
        period,
      });
```

**該当コード（変更後・payout-runs.repository.ts claim）:**
```typescript
        set: {
          status: 'processing',
          attempt: sql`CASE WHEN ${payoutRuns.status} = 'processing' THEN ${payoutRuns.attempt} ELSE ${payoutRuns.attempt} + 1 END`,
          updatedAt: new Date().toISOString(),
        },
        setWhere: or(
          inArray(payoutRuns.status, ['held', 'failed']),
          and(eq(payoutRuns.status, 'processing'), lt(payoutRuns.updatedAt, staleBefore)),
        ),
```

**問題:**

1. **対策3が謳う主要ケース（`payouts.create` 成功直後クラッシュ）を回復できない。** payout 作成が成功すると connected account の `available` は即座に減る。次回実行では `available<=0` → `:280` の早期 return で `recordHeld()` に入り、**`:365` の `claim`（=stale reclaim）に到達しない**。結果、
   - `processing` 行が `stripePayoutId=null` のまま無期限に孤児化する。
   - 実際に成功した payout が DB に記録されない。webhook `payout.paid` は `findByStripePayoutId(payout.id)` で引くが行に `stripePayoutId` が無いため一致せず、`webhook.service.ts:351-355` が「no payout_run found」を warn するだけで**バックフィルしない**（＝ledger 上、成功 payout がどこにも残らない）。
   - stale reclaim が実際に発火するのは「クラッシュ後に新規入金で `available>0` に戻った」場合のみで、これは対策3が主眼に置いた「create 成功直後クラッシュ」の回復とは別ケース。

2. **安全論 `STALE_PROCESSING_RECLAIM_MINUTES(120分) << 24h` が cron 周期に依存し、現構成では不正確。** `120分` は「再確保の対象になる最小 staleness」であって「再確保までの最大遅延」ではない。実 reclaim は「次に同じ (account, period) で `claim` が呼ばれる実行」＝ cron 周期に律速される。
   - **現状は月次 cron**（PR 本文「塞ぐ穴」項目4: `cron が月末のまま（→ インフラ側で日次化。別 PR）`）。月次だと次回自動実行は**別 period**（新規行を insert）となり、取り残された旧 period の `processing` 行は自動実行では二度と reclaim されない（＝この機能は日次 cron 前提で、現状は事実上不発）。
   - `batch.ts:60-62` のコメントは `#34 で当月末日 → 日次へ変更` と書いており、PR 本文（月次のまま）と食い違う（batch.ts は本 PR の差分外だが、対策3の安全性がこの前提に乗っているため要整合）。
   - 日次化後でも、クラッシュが直前実行の直後だと reclaim は原 create から最悪 ~24h に着地し、Stripe idempotency の 24h 失効境界に重なる。失効後に同一キー・**異なる金額**で再送すると Stripe が `idempotency_error`（パラメータ不一致）で弾く→failed→翌実行 attempt+1 で救済されるため「同一資金の二重払い」は狭い条件だが、コメントの「冪等有効期間内に必ず再確保される」という保証は厳密には成立しない。

**修正提案:**
- stale `processing` の回復を `available<=0` の早期 return より前に処理する（＝残高が枯れていても孤児 processing を検知して整合させる）。もしくは webhook 側で「`stripePayoutId` 無しの stale processing」を metadata（`period`/`applicationId`）で突合してバックフィルする経路を足す。
- reclaim 時に同一パラメータで再送できるよう `claim` 時に amount/currency/metadata を保存し、create 前に `stripe.payouts.list({ /* metadata.period */ }, { stripeAccount })` で既存 payout を照合してから finalize のみ行う。
- staleness に**上限**を設け、idempotency ウィンドウ（例 ~20h）超の processing は自動 reclaim+再送せず手動突合アラートに落とす。
- 対策3の安全論は日次 cron 稼働が前提。`batch.ts` コメントと PR 本文（＋インフラ側 cron 適用状況）を整合させ、日次化前にこのコードに依存しない旨を明記する。

---

### [Test Coverage] 「stale reclaim → 同一 idempotencyKey 再送」という核心が結合テストで検証されていない

**ファイル:** `api/src/__tests__/e2e/payout-stale-processing.test.js:305-317`
**重要度:** Medium

**該当コード（変更後）:**
```javascript
  it('取り残し processing（updated_at が閾値超）は再確保できる／attempt は据え置き（同一 idempotencyKey）', async () => {
    const first = await payoutRunsRepo.claim(ARGS);
    expect(first.attempt).toBe(1);
    await ageUpdatedAt(STALE_PROCESSING_RECLAIM_MINUTES + 1);
    const reclaim = await payoutRunsRepo.claim(ARGS);
    expect(reclaim).not.toBeNull();
    expect(reclaim.status).toBe('processing');
    expect(reclaim.attempt).toBe(1);   // ← repository 層の attempt 値しか見ていない
  });
```

**問題:** 追加テストは **repository 層の `attempt` 値**（据え置き=1 / failed=+1）しか assert していない。本 PR の load-bearing な主張＝「stale reclaim 後、`runMonthlyPayouts` 経由で **同一 `idempotencyKey` が再送**され Stripe 冪等が二重を防ぐ」は、`runMonthlyPayouts` を通す e2e で一度も実行されていない。`stripe.payouts.create` のモックは呼び出し引数を記録できる（`force-payout-sweep.test.js` が `mock.calls[0][0]` を検査済み）。

**修正提案:** 「取り残し reclaim 後の `stripe.payouts.create` が、原 attempt と同じ `idempotencyKey` オプション（`payout_<acct>_<period>_1`）で呼ばれる」ことを assert する e2e を追加する。あわせて指摘1の「create 成功→finalize 前クラッシュ→次回 available<=0」シナリオの e2e があれば、対策3の到達性ギャップも回帰で顕在化できる。

---

### [Code Quality] 「滞留警告のみ」の実行日はレポート（メール/CSV）が送られない

**ファイル:** `api/src/services/payout.service.ts:466`、`api/src/services/payout-report.service.ts:30-42`
**重要度:** Medium

**該当コード（変更後・payout.service.ts）:**
```typescript
  // 「入金実行（pending/paid）or 失敗（failed）が 1 件以上」の実行だけ送る。held/skipped のみの日は送らない。
  const hasReportable = summary.executedCount > 0 || summary.failedCount > 0;
  if (!dryRun && hasReportable) {
    await sendPayoutRunReport({ period, results });
  }
```

**該当コード（変更後・payout-report.service.ts）:**
```typescript
export const summarizePayoutResults = (results: any[] = []) => {
  const executed = results.filter((r) => r.status === 'pending' || r.status === 'paid');
  return {
    ...
    heldCount: results.filter((r) => r.status === 'held').length,   // held は executed/failed に含まれない
    failedCount: results.filter((r) => r.status === 'failed').length,
```

**問題:** `staleAlert` 口座は `status='held'`（スイープしない）。`hasReportable` は pending/paid/failed の件数のみ見るため、「その日 payout も失敗も無いが滞留口座だけある」実行日は `hasReportable=false` となり `sendPayoutRunReport` が呼ばれず、本 PR で追加した CSV「滞留警告」列・本文が運営メールに届かない。日次 cron ではこうした静かな日が多発し得、滞留口座は 80→90 日の間 CloudWatch ログ（`console.warn` MONITOR）にしか現れない。

**補足:** PR 本文は滞留アラートの通知手段を「MONITOR ログ」と規定しており、`payout.service.ts:333` の `console.warn` は発火する（＝一次チャネルは仕様準拠）。ただし追加した報告列の実効性は損なわれる。

**修正提案:** `hasReportable` に `results.some(r => r.staleAlert)` を含める、または滞留専用の軽量通知を送る。staleAlert のみで SES 送信されることを固定する e2e を追加。

---

### [Code Quality] `isTargetEndpoint` の pathname 完全一致が stage 付き raw API GW URL を取りこぼす（コメントの設計意図と矛盾）

**ファイル:** `api/scripts/ensure-stripe-webhook.ts:65-74`
**重要度:** Medium（ただし exit 1 で loud に失敗＝サイレント誤購読ではない。prod がカスタムドメイン運用なら現時点では顕在化しない）

**該当コード（変更後）:**
```typescript
const WEBHOOK_PATH = '/webhook/stripe';

const isTargetEndpoint = (ep: any): boolean => {
  if (ep?.status !== 'enabled') return false;
  try {
    return new URL(ep.url).pathname === WEBHOOK_PATH;   // ← 完全一致
  } catch {
    return false;
  }
};
```

**問題:** スクリプト冒頭コメントは「**カスタムドメイン/生 API GW URL の揺れ**があるため完全一致ではなく path で特定する」と明言しているのに、実装は `pathname === '/webhook/stripe'` の完全一致。`serverless.yml` はカスタムドメインプラグイン不使用・`stage: ${opt:stage,'dev'}` + `path: /{proxy+}` 構成のため、raw invoke URL は `https://{id}.execute-api.ap-northeast-1.amazonaws.com/dev/webhook/stripe`（pathname=`/dev/webhook/stripe`）となり、完全一致では対象 0 件 → エラー終了し購読保証が働かない。カスタムドメイン `api.cancel.co.jp/webhook/stripe` なら一致する。実際にどちらが Stripe に登録済みかはダッシュボード状態依存（コードからは判定不能）。

**修正提案:** `new URL(ep.url).pathname.endsWith('/webhook/stripe')` に緩めるか、環境別 `WEBHOOK_URL` で明示照合する。`/dev/webhook/stripe`・`/prod/webhook/stripe` を含む `isTargetEndpoint` の unit test を追加する（現状 `isTargetEndpoint` はテスト無し）。

---

### [Test Coverage] `held → attempt+1` 経路と `isTargetEndpoint` が未テスト

**ファイル:** `api/src/__tests__/e2e/payout-stale-processing.test.js`、`api/src/__tests__/unit/ensure-stripe-webhook.test.js`
**重要度:** Low

**問題:** `claim` の分岐は `failed → attempt+1` のみテストされ、**`held → attempt+1`**（しきい値未達で held になった行が翌実行の残高増/期限到達で再確保される主経路）が未テスト。同一 CASE 分岐だが主経路のため回帰価値あり。webhook 側も純関数 `resolveMissingEvents` のみで、`isTargetEndpoint`（URL path 抽出・status フィルタ・不正 URL の try/catch）は未テスト。

**修正提案:** `held → attempt+1` の e2e/unit と `isTargetEndpoint` の unit を追加（指摘4の修正と同時に行うと効率的）。

---

### [Code Quality] 例外検知スイープ (b') に最小金額ゲートが無い

**ファイル:** `api/src/services/payout.service.ts:309-324`
**重要度:** Low

**該当コード（変更後）:**
```typescript
        } else if (lastPayoutAt) {
          // (b') 例外検知（#34-2）: …未払い決済で説明できない「見えない資金」→ 当該アカウントだけ即スイープ
          shouldSweep = true;
          result.forcedByOrphan = true;
          console.warn(`[payout] MONITOR orphan: available=${available} …`);
        }
```

**問題:** (b') は金額下限ゲートが無い。持続的な微少残余（数円の reserve 端数等・返金相殺で `oldest` に載らないケース）が毎実行スイープ対象になり、Stripe の最小 payout 額を下回ると `payouts.create` 失敗 → failed 記録 → 翌実行 attempt+1 再試行…とノイズ化し得る。`available=0` へ戻る正常系は T-O5 で担保されているので影響は限定的。

**修正提案:** (b') に小額ゲート（例: `available >= 最小 payout 額`）を設けるか、orphan 由来 failed が一定回数続いたら滞留アラート側へ落とす。

---

## 参考

- Codex 生出力: `/private/tmp/claude-501/-Users-aki-cancel/764e4f69-34ce-4234-9ed9-100bcf09ee01/scratchpad/codex-review-output-api.txt`
- 差分/ログ: `/tmp/review-diff-api.txt` / `/tmp/review-log-api.txt`
- 検証済みで問題なしと判断（＝指摘に含めない）: `claim` の CASE/setWhere・timestamptz 比較・(b') 発火条件と truncation 安全性・`resolveMissingEvents`・レポート列整合・lessons 照合（一致なし）。
