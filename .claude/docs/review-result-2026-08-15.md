---
issue: 67
date: 2026-08-15
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: main
    toBranch: GTSS-909
  - repo: lp
    repoDir: cancel-billing-service-lp
    baseBranch: main
    toBranch: GTSS-909
---

# レビュー結果: #67

## 概要

**Issue:** #67 feat: Stripe登録未完了サロンへの自動リマインドメール（初回案内の3日後・7日後の2回）— Stripe requirements ベースの対象判定・既存滞留申込のバックフィル

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `main` | `GTSS-909` | 2 | 20 |
| lp | `main` | `GTSS-909` | 2 | 2 |

> **ベースブランチについて**: manifest（`.claude/worktree-manifests/GTSS-909.json`）は api の `baseBranch` を `origin/develop` と記録しているが、`git merge-base origin/develop origin/GTSS-909` は `origin/main` の HEAD と一致し、`origin/develop` は GTSS-909 の祖先ではない（develop は main より 23 コミット先行）。実際に `GTSS-909` は `origin/main` から切られているため、引数指定どおり `main` を base としてレビューした。**マージ先が develop の場合は指摘 R-3 を参照すること。**

### 検証状況

| 対象 | 結果 |
|---|---|
| api: GTSS-909 関連 + 契約系 8 ファイル（`stripe-onboarding-reminder-{decision,content,contract}` / `stripe-onboarding-reminders` / `stripe-guide-sent-at` / `schema` / `repository-columns` / `response-contract`） | ✅ 165 tests passed |
| lp: `src/__tests__/stripeRefresh.test.jsx` | ✅ 3 tests passed |
| api 全スイート | 未実行（本レビューでは対象ファイルのみ実行） |
| 指摘 C-1 の再現 | ✅ スクラッチテストで実測（実行後削除済み） |
| 指摘 L-1 の再現 | ✅ 実行時の stdout 漏れを実測 |
| 指摘 R-1 / R-2 / R-4 の前提 | ✅ infra リポジトリ・`buildspec-batch.yml`・`git merge-tree` で実確認 |

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/services/stripe-onboarding-reminder.service.ts` | +439 | -0 | Added |
| `src/repositories/application-notifications.repository.ts` | +153 | -0 | Added |
| `src/repositories/applications.repository.ts` | +81 | -1 | Modified |
| `src/services/application.service.ts` | +16 | -0 | Modified |
| `src/constants/application-enums.ts` | +12 | -1 | Modified |
| `src/db/schema.ts` | +65 | -0 | Modified |
| `src/db/migrations/0025_gtss909_stripe_onboarding_reminders.sql` | +33 | -0 | Added |
| `src/db/migrations/0026_gtss909_backfill_stripe_guide_sent_at.sql` | +35 | -0 | Added |
| `src/db/migrations/rollback/0025_...down.sql` | +8 | -0 | Added |
| `src/db/migrations/meta/_journal.json` | +14 | -0 | Modified |
| `src/batch.ts` | +13 | -0 | Modified |
| `deploy-batch-ecs.sh` | +6 | -1 | Modified |
| `src/__tests__/e2e/stripe-onboarding-reminders.test.js` | +764 | -0 | Added |
| `src/__tests__/e2e/stripe-guide-sent-at.test.js` | +284 | -0 | Added |
| `src/__tests__/unit/stripe-onboarding-reminder-decision.test.ts` | +313 | -0 | Added |
| `src/__tests__/unit/stripe-onboarding-reminder-contract.test.ts` | +198 | -0 | Added |
| `src/__tests__/unit/stripe-onboarding-reminder-content.test.ts` | +159 | -0 | Added |
| `src/__tests__/helpers/db.js` | +4 | -1 | Modified |
| `src/__tests__/e2e/repository-columns.test.js` | +2 | -0 | Modified |
| `src/__tests__/e2e/schema.test.js` | +2 | -1 | Modified |

### lp

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/components/StripeRefresh.jsx` | +5 | -3 | Modified |
| `src/__tests__/stripeRefresh.test.jsx` | +122 | -0 | Added |

---

# A. リリース手順に関する指摘（マージ前に判断が必要）

このセクションはコード品質ではなく**リリース順序の問題**で、いずれも「静かに失敗する」種類のもの。コード修正が不要なものも含むが、PR / Issue への明記は必要。

- [x] 対応する

### [Release] R-1: バックフィル（0026）が「リリース時刻から 14 日」のワンショット時計を始める。infra 未適用のまま migrate すると滞留サロン全件が恒久的に対象外になる

**ファイル:** `api/src/db/migrations/0026_gtss909_backfill_stripe_guide_sent_at.sql`
**重要度:** High（機能の目的そのものが静かに失われる）

**該当コード:**

```sql
-- src/db/migrations/0026_gtss909_backfill_stripe_guide_sent_at.sql
UPDATE applications
SET stripe_guide_sent_at = to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
WHERE deleted_at IS NULL
  AND status IN ('approved', 'onboarding', 'Stripe登録待ち', 'オンボーディング待ち')
  AND stripe_account_id IS NOT NULL
  AND email IS NOT NULL
  AND stripe_guide_sent_at IS NULL;   -- ← 冪等ガード。二度と再実行されない
```

```typescript
// src/repositories/applications.repository.ts:222-224（抽出窓）
    const sentBefore    = jstDayStartIso(addDaysJst(todayJst, -2));   // 経過 3 日以上
    const sentAtOrAfter = jstDayStartIso(addDaysJst(todayJst, -13));  // 経過 14 日未満
```

**問題:**
バックフィルは**マイグレーション実行時刻**を起点として書き込み、`WHERE stripe_guide_sent_at IS NULL` により再実行されない。抽出窓は経過 3〜14 日なので、**migrate 実行から 14 日以内に `send-stripe-onboarding-reminders` の EventBridge Scheduler が稼働していないと、バックフィル対象の滞留サロン全件が 1 通も受け取らないまま恒久的に窓から外れる。**

さらに、この状態からの回復手段が用意されていない:

- `src/db/migrations/rollback/` に **0026 の down SQL は意図的に存在しない**（0025 の down にその旨のコメントあり。バックフィルで書いた値と承認経路が書いた値を列上で区別できないため）
- したがって「起点を NULL に戻して再実行」も安全にはできない

