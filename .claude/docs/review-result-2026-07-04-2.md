---
issue: 35
date: 2026-07-04
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-854-payout-safeguards
    toBranch: GTSS-854-sqs
  - repo: infra
    repoDir: infra/cancel-billing-service-infra
    baseBranch: GTSS-854-payout-daily-cron
    toBranch: GTSS-854-sqs
---

# レビュー結果: #35

## 概要

**Issue:** #35 [Infra/API] バッチ Lambda を SQS ファンアウト（coordinator + worker + DLQ）化し、逐次ループによるタイムアウトのスケール限界を解消（月次入金 GTSS-854 / サロンボード取り込み GTSS-817）

月次入金（`run-monthly-payouts`）とサロンボード取り込み（`salonboard-import`）の直列ループを、**coordinator（対象列挙 → SQS enqueue）→ worker（SQS トリガーで 1 単位ずつ並列処理）** へ移行する。フィーチャーフラグ（`PAYOUT_FANOUT`/`IMPORT_FANOUT=sqs` + queue URL）で新旧を切替。段階移行（dev で `enable_fanout=true` 検証 → prod）。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-854-payout-safeguards` | `GTSS-854-sqs` | 2 | 19（うち lockfile 1・テスト 5） |
| infra | `GTSS-854-payout-daily-cron` | `GTSS-854-sqs` | 1 | 5 |

**全体所見:** 設計の骨格（二相分離・冪等担保・標準キュー選定・IAM の 2 キュー限定スコープ・ESM `depends_on`・visibility timeout ≥ worker timeout・`enable_fanout` 既定 false / worker `required=0` の安全な段階移行）は堅実で、金銭移動（`payout_runs` の claim + attempt idempotencyKey）は二重入金から保護されている。**懸念は「入金そのもの」ではなく「実行レポートの直列版との等価性（AC-2.2）」に集中**する。SQS の at-least-once + 部分失敗セマンティクスに対し、`count==expected` の完了検知・item の無条件 upsert・非原子な enqueue・送信前の `report_sent` 確定が複数経路で脆く、レポートが静かに欠落/不正確になり得る。しかもその検知手段である DLQ アラームが SNS 未結線で通知されない（INFRA-1）。**dev 検証前に High 2 件 + Medium 2 件の手当てを推奨。**

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/batch.ts` | +55 | -3 | Modified（SQS Records 経路 dispatch） |
| `src/config.ts` | +26 | 0 | Modified（フラグ解決） |
| `src/services/payout.service.ts` | +157 | -29 | Modified（coordinator/worker/`processOnePayout` 抽出・レポート DB 再生成） |
| `src/services/salonboard-import.service.ts` | +72 | -1 | Modified（coordinator/worker） |
| `src/services/sqs.service.ts` | +60 | 0 | Added（enqueue ヘルパ） |
| `src/services/batch-fanout.service.ts` | +55 | 0 | Added（`processWorkerRecords` 部分バッチ応答） |
| `src/repositories/payout-run-batches.repository.ts` | +47 | 0 | Added |
| `src/repositories/payout-run-items.repository.ts` | +92 | 0 | Added |
| `src/db/schema.ts` | +48 | 0 | Modified（payout_run_batches / payout_run_items） |
| `src/db/migrations/0020_gtss854_sqs_payout_fanout.sql` | +39 | 0 | Added |
| `src/db/migrations/meta/_journal.json` | +7 | 0 | Modified |
| `deploy-batch.sh` | +120 | -118 | Modified（3 関数へ配備） |
| `package.json` / `package-lock.json` | — | — | Modified（`@aws-sdk/client-sqs` 追加） |
| `src/__tests__/e2e/payout-fanout.test.js` | +303 | 0 | Added |
| `src/__tests__/e2e/salonboard-import-fanout.test.js` | +145 | 0 | Added |
| `src/__tests__/unit/batch-fanout.test.js` | +56 | 0 | Added |
| `src/__tests__/unit/sqs-service.test.js` | +47 | 0 | Added |
| `src/__tests__/e2e/schema.test.js` | +4 | -1 | Modified（13→15 テーブル） |

### infra

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `modules/batch-compute/fanout.tf` | +247 | 0 | Added（SQS×2 + DLQ×2 + worker×2 + ESM + IAM + アラーム） |
| `modules/batch-compute/variables.tf` | +95 | 0 | Modified |
| `modules/batch-compute/outputs.tf` | +35 | 0 | Modified |
| `dev/main.tf` | +30 | 0 | Modified（`enable_fanout=true`） |
| `prod/main.tf` | +26 | 0 | Modified（配線のみ・`enable_fanout=false`） |

