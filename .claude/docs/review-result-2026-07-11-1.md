---
issue: 36
date: 2026-07-11
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-859
    toBranch: GTSS-860
  - repo: infra
    repoDir: cancel-billing-service-infra
    baseBranch: GTSS-859
    toBranch: GTSS-860
---

# レビュー結果: #36

## 概要

**Issue:** #36 [Infra/API] バッチを ECS(Fargate) 直列タスク化してタイムアウトを解消（SQS ファンアウト #35 を破棄し再実装）— 月次入金 GTSS-854 / サロンボード取り込み GTSS-817

SQS ファンアウト（#35 / `GTSS-854-sqs`）を破棄し、バッチ（`run-monthly-payouts` / `salonboard-import`）を **タイムアウト上限の無い ECS(Fargate) 単発タスク** で既存の直列ループのまま走らせる方針への切り替え。EventBridge Scheduler の起動先を Lambda invoke → ECS RunTask に変更。フロントエンド変更なし。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-859` | `GTSS-860` | 1 | 8 |
| infra | `GTSS-859` | `GTSS-860` | 1 | 7 |

**関連 PR:** api = `cancel-billing-service-api#33` / infra = `cancel-billing-service-infra#8`（いずれも base `GTSS-859` ← `GTSS-860`）

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `.dockerignore` | +21 | -0 | Added |
| `Dockerfile.batch` | +53 | -0 | Added |
| `build.mjs` | +10 | -7 | Modified |
| `deploy-batch-ecs.sh` | +148 | -0 | Added |
| `src/__tests__/unit/batch-cli.test.js` | +114 | -0 | Added |
| `src/batch-cli.ts` | +77 | -0 | Added |
| `src/batch-entry.ts` | +16 | -0 | Added |
| `src/batch.ts` | +8 | -1 | Modified |

### infra

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `dev/main.tf` | +74 | -5 | Modified |
| `modules/api-compute/main.tf` | +3 | -1 | Modified |
| `modules/api-compute/variables.tf` | +11 | -0 | Modified |
| `modules/batch-fargate/main.tf` | +321 | -0 | Added |
| `modules/batch-fargate/outputs.tf` | +49 | -0 | Added |
| `modules/batch-fargate/variables.tf` | +109 | -0 | Added |
| `prod/main.tf` | +68 | -6 | Modified |

---

## 指摘一覧

> 全指摘は 4 サブエージェント（code-reviewer / lessons-reviewer / codex-reviewer×2）＋メインエージェントの
> cross-file 再検証（呼び出しチェーン追跡）を通過したもの。lessons 照合は「違反なし（過去 lessons を正しく踏襲）」。

---

### [Codex] `:bootstrap` + `ignore_changes[container_definitions]` の再登録トラップ — 将来のタスク定義編集で壊れたイメージが起動しうる

- [x] 対応する

**ファイル:** `infra/modules/batch-fargate/main.tf:213`（`local.image`）/ `:358-396`（`aws_ecs_task_definition.this` + `ignore_changes`）/ `:452-480`（family 参照スケジュール）
**重要度:** Medium（潜在・silent failure）

**該当コード（変更後・toBranch）:**
```hcl
locals {
  image = var.image != "" ? var.image : "${aws_ecr_repository.batch.repository_url}:bootstrap"
}

resource "aws_ecs_task_definition" "this" {
  for_each = local.batch_actions
  family   = "${var.name_prefix}-${each.key}"
  cpu      = tostring(var.cpu)      # ← 非 container_definitions 属性
  memory   = tostring(var.memory)  # ← 同上
  container_definitions = jsonencode([{ name = "batch", image = local.image, ... }])
  lifecycle { ignore_changes = [container_definitions] }
}
# schedule は arn_without_revision（family）参照で「最新 ACTIVE」を起動する
```