そして実際にリスクが顕在化する条件が揃っている（実確認済み）:

| 確認項目 | 結果 |
|---|---|
| infra に `stripe_reminders` の定義があるか | **無い**（`~/infra/cancel-billing-service-infra`・`grep -rn stripe_reminders --include='*.tf'` → 0 件）。REQ-9 の PR-3 は未着手 |
| `deploy.sh` の実行順 | `[1/3] migrate` → `[2/3] deploy-api.sh` → `[3/3] deploy-batch.sh`。**migrate が最初** |
| 0026 は 0025 と分離適用できるか | できない。`deploy.sh` は未適用マイグレーションを一括適用する（Issue 本文にも明記） |

Issue の「実装順序」節は「PR-3（infra）を先に apply → PR-1/PR-2 をマージしてデプロイ」と正しい順序を指定しているが、**この順序を守れなかった場合のペナルティが「リマインドが 1 通も出ないまま静かに終わる」ことは Issue にも書かれていない。**

**修正提案:**
次のいずれか。

- **(推奨・コード変更なし)** go-live 手順として「**infra apply → dev で手動 invoke して動作確認 → 最後に prod migrate + deploy**」を PR 本文と Issue に明記し、`0026` の SQL ヘッダにも「このマイグレーションを適用した時点で 14 日のカウントダウンが始まる。Scheduler が稼働していることを先に確認すること」と警告コメントを足す
- **(構造的な解)** バックフィルを journal 管理外の運用スクリプト（`scripts/backfill-stripe-guide-sent-at.ts` 等）へ移し、日付を引数で渡して再実行できるようにする。Issue 本文も「バックフィルの実行タイミングを本当に切り離したい場合は、journal 管理外の運用スクリプトにすること」と同じ選択肢を提示している

---

- [x] 対応する

### [Release] R-2: `FAMILIES` への新 family 追加を TF apply より先に develop/main へマージすると、batch イメージの CI が確実に落ちる

**ファイル:** `api/deploy-batch-ecs.sh:50`
**重要度:** Medium

**該当コード（toBranch 側）:**

```bash
# deploy-batch-ecs.sh:17
set -euo pipefail
…
# deploy-batch-ecs.sh:50
FAMILIES=("${PREFIX}-payouts" "${PREFIX}-import" "${PREFIX}-reminders" "${PREFIX}-stripe_reminders")
…
# deploy-batch-ecs.sh:228-231
for FAMILY in "${FAMILIES[@]}"; do
  log_info "タスク定義を更新しています: ${FAMILY}"
  CURRENT=$(aws ecs describe-task-definition --task-definition "$FAMILY" "${PROFILE_ARGS[@]}" --query taskDefinition)
```

**問題:**
`buildspec-batch.yml` は自身のヘッダで「専用 CodeBuild プロジェクト（cancel-batch-image-<env>）が本 spec を使い、**develop / main push 契機で常に** batch イメージを build → ECR push → タスク定義 register する。差分判定はしない」と定義している。

`set -euo pipefail` 下で `CURRENT=$(aws ecs describe-task-definition …)` は、family が存在しないと非ゼロ終了してスクリプト全体を中断する。Terraform に `cancel-billing-batch-{env}-stripe_reminders` が無い状態でマージすると:

1. docker build と ECR push は**完了する**
2. `payouts` / `import` / `reminders` の register も**完了する**
3. ループ 4 周目の `stripe_reminders` で describe が失敗 → **CI 赤**

「3 family だけ新リビジョンが登録され、ビルドは赤」という中途半端で読み解きにくい状態になる。なお `TD_ARCH` を取る 140 行目は `FAMILIES[0]`（= payouts・既存）を見るので早期には落ちない。

**修正提案:**
R-1 と同じく **infra apply を先行**させる運用で回避できる。順序を守れない可能性があるなら、ループ側を「family が無ければ warning でスキップ」に緩める手もあるが、その場合「TF 追加漏れに気づけなくなる」ので推奨しない。**PR 本文に「この PR は infra PR-3 の apply 後にマージすること」を明記**するのが最小コスト。

---

- [x] 対応する

### [Release] R-3: develop へマージする場合、4 ファイルが衝突する（特に `deploy-batch-ecs.sh` は develop で大改修済み）

**重要度:** Medium

**実確認結果（`git merge-tree $(git merge-base origin/develop origin/GTSS-909) origin/develop origin/GTSS-909`）:**

| ファイル | 状態 |
|---|---|
| `deploy-batch-ecs.sh` | changed in both（develop 側は main から **+101 / -11** の大改修） |
| `src/batch.ts` | changed in both |
| `src/db/schema.ts` | changed in both |
| `src/services/application.service.ts` | changed in both |

`src/db/migrations/meta/_journal.json` は develop 側が base と同一（= develop も最新は 0024）なので、**マイグレーション番号 0025 / 0026 の衝突は無い**。

特に注意すべきは `deploy-batch-ecs.sh`:

- develop 側には **`BATCH_CONTAINER_SECRETS` を使って register のたびに ECS secrets を載せ直す機構が入っている**（`git grep -c BATCH_CONTAINER_SECRETS origin/develop -- deploy-batch-ecs.sh` → 6 件。`origin/main` には 0 件）
- GTSS-909 は main ベースなのでこの機構を知らず、`FAMILIES` 行だけを編集している
- 新設の契約テストは `FAMILIES=(...)` 行の**完全一致**を assert しているため（`stripe-onboarding-reminder-contract.test.ts`）、マージ後にこの行が develop 側の形へ変わっているとテストが落ちる

**修正提案:**
マージ先を決めたうえで、develop なら 4 ファイルのコンフリクト解消後に契約テストを再実行すること。`deploy-batch-ecs.sh` は develop 側の `BATCH_CONTAINER_SECRETS` 機構を残したまま `FAMILIES` に `stripe_reminders` を足す形へ手で解決する必要がある。

---

- [x] 対応する

### [Release] R-4: `chore/remove-dead-approve-application` と正面衝突する（マージ順の決定が必要）