---

## 指摘一覧

- [x] 対応する

### [Code Quality / 分散処理] API-1: 重複配信で run item が `pending`→`skipped` に無条件降格し、レポートが直列版と非等価（入金額の欠落・レポート間引き）

**ファイル:** `api/src/repositories/payout-run-items.repository.ts:58`（`onConflictDoUpdate` の `set`）＋ `api/src/services/payout.service.ts:259`（既処理スキップ）＋ `api/src/services/payout-report.service.ts:31,38`（集計）
**重要度:** High

**該当コード:**
```typescript
// payout-run-items.repository.ts:51- — PK 衝突時に status を無条件上書きする
upsertResult: async (runId, result, db = getDb()) => {
  const row = toRow(fromResult(runId, result));
  const rows = await db.insert(payoutRunItems).values(row)
    .onConflictDoUpdate({
      target: [payoutRunItems.runId, payoutRunItems.stripeAccountId],
      set: {
        shopName: row.shopName ?? null,
        status: row.status,          // ← pending の行に skipped が来ると skipped へ降格
        amount: row.amount ?? 0,     // ← 5000 → existing.amount(=5000) だが status=skipped で集計外
        ...
```
```typescript
// payout.service.ts:257-265 — 重複配信は既存 pending/paid を見て status='skipped' を返す
const existing = await payoutRunsRepo.findByAccountAndPeriod(stripeAccountId, period);
if (existing && (existing.status === 'pending' || existing.status === 'paid')) {
  result.status = 'skipped';
  result.amount = existing.amount ?? 0;
  result.failureReason = 'already processed for this period';
  return result;   // ← この result を upsertResult が pending 行に上書きする
}
```
```typescript
// payout-report.service.ts:30-38 — executed は pending|paid のみ。skipped は totalAmount に非計上
const executed = results.filter((r) => r.status === 'pending' || r.status === 'paid');
...
totalAmount: executed.reduce((s, r) => s + Number(r.amount || 0), 0),
```

**問題:** SQS は at-least-once。worker が payout 作成 + `pending` item を書いた後に ack 前でクラッシュ/タイムアウトすると、可視性タイムアウト経過で**同一口座メッセージが再配信**される。2 回目の `processOnePayout` は既存 `pending` を見て `status='skipped'` を返し、`upsertResult` が **`pending` item を無条件で `skipped` へ降格**させる。これが **run 完了前**に起きると、当該口座は `summarizePayoutResults` の `executedCount`/`totalAmount` から脱落する。単発入金 run では `sendPayoutRunReportForRun` の `hasReportable`（`executedCount>0 || failedCount>0 || staleAlert`）が false に転じ、**レポート自体が間引かれて未送**になり得る。直列版は各口座を 1 回しか処理しないため発生しない = **AC-2.2「レポートは直列版と等価」を破る**。金銭移動自体は claim + idempotencyKey で保護されるため二重入金はしない（壊れるのは運営向けレポートの正確性・送達）。

**修正提案:** upsert を **terminal ステータス（pending/paid/failed/held）を `skipped` で降格させない条件付き更新**にする（例: `set` を `CASE WHEN existing.status IN ('pending','paid','failed','held') THEN existing.status ELSE excluded.status END` 相当、または `WHERE payout_run_items.status = 'skipped' OR excluded.status <> 'skipped'`）。あるいは claim 不成立時に item へ書く status を既存 `payout_runs` の実状態（pending/paid）にマップする。**回帰テスト**（`payout-fanout.test.js`）に「完了前の重複配信で当該口座がレポートから欠落しない」ケースを追加すること（現状 T-6 は単発口座の完了後重複のみで、この経路を突いていない）。

---

### [分散処理 / 可用性] API-2: 1 メッセージが DLQ へ落ちると run が永久に未完了になりレポートが送られない（reconciler 不在・直列版との差分）

**ファイル:** `api/src/services/payout.service.ts:610-616`（完了検知）
**重要度:** High

