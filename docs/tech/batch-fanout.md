# バッチ SQS ファンアウト（cancel-billing-service-api / GTSS-854-sqs）

バッチ Lambda の「対象を 1 件ずつ直列ループ処理する」構造による Lambda timeout のスケール限界を、
**SQS ファンアウト（coordinator → SQS → worker → DLQ）** で解消するアーキテクチャ。対象は同じ構造問題を持つ
2 バッチ — 月次入金（`run-monthly-payouts`・GTSS-854）とサロンボード一括取り込み（`salonboard-import`・GTSS-817）。

実行時間を「全件の合計」から「最も遅い 1 単位 + 並列度による分散」へ変える。ECS/Fargate のような常駐基盤は
持ち込まず、各単位が独立・冪等・I/O バウンドである性質を活かして Lambda ファンアウトで解決する。

関連: [batch-jobs.md](./batch-jobs.md)（バッチ実行基盤の全体）・[stripe-connect.md](./stripe-connect.md)（月次入金）・
[salonboard-import.md](./salonboard-import.md)（取り込み）。

## アーキテクチャ

```
EventBridge Scheduler ──(action)──> coordinator（主 batch Lambda の action 分岐）
                                        │  対象を列挙し 1 単位 = 1 メッセージを enqueue
                                        ▼
                                   SQS（標準キュー）──> worker Lambda（並列・batch_size=1）─┐
                                        │                                                    │ 1 単位処理
                                        └──(maxReceiveCount 超過)──> DLQ                       │
                                                                                             ▼
                            （入金のみ）全 worker 完了検知 ──> レポート DB 再生成（payout_runs.listByPeriod）
```

- **coordinator** = 主 batch Lambda（`cancel-billing-service-batch-{env}`）の既存 action（`run-monthly-payouts` /
  `salonboard-import`）。フラグが ON のとき「対象列挙 + enqueue」だけを行い短時間で完了する。**EventBridge
  Scheduler の起動先は変えない**（コード側フラグで coordinator/直列を切替）。
- **worker** = 専用 Lambda（`cancel-billing-service-{payout,import}-worker-{env}`）。SQS をイベントソースとして
  起動され、1 メッセージ（1 単位）を処理する。**主 batch と同一コードバンドル**（handler = `src/batch.handler`）を
  共有し、SQS イベント（`event.Records`）をメッセージ本文の `type`（`payout` / `import`）で振り分ける。

### コード構成（cancel-billing-service-api）

| ファイル | 役割 |
|---|---|
| `src/batch.ts` | handler 先頭で `Array.isArray(event.Records)` を worker 経路に振り分け、`processWorkerRecords` へ。既存 `switch(event.action)` は coordinator/legacy 経路（各 action がフラグで coordinator/直列を分岐）。 |
| `src/services/sqs.service.ts` | `enqueueMessages(queueUrl, bodies)`（SendMessageBatch を 10 件チャンクで送信、Failed は throw）。`@aws-sdk/client-sqs` を lazy-require。テストは `__setSqsClientForTest` で注入。 |
| `src/services/batch-fanout.service.ts` | `processWorkerRecords(records, handlers)`。`type` でハンドラ振り分け、失敗メッセージのみ `batchItemFailures` で返す（ReportBatchItemFailures = 部分バッチ応答）。 |
| `src/config.ts` | `resolvePayoutQueueUrl` / `resolveImportQueueUrl` / `resolvePayoutFanoutEnabled` / `resolveImportFanoutEnabled`（env 注入・default-off opt-in）。 |
| `src/services/payout.service.ts` | `runMonthlyPayoutsCoordinator`（列挙+enqueue）/ `processPayoutMessage`（worker）/ `enumeratePayoutTargets` / `processOnePayout`（1 口座・現行 `processOne`）/ `sendPayoutRunReportForRun`（run の items からレポート再生成）。 |
| `src/services/salonboard-import.service.ts` | `runSalonboardImportCoordinator`（会社列挙+enqueue）/ `processImportMessage`（worker = 既存 `runSalonboardImport` を当該会社で呼ぶ）。 |
| `src/repositories/payout-run-batches.repository.ts` / `payout-run-items.repository.ts` | 入金の run 登録・レポート一意ガード（`payout_run_batches`）と、run 単位・口座単位の判定結果（`payout_run_items`。完了検知 + レポート再生成源。冪等 upsert）。 |