**重要度:** Medium

**実確認結果:**

| 確認項目 | 結果 |
|---|---|
| `git branch -a --contains 9f5b8dd` | `chore/remove-dead-approve-application` のみ。**main / develop 未取り込み** |
| `origin/main` の `approveApplication` | 存在する |
| `chore/remove-dead-approve-application` の `approveApplication` | **削除済み**（`git grep -c` → 0 件） |
| ローカル `/Users/aki/cancel/cancel-billing-service-api` の checkout | `chore/remove-dead-approve-application`（= このリファクタが現在進行中） |

本 PR は `approveApplication` の存在に依存している:

- `src/services/application.service.ts:506` の起点記録（`approveApplication` 内部）
- `src/__tests__/e2e/stripe-guide-sent-at.test.js` の `postApprove` を使う 4 ケース
- 契約テストの `KNOWN_SUBJECT_SITES = 3` / `KNOWN_RECORDING_SITES = 2`

どちらを先にマージしても他方が壊れる。`approveApplication` を落とす方針なら、本 PR 側は「起点記録 1 箇所削除・契約テスト定数を 2 / 1 へ・e2e から 4 ケース削除」で済む。

なお契約テスト（T-3）は**この増減を検知するために作られている**ので、壊れ方は分かりやすく設計されている。順序だけ決めればよい。

**修正提案:**
どちらを先にマージするか決めて Issue にコメントを残す。`chore/...` を先にマージするなら、GTSS-909 側の rebase と上記 3 点の修正を同 PR 内で行う。

---

- [x] 対応する

### [Release] R-5: **【本レビューの前稿の訂正】** ECS 新 family の `STRIPE_SECRET_KEY` は TF が自動で配線するため、per-family の追加作業は不要

**重要度:** Low（情報訂正。作業は減る）

Issue 本文の実装設計表は「`container_secrets` へ**新 family 分の** `STRIPE_SECRET_KEY`（SSM `valueFrom`）を配線する（TF が初回に入れないと永久に入らない）」と書いており、本レビューの初稿もこれをそのまま引き写していた。**infra を実確認した結果、これは不正確だった。**

```hcl
# modules/batch-fargate/main.tf:69（モジュール共通の local）
  container_secrets = [for k, v in var.container_secrets : { name = k, valueFrom = v }]

# modules/batch-fargate/main.tf:232-254（全 family へ一律適用）
resource "aws_ecs_task_definition" "this" {
  for_each = local.batch_actions
  family   = "${var.name_prefix}-${each.key}"
  …
  container_definitions = jsonencode([{
    …
    secrets     = local.container_secrets   # ← family ごとの出し分けは無い
  }])
  lifecycle {
    ignore_changes = [container_definitions]
  }
}
```

```hcl
# dev/main.tf:226-236 / 284
  batch_container_secret_keys = {
    STRIPE_SECRET_KEY = "stripe_secret_key"
    DECODO_PASSWORD   = "decodo_password"
    TWILIO_AUTH_TOKEN = "twilio_auth_token"
    SLACK_BOT_TOKEN   = "slack_bot_token"
  }
  …
  container_secrets = local.batch_container_secret_arns
```

`container_secrets` は **family ごとではなくモジュール共通の 1 リスト**で、`for_each = local.batch_actions` の全 family に同じものが入る。しかも infra 側 `dev/main.tf:217-222` が「`ignore_changes = [container_definitions]` はこれは**更新時のみ**効いて**新規作成時は効かない**」と自ら明記している。

したがって **`local.batch_actions` に `stripe_reminders` を足せば、その family の初回リビジョンに `STRIPE_SECRET_KEY` が自動的に入る。** `container_secrets` への追加作業は不要。

**修正提案:**
Issue 本文の実装設計表（`modules/batch-fargate/main.tf` の行）から「`container_secrets` へ新 family 分の `STRIPE_SECRET_KEY` を配線する」の記述を削除・訂正する。AC-10.4 / T-55 の「デプロイ前に `describe-task-definition` で secrets を確認する」は残してよい（確認自体は有用）。

---

# B. コードに関する指摘

- [x] 対応する

### [Test Coverage] C-1: 注入した `now` が履歴の時刻へ伝播せず、「実バッチで round1 → 実バッチで round2」の経路がテストで再現できない

**ファイル:** `api/src/services/stripe-onboarding-reminder.service.ts:268-276`（`finalizeClaim`）／`api/src/repositories/application-notifications.repository.ts:52-78`（`claimRound` の `created_at`）
**重要度:** Medium

**該当コード（toBranch 側・現状）:**

```typescript
// src/services/stripe-onboarding-reminder.service.ts:266-277
const finalizeClaim = async (claimId: string, outcome: NotificationOutcome): Promise<boolean> => {
  try {
    await applicationNotificationsRepo.finalize(claimId, {
      status: outcome.status,
      ...outcome.patch,
      sentAt: new Date().toISOString(),   // ← 注入された now ではなく実時間
    });
    return true;
```

```typescript
// src/services/stripe-onboarding-reminder.service.ts:88-98（この sentAt を読む側）
    const lastAttemptedAt = attempts
      .map((a) => a.attemptedAt)
      .filter((v): v is string => !!v)
      .sort()
      .pop();
    if (lastAttemptedAt && daysBetweenJst(lastAttemptedAt, now) < MIN_GAP_DAYS) return null;
    return 2;
```

**問題:**
バッチ本体は `runStripeOnboardingReminders({ now })` で時刻を注入できる設計だが、履歴の `sent_at`（`finalizeClaim`）は `new Date()`、`created_at` は DB の `now()` で書かれる。一方リマインド 2 の最小間隔判定（`MIN_GAP_DAYS`）はその値と**注入された `now`** を比較する。

**本番影響は無い**（`src/batch.ts` の dispatch は常に `now: new Date()` を渡し、運用者が上書きする経路は無い）。問題は**テストで自然な 2 回シーケンスを再現できないこと**で、実際に検証した:

```javascript
// スクラッチ検証（実行後に削除済み・worktree クリーン確認済み）
const a = await runStripeOnboardingReminders({ now: dayN(3) });  // → remindersSent: 1（round 1 送信）
const b = await runStripeOnboardingReminders({ now: dayN(7) });  // → remindersSent: 0 ★
// b の summary: {"targets":1,"stripeChecked":0,"remindersSent":0,…}
```

round 1 の `sent_at` に実時間（2026-08-15）が入るため `daysBetweenJst('2026-08-15…', dayN(7)='2026-06-08')` が負値になり、最小間隔チェック（`< 4`）で `null` に倒れ、Stripe 問い合わせすら行われない。

そのため T-47 / T-58 は**履歴を手で seed して**最小間隔を検証しており、「バッチ自身が書いた履歴」に対する最小間隔ロジックは 1 度も通っていない。素直にそのテストを書こうとすると書けず、初めてこの構造に気づくことになる。

**修正提案:**
`claimRound` / `finalize` に時刻を引数で渡し、バッチからは注入された `now` を流す（`createdAt: now.toISOString()` / `sentAt: now.toISOString()`）。そのうえで「day3 に実バッチ送信 → day7 に実バッチ再実行 → リマインド 2 が送られる」「day3 送信 → day6 再実行 → 送られない」の E2E を 1 本追加する。

---

- [x] 対応する

### [Code Quality] C-2: `attemptedRoundsByApplicationIds` が timestamptz を正規化しておらず、`Date.parse` が実行環境 TZ 依存になる

**ファイル:** `api/src/repositories/application-notifications.repository.ts:108-135`
**重要度:** Medium

**該当コード（toBranch 側）:**

```typescript
// src/repositories/application-notifications.repository.ts:112-134
    const rows = await db
      .select({
        applicationId: applicationNotifications.applicationId,
        round: applicationNotifications.round,
        sentAt: applicationNotifications.sentAt,
        createdAt: applicationNotifications.createdAt,
      })
      .from(applicationNotifications)
      .where(/* … */);
    for (const r of rows) {
      const list = map.get(r.applicationId) ?? [];
      list.push({ round: Number(r.round), attemptedAt: r.sentAt ?? r.createdAt ?? null });  // ← 生文字列のまま
      map.set(r.applicationId, list);
    }
```

**該当コード（先行実装 = 同じ形の既存パターン）:**

```typescript
// src/repositories/cancellation-notifications.repository.ts:38-43
// 集約クエリ（max(...)）が返す timestamptz 生文字列を API 契約の ISO8601 UTC（…Z）へ正規化する。
// 集約列は toDomain（normalizeTimestamps）を通らないため、ここで明示的に揃える。
export const normalizeAggregateTimestamp = (value: unknown): string | null => {
  if (value === null || value === undefined || value === '') return null;
  return parseDbTimestamp(String(value)).toISOString();
};
```

**問題:**
このメソッドは `.select({...})` の列指定なので `toDomain`（= `normalizeTimestamps`）を通らず、`attemptedAt` にドライバの生文字列が入る。同ファイルの他の読み出し経路は `toDomain` を通しているのに、ここだけ素通し。`src/db/timestamps.ts:1-23` が明記するとおり形式はドライバで異なる:

- node-postgres（local/test）: `'2026-06-07 01:00:00+00'` → `Date.parse` OK
- **aws-data-api（dev/prod）: `'2026-06-07 01:00:00'`（オフセットなし naive）** → `Date.parse` は**実行環境の TZ でローカル解釈**する

`attemptedAt` は最小間隔判定で `daysBetweenJst()` → `jstCalendarDate()` → 素の `Date.parse()` へ流れる。実測:

```
Date.parse('2026-08-15 01:23:45.678+00') → 2026-08-15T01:23:45.678Z   （node-postgres: OK）
Date.parse('2026-08-15 01:23:45.678')    → 2026-08-14T16:23:45.678Z   （aws-data-api: TZ=Asia/Tokyo で 9h ずれる）
```

`parseDbTimestamp` は「Lambda 既定 TZ=UTC という暗黙前提に依存しない（TZ 非依存にハードニング）」ために用意されたもので、**本ファイルだけがその規約から外れている。** ずれた場合の症状はリマインド 2 が 1 日早く／遅く出るという静かなもので、テストは node-postgres なので永久に検出できない。

**修正提案:**
`cancellation-notifications.repository.ts` の `normalizeAggregateTimestamp`（既に同ファイルから `sanitizeNotificationError` を再利用している）を import して

```typescript
attemptedAt: normalizeAggregateTimestamp(r.sentAt ?? r.createdAt),
```

---

- [x] 対応する

### [Code Quality] C-3: `updateApplicationStatus` で起点記録を案内メール送信の**前**に await しており、記録の失敗が案内メール未送信を巻き込む

**ファイル:** `api/src/services/application.service.ts:1065-1090`
**重要度:** Medium

**該当コード（baseBranch 側 = 変更前）:**

```javascript
    const updated = await applicationsRepo.update(applicationId, patch);

    // 申請が ACTIVE になったら、紐づく application_user も同じタイミングで有効化する。
    if (status === APPLICATION_STATUS.ACTIVE) {
      await applicationUsersRepo.markActiveByApplicationId(applicationId, patch.updatedAt);
    }

    // ステータスに応じてメール送信
    try {
      let emailSubject = '';
```

**該当コード（toBranch 側 = 変更後）:**

```javascript
    const updated = await applicationsRepo.update(applicationId, patch);

    // Stripe 登録案内メール（初回案内）の送信日時 = 自動リマインドの起点を記録する
    if (status === APPLICATION_STATUS.APPROVED && stripeData) {
      await applicationsRepo.setStripeGuideSentAtIfUnset(applicationId, patch.updatedAt);  // ← ここ
    }

    if (status === APPLICATION_STATUS.ACTIVE) {
      await applicationUsersRepo.markActiveByApplicationId(applicationId, patch.updatedAt);
    }

    // ステータスに応じてメール送信
    try {
      let emailSubject = '';
```

**問題:**
この `await` は関数全体を包む try の中にあり、`catch` は 500 を返して終了する（`application.service.ts:1185-1197`）。したがって `setStripeGuideSentAtIfUnset` が一時的な DB エラー（Aurora オートポーズ復帰中の接続断など）で throw すると:

1. `status = approved` への UPDATE は**既にコミット済み**
2. Stripe 連結アカウントも**既に作成済み**
3. しかし「Stripe登録のご案内」メールは**一通も送られない**
4. 管理者には 500 が返るので再度「承認」を押す → `updateApplicationStatus` が再走 → Issue 記載の既知挙動どおり **Stripe 連結アカウントが新規作成されて上書きされる**

もう一方の承認経路 `approveApplication`（`application.service.ts:506`）は**メール送信の後ろ**に置いており、この非対称も意図したものには見えない。REQ-1 は「メール送信の成否によらず記録する」ことを求めているだけで、記録の失敗がメール送信を止めてよいとは言っていない。

**修正提案:**

```javascript
    if (status === APPLICATION_STATUS.APPROVED && stripeData) {
      try {
        await applicationsRepo.setStripeGuideSentAtIfUnset(applicationId, patch.updatedAt);
      } catch (e) {
        // 起点の記録失敗で承認処理・案内メールを止めない（リマインド対象外になるだけ）
        console.error('Failed to record stripeGuideSentAt:', applicationId, e?.message || e);
      }
    }
```

あるいは `approveApplication` に合わせてメール送信ブロックの後ろへ移す。合わせて「起点記録が失敗しても案内メールは送られ、200 が返る」E2E を 1 本追加する。

---

- [x] 対応する

### [Test Coverage] C-4: `claimSkipped` 分岐（二重送信の最終ガード）が 1 件もテストされていない

**ファイル:** `api/src/services/stripe-onboarding-reminder.service.ts:379-386`
**重要度:** Medium

**該当コード（toBranch 側）:**

```typescript
      // 回の claim（processing 先行 insert）。既存記録・多重起動の競合があれば null → 送らない。
      const claim = await applicationNotificationsRepo.claimRound(
        fresh.applicationId,
        KIND,
        round,
        STRIPE_ONBOARDING_REMINDER_TEMPLATE_VERSION,
      );
      if (!claim) {
        summary.claimSkipped += 1;   // ← ここへ到達するテストが無い
        continue;
      }
```

**問題:**
`claimSkipped` はテストコード中で 1 箇所（`stripe-onboarding-reminders.test.js:542`）にしか現れず、それは **T-33 の「summary が期待キーをすべて含む」というキー名一覧のアサーション**でしかない。**分岐そのものを通すテストはゼロ。**

既存テストはいずれもこの分岐に到達しない:

- T-18（同一 `now` で 2 回実行）: 2 回目は回判定（`attempted.has(1)`）で `null` になり claim 前に落ちる
- T-19（`processing` 残留）: 同上

`claimRound` の UNIQUE 衝突は REQ-3 が定める**二重送信の絶対回避の最終防壁**であり、回判定のスナップショットをすり抜けた競合（多重起動）に対する唯一のガード。ここが無検証だと、将来 `onConflictDoNothing` の `target` を触ったときに黙って壊れる。

**修正提案:**
T-59 と同じ手法で 1 ケース追加できる。

```javascript
stripe.accounts.retrieve.mockImplementation(async () => {
  // 回判定のスナップショット取得後・claim 前に別実行が claim した状況を再現
  await applicationNotificationsRepo.claimRound('app_r1', KIND, 1, 'v1');
  return ACTION_REQUIRED;
});
const summary = await runStripeOnboardingReminders({ now: dayN(3) });
expect(summary.claimSkipped).toBe(1);
expect(summary.remindersSent).toBe(0);
expect(sesInputs()).toHaveLength(0);
```

---

- [x] 対応する

### [Test Coverage] L-1: lp テストの `vi.restoreAllMocks()` が共通 setup の console spy を壊し、React 警告ゲートを無効化する

**ファイル:** `lp/src/__tests__/stripeRefresh.test.jsx:59-63`
**重要度:** Medium

**該当コード（toBranch 側）:**

```javascript
// src/__tests__/stripeRefresh.test.jsx:59-63
afterEach(() => {
  Object.defineProperty(window, 'location', originalLocationDescriptor);
  vi.unstubAllGlobals();
  vi.restoreAllMocks();   // ← ここ
});
```

**該当コード（壊される側 = 共通 setup）:**

```javascript
// src/test/setup.js
// 意図的にモジュールスコープで 1 度だけ張り、復元しない（このスイート全体で console.log を恒久抑止）。
vi.spyOn(console, 'log').mockImplementation(() => {});

beforeEach(() => {
  // console.error は恒久抑止せず毎テスト張り直す。afterEach で React 警告（act 漏れ等）を検出するため。
  consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
  …
});

afterEach(() => {
  cleanup();   // ← アンマウント。ここでも act 警告が出うる
  const reactWarnings = consoleErrorSpy.mock.calls.filter(/* … */);
  consoleErrorSpy.mockRestore();
  if (reactWarnings.length > 0) throw new Error(`予期しない React 警告が検出されました…`);
});
```

**問題:**
Vitest の `sequence.hooks` は既定 `'stack'`（本リポジトリは未設定）なので `afterEach` は登録の**逆順**で走り、テストファイル側の `afterEach` が `src/test/setup.js` の `afterEach` より**先**に実行される。そこで `vi.restoreAllMocks()` が全 spy を復元してしまい:

1. **`console.log` の恒久抑止が外れる。** setup.js はモジュールスコープで 1 度だけ張り「復元しない」と明記しているため、一度剥がれると張り直されない。**実測で確認済み** — 本ファイルを実行すると 1 本目（T-35）では出ないが、2 本目（T-37）と 3 本目（T-38）で `=== App Render Debug ===` が stdout に漏れる
2. **React 警告ゲートが空振りする。** `consoleErrorSpy.mockRestore()` 済みなので `.mock.calls` は空にリセットされ、その後 setup.js の `cleanup()`（アンマウント）で出る `act` 漏れ警告は記録されず検出ロジックを素通りする

（プローブによる独立検証でも、`restoreAllMocks` 無しなら setup.js のガードが throw して FAIL・有りなら PASS することが確認されている。＝ガードが完全に無効化される）

