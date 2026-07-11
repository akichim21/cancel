# バッチ ECS(Fargate) 直列実行（cancel-billing-service-api / GTSS-860）

バッチ Lambda の「対象を 1 件ずつ直列ループ処理する」構造は、対象件数 × 1 件あたりレイテンシで実行時間が
線形に伸び、Lambda の実効 timeout（600s / ハード上限 900s）を超えると途中で強制終了する **スケール限界** を
持つ。対象は月次入金（`run-monthly-payouts`・GTSS-854）とサロンボード一括取り込み（`salonboard-import`・GTSS-817）。

この課題を、**分散処理を一切持ち込まず**、既存の直列ループを **実行時間の上限が無い ECS(Fargate) タスク** で
走らせることで解く。トリガーは EventBridge Scheduler の起動先を Lambda invoke から **ECS RunTask** に切り替える。

関連: [batch-jobs.md](./batch-jobs.md)（バッチ実行基盤の全体）・[stripe-connect.md](./stripe-connect.md)（月次入金）・
[salonboard-import.md](./salonboard-import.md)（取り込み）。

## なぜ SQS ファンアウト（#35）を破棄したか

先行して **SQS ファンアウト（coordinator + worker + DLQ・親リポ #35 / ブランチ `GTSS-854-sqs`）** に着手したが、
レビューの結果 **分散処理を自作したことによる付随的な複雑さ** が多数露出した（at-least-once 再配信の冪等・完了検知・
部分 enqueue・DLQ からの stuck run 回復・レポートの DB 再生成）。これらは本質課題（timeout）とは別レイヤの負債。

一方 **この 2 バッチはどちらも高並列を必要としない**:

- **月次入金**: 日次 cron（JST 06:00）で誰も待っていない。500 口座 × 数秒でも直列で数十分に収まり、速度要件がない。
- **サロンボード取り込み**: BAN 回避のため **並列度を意図的に絞る**（ファンアウトでも `maximum_concurrency=2`）。
  並列の恩恵をほぼ捨てているのに、分散処理の複雑さだけを全部払っていた。

したがって timeout という唯一の実問題だけを、長時間実行できる Fargate タスクで直列コードを走らせて解く。
実行時間の制約は「全件の合計 < 900s」から「Fargate は数時間走れる（＝実質無制限）」へ変わり、#35 で露出した
分散処理由来の指摘は **設計上まるごと消滅** する。#35 の資産（`fanout.tf` / `sqs.service.ts` /
`batch-fanout.service.ts` / `payout_run_batches`・`payout_run_items` / fanout フラグ / `@aws-sdk/client-sqs`）は
**一切導入しない**（base をファンアウト以前のブランチに置き最初から含めない）。

## アーキテクチャ

```
EventBridge Scheduler ──(RunTask + task定義: action別 command)──> ECS Fargate Task（単発）
                                                                   └─ 既存の直列ループを同期実行
                                                                       payout: 対象列挙 → 1口座ずつ processOnePayout
                                                                               → in-memory results → レポート送信
                                                                       import: 連携会社を列挙 → 1会社ずつ
                                                                               runSalonboardImport（Chromium 逐次クロール）
                                                                   └─ 成功=exit 0 / 失敗=exit≠0
                                                                       （CloudWatch Logs / タスク停止理由で検知）
（purge-expired-backups は現行 Lambda + Scheduler のまま。スコープ最小化）
```

- **常駐サービス（ECS Service）ではなく単発タスク（RunTask）**。バッチは「起動 → 直列処理 → 終了」の一過性ジョブ。
- 1 回の起動が対象総数に依存せず数時間走れるため、対象件数の増加で timeout に打ち切られない。
- **並列制御のためのインフラは不要**。単一タスクが逐次クロールするため取り込みのリクエスト速度が自然に抑制され
  BAN 回避方針を満たす。

## コンテナ（cancel-billing-service-api）

| ファイル | 役割 |
|---|---|
| `src/batch.ts` | `dispatchBatchAction(event)` を export（`event.action` で dispatch する中核）。Lambda `handler` は薄いラッパ。 |
| `src/batch-cli.ts` | コンテナ CLI ロジック。`parseCliEvent(argv, env)` で action（argv[2] > `BATCH_ACTION`）と補助フィールド（`BATCH_APPLICATION_ID`/`BATCH_DRY_RUN`/`BATCH_TRIGGER`/`BATCH_RUN_ID`）を解決し、`runCli` が `dispatchBatchAction` を実行して終了コード（成功 0 / 失敗 1）を返す。副作用なし＝テスト可能。 |
| `src/batch-entry.ts` | Docker CMD の対象。`runCli()` を実行して `process.exit(code)` するだけの薄いプロセスラッパ。 |
| `Dockerfile.batch` | Node 24 + esbuild バンドル（`build.mjs` が `dist/src/batch-entry.js` を出力）+ Playwright 同梱 Chromium。 |
| `build.mjs` | エントリに `src/batch-entry.ts` を追加（lambda / batch / batch-entry の 3 出力）。 |

### Chromium

`selectChromiumSource`（`salonboard-client.ts`）の優先順位は
**`CHROMIUM_EXECUTABLE_PATH` > `CHROMIUM_CHANNEL` > `AWS_LAMBDA_FUNCTION_NAME`(sparticuz) > bundled**。
コンテナは **`CHROMIUM_EXECUTABLE_PATH` を Playwright 同梱 Chromium への symlink（`/usr/local/bin/chromium`）** に
指すため executablePath 経路を選び、Lambda 専用の `@sparticuz/chromium`（brotli 展開・/tmp 制約）を排除できる。
取り込みは **`SALONBOARD_TRANSPORT=playwright`** を明示 opt-in して Chromium 経路を有効化する（既定は `http`）。