## SQS: 標準 vs FIFO の選択

**標準（Standard）キューを採用**。理由:
1. 各単位は独立で**処理順序に依存しない**。
2. at-least-once による重複配信は既存の冪等担保（入金: `claim` + idempotencyKey / 取り込み: `external_import_runs`
   claim + 予約重複排除）で吸収できるため、FIFO の厳密重複排除は不要。
3. 標準はスループット無制限で高並列が素直（入金の短縮に有利）。
4. FIFO は MessageGroupId 単位の順序制約でスループットが落ち、本用途の利点が無い。

並列度の抑制（取り込みの BAN 回避）は FIFO の順序制約ではなく、**イベントソースマッピングの
`scaling_config.maximum_concurrency` + worker の同時実行**で行う（順序ではなく同時実行数の制御が要件）。

## 冪等性・リトライ・部分失敗・DLQ

- **at-least-once の吸収**: worker は同一単位が 2 回配信されても二重処理しない。
  - 入金: `payout_runs` の `claim`（(account, period) を processing で原子確保）+ Stripe `idempotencyKey`
    (`payout_${account}_${period}_${attempt}`)。2 回目は既存 pending/paid の短絡または claim 不成立で skip。
  - 取り込み: `external_import_runs` の per-company claim（(applicationId, source) running-unique）で 2 回目は skip。
    予約単位は `cancellations` の part-unique（(shopId, externalReservationId)）+ `external_import_logs` で二重作成しない。
- **失敗の切り分け（重要）**:
  - **業務的失敗**（held/failed 記録・ログイン失敗・連携未設定）は worker 内で「正常完了」させる（throw しない →
    メッセージ削除）。DLQ には溜めない。翌日の再実行（冪等）で回復する。
  - **インフラ的失敗**（DB 到達不能・想定外例外・Lambda timeout）は throw / 応答なしで SQS へ返し、可視性
    タイムアウト経過後に再配信、`maxReceiveCount` 超過で **DLQ** へ退避。
- **部分バッチ応答**: `function_response_types = ["ReportBatchItemFailures"]`。同一バッチの成功メッセージは
  再処理しない（`batch_size=1` のため実質 1 メッセージ単位）。
- **可視性タイムアウト ≥ worker timeout + バッファ**: 処理中メッセージが再配信されて無駄な二重実行（冪等で
  吸収されるが無駄）になるのを防ぐ。dev/prod は `payout=360s`（worker 300s）/ `import=720s`（worker 600s）。
- **毒メッセージ対策**: `maxReceiveCount` を小さく（既定 3）。業務的失敗は結果記録（failed）で正常完了させ、
  DLQ には**インフラ的失敗のみ**が溜まるようにする。DLQ 滞留は CloudWatch アラームで運営が検知する。

## 月次入金の完了検知とレポート DB 再生成（REQ-2 / AC-2.2）

worker は非同期・並列に完了するため末尾でまとめて集計できない。そこで入金レポートは、従来の in-memory `results`
配列の代わりに **`payout_run_items`（run 単位・口座単位の判定結果）** から run 完了時に再生成する。これにより
直列版の per-run `results` と**等価**になる（暦月 period の多日累積にならない・`skipped` も per-run で正しく記録・
SQS 重複配信でも二重計上しない）。`payout_runs`（金銭状態テーブル）は変更しない。

- **run 登録（`payout_run_batches`）**: cron は日次だが period は暦月粒度のため、完了検知は **run 単位**で行う。
  coordinator が run ごとに `run_id` を発番し `payout_run_batches(run_id, period, expected=対象口座数)` を作成、
  各メッセージに `runId` を載せる。`report_sent` は多重送信防止の一意ガード。