**修正提案:**
このファイルは自前で `vi.spyOn` を張っていない（`vi.fn()` は復元不要）ため、当該 1 行を削除すれば足りる。

```javascript
afterEach(() => {
  Object.defineProperty(window, 'location', originalLocationDescriptor);
  vi.unstubAllGlobals();
});
```

---

- [x] 対応する

### [Security] C-5: 推測可能な `applicationId` を鍵にした無認可導線を、メールで恒常配信する設計になる（既存問題／本 PR で露出が増える）

**ファイル:** `api/src/services/application.service.ts:204`（ID 生成）／`api/src/handlers/applications.handler.ts`（公開ルート）／`api/src/services/stripe-onboarding-reminder.service.ts:buildReminderEmail`
**重要度:** Medium（**本 PR で直す必要はない。別 Issue 起票を推奨**）

**該当コード:**

```javascript
// src/services/application.service.ts:204
  const applicationId = `app_${Date.now().toString()}`;
```

```typescript
// メール本文（REQ-5）
【Stripe登録を再開する】
${baseUrl}/stripe-refresh?applicationId=${application.applicationId}
```

**問題:**
REQ-5 の判断（Account Link を直接載せず `/stripe-refresh?applicationId=` へ誘導する）は、Account Link が単回利用・短時間失効である以上**妥当**。ただしその先の導線は次の性質を持つ:

- `POST /applications/:id/stripe-account-link` は**無認可の公開エンドポイント**（LP のため意図的）
- `applicationId` は `app_${Date.now()}`（ミリ秒 epoch）で、**推測・列挙が可能**
- `GET /applications/:id/stripe-status` も無認可で、有効 ID の存在オラクルになる
- 得られる Account Link は Express オンボーディング画面（**入金先口座の入力を含む**）への入口。`active` は 400 で弾かれるが、**オンボーディング中＝まさに本バッチの対象**がそのまま該当する

本 PR が作った穴ではない（`/stripe-refresh` も公開エンドポイントも既存）が、**この導線をメールで恒常配信する設計へ切り替える PR**なので、リスクの露出面は確実に増える。

**修正提案:**
本 PR のスコープ外として**別 Issue を起票**する。対策の方向性は「`applicationId` ではなく短期・単回の署名トークンをメールに載せ、`/stripe-refresh` はトークンを検証してから Account Link を発行する」。ID 生成を推測困難な値（`randomUUID()` 等）へ変えるのは既存データとの互換があるため単独では解にならない。

---

- [x] 対応する

### [Code Quality] C-6: claim 直前の再読込で、Stripe へ問い合わせた連結アカウント ID と同一かを検証していない

**ファイル:** `api/src/services/stripe-onboarding-reminder.service.ts:361-378`
**重要度:** Low

**該当コード（toBranch 側）:**

```typescript
      const fresh = await applicationsRepo.getById(target.applicationId);
      if (
        !fresh ||
        fresh.deletedAt ||
        !fresh.email ||
        !fresh.stripeAccountId ||          // ← 存在チェックのみ。target と同一かは見ていない
        decideOnboardingReminderRound({ status: fresh.status, stripeGuideSentAt: fresh.stripeGuideSentAt, attempts, now }) !== round
      ) {
        summary.staleSkipped += 1;
        continue;
      }
```

**問題:**
`stripe.accounts.retrieve()` は `target.stripeAccountId`（実行開始時点のスナップショット）に対して行われる。この再読込は「Stripe 呼び出し中に申込が変化していないか」を確認するためのものなのに、`stripeAccountId` については**存在すること**しか見ていない。

Issue 本文が「現行の承認処理は `stripeAccountId` の有無を確認せず、`approved` へ遷移するたびに Stripe 連結アカウントを新規作成して上書きする」と明記しているとおり、ループ中の再承認で ID が差し替わるケースは実在する（`application.service.ts:1018,1033`）。この場合、**旧アカウントの `requirements` に基づく判定で、新アカウントの申込へリマインドを送る**ことになる。

実害は限定的（新アカウントは `details_submitted: false` なのでどちらにせよ「送る」判定になり、メールのリンクはクリック時に現行アカウントで再発行される）。また Issue はこの再承認シナリオ自体を「本 Issue では許容」とスコープ外宣言している。ただし判定の前提が崩れた状態で送っている点は再読込の趣旨と矛盾する。

**修正提案:**
1 行足して stale 扱いにする。翌日の実行で新アカウントに対して正しく再評価される（回は消費していないので取りこぼしにならない）。

```typescript
        fresh.stripeAccountId !== target.stripeAccountId ||
```

---

- [x] 対応する

### [Test Coverage] C-7: 部分インデックス契約テストが repository の実定数を参照せず、期待値をテスト内で再構築している

**ファイル:** `api/src/__tests__/unit/stripe-onboarding-reminder-contract.test.ts:125-140`
**重要度:** Low

**該当コード（toBranch 側）:**

```typescript
  it('述語の status 集合が STRIPE_REMINDER_STATUS_VALUES と過不足なく一致する', () => {
    const inClause = /IN \(([^)]*)\)/.exec(indexPredicate)?.[1] ?? '';
    const fromMigration = [...inClause.matchAll(/'([^']+)'/g)].map((m) => m[1]).sort();

    // repository 側: 定数が参照している enum / ラベルを実値へ解決する。
    const fromRepo = [
      APPLICATION_STATUS.APPROVED,
      APPLICATION_STATUS.STRIPE_PENDING,
      APPLICATION_STATUS_LABELS[APPLICATION_STATUS.APPROVED],
      APPLICATION_STATUS_LABELS[APPLICATION_STATUS.STRIPE_PENDING],
    ].sort();

    expect(fromMigration).toEqual(fromRepo);
  });
```

**問題:**
テスト名は「`STRIPE_REMINDER_STATUS_VALUES` と過不足なく一致する」だが、`fromRepo` は**その定数を import しておらず**、同じ式をテスト内で書き写している（`STRIPE_REMINDER_STATUS_VALUES` は `applications.repository.ts:22` で export されていない）。したがって repository 側の定数から旧日本語値を落としても、マイグレーション側を触らない限りこのテストは green のまま通る — **まさにこのテストが防ぎたかった drift**。