イメージは **単一**（`playwright-core` は依存ゼロ・自己完結なので runtime ステージへコピー、Chromium は
`playwright-core install --with-deps chromium` で導入）。アクションは **タスク定義の `command` で出し分ける**
（EventBridge Scheduler の ECS ターゲットは container command override を渡せないため、アクション別に
タスク定義 family を分ける — `*-payouts` / `*-import`）。秘密（`STRIPE_SECRET_KEY`/`AURORA_*`/`CREDENTIALS_KMS_KEY_ID`
等）は **イメージに焼かず** タスク定義の environment として注入する。

## 実行環境（裏取り済み）

- batch は **VPC 外**の Lambda と同じく **Aurora RDS Data API（HTTPS）** で DB を叩くため、Fargate も VPC 内
  DB 接続は不要。**パブリックサブネット + `assign_public_ip=ENABLED` + egress 許可 SG**（NAT 不要）で足りる
  （外向き egress: ECR / Stripe / SES / RDS Data API / サロンボード / Decodo プロキシ）。
- タスクロールは **API/batch Lambda と共有する `cancel-billing-lambda-role` を再利用**する（Data API / Secrets /
  SES / KMS 復号を既に保持）。当該ロールの信頼ポリシーへ `ecs-tasks.amazonaws.com` を追加して ECS タスクロールに
  流用する（`api-compute` の `extra_assume_role_service_principals`）。タスク実行ロール（ECR pull + Logs）は別途新設。

## インフラ（cancel-billing-service-infra）

- **`modules/batch-fargate`**（新規）: ECR / 最小 VPC（パブリック×2AZ + IGW + egress-only SG）/ ECS クラスタ /
  アクション別タスク定義（placeholder image + `lifecycle ignore_changes[container_definitions]`）/ タスク実行ロール /
  CloudWatch Logs / EventBridge Scheduler 実行ロール（`ecs:RunTask` + `iam:PassRole`）/ RunTask スケジュール。
  - タスク定義は**常に全アクション分**作成する（スケジュール無効でも手動 RunTask で単発実行・Chromium 検証が可能）。
  - スケジュールはタスク定義 **family（リビジョン無し）** を参照するため、deploy が新リビジョンを register すれば
    最新 ACTIVE が自動採用される（スケジュール更新不要）。
- **`modules/batch-compute`**: `purge-expired-backups` の Lambda + Scheduler を維持。入金/取り込みの Lambda
  スケジュールは `dev/prod` の `local.batch_execution` で排他制御する。
- **`dev/main.tf` / `prod/main.tf`**: `local.batch_execution = "ecs" | "lambda"` で新旧を切替（後述）。dev 先行、prod 後追い。

## デプロイとロールバック

- **デプロイ**: `deploy-batch-ecs.sh [env]` が `docker build`（`Dockerfile.batch`）→ ECR push →
  各 family（`*-payouts` / `*-import`）のタスク定義を `describe → image/env 差し替え → register` する。Terraform は
  スケルトン（タスク定義・ネットワーク・IAM・Scheduler）を所有し、イメージタグ・環境変数はデプロイスクリプトが所有
  （現行 batch Lambda の「placeholder を TF、コード/env をスクリプト（lifecycle ignore）」の所有分割を踏襲）。
  Lambda 版 `deploy-batch.sh` はロールバック用に温存する。
- **切替 / ロールバック**: `local.batch_execution` を `"ecs"` にすると入金/取り込みの Scheduler が RunTask に切り替わり、
  `batch-compute` の Lambda スケジュールは無効化される。`"lambda"` に戻すだけで **Scheduler の起動先が Lambda invoke に
  即時復帰**する（Lambda 経路と直列サービスコードは移行期間中温存）。同名スケジュールの二重作成を避けるため、両モジュールの
  `enable_*_schedule` は `local.batch_execution` で排他にしている。

## 段階移行（dev 検証 → prod）

dev は `batch_execution="ecs"`、prod は当面 `"lambda"`（ECS 基盤は apply で先行構築するが Scheduler は Lambda のまま）。
dev で以下を確認してから prod を `"ecs"` へ切替える:

1. スケジュールされた RunTask が Fargate タスクを起動し完走（exit 0）する
2. サロンボード取り込みが Chromium コンテナで動く（手動 RunTask で `*-import` を起動）
3. 月次入金が直列で完了しレポートが届く
4. 900s を超える実行が打ち切られない
5. ロールバック（`batch_execution="lambda"`）が効く

## 冪等性・失敗分離・再実行

タスク丸ごと再実行が安全（移行の安全性の土台）:

- **月次入金**: `payout_runs` の claim（`(stripe_account_id, period)` を processing で原子確保）→ payouts.create →
  finalize の 2 段階。`idempotencyKey = payout_${account}_${period}_${attempt}`。(account, period) 一意。
- **サロンボード取り込み**: 会社（applicationId）単位で `external_import_runs` を claim（running）→ finalize、
  `IMPORT_RUN_STALE_MS=15分`。予約単位は `external_import_logs` upsert ＋ `cancellations` の part-unique で二重作成しない。

1 単位の失敗は他単位を止めない（per-item try/catch）。タスク異常終了は非 0 終了コードと CloudWatch Logs /
ECS タスク停止理由で運営が検知でき、翌日 cron の再実行が未処理分の回復経路になる（DLQ/reconciler は不要）。