**問題:** `ignore_changes` は **既存リソースの UPDATE 時のドリフト抑止のみ** で、`container_definitions` 以外の属性（`cpu`/`memory`/`task_role_arn`/`execution_role_arn`/`runtime_platform`）を将来変更すると、provider は **新リビジョンを config 値（＝`:bootstrap` イメージ）の container_definitions で登録**する（ignore 対象は prior state 値＝初回 apply の bootstrap を保持）。schedule は family の最新 ACTIVE を引くため、この bootstrap リビジョンが起動され `CannotPullContainerError` で **アラート無しに定期バッチが停止** する。初回 apply でも dev は `batch_execution="ecs"` 固定で payout schedule が有効なため、`deploy-batch-ecs.sh` でイメージを push する前に JST06:00 が来ると同様に失敗する（後者は Issue が運用ゲートとして自認済みだが、**後続 apply での再登録リスクは未記載の新規論点**）。

**修正提案:** 「TF が雛形 family＋deploy が実リビジョン」を同一 family で混在させない。(a) 実イメージ配備前は schedule を `state = "DISABLED"` で作る、(b) デプロイ済み task-def ARN を明示入力にする、(c) image/env/secrets まで TF 所有に寄せて `container_definitions` を完全所有する、のいずれか。

---

### [Code Quality] 新 ECS デプロイスクリプトがどの自動デプロイ経路からも呼ばれない（cutover ブロッカー）

- [x] 対応する

**ファイル:** `api/deploy.sh:80-86` / `api/buildspec.yml:44` / `api/deploy-batch-ecs.sh`（新規・参照ゼロ）
**重要度:** Medium（運用ブロッカー）

**該当コード（変更後・toBranch — deploy.sh）:**
```bash
# 2) API Lambda
"$SCRIPT_DIR/deploy-api.sh" "$ENVIRONMENT"
# 3) batch Lambda
log_info "[3/3] batch Lambda をデプロイしています (deploy-batch.sh $ENVIRONMENT)..."
"$SCRIPT_DIR/deploy-batch.sh" "$ENVIRONMENT"   # ← Lambda のみ。deploy-batch-ecs.sh は呼ばれない
```
```yaml
# buildspec.yml:44
- ./deploy.sh "${DEPLOY_ENV}"   # → deploy-api.sh + deploy-batch.sh（Lambda）だけ
```

**問題:** 本 PR で dev は `batch_execution="ecs"`（`dev/main.tf:136`）に切り替わり、実際に定期起動するのは **ECS Fargate タスク**。しかし `deploy.sh` も CI（CodeBuild）も更新するのはスケジュール無効化済みの **Lambda** だけで、ECS が参照するイメージを誰も更新しない（`grep -rn deploy-batch-ecs` は参照ゼロ）。結果:
1. apply 直後はタスク定義が `:bootstrap`（ECR に無いタグ）を指すため、初回 `deploy-batch-ecs.sh dev` を手動実行するまで **dev の入金バッチは ImagePull 失敗で一切起動しない**。
2. その後も `payout.service` 等のコード修正を通常の CI / `deploy.sh dev` で流しても ECS には反映されず、**dev の実行バッチが恒常的に stale コードで走る**。prod を `ecs` に切り替えた後は同じ問題が本番の資金移動バッチに及ぶ。

**修正提案:** cutover 前に `deploy.sh`（および buildspec 経由の CI）へ ECS build/push/register 工程を追加する（`batch_execution=="ecs"` の環境では `deploy-batch-ecs.sh <env>` を実行）。CodeBuild に Docker privileged / ECR push / `ecs:RegisterTaskDefinition` 権限も付与が必要。当面手動運用にするなら、apply→`deploy-batch-ecs.sh`→検証の順序を runbook に固定し、`deploy.sh` に「ecs モードでは本スクリプトは ECS を更新しない」旨の警告 log を出す。

---

### [Code Quality] `deploy-batch-ecs.sh` の必須 env ガードに import 実行必須変数（Decodo / KMS）が無い

- [x] 対応する