同 describe の最後の it は `fn.toContain('inArray(applications.status, STRIPE_REMINDER_STATUS_VALUES)')` と**定数名しか**照合していないため代替にならない。

これは本 Issue の「技術的な考慮事項 11」が最も恐れているケース（旧日本語ステータスの取りこぼし → 最も長く滞留しているサロンにだけ 1 通も届かない静かな失敗）を守れていないことを意味する。

**修正提案:**

```typescript
import { STRIPE_REMINDER_STATUS_VALUES } from '../../repositories/applications.repository';
// …
expect(fromMigration).toEqual([...STRIPE_REMINDER_STATUS_VALUES].sort());
```

なお、同じステータス集合は **4 箇所**（0025 の部分インデックス述語 / `schema.ts` の index `where` / 0026 のバックフィル / repository の定数）に散っており、契約テストが束縛しているのは 0025 ↔ repository のみ。`schema.ts` と 0026 は未束縛（優先度は低いが、上記の修正ついでに 0026 も同じ突き合わせに含められる）。

---

- [x] 対応する

### [Code Quality] C-8: `summary.ok` が常に `true` で、成否を表さない

**ファイル:** `api/src/services/stripe-onboarding-reminder.service.ts:StripeOnboardingReminderSummary` / `runStripeOnboardingReminders`
**重要度:** Low

**問題:**
`ok: true` は初期化後に一度も書き換えられず、`errors` / `finalizeErrors` / `byRound[*].failed` がいくつ立っても `true` のまま。ECS も exit 0 で終わる。失敗アラート非設置は仕様どおり（REQ-7）だが、`ok` というキー名は CloudWatch Logs Insights でフィルタを書く人に「成功したかどうか」と読まれる。

**修正提案:**
どちらかへ寄せる。

- 型コメントに「`ok` は成否ではなく『実行が最後まで到達したこと』を表す。失敗件数は `errors` / `finalizeErrors` / `byRound[*].failed` を見ること」と明記する
- または `ok: summary.errors === 0 && summary.finalizeErrors === 0` にする（`dispatchBatchAction` の戻り値にも影響するため、GTSS-886 の慣行と揃えるなら前者が無難）

---

- [x] 対応する

### [Code Quality] C-9: 履歴スナップショットが再読込時に更新されず、多重起動が JST 日跨ぎと重なると最小間隔を破りうる

**ファイル:** `api/src/services/stripe-onboarding-reminder.service.ts:314`（一括取得）／`:361-376`（再読込・再評価）
**重要度:** Low

**問題:**
claim 直前の再読込は**申込行のみ**を取り直し、`decideOnboardingReminderRound` へ渡す `attempts` は 314 行のバッチ開始時スナップショットを再利用している。UNIQUE 制約は `(application_id, kind, round)` なので**round が違えば衝突しない**。

したがって、実行 A（`now` = 6 日目・JST 23:59）と実行 B（`now` = 7 日目・JST 00:00）が重なり、B のスナップショットが A の round1 claim より先に取られた場合、B は `lastAttemptedAt` を見つけられず `MIN_GAP_DAYS` チェックを素通りして round2 を送る。数秒差で 2 通届く。

**これはコード上の事実から導いた推論で、並行実行を再現して観測してはいない。** 成立には「手動再実行・二重発火が JST 日跨ぎと重なる」ことが必要で、EventBridge の日次 1 本だけなら起きない。優先度は低い。

**修正提案:**
claim 直前の再評価で当該 1 件分の試行履歴も取り直す。既に Stripe 呼び出しがある直列ループなので 1 クエリ増は無視できる。

---

## 軽微（任意対応）

- **[Code Quality]** `buildReminderEmail`: `contactName` / `partnerName` が両方欠落すると宛名が `様` 単独になる（unit テストが仕様として固定している）。`ご担当者様` 等のフォールバックの方が自然
- **[Test Coverage]** `stripe-guide-sent-at.test.js:240` の `expect(items.length).toBeGreaterThan(0)` は `.claude/skills/playwright/lesson.md` の「弱検証禁止」と同型。実質はループ空回りガードなので害は小さいが `toHaveLength(1)` にできる
- **[Test Coverage]** 時刻列の `toBeTruthy()`（T-2 / T-14 / T-29）。同 PR の T-1 / T-57 は ISO 書式の `toMatch` を使っているので揃えられる
- **[Test Coverage]** lp: `!response.ok` のエラー分岐（「リンクの再発行に失敗しました」）が未カバー（T-38 は `applicationId` 欠落のみ）
- **[Test Coverage]** `schema.test.js` はテーブル数のみ更新で、新規 FK の `ON DELETE CASCADE`（`confdeltype='c'`）と UNIQUE インデックスの DDL アサーションが無い。`payout_runs` / `shop_integrations` は `pg_constraint` で固定している慣行なので揃えると良い（機能面は e2e T-51 が押さえているので必須ではない）
- **[Test Coverage]** T-59 は `accounts.retrieve` 解決中の削除しか再現しておらず、「**再読込後**の削除」は未テスト（窓は INSERT 1 本ぶんなので実害は小さい）
- **[Performance][未検証]** 部分インデックスの述語一致は「マイグレーション SQL のテキスト」対「repository の WHERE 句」の文字列比較で担保されているが、実際にインデックスが使われるかは未検証。`inArray` はプレースホルダ発行のため、汎用プラン（named prepared statement）へ切り替わると述語の含意証明が効かず seq scan に落ちうる。dev で一度 `EXPLAIN` を取るとコード内コメントの主張が裏付けられる
- **[Performance]** 全体の時間予算・件数上限が無い（Issue が「打ち切り機構は実装しない」と確定済み）。ただし R-1 のバックフィル直後だけは滞留申込の**全件が同じ日に窓へ入り 3 日目に一斉処理**される。Lambda 経路で回すなら関数タイムアウトを事前確認すること（ECS 経路なら実害なし）

---

## 破棄した指摘（再検証で裏取りできなかったもの）

記録として残す。**対応不要。**