**該当コード:**
```typescript
// payout.service.ts:601-616 — 完了検知は count==expected のみ。DLQ 分は永久にカウントされない
await payoutRunItemsRepo.upsertResult(runId, result);        // ← ここに到達しないと未完了
const batch = await payoutRunBatchesRepo.get(runId);
if (!batch) { throw new Error(`... no payout_run_batch ...`); }
const done = await payoutRunItemsRepo.countByRun(runId);
if (batch.expected > 0 && done >= batch.expected) {
  const claimed = await payoutRunBatchesRepo.claimReportSend(runId);
  if (claimed) await sendPayoutRunReportForRun(runId, period);
}
```

**問題:** `processOnePayout` は業務/Stripe 失敗を握って必ず result を返すが、その後の `upsertResult` は未ガード。worker が **(a) `processOnePayout` 中に Lambda timeout/crash**（`findOldestUnpaidChargeAt` の `balanceTransactions.list` は最大 100 ページ辿るため遅い口座は payout worker timeout=300s を超え得る＝**まさに本 Issue が解こうとしている「遅い単位」**）、**(b) `upsertResult` で永続 DB 障害** に陥り `maxReceiveCount=3` 超過で DLQ へ退避すると、当該口座の item は永久に未記録 → `countByRun` は最大 `expected-1` 止まり → **どの worker も完了を検知せず `report_sent=false` のまま固定 → 成功済み口座があってもレポートが送られない**。一方**直列版 `runMonthlyPayouts`（payout.service.ts:496-529）は末尾で必ず `sendPayoutRunReport` を呼ぶ**（全口座が results に入るため）。回復用の時間ベース reconciler / sweeper は差分中に存在しない（`payout.paid`/`payout.failed` webhook のバックフィルは `payout_runs` の finalize のみで、`payout_run_batches`/レポートは対象外）。**INFRA-1 により DLQ アラームが未結線のため、運営が気づく手段も弱い。**

**修正提案（いずれか）:**
1. **時間ベース reconciler**（後続 Lambda / cron）: `payout_run_batches` に `status/completed_at` を持たせ、`report_sent=false` かつ `created_at` が閾値超の run を検知して、その時点の items から `sendPayoutRunReportForRun` を強制発火（DLQ 分は欠落計上のまま、他口座のレポートは届く）。
2. **先行 pending item**: worker 冒頭（`processOnePayout` 前）に PK 行を `dlq`/`processing` で先行 upsert し、DLQ でも件数に載せて完了検知を前進させる。
3. 最低限、`sendPayoutRunReportForRun(runId, period)` を手動 action として `batch.ts` に露出し、stuck run を運営が回復できるようにする。

**テストギャップ:** 「実 run のうち 1 メッセージが DLQ 行きで item 未記録 → 他口座のレポートが送られない stuck シナリオ」は未カバー。

---

### [分散処理] API-3: coordinator の部分 enqueue 失敗で `expected` が実配信数より過大になり run が閉じない（既払い口座が全レポートから消える）

**ファイル:** `api/src/services/payout.service.ts:551`（`expected` 先行確定）→ `:567`（enqueue）＋ `api/src/services/sqs.service.ts`（`enqueueMessages` のチャンク throw）
**重要度:** Medium

**該当コード:**
```typescript
// payout.service.ts:548-567 — batch 行を先に作ってから enqueue（非原子）
if (targets.length === 0) return { period, runId: null, enqueued: 0 };
const runId = randomUUID();
await payoutRunBatchesRepo.create({ runId, period, expected: targets.length });  // expected=N を先行確定
...
const enqueued = await enqueueMessages(queueUrl, bodies);   // ← 途中チャンク失敗で throw
```
```typescript
// sqs.service.ts — チャンク失敗で即 throw（前チャンク分は既に SQS に載ったまま un-send しない）
const failed = res?.Failed ?? [];
if (failed.length > 0) { throw new Error(`enqueueMessages: ${failed.length}/${chunk.length} ... failed ...`); }
```

**問題:** coordinator は batch 行を `expected=targets.length` で作成してから 10 件チャンクで enqueue する。`enqueueMessages` はあるチャンクの `Failed` で throw するが、**それ以前のチャンク（および失敗チャンク内の `Successful` 分）は既にキューに載ったまま**。結果、`expected=N` に対し実 enqueue < N → API-2 と同様に **run が永久未完了（レポート未送）**。EventBridge Scheduler が coordinator 失敗をリトライすると**新 runId で全件再 enqueue** され、1 回目で入金済みの口座は 2 回目 run では claim 不成立で `skipped` 計上。結果、**1 回目で実入金した口座は「1 回目 run=未送」「2 回目 run=skipped 表示」でどのレポートにも実行額として現れない**。孤児 batch 行（`report_sent=false`）も残置する。