**ファイル:** `api/deploy-batch-ecs.sh:200-208`（必須ガード）/ `:246-249`（Decodo）/ `:241`（KMS）
**重要度:** Medium（silent runtime failure）

**該当コード（変更後・toBranch）:**
```bash
MISSING=""
[ -z "${AURORA_RESOURCE_ARN:-}" ] && MISSING="${MISSING} AURORA_RESOURCE_ARN"
[ -z "${AURORA_SECRET_ARN:-}" ]   && MISSING="${MISSING} AURORA_SECRET_ARN"
[ -z "${AURORA_DATABASE:-}" ]     && MISSING="${MISSING} AURORA_DATABASE"
[ -z "${STRIPE_SECRET_KEY:-}" ]   && MISSING="${MISSING} STRIPE_SECRET_KEY"
# ← CREDENTIALS_KMS_KEY_ID / DECODO_USERNAME / DECODO_PASSWORD は未チェック
...
CREDENTIALS_KMS_KEY_ID: env.CREDENTIALS_KMS_KEY_ID || "",   # 空許容
DECODO_USERNAME: env.DECODO_USERNAME || env.DECODE_USERNAME || "",
DECODO_PASSWORD: env.DECODO_PASSWORD || env.DECODE_PASSWORD || "",
```

**問題:** 1 回の deploy で payouts と **import** の両 family を同一 env で register するが、ガードは payout 系のみ。`salonboard-import` は実行時に必ず以下を要求し、欠けると throw する（メインエージェント検証済み）:
- `requireSalonboardProxy(null)` → dev/prod で `SALONBOARD_PROXY_NOT_CONFIGURED`（`config.ts:206`）
- `decryptSecret` → dev/prod で `CREDENTIALS_KMS_KEY_ID` 未設定時 throw（`utils/crypto.ts:76-79`）

`SALONBOARD_TRANSPORT=playwright` 固定・`NODE_ENV=dev|prod` のコンテナではこの throw 経路が有効なため、空文字で register すると **手動 RunTask（T-5 の Chromium 検証含む）や import 定期起動が実行時に確実に失敗**するのに、deploy 自体は成功扱いになる。

**修正提案:** import family を register する場合は `CREDENTIALS_KMS_KEY_ID` / `DECODO_USERNAME` / `DECODO_PASSWORD` をアクション別に必須検証するか、空なら import family の register をスキップして warning を出す。

---

### [Security] 機密値（STRIPE_SECRET_KEY / DECODO_PASSWORD）を ECS タスク定義 environment に平文投入。`secrets` 経路が未使用で `kms:Decrypt` も欠落

- [x] 対応する

**ファイル:** `api/deploy-batch-ecs.sh:232-256`（`ENV_JSON`）/ `:263-271`（`.environment = $ENV`）/ `infra/modules/batch-fargate/main.tf:336-349`（`task_exec_secrets`）/ `infra/dev/main.tf:82-84`・`prod/main.tf:727-729`（`container_secrets` 未配線）
**重要度:** Medium（セキュリティ・現行 Lambda パリティ＝新規リグレッションではない）

**該当コード（変更後・toBranch）:**
```bash
# deploy-batch-ecs.sh — 実秘密を平文 environment へ
STRIPE_SECRET_KEY: env.STRIPE_SECRET_KEY || "",
DECODO_PASSWORD:   env.DECODO_PASSWORD || env.DECODE_PASSWORD || "",
# → .containerDefinitions[0].environment = $ENV
```
```hcl
# batch-fargate/main.tf — secrets 経路は実装済みだが未配線、かつ kms:Decrypt を含まない
resource "aws_iam_role_policy" "task_exec_secrets" {
  count  = length(var.container_secrets) > 0 ? 1 : 0   # dev/prod は container_secrets={} → 作られない
  policy = jsonencode({ Statement = [{
    Action   = ["secretsmanager:GetSecretValue", "ssm:GetParameters"]  # ← kms:Decrypt 無し
    Resource = values(var.container_secrets)
  }]})
}
```