- **per-run 結果の冪等記録（`payout_run_items`）**: 各 worker は `processOnePayout` の結果（現行 `processOne` の
  result と同一形。status held/pending/paid/failed/skipped・残高・強制理由・滞留・退会）を
  **PK `(run_id, stripe_account_id)` で冪等 upsert** する。SQS 重複配信でも同一口座は 1 件に収束する（over-count なし）。
- **完了検知（冪等）**: 当該 run の `payout_run_items` 件数が `expected` に達したら全 worker 完了とみなす。件数ベース
  かつ (run_id, account) 一意のため、重複配信で「他口座の初回処理前に完了と誤検知」する穴が無い（旧カウンタ方式の
  弱点を解消）。完了 worker が `report_sent` を確保できたときだけレポートを 1 回送る。
- **レポート本文 + 間引き（当該 run の items 由来）**: `payout_run_items` の当該 run 分を `buildPayoutReport` へ渡し、
  現行と等価な本文/CSV を生成する。送信可否（no-op 間引き）は同じ items から `summarizePayoutResults` で判定する
  （入金実行 or 失敗が 1 件以上、または滞留警告あり）。全口座 held/skipped の静かな run は `report_sent` を立てるだけで送らない。
  - **per-run 等価の要点**: 月内 2 日目以降の run では、前日入金済みの口座は当日 `skipped`（executed に非計上）として
    その run の items に記録される。よってレポートは「当日処理分」を示し、`payout_runs` を period 全体で読む方式のような
    「前日入金を当日レポートに累積計上」する乖離が起きない（テスト `payout-fanout.test.js` の多日ケースで検証）。

## サロンボード取り込みの粒度（REQ-3）

- **会社粒度ファンアウト（1 会社 = 1 メッセージ）**を採用。worker（`processImportMessage`）は既存
  `runSalonboardImport({ applicationId })` を当該会社で呼ぶだけで、per-company claim → `importCompany`
  （effectiveUnit=company/shop を内部判定。company=1 ログイン、shop=店舗ごとにログイン）→ finalize を現行どおり行う。
- これにより **既存の per-company claim/finalize・Decodo sticky session・jitter・login retry・予約重複排除を
  一切変更せず**、直列の会社ループ由来 timeout を解消する（会社間は SQS で並列、`maximum_concurrency` で BAN 回避）。
- **集約メールは追加しない**（現状どおり会社別 `external_import_runs` 行 + CloudWatch 構造化ログで観測）→ 入金と
  異なり**完了検知バリアは不要**。
- **失敗と DLQ**: `runSalonboardImport` は会社ループ内の例外をほぼ握って `summary(ok:false)` を返す設計のため、業務的
  失敗（ログイン失敗・連携未設定・クロール失敗）だけでなく大半の一時失敗も `external_import_runs` へ failed 記録して
  正常完了する（= メッセージ削除。回復は翌日の日次 cron 再実行、二重作成は予約 part-unique が防止）。したがって
  取り込み worker で DLQ へ載るのは限られた経路（会社列挙前の致命的失敗後の可視化用 claim が投げる永続 DB 障害、
  Lambda 自体の timeout で応答を返せず SQS が再配信するケース等）のみで、業務的失敗は DLQ に溜めない。
- **店舗粒度化（1 店舗 = 1 メッセージ）は将来最適化として据え置く**。`external_import_runs` の running-unique が
  (applicationId, source) 単位のため、店舗粒度にすると同一会社の店舗メッセージが互いに claim を潰し合う。店舗
  粒度化には claim キーへ shop_id を含めるスキーマ変更が必要で、1 会社が 900s を超えるケースが顕在化した時に
  行う（Issue「なぜ ECS 不要か」の段階分割方針に一致）。
- **手動取り込み**（`applicationId` / `runId` 指定 = サロン本人・運営の単発）はファンアウトせず従来どおり直列
  （即時レスポンスのため）。ファンアウトするのは日次スケジュール（全社・`applicationId`/`runId` 無し）のみ。

## インフラ（`~/infra/cancel-billing-service-infra` / `modules/batch-compute`）