**修正提案:** enqueue **成功実数**で `expected` を確定する（`create` を enqueue 後へ移す、または enqueue 後に `expected` を更新）。もしくは同一 runId の再開（outbox 方式）を可能にし、`Failed` エントリはリトライし尽くす。少なくとも API-2 の reconciler があれば孤児 run も回収できる。

---

### [Infra / 可観測性] INFRA-1: DLQ・キュー滞留アラームが通知先（SNS）に結線されていない（`alarm_sns_topic_arn` 未指定）

**ファイル:** `infra/modules/batch-compute/fanout.tf:191,209,228,245`（`alarm_actions`）＋ `variables.tf`（`alarm_sns_topic_arn` default `""`）＋ `dev/main.tf`・`prod/main.tf`（当変数を batch_compute へ渡していない）
**重要度:** Medium

**該当コード:**
```hcl
# fanout.tf:191 ほか — SNS ARN 未指定なら alarm_actions は空 = 画面上の ALARM のみ
alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
ok_actions    = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
```
```hcl
# variables.tf — default 空。dev/main.tf の module "batch_compute" ブロックはこの変数を渡していない
variable "alarm_sns_topic_arn" { type = string, default = "" }
```

**問題:** `enable_fanout=true`（dev）でも `alarm_sns_topic_arn` が空のままなので `alarm_actions=[]` = **CloudWatch 画面上の ALARM 状態のみで、誰にも通知が飛ばない**。REQ-4「DLQ 滞留を運営が検知できるようにする」を満たさず、**API-2/API-3 でレポートが静かに欠落する唯一の検知手段（DLQ アラーム）が沈黙**する。

**修正提案:** `dev/main.tf`・`prod/main.tf` の `module "batch_compute"` から SNS topic ARN（既存の運営通知トピック等）を `alarm_sns_topic_arn` に渡す。prod 有効化時は SNS 結線を必須化（`precondition`/`check`）することを推奨。

---

### [Code Quality] API-4: `expected` は application 数だが item PK は `stripe_account_id` — 口座共有時に完了検知が永久に不成立（不変条件が未強制）

**ファイル:** `api/src/services/payout.service.ts:551`（`expected=targets.length`）vs `api/src/db/schema.ts`（`payout_run_items_pk = (run_id, stripe_account_id)`）＋ `applications.stripe_account_id` は**非**ユニークインデックス（`schema.ts:100`）
**重要度:** Low

**問題:** `expected` は列挙された application 数、完了は `(run_id, stripe_account_id)` の件数で数える。通常 1 application = 1 Connect アカウントで一致するが、`applications.stripe_account_id` には**ユニーク制約が無い**（`index` のみ）。万一 2 target が同一 `stripeAccountId` を持つと、`payout_runs` の `(account, period)` claim で 2 件目が `skipped` になり item は 1 行に collapse → `countByRun(=1) < expected(=2)` で**永久未完了 = レポート未送**。完了検知の健全性が「列挙対象内で stripeAccountId 一意」という**未強制の不変条件**に暗黙依存している。

**修正提案:** coordinator で **targets を `stripeAccountId` で重複排除**してから `expected`/enqueue する（item PK と粒度を揃える）。実データ上は稀だが、破れると静かにレポートが止まるため低コストで堅牢化できる。

---

### [Code Quality] API-5: `report_sent` をレポート**生成前**に true 化 → 生成途中の失敗/crash で再送不能

**ファイル:** `api/src/services/payout.service.ts:614-615`（claim → send の順序）＋ `api/src/repositories/payout-run-batches.repository.ts`（`claimReportSend`）
**重要度:** Low

**問題:** `claimReportSend` が先に `report_sent=true` を確保してから `sendPayoutRunReportForRun`（`listByRun` の DB 読み出し・本文生成・SES 送信）を実行する。`sendPayoutRunReport` 自体は throw しない（送信失敗はログのみ = 直列版と等価）が、**claim と send の間の `listByRun`/`summarize` の DB 一時失敗や Lambda crash** が起きると、再配信されても `report_sent=true` で claim が null になり**レポートが二度と生成されない**。発生窓は狭いが mark-before-send の順序自体が正しさの匂い。