**問題:** `STRIPE_SECRET_KEY`（prod は `sk_live_`）と `DECODO_PASSWORD` を平文 `environment` に入れており、`ecs:DescribeTaskDefinition` 権限で露出する。Issue の技術考慮「Secrets は Secrets Manager / SSM から注入」と乖離する。既存 Lambda 版 `deploy-batch.sh` も同様に平文 env 注入する **踏襲パターン（新規リグレッションではない）** だが、ECS には `container_secrets`（`valueFrom`）というより安全な経路がモジュールに実装済みなのに使っていない。加えて `task_exec_secrets` ポリシーは `kms:Decrypt` を含まないため、将来 CMK 暗号化した Secret/Parameter を `secrets` 注入すると復号できず `ResourceInitializationError` でタスクが起動失敗する（潜在バグ）。
※ `AURORA_SECRET_ARN` / `CREDENTIALS_KMS_KEY_ID` は ARN/ID であり秘密値ではない（過剰指摘に注意。実秘密は上記 2 値）。

**修正提案:** `STRIPE_SECRET_KEY` / `DECODO_PASSWORD` を `container_secrets`（SSM Parameter Store / Secrets Manager の ARN）へ移し、deploy は `environment` から除外・`secrets` を保持して image と非秘密 env のみ更新する。併せて `task_exec_secrets` に対象 ARN と使用 CMK の `kms:Decrypt` を別 Statement で限定付与する。prod（`sk_live_`）カットオーバーまでに寄せるのを推奨。

---

### [Codex] `batch_execution` が未検証の生文字列 — タイプミスで両経路が静かに全無効化

- [x] 対応する

**ファイル:** `infra/dev/main.tf:136`（`= "ecs"`）/ `infra/prod/main.tf:42`（`= "lambda"`）/ 判定 `dev:156,206` `prod:163-164,211-212`
**重要度:** Medium（foot-gun・silent failure）

**該当コード（変更後・toBranch）:**
```hcl
locals {
  batch_execution = "ecs"   # "ecs" | "lambda"（生文字列・検証なし）
}
# batch_compute:  enable_payout_schedule = local.batch_execution == "lambda"
# batch_fargate:  enable_payout_schedule = local.batch_execution == "ecs"
```

**問題:** `"ecs"` / `"lambda"` 以外（例 `"ecss"`）を書くと、Lambda 側も ECS 側も両方 `false` になり、payout/import スケジュールが **全て消える＝バッチが無警告で停止** する。`terraform plan`/`validate` では検知できない。

**修正提案:** `variable "batch_execution"` + `validation { condition = contains(["ecs","lambda"], var.batch_execution) }` にするか、`use_ecs = true/false` の bool トグルにして Lambda 側を `!use_ecs` で導出し「排他かつ網羅」を構造的に保証する。

---

### [Security] 過剰権限の共有ロール（SES / DynamoDB FullAccess）が Chromium 実行コンテナの task role にも拡大

- [x] 対応する

**ファイル:** `infra/dev/main.tf:39`（`extra_assume_role_service_principals`）/ `:71`（`task_role_arn = module.api_compute.lambda_role_arn`）/ `modules/api-compute/variables.tf` の default policy（`AmazonSESFullAccess` + `AmazonDynamoDBFullAccess`）
**重要度:** Low〜Medium（セキュリティ・既存負債の露出拡大）

**問題:** 共有 Lambda ロールを ECS task role に再利用するため、**外部サイト（サロンボード＋Decodo プロキシ）を headless Chromium で開くコンテナが SES / DynamoDB の FullAccess を保持** する。Lambda より攻撃面（悪性ページ / 依存経由の RCE）が広く、被害時の blast radius（任意メール送信等）が大きい。FullAccess 自体は既存負債（`dev/main.tf:41-46` のコメントで自認済み）だが、ブラウザ実行 ECS への拡大は本 PR が持ち込む新しい露出。