| 指摘 | 出所 | 破棄理由 |
|---|---|---|
| 再読込後にも論理削除との TOCTOU が残る（重要度: 高） | codex | check-then-act に内在する窓であり、advisory lock 等での協調は Issue の要求（REQ-6「claim の直前に最新行を読み直し、条件を外れていればスキップ」）を超える設計変更。先行実装 `billing-reminder.service.ts:192-207` も同一構造で、本実装はそれより厳格（`deletedAt` / `email` / `stripeAccountId` を明示チェック）。窓も「Stripe 呼び出し最大 5 秒」から「INSERT 1 本」へ縮んでおり退行ではない。なお codex が併せて挙げた「claim 後の物理削除で履歴が CASCADE 削除される」は指摘にならない（`0025` で意図的に定義し、T-51 が仕様としてテスト済み）。テストカバレッジの観察としてのみ軽微欄へ残した |
| 新 family の `STRIPE_SECRET_KEY` が TF の `container_secrets` に配線されないと永久に入らない | Issue 本文・code-reviewer | infra を実確認して否定。R-5 を参照 |

---

## 総評

**全体として完成度が高く、コード自体はマージ可能な水準にある。** Issue の REQ-1〜REQ-8 は実装・テストとも網羅されており、特に以下は明示的に確認した。

- **PII 方針**: 新列 `stripeGuideSentAt` は `SENSITIVE_APPLICATION_KEYS` へ追加済みで、`serializeApplication` の spread 透過による自動露出を塞いでいる（`.claude/lessons.md` の「spread passthrough な serializer に機微フィールドを足すと無認可エンドポイントから漏れる」に正しく対応）。既存契約テストが `toMatchObject` で追加キーを許容する点も認識され、T-56 が `not.toHaveProperty` を明示 assert している。履歴テーブルは宛先・本文の列を持たず、エラーは `sanitizeNotificationError` でコード/種別のみに落としている。退会競合時にスナップショットのマスク前アドレスへ送らないための claim 直前再読込も実装・テスト済み（T-59）
- **マスアサインメント**: この列への書き込みは `setStripeGuideSentAtIfUnset`（`isNull` ガード付き条件付き UPDATE）のみ。ユーザー入力が届く 2 経路は `pickApplicationInput` の allow-list を通り、この列は含まれない。`updateApplicationStatus` の `patch` も明示構築で `req.body` の spread なし
- **冪等性**: UNIQUE `(application_id, kind, round)` + `onConflictDoNothing` の claim、`processing` 残留を試行済みとして扱う方針、配信成功／finalize 失敗を `failed` へ倒さない 2 段 try 分離まで、いずれも仕様どおり
- **既知の落とし穴**: `truncateAll()` への `application_notifications` 追加、`installExternalMocks()` の後にスタブする順序、`_journal.json` の手動追記、`accounts.retrieve` の per-request 予算 `{timeout:5000, maxNetworkRetries:0}` — Issue が列挙した罠をすべて踏まずに処理し、静的検査テストで固定までしている
- **日付境界**: 一次抽出の SQL 窓（`jstDayStartIso(todayJst-2)` / `(todayJst-13)`）は部分インデックスの述語と一致し、旧日本語ステータスも併記されている。JST 15:00 UTC 境界の実 DB テスト（T-57）まである
- **lessons 照合**: `.claude/lessons.md` および `skills/{vitest,playwright,issue,authz}/lesson.md` の全項目と突き合わせたが、**明確な違反は無し**。`expect.any(Object/Array/Number)` の使用なし、外部 API は全モック、メール本文は完全一致スナップショット、日付依存テストも `now` 注入か固定 fixture で将来落ちない作り

**懸念の中心はコードではなくリリース手順にある。** REQ-9（infra PR-3）が未着手で、infra リポジトリに `stripe_reminders` は 1 件も存在しない。この状態でコードを先にマージ／デプロイすると:

- **R-1**: バックフィルの 14 日カウントダウンが始まり、Scheduler が間に合わなければ滞留サロン全件が恒久的に対象外（回復手段なし）— **本 Issue の目的が静かに失われる最悪ケース**
- **R-2**: `FAMILIES` に追加した family が存在せず、develop/main push で batch イメージの CI が確実に落ちる

いずれも **「infra apply → dev 手動 invoke で確認 → 最後に prod migrate + deploy」の順序を守れば回避できる**。PR 本文と Issue に順序制約を明記すること（R-1 は 0026 の SQL ヘッダにも警告を残すのが望ましい）。

### 対応の優先度

| 順 | 指摘 | 理由 |
|---|---|---|
| 1 | **R-1 / R-2**（リリース順序の明記） | コード変更ゼロ〜数行。守らないと機能が無音で死ぬ／CI が落ちる |
| 2 | **R-3 / R-4**（マージ先と `chore/...` の順序決定） | マージ前に決めないと後から手戻り |
| 3 | **L-1**（`vi.restoreAllMocks()` 1 行削除） | 他テストへ波及。実測でログ漏れ確認済み |
| 4 | **C-3**（起点記録を try/catch で囲む） | 発生確率は低いが影響（案内メール未送信＋再承認で Stripe アカウント再作成）が大きい |
| 5 | **C-2**（timestamptz 正規化・1 行） | 現状は TZ=UTC 前提で動いているが、コードベースが明示的に潰した前提依存の再導入 |
| 6 | **C-1 / C-4**（テスト追加） | 最小間隔ロジックと二重送信の最終防壁がいずれも未検証 |
| 7 | **C-5**（別 Issue 起票） | 本 PR で直すものではないが、露出が増える PR なので記録を残す |
| 8 | C-6 / C-7 / C-8 / C-9・軽微 | 任意 |

### その他リリース時に確認が必要な事項

- **バックフィル（0026）の対象件数を prod で事前確認すること**（T-43）。`deploy.sh` は未適用マイグレーションを一括適用するため 0025 と 0026 は同一デプロイで走る
- **旧日本語ステータスの実データ分布**を dev / prod で確認すること。本実装は IN 句へ併記する方針を採ったが、`SELECT status, count(*) FROM applications WHERE deleted_at IS NULL GROUP BY status` で想定外の値が無いことを見ておくと安全
- 人力テスト T-36 / T-41 / T-42 / T-44 / T-53 / T-54 / T-55 は未実施