**修正提案:** `report_status = pending/sending/sent` + lease timeout を導入し、**生成完了後に `sent` を確定**する（優先度は低め）。

---

### [分散処理] API-6: サロンボード取り込みの遅延重複配信は finalize 後に再クロールされる（BAN リスク・二重 run 記録）

**ファイル:** `api/src/services/salonboard-import.service.ts:1078`（`processImportMessage` → `runSalonboardImport({ applicationId })`）＋ `external-import-runs.repository.ts`（`running` 部分ユニーク claim）
**重要度:** Low

**問題:** 会社単位 claim は `external_import_runs` の `status='running'` 部分ユニークのみ。**concurrent な二重起動は弾くが、1 通目が success/failed に finalize された後の遅延重複配信は `running` 行が無いため再 claim に成功し、再ログイン・再クロールする**。`cancellations` は part-unique で二重作成を防ぐが、クロール（サロンボードへの実アクセス）と run 記録は二重化する = 低並列で BAN 回避する本 batch の趣旨を一部損なう。テスト `T-7` は逐次 2 回で `cancellations` が 1 件であることは確認するが、**2 通目がスキップされたこと（=再クロールが起きていないこと）は確認していない**。

**修正提案:** message に決定的 import-run-id（coordinator の runId + applicationId）を載せ、完了済みなら worker を no-op にする dedupe を追加する（running-only claim は同時実行防止として残す）。

---

### [Infra] INFRA-2: 共有実行ロールへ send+receive を一括付与（最小権限からの逸脱・共有ロール構成に起因）

**ファイル:** `infra/modules/batch-compute/fanout.tf:119-`（`aws_iam_role_policy.fanout_sqs` の 2 ステートメント）
**重要度:** Low（情報提供）

**問題:** dev/main.tf は `lambda_role_arn` も `lambda_role_name` も同一 `module.api_compute.lambda_role` を渡すため、coordinator・payout worker・import worker、さらに同ロールを共有する **API Lambda** まで両キューへの send/receive/delete を持つ。Issue REQ-5 の「coordinator=send / worker=receive」の権限分離は効いていない。**内部キューで外部露出はなく実害は限定的**だが、既存の共有ロール設計（batch が API lambda ロールを再利用）に起因する。

**修正提案:** 完全分離は設計変更のため必須ではない。将来 send/receive を機能別ロールに分ける改善余地として記録。

---

### [Infra] INFRA-3: `enable_fanout=true` + `lambda_role_name=""` の footgun が仕組みで防がれていない／worker の reserved concurrency 未設定・`maximum_concurrency` の下限 validation なし

**ファイル:** `infra/modules/batch-compute/fanout.tf:120`（policy の count 条件）・`:155,170`（ESM `scaling_config`）・worker Lambda（`reserved_concurrent_executions` なし）＋ `variables.tf`
**重要度:** Low

**問題:**
1. IAM policy は `lambda_role_name != ""` 時のみ作成されるが ESM は `enable_fanout` で作成される。名前未指定だと policy が count=0 で受信権限が付かず、**ESM 作成が AWS 側で失敗**（コメントの注意書きのみで仕組みで防いでいない）。
2. Issue REQ-3/5 は「`maximum_concurrency` **＋** worker reserved concurrency」の二段構えを求めるが、reserved concurrency 未設定（現状 worker トリガーは ESM のみなので実効上は `maximum_concurrency` で上限が効く）。
3. `payout_max_concurrency`/`import_max_concurrency` に AWS 制約（ESM は最小 2）の `validation` が無く、`1` を渡すと apply 時に失敗する（現行 default/dev 値は 2 以上で問題なし）。

**修正提案:** `enable_fanout=true` で `lambda_role_name` 必須の `precondition`/`check` を追加。worker に `reserved_concurrent_executions` を付与（少なくとも判断根拠をコメント明記）。`maximum_concurrency` 変数へ `2..1000` の validation を付与。

---

### [Code Quality] API-7: payout の手動単発（`applicationId` 指定）がフラグ ON で非同期化 — salonboard（手動は直列維持）と非対称

**ファイル:** `api/src/batch.ts`（payout は `applicationId` 有無に関わらず `!dryRun && resolvePayoutFanoutEnabled()` で coordinator 化 / salonboard は `isScheduledAll = !applicationId && !runId` で手動を直列維持）
**重要度:** Low（破壊的ではない）