**修正提案:** 既存コメントが予告する最小権限化 follow-up を、攻撃面が広がる ECS 化のこのタイミングで優先する。batch 用に task role を分離し SES/DynamoDB を必要最小へ絞ることも検討（本 PR 範囲外だが Issue 化推奨）。

---

### [Code Quality] ECS RunTask のタスク失敗が観測されない（DLQ / retry / アラーム無し）

- [x] 対応する

**ファイル:** `infra/modules/batch-fargate/main.tf:452-480`（`aws_scheduler_schedule.this`）
**重要度:** Low（可観測性）

**問題:** EventBridge Scheduler は RunTask **API 呼び出しの成否**しか判定しない。コンテナが `exit 1`（`batch-cli.ts:479` の失敗パス）で終わっても Scheduler 側は成功扱いになり、**入金バッチの失敗が SES レポート以外では黙殺**される（コンテナ起動前クラッシュ時はレポートも出ない）。schedule に `dead_letter_config` / `retry_policy` も無い。Lambda 非同期 invoke も DLQ 未設定だったため部分パリティだが、資金移動バッチとしては監視が薄い。

**修正提案:** (a) schedule に `dead_letter_config`（SQS）を付ける、(b) ECS タスク停止イベント（`stoppedReason` / `exitCode != 0`）を EventBridge ルール＋SNS でアラート化、または最低限 `/ecs/cancel-billing-batch-*` の `[batch-cli] failed` に metric filter + アラームを設定する。

---

### [Codex] `batch-entry.ts` の `process.exit()` が完了/失敗ログを CloudWatch へ flush する前に切り捨てうる

- [x] 対応する

**ファイル:** `api/src/batch-entry.ts:11-15`
**重要度:** Low（可観測性）

**該当コード（変更後・toBranch）:**
```typescript
runCli()
  .then((code) => process.exit(code))   // ← runCli 内の console.log/error 直後に exit
  .catch((err) => { console.error('[batch-entry] unexpected error:', err); process.exit(1); });
```

**問題:** `runCli` が完了サマリ / 失敗 stack を `console.log/error` した直後に `process.exit()`。Fargate は stdout/stderr が awslogs へ非同期パイプ書き込みのため、flush 前に切り捨てられうる。非 0 終了コード自体は残るが、REQ-7 の障害調査性が落ちる。

**修正提案:** `process.exitCode = code` にしてイベントループの自然終了に委ねる（RDS Data API は HTTPS で常駐接続を持たず、nodemailer/Stripe も idle でループを保持しないため自然終了する見込み。lingering handle が無いことは確認して適用）。

---

### [Security] 共有ロール信頼ポリシーの `ecs-tasks` に confused-deputy 条件（SourceAccount/SourceArn）が無い

- [x] 対応する

**ファイル:** `infra/modules/api-compute/main.tf:122-131`
**重要度:** Low（セキュリティ・任意）

**該当コード（変更後・toBranch）:**
```hcl
Principal = { Service = distinct(concat(["lambda.amazonaws.com"], var.extra_assume_role_service_principals)) }
Action    = "sts:AssumeRole"
# ← Condition（aws:SourceAccount / aws:SourceArn）無し
```

**問題:** サービスプリンシパル信頼に `SourceAccount`/`SourceArn` 条件を付けるのが confused-deputy 対策のベストプラクティス。既存の lambda 信頼も無条件で **現状ポスチャと一貫**（アカウントローカル＋PassRole は scheduler ロールに限定済み）のため実害は限定的だが、権限昇格面を新規に増やすこのタイミングで締めておくと堅牢。

**修正提案:** 任意。`Condition = { StringEquals = { "aws:SourceAccount" = <account_id> } }` を信頼ステートメントへ追加（lambda 側も同時に）。

---

### [Codex] Lambda→ECS スケジュール切替が単一 apply 内で原子的でない

- [x] 対応する