`fanout.tf` が `enable_fanout=true` のとき以下を作成する（入金/取り込みで並列度要件が正反対のため**独立キュー/独立 worker**）:

| リソース | 入金 | 取り込み |
|---|---|---|
| SQS 本キュー | `{fn}-payout` | `{fn}-import` |
| DLQ（redrive） | `{fn}-payout-dlq`（maxReceiveCount 3） | `{fn}-import-dlq`（maxReceiveCount 3） |
| worker Lambda | `{svc}-payout-worker-{env}`（1024MB/300s） | `{svc}-import-worker-{env}`（2048MB/600s・Chromium） |
| イベントソースマッピング | `maximum_concurrency`（dev 5・高並列） | `maximum_concurrency`（dev 2・低並列 BAN 回避） |
| 可視性タイムアウト | 360s | 720s |
| CloudWatch アラーム | DLQ 滞留 / 本キュー最古メッセージ滞留 | 同左 |

- worker Lambda は主 batch と同一の共有実行ロールを使い、`fanout_sqs` inline policy で coordinator=SendMessage /
  worker=Receive/Delete を付与する。コードは `deploy-batch.sh` が 3 関数（coordinator + worker×2）へ同一バンドルを配備する。
- `enable_fanout` は既定 false（段階移行）。dev で有効化 → 検証 → prod で有効化。`enable_fanout=true` 時は
  `lambda_role_name`（共有ロール名）も必須。

## 段階移行とロールバック（REQ-6）

1. 緊急緩和の timeout 900s 化は本移行の前提（別作業。恒久解ではない）。
2. framework/flag（default-off）を用意 → dev で `enable_fanout=true` apply → `terraform output` の queue URL を
   `.env.development` の `PAYOUT_QUEUE_URL` / `IMPORT_QUEUE_URL` へ転記。
3. **月次入金を先に移行**（冪等性が強く外部依存が Stripe のみ）: `PAYOUT_FANOUT=sqs` を設定 → `deploy-batch.sh dev`。
4. 次に**サロンボード取り込み**（Chromium・BAN リスク）: `IMPORT_FANOUT=sqs`。
5. dev 検証後に prod で `enable_fanout=true` + フラグ設定 → `deploy-batch.sh prod`。
- **ロールバック**: `PAYOUT_FANOUT` / `IMPORT_FANOUT` を外す（または `enable_fanout=false`）だけで、coordinator が
  enqueue せず従来の直列経路に戻る。Scheduler の起動先は不変なので切替は env のみ。

## デプロイ（deploy-batch.sh）

`deploy-batch.sh {env}` が主 batch（coordinator）+ payout/import worker の **3 関数へ同一バンドルを配備**する。
worker は Terraform 未作成ならスキップ（段階移行可）。env JSON（全置換）に `PAYOUT_QUEUE_URL` / `IMPORT_QUEUE_URL` /
`PAYOUT_FANOUT` / `IMPORT_FANOUT` を含める（省略すると次回デプロイで消え、coordinator が queue を見失う）。

## テスト

Vitest（`app.request()` 相当のインプロセス + SQS/Stripe/SES/salonboard はモック注入）で担保:
- `src/__tests__/unit/sqs-service.test.js` — enqueue の 10 件チャンク・Failed throw。
- `src/__tests__/unit/batch-fanout.test.js` — 部分バッチ応答（throw/未知 type/不正 JSON → batchItemFailures）。
- `src/__tests__/e2e/payout-fanout.test.js` — coordinator enqueue（T-1）・worker 判定分岐（T-3）・二重配信冪等（T-6）・
  完了検知 + レポート DB 再生成 + 間引き（T-4）・フラグ切替。
- `src/__tests__/e2e/salonboard-import-fanout.test.js` — 会社列挙 enqueue（T-2）・worker 1 会社処理（T-5）・二重配信（T-7）・
  手動/フラグ切替。

DLQ redrive・並列度上限・Scheduler 切替は実 AWS 挙動のため dev の人力/IaC 結線確認とする。