**問題（検証済み）:** `run-monthly-payouts` を**同期消費する HTTP/管理エンドポイントは存在しない**（`lambda.ts` に invoker 無し、`application.service.ts` の参照はコメントのみ）ため **UI 破壊は無い**。ただし運営の手動単発 invoke の戻り値が `{mode:'coordinator', enqueued}` に変わり従来の `{executedCount,...}` サマリが得られなくなる。また同一 PR 内で payout と salonboard が「手動」の扱いを分ける意図が読み取りづらい。

**修正提案:** 意図的なら `batch.ts` に 1 行理由コメント（payout は同期消費者なし＝非同期化してよい / salonboard はサロン本人への即時レスポンスがあるので直列維持）を足す。

---

### [Code Quality] API-8（nit）: `payout_run_batches` / `payout_run_items` に保持期間・整理が無く無制限に増加

**ファイル:** `api/src/db/schema.ts`（両テーブル）
**重要度:** Low（nit）

**問題:** daily cron で run ごとに `payout_run_batches` 1 行 + 口座数分の `payout_run_items` が永続追加され、TTL/pruning が無い。レポート再生成専用の履歴なので、古い run は不要になる。

**修正提案:** 後続 Issue で保持期間（例: N ヶ月）を超えた行の定期削除を検討。

---

### [Infra / 設計確認] SB-CONC: salonboard 取り込みは「低並列を意図的に維持」する（案 A 採用・並列度を上げないことが正しさの前提）

**ファイル:** `infra/dev/main.tf:18`（`import_max_concurrency = 2`）＋ `infra/modules/batch-compute/fanout.tf:170`（import ESM `scaling_config.maximum_concurrency`）＋ `infra/modules/batch-compute/variables.tf`（`import_max_concurrency` default 2）
**重要度:** Low（設計方針の明示。**並列度を上げない限り問題なし**）

**背景・意思決定:** 「ファンアウト化で salonboard が並列クロールされ、サイトに負荷がかかるのでは」という懸念に対する結論。**タイムアウト解消はファンアウトの「1 社 = 1 Lambda 起動（各起動に新しい 600s 予算）」で達成され、並列度に依存しない**。したがって salonboard は**低並列を維持したまま**タイムアウトだけを解消できる。BAN の実トリガーは「1 アカウント / 1 IP あたりのリクエスト速度」であり、そこは worker 内のジッタ・スティッキーセッション（別社=別アカウント=別 Decodo IP）で現行どおり維持される。`import_max_concurrency=2` で同時に走るのは「別サロン 2 社が別 IP で使う」状態に等しく、集約負荷は誤差。

**採用方針（案 A）:**
- import キューは **Standard のまま + 低並列（`import_max_concurrency = 2` を維持）**。payout（高並列）とは**逆方向のチューニング**を厳守する（入金=短縮のため高並列、取り込み=BAN 回避のため低並列）。
- **`IMPORT_FANOUT` フラグ運用**で、まず dev で有効化して BAN / ソフトブロック兆候（ログイン失敗率・クロール失敗率・`external_import_runs` の failed 増加）を観測してから prod（`enable_fanout=true`）へ。
- **並列度を payout 感覚で引き上げないこと**が正しさの前提。将来社数が増えて wall-clock が問題化しても、上げるのは 2→3〜5 程度にとどめ、都度 dev で BAN 兆候を確認する。

**不採用にした代替と理由:**
- **厳密直列（同時 1）**: SQS Standard の ESM は `maximum_concurrency` の下限が **2** で、1 は作れない。`reserved_concurrent_executions=1` で絞るとスロットリングが `maxReceiveCount` を消費して**早期 DLQ**になる footgun。厳密 1 を作るには **FIFO + 単一 MessageGroupId** が必要だが、**head-of-line blocking（1 社の停滞が後続全社を DLQ 落ちまで停止）**と社数増での wall-clock 無制限を招くため不採用。低並列 2 のほうが障害分離が良く wall-clock も有界。
- **salonboard を当面ファンアウトしない**: 取り込みのタイムアウトが未解消のまま残るため不採用。

**補足（関連指摘）:** worker の `reserved_concurrent_executions` 未設定は INFRA-3 で挙げたが、**案 A では ESM `maximum_concurrency=2` を並列上限の制御点とし、reserved concurrency=1 での直列化は上記 footgun のため行わない**。安全網として reserved concurrency を「`maximum_concurrency` 以上」で設定するのは可（直列化目的ではなく、他経路からの暴走防止）。`import_max_concurrency` へ `2..1000` の validation を付けておくと「1 を渡して apply 失敗」を防げる（INFRA-3 と統合対応）。