**ファイル:** `infra/dev/main.tf:156 vs 206` / `infra/prod/main.tf:163-164 vs 211-212`
**重要度:** Low（運用・冪等性で緩和済み）

**問題:** 旧 Lambda schedule（`cancel-billing-service-batch-*-run-monthly-payouts`）と新 ECS schedule（`cancel-billing-batch-*-payouts`）は別名・別リソースで相互依存が無いため、Terraform は destroy と create を並列実行しうる。apply 途中で「一時的な二重有効」または「旧削除後に新作成失敗→無スケジュール」が起こりうる。**ただし実害は低い**: apply は人手ゲートで cron 時刻と重ならず、二重起動しても payout の claim + idempotencyKey / import の part-unique で二重処理は防止される（メインエージェント検証済み）。

**修正提案:** 段階 apply（新 schedule を `state="DISABLED"` で作成→検証→旧停止→新有効化）を運用手順化する。

---

### [Codex] CloudWatch Logs 保持期間が既定 `null`（無期限）

- [x] 対応する

**ファイル:** `infra/modules/batch-fargate/variables.tf:604-608`（`log_retention_in_days` default `null`）→ `main.tf:292-296`
**重要度:** Low（コスト）

**問題:** dev/prod とも未指定のため `/ecs/cancel-billing-batch-*` のログが **無期限保持** となりコストが単調増加する。

**修正提案:** 30/90 日等の保持を既定または環境側で指定する。

---

### [Test Coverage] batch-cli テストの薄い 2 点 / dev import の Scheduler 経路が未検証

- [x] 対応する

**ファイル:** `api/src/__tests__/unit/batch-cli.test.js` / `infra/dev/main.tf`（import schedule 無効）
**重要度:** Low

**問題:**
1. `runCli` 経由で補助フィールド（applicationId/dryRun/trigger/runId）が `dispatchBatchAction` へ透過することの直接アサーションが無い（`parseCliEvent` 単体では検証済みなので実害低）。
2. 「非空の未知 action → 実 `dispatchBatchAction` の default throw → CLI exit 1」の契約が未 mock で未検証（実装は `batch.ts:79-80` + `batch-cli.ts` catch で正しい）。
3. dev は Lambda/ECS とも `salonboard-import` schedule 無効（Decodo 費用回避）のため、AC-1.1/T-1 の「Scheduler→RunTask」を import では実機確認不能。ただし Scheduler→RunTask **機構自体は dev の payout schedule で代表検証可能**なので過大視は不要。

**修正提案:** 任意。`runCli(['node','x','salonboard-import'], { BATCH_APPLICATION_ID:'app_1', BATCH_DRY_RUN:'true' })` で `dispatchBatchAction` が `{action, applicationId, dryRun:true}` で呼ばれる 1 ケースと、未 mock 未知 action → exit 1 の 1 ケースを追加。AC 側は「import は手動 RunTask のみ・Scheduler 機構は payout で代表検証」と明記。

---

## スコープ外の重要指摘（本 PR 差分外・別 Issue 推奨）

### [Security] `initClients()` に SES SMTP 認証情報がハードコードされている（実鍵がリポジトリに残存）

**ファイル:** `api/src/clients.ts:76-77`
**重要度:** High（ただし本 PR 差分外）

**該当コード:**
```typescript
auth: {
  user: process.env.SMTP_USERNAME || 'AKIASD54XXXXXXXXXXXX',       // ← AWS アクセスキー ID がフォールバックに直書き
  pass: process.env.SMTP_PASSWORD || '<40 文字超の SMTP パスワード>', // ← 同上（マスク済み。実値がソースに残存）
}
```

**問題:** `initClients()` 内で SES SMTP の user/pass が **実値でハードコード** されている。本 PR の変更対象ではない（diff に含まれない）が、この PR で ECS タスクも同じ `initClients()` 経路を通る（`run-monthly-payouts` 分岐）ため念のため。リポジトリに実鍵が残っている状態。

**修正提案:** 別 Issue で (1) 当該 SMTP 認証情報を **即時ローテーション**、(2) フォールバック直書きを削除して SSM/Secrets 必須化、(3) git 履歴からの除去可否を検討。

---

## 総評

**設計・実装は総じて妥当で、致命的な即時バグや挙動リグレッションは無い。** SQS ファンアウトの複雑さを捨て「timeout だけを ECS で解く」という Issue の判断は、既存のテスト済み直列コードをそのまま活かせており筋が良い。lessons 照合も「違反なし（過去 lessons を正しく踏襲）」。

メインエージェントが cross-file で **裏取りして問題なしと確認した重点項目**（誤検知防止のため明記）:
- **挙動不変性**: `initClients()` は `dispatchBatchAction` の `run-monthly-payouts` 分岐内に保持（`batch.ts:70`）。`handler` は薄い委譲でロールバック温存も担保。既存 e2e（monthly-payouts / force-payout-sweep / payout-stale-processing 88 passed ほか）が等価性を担保。
- **Chromium 配線**: `selectChromiumSource` は `CHROMIUM_EXECUTABLE_PATH` 最優先（`salonboard-client.ts:874`）。`@sparticuz/chromium` の動的 import は `AWS_LAMBDA_FUNCTION_NAME` 時のみ評価されコンテナでは到達しない → runtime 未コピーでも壊れない。`build.mjs` external と Dockerfile の playwright-core コピー + symlink + `test -x` も整合。
- **IAM 最小権限**: `ecs:RunTask` は `${arn_without_revision}:*`（family 全リビジョン）+ cluster Condition、`iam:PassRole` は task_role/exec_role の 2 本のみ + `PassedToService=ecs-tasks` 限定。scheduler role の `count` ガードと `[0]` 参照も整合。
- **命名衝突なし**: Lambda 側 `cancel-billing-service-batch-*-run-monthly-payouts` vs ECS 側 `cancel-billing-batch-*-payouts`、ロールも別名。`local.batch_execution` トグルで同時作成もされない。
- **信頼ポリシー拡張の適用**: dev/prod とも `manage_role=true`（dev は既定 true）でロールを所有 → `extra_assume_role_service_principals` が有効。`distinct(concat(...))` で既存 lambda 信頼を保持。
- **VPC / ネットワーク**: dev 10.50/16・prod 10.51/16 は Aurora（10.40/10.41）と非重複。Data API(HTTPS) で VPC ピアリング不要。public subnet + `assign_public_ip=true` + egress-only SG で ECR pull/外部 egress 成立・インバウンド無しも適切。
- **jq whitelist**: `ephemeralStorage`/`volumes`/`placementConstraints` を落とすが TF はこれらを設定していないため無害（メインエージェント確認）。
- **秘密のイメージ焼き込みなし**: `.dockerignore` が `.env*` / `*.login.json` を除外。

**対応の優先度:**
1. **cutover 前に必須** — 「deploy 経路への ECS 配線」（Medium）と「`:bootstrap` 再登録トラップ」（Medium/潜在）は、dev apply／prod カットオーバー前に手当てしないと **無警告でバッチが停止** する。
2. **cutover 前に推奨** — import env ガード（Medium）、`batch_execution` の検証化（Medium）、Secrets の `secrets` 経路化 + `kms:Decrypt`（Medium/セキュリティ）。
3. **改善・任意** — 失敗アラーム / DLQ、`process.exitCode` 化、confused-deputy 条件、log 保持期間、テスト補強、過剰権限ロールの分離（別 Issue）。
4. **別 Issue（緊急）** — `clients.ts` の SMTP 認証情報ハードコードは即時ローテーション。

自動テスト（Vitest 全 green / typecheck / terraform validate dev・prod / 実 docker build / コンテナ内 Chromium 実起動）は担保済み。残りは dev 実 apply での人力/IaC 検証（T-1/T-5/T-9/T-10/T-11）。