---

## 確認済みで問題なしと判断した点（3 レビュアー + メインで裏取り）

- **worker Lambda 命名**: `var.function_name = cancel-billing-service-batch-dev` に対し `replace("batch", "payout-worker"/"import-worker")` は正しく `…-payout-worker-dev`/`…-import-worker-dev` を生成し、`deploy-batch.sh` の探索名と一致・"batch" は 1 回のみ出現で衝突なし。
- **salonboard coordinator の会社列挙**: 直列 `executeImport` と同一（`shopIntegrationsRepo.findAllLinkedWithShop()` を source フィルタ → distinct applicationId）でパリティ一致。
- **冪等性（正常系）**: payout=claim + attempt idempotencyKey、salonboard=会社単位 claim + 予約 part-unique。`claimReportSend` は `UPDATE ... WHERE report_sent=false RETURNING` の行ロックで並列 worker でも 1 回のみ送信（完了レースも「後コミットの worker が必ず全件を観測して送る」ことを追跡確認）。
- **IAM リソーススコープ**: send/receive を payout/import の 2 キュー ARN に限定（`*` 不使用）。
- **ESM `depends_on`**: `aws_iam_role_policy.fanout_sqs` に依存（受信権限先付けの検証失敗を回避）。
- **visibility timeout ≥ worker timeout**: payout 360≥300 / import 720≥600（+バッファ）。
- **migration 0020 ⇔ schema.ts**: tag `0020_gtss854_sqs_payout_fanout` / idx 20 / `_journal.json` の `when` 刻み一致、DDL と drizzle 定義（列・PK）一致。`schema.test.js` が 13→15 テーブルで追従。
- **deploy-batch.sh の env 全置換**: 既存変数（`AURORA_*`/`STRIPE_SECRET_KEY`/`CREDENTIALS_KMS_KEY_ID`/`SALONBOARD_*`/`DECODO_*`）を温存しつつ `PAYOUT_QUEUE_URL`/`IMPORT_QUEUE_URL`/`PAYOUT_FANOUT`/`IMPORT_FANOUT` を追加（過去の「全置換で変数脱落」lesson に非該当）。coordinator + worker×2 の 3 関数へ同一 env を配備。
- **lessons 照合**: `.claude/lessons.md` + `skills/{vitest,issue,playwright,authz}/lesson.md` と照合し違反なし（drizzle 手書き migration 運用・テスト後クリーンアップ・PII 露出なし）。
- **fanout.tf が参照する既存モジュール変数**（`lambda_role_arn`/`handler`/`runtime`/`architectures`/`function_name`/`data.archive_file.placeholder`）は全て実在 = `terraform plan` は未定義変数で失敗しない。

## 総評

アーキテクチャの方向性・段階移行の安全設計・金銭移動の冪等担保は妥当で、**「入金が壊れる」タイプのバグは無い**（claim + idempotencyKey + webhook バックフィルで durable）。一方、**AC-2.2「実行レポートは直列版と等価」を SQS の at-least-once + 部分失敗に対して守り切れていない**のが本 PR の核心的懸念で、API-1（重複配信で pending→skipped 降格）・API-2（DLQ で run 未完了 → 未送）・API-3（部分 enqueue で expected ズレ）が一つの根本課題 —「run 完了検知（`count==expected` のみ・reconciler 無し）と item upsert（terminal 降格を許す）と enqueue（非原子・expected 先行）が脆い」— に収束する。しかもその劣化を検知するはずの DLQ アラームが INFRA-1 で SNS 未結線のため**静かに劣化**する構図。

**dev 検証前に最低限:** (1) API-1 の upsert terminal 降格防止（+回帰テスト）、(2) API-2 の未完了 run 向け reconciler/強制送出、(3) INFRA-1 の alarm SNS 結線 — の 3 点を推奨。API-3/API-4/API-5/API-6 は (1)(2) の reconciler があれば大半が回収でき、残りは Low として段階対応可。テストは配線・冪等・完了検知・レポート DB 再生成を広くカバーしており質は高いが、**「完了前の重複配信」「1 メッセージ DLQ で他口座レポート未送」「import 2 通目のスキップ」の 3 つの stuck/degradation 経路が未カバー**。
