---
issue: 20
date: 2026-06-06
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: feature/GTSS-13
    toBranch: feature/GTSS-13-mask
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: feature/GTSS-13
    toBranch: feature/GTSS-13-mask
  - repo: infra
    repoDir: cancel-billing-service-infra
    baseBranch: feature/GTSS-13
    toBranch: feature/GTSS-13-mask
---

# レビュー結果: #20

## 概要

**Issue:** #20 申請削除フローの拡張: 退会(withdrawn)ステータス化 + cancellations 顧客PIIマスク + 元データバックアップ(90日)/restore + 削除バッチ(Terraform/毎月3日)

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `feature/GTSS-13` | `feature/GTSS-13-mask` | 1 | 26 |
| admin | `feature/GTSS-13` | `feature/GTSS-13-mask` | 1 | 7 |
| infra | `feature/GTSS-13` | `feature/GTSS-13-mask` | 1 | 6 |

レビューは code-reviewer / lessons-reviewer / codex-reviewer の3エージェント出力を、メインエージェントが
worktree 最終ソース・drizzle `aws-data-api` ドライバ実装・呼び出しチェーンまで cross-file 再検証して確定した。
**全体として設計品質・テストカバレッジは高い**（コア設計＝単一Tx化・冪等ガード・restore/purge 境界・withdrawn 手動遷移ガード・migration backfill順序・infra Scheduler ロールは追跡の結果いずれも妥当）。以下は注目に値する指摘のみ。

## 変更ファイル一覧（主要）

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/services/application.service.ts` | +71 | -11 | Modified |
| `src/services/application-backup.service.ts` | +171 | -0 | Added |
| `src/repositories/application-deletion-backups.repository.ts` | +82 | -0 | Added |
| `src/repositories/cancellations.repository.ts` | +20 | -5 | Modified |
| `src/repositories/applications.repository.ts` | +12 | -6 | Modified |
| `src/repositories/application-users.repository.ts` | +3 | -2 | Modified |
| `src/handlers/applications.handler.ts` | +4 | -0 | Modified |
| `src/db/schema.ts` | +36 | -7 | Modified |
| `src/db/migrations/0001_gtss20_backups_notnull.sql` | +27 | -0 | Added |
| `src/constants/application-enums.ts` | +6 | -0 | Modified |
| `src/batch.ts` | +35 | -0 | Added |
| `deploy-batch.sh` | +133 | -0 | Added |
| `build.mjs` / `package.json` | +20 | -8 | Modified |
| `scripts/{purge-expired-backups,restore-application}.ts` | +56 | -0 | Added |
| `src/__tests__/**`（e2e/unit） | +495 | -16 | Added/Modified |

### admin

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/constants/applicationStatus.ts` | +9 | -2 | Modified |
| `src/constants/cancellationStatus.ts` | +3 | -1 | Modified |
| `src/components/CancellationManagement.tsx` | +2 | -2 | Modified |
| `src/constants/*.test.ts` / `__tests__/*.test.tsx` / `src/test/utils.tsx` | +73 | -1 | Modified |

### infra

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `modules/batch-compute/{main,variables,outputs}.tf` | +261 | -0 | Added |
| `dev/main.tf` / `prod/main.tf` | +81 | -0 | Modified |
| `README.md` | +34 | -2 | Modified |

## 指摘一覧

- [x] 対応する

### [Code Quality] purge の `deleteExpired` が `.returning()` で全カラム（巨大 payload 含む）を読み戻す — dev/prod の Data API でサイズ上限により purge が失敗しうる

**ファイル:** `api/src/repositories/application-deletion-backups.repository.ts:78-81`（`deleteExpired`）
**重要度:** Medium（データ量によっては High。90日PII恒久消去という要件が静かに失敗する）

**該当コード:**
```typescript
// toBranch側（変更後）— 失効バックアップを物理削除し件数を返す
  deleteExpired: async (now: string, db: any = getDb()) => {
    const rows = await db
      .delete(applicationDeletionBackups)
      .where(lte(applicationDeletionBackups.expiresAt, now))
      .returning();              // ← payload（マスク前 PII の JSON 全文）含む全カラムを読み戻す
    return (rows || []).length;  // ← 件数算出のためだけに全行を転送している
  },
```

**問題:** 件数を返すためだけに `RETURNING *` 相当で**削除行の全カラム（`payload` = application + 全 cancellations のマスク前 PII を含む巨大 JSON text）**をアプリ側へ転送している。テスト経路（node-postgres）では顕在化しないが、dev/prod の RDS Data API は `ExecuteStatement` のレスポンスサイズに上限（〜1MB級）がある。月次 purge で失効バックアップが多数／payload が大きいと **purge 自体が失敗**し、「90日経過 PII を物理削除する」プライバシー要件を満たせなくなる。まさに `aws-data-api`(prod) と `node-postgres`(test) の挙動差リスク。

**修正提案:** `returning({ id: applicationDeletionBackups.id })` で id のみ返す（payload を転送しない）。件数だけ必要なら id 射影で十分。テストに「多数／大 payload の失効バックアップを purge」ケースを追加できるとなお良い。

---

### [Code Quality] `createCancellation` が `...cancellationData` を無加工スプレッドし、NOT NULL 化と相性が悪い（明示 `null` で 500 回帰）

**ファイル:** `api/src/services/cancellation.service.ts:43-52`（呼び出し）／`api/src/repositories/cancellations.repository.ts:14-18`（`toRow`）／ルート `api/src/handlers/cancellations.handler.ts:15-19`（`POST /cancellations`）
**重要度:** Medium

**該当コード:**
```typescript
// toBranch側 — 認証済みユーザーの POST /cancellations 経路
const cancellation = {
  id: cancellationId,
  applicationId: authCheck.decoded.application_id,
  createdByApplicationUserId: authCheck.decoded.sub,
  ...cancellationData,          // ← client 由来。customerName/Email/Phone を無加工で取り込む
  status: 'pending',
  createdAt: new Date().toISOString()
};
await cancellationsRepo.create(cancellation);   // toRow は d[k] !== undefined なので null は INSERT に含む
```

**問題:** REQ-9 で `cancellations.customer_name/email/phone` を NOT NULL + `default('')` 化したが、本経路は client の `cancellationData` を無加工スプレッドする。`toRow` は「`undefined` のみ除外（null は含める）」ため、client が `customerName: null` を**明示送信**すると DB の `DEFAULT ''` を上書きして NOT NULL 違反 → 500。主経路 `POST /invoices`（`invoice.service.ts:161` で `customerName: invoiceData.customerName || ''`）は coerce 済みで安全だが、`POST /cancellations`（`createCancellation`）は **zod 等の入力バリデーションが無く**（grep で schema 参照なしを確認）、認証済みサロンユーザーが直叩き可能。キー省略時は DB 既定 `''` で救われるが、明示 null は救われない。

**修正提案:** `createCancellation` でも `customerName: cancellationData.customerName || ''`（email/phone も同様）で coerce する。または当該ルートが未使用なら撤去する。

---

### [Test Coverage] 再 DELETE で `deletedAt` が毎回新時刻で上書きされる（初回削除時刻が失われる）— T-6 が値不変を検証していない

**ファイル:** `api/src/services/application.service.ts:978-987`（`maskApplicationPii`）／ テスト `api/src/__tests__/e2e/application-deletion-backup.test.js`（T-6, 410-433 付近）
**重要度:** Low

**該当コード:**
```typescript
// toBranch側 — maskApplicationPii は呼ばれるたび新しい deletedAt を生成
const patch: Record<string, any> = {
  email: null, phone: null, representativeName: null, contactName: null, birthDate: null,
  status: APPLICATION_STATUS.WITHDRAWN,
  deletedAt: new Date().toISOString(),   // ← 再削除でも新時刻で上書きされる
};
```
```javascript
// T-6 のアサーション（値不変を検証していない）
const row = await applicationsRepo.getById('app_re');
expect(row.status).toBe('withdrawn');
expect(row.deletedAt).toEqual(expect.any(String));  // ← 「不変」ではなく「文字列であること」しか見ていない
```

**問題:** REQ-2 は「再削除でも `status='withdrawn'`／`deletedAt` を保つ」とするが、再 DELETE でも `softDelete` が走り `deletedAt` が新時刻に更新される。90日保持は `backup.expiresAt`（初回削除起点・再生成しない）にアンカーされるため**機能・retention 上は無害**だが、監査上の「初回削除時刻」は失われる。T-6 のコメントは「`deletedAt` 維持」と書くがアサーションは `expect.any(String)` のみでこの上書きを捕捉できない。

**修正提案:** 既に `deletedAt` がある場合は patch に含めず既存値を維持する（再削除時は `maskApplicationPii` 側で既存 `deletedAt` を尊重）。T-6 に「`deletedAt` が初回値から不変」のアサーションを追加。

---

### [Code Quality] `cancellationsRepo.update` の空 patch 早期 return が executor(tx) を引き継がない（潜在的に Tx 外読み取り）

**ファイル:** `api/src/repositories/cancellations.repository.ts:93-96`
**重要度:** Low（code-reviewer・lessons-reviewer の両方が独立検出）

**該当コード:**
```typescript
// toBranch側 — db(tx) を受け取れるようにしたが、空 patch 分岐だけ tx 透過が漏れている
update: async (id: string, patch: Record<string, any>, db: any = getDb()) => {
  const set = toRow(patch);
  if (Object.keys(set).length === 0) return cancellationsRepo.getById(id);  // ← db(tx) を渡していない
  const rows = await db.update(cancellations)...
```

**問題:** `applications.repository.ts:84` は `getById(applicationId, db)` と tx を透過させているのに、`cancellations` 側は空 patch 時に `getById(id)`（tx 未透過）を呼ぶため非対称。restore フローは常に3フィールドの patch を渡すため**現状この分岐には到達せず実害なし**だが、将来 Tx 内で空 patch update を呼ぶと Tx 外接続で読む潜在バグ。

**修正提案:** `return cancellationsRepo.getById(id, db);` に統一する。

---

### [Code Quality] `deploy-batch.sh` が設定更新（handler/runtime/env）の失敗を握りつぶして「成功」終了する

**ファイル:** `api/deploy-batch.sh:162-187`
**重要度:** Low

**該当コード:**
```bash
# toBranch側 — 失敗しても log_warning だけで継続し、最終的に success で終了
aws lambda update-function-configuration --function-name "$LAMBDA_FUNCTION" \
  --handler "src/batch.handler" --runtime nodejs24.x --timeout 300 \
  --profile "$AWS_PROFILE" > /dev/null || log_warning "configuration 設定に失敗（既存設定を確認してください）"
...
aws lambda update-function-configuration --function-name "$LAMBDA_FUNCTION" \
  --environment "file://${ENV_VARS_FILE}" \
  --profile "$AWS_PROFILE" > /dev/null || log_warning "環境変数設定に失敗"
```

**問題:** 環境変数（`AURORA_*`）設定が失敗しても warning だけで `log_success` まで進む。AURORA_* が入らないと batch Lambda は Aurora に接続できず restore/purge が本番で実行不能になるが、デプロイは「成功」と表示される。`deploy-api.sh` が同種処理を retry + 非ゼロ終了で守っているのと非対称。

**修正提案:** API デプロイ同様、設定更新失敗時は cleanup のうえ非ゼロ終了する（特に環境変数更新失敗を成功扱いしない）。

---

### [Lessons] `auth.ts` の docstring が陳腐化（softDelete が status を変えない前提のコメント）

**ファイル:** `api/src/middleware/auth.ts:126-128`
**重要度:** Low

**該当コード:**
```typescript
// toBranch側 — コメントは旧 GTSS-19 の前提のまま
const application = await applicationsRepo.getById(applicationId);
// 論理削除（deletedAt セット済み）も拒否する。softDelete は status を変えない（'active' のまま残す）
// 設計のため、status だけでは削除前に発行済みの JWT（最大 24h）が削除後も通過してしまう。
if (!application || application.deletedAt || normalizeApplicationStatus(application.status) !== APPLICATION_STATUS.ACTIVE) {
```

**問題:** 本 PR で `softDelete` は `status='withdrawn'` を設定するようになった（`maskApplicationPii`）ため、コメント「softDelete は status を変えない（'active' のまま残す）」は事実と異なる。ガード実体（`deletedAt` セット OR status≠ACTIVE で拒否）は withdrawn も弾くため**機能上のバグはなく**、コメント追従漏れのみ。

**修正提案:** コメントを「softDelete は `deletedAt` をセットし `status='withdrawn'` へ変更する」へ更新する。

---

## 軽微（任意・総評内）

- **[Low] 並行 DELETE のレース（codex）**: `wasNotDeleted` 判定と snapshot 取得が Tx 外のため、同一 applicationId への並行 DELETE が2本走るとバックアップ二重生成・「snapshot〜mask の間に入った新規 cancellation」が backup 未収録になる理論的余地。admin 操作で同時多重発火は稀、restore は未失効1件に収束するため実害は低。気になるなら Tx 内で `deleted_at IS NULL` 条件付き更新により初回削除を確定してから backup 生成する。
- **[Low] restore の堅牢性（codex）**: `restoreApplication` は `applicationsRepo.update` の戻り値（対象行 0 件）を確認せず `restored:true` を返す。applications は本番では論理削除のみで行が消えない（hard `applicationsRepo.delete` はテストのみ使用＝確認済み）ため**現行経路では到達不能**。防御として update 0 件時は rollback + `APPLICATION_NOT_FOUND`、JSON parse 後の `payload.application.applicationId === applicationId` 検証を入れると堅い。
- **[Low] restore のバックアップ選択タイブレーク**: `orderBy(desc(createdAt))` のみ。同一 ms `createdAt` 衝突時に「最新」選択が非決定的。第2キーに `desc(id)` を加えると決定的。
- **[Low] `isBackupExpired` が purge 本経路で未使用**: 境界判定は repo の SQL `lte` を直呼びし、`isBackupExpired`(`<=`) は unit テスト専用ミラー。両者 `<=` で一致し実害なしだが、将来ドリフト防止に「テスト専用ミラー」と明記推奨。
- **[Low] batch Lambda の `environment` が `ignore_changes`**: 初回 apply（`NODE_ENV` のみ）→ `deploy-batch.sh` 実行前に Scheduler が発火すると AURORA_* 未設定で purge 失敗。月次・低頻度のため軽微。運用 Runbook に「apply 直後に必ず deploy-batch.sh」を明記すれば足りる。

## 設計上の確認事項（指摘ではない）

- **codex の「未決済 cancellations の `canceled` 化が Tx 外」指摘は仕様どおり**。Issue 本文「削除順序とトランザクション」は **②（Stripe expire + 請求 canceled）を外部副作用として Tx 外**に置く（既存挙動踏襲）と明記しており、DB 副作用 Tx は①③④⑤に限定する設計。実装はこの設計に一致。`status='canceled'`（純 DB 更新）だけを Tx 内へ寄せる微改善は可能だが、Stripe expire とループで密結合のため任意。中間状態は再削除の冪等収束でカバーされる。
- **migration `0001` のファイル番号は正しい**。base（GTSS-13）には `0000_init` のみ存在するため、本 PR の増分は `0001`（Issue 本文が言う `0002` は「`0001` 適用済み」前提の記述で、GTSS-13 ベースでは `0001` が正）。backfill UPDATE → `SET NOT NULL` → `SET DEFAULT ''` の順序も整合。
- **drizzle `aws-data-api`(dev/prod) でも `db.transaction()` は成立**。`drizzle-orm@0.45.2` の `aws-data-api/pg/session` は `BeginTransaction`/`Commit`/`Rollback` で transaction を実装しており、`deleteApplication`/`restoreApplication` の Tx 化は両ドライバで動作する（node-postgres と aws-data-api で挙動一致）。email 一意衝突の rollback（`EMAIL_CONFLICT`）も両ドライバで成立。
- **withdrawn 手動遷移ガードは到達/離脱の両方**を enum 包含チェックとは別レイヤで早期 400（`application.service.ts` 到達側・離脱側の2分岐、T-8 でカバー）。admin もフィルタ選択肢除外・遷移アクション非出現を確認。
- **infra: EventBridge Scheduler は scheduler 実行ロール（`lambda:InvokeFunction`）で invoke する**ため `aws_lambda_permission` 不要（EventBridge Rule とは異なる）。`enable_purge_schedule` の count guard は role/policy/schedule で一貫。`cron(0 0 3 * ? *)` + `Asia/Tokyo`（曜日 `?`）で毎月3日 JST 00:00 も正しい。

## 総評

REQ-1〜REQ-9 の各仕様は実装・テスト（unit + 実 Postgres 統合 E2E）ともよく対応しており、退会ステータスの内部遷移制約・固定マスク `***`・90日バックアップ/restore/purge・NOT NULL backfill・status ルート認可是正・infra の Scheduler 設計はいずれも追跡の結果妥当。lessons 違反は無し。

最も対応価値が高いのは **purge の `.returning()` 全カラム読み戻し（dev/prod の Data API でサイズ上限により PII 物理削除が失敗しうる）** と **`createCancellation` の明示 null による NOT NULL 500 回帰** の2点（いずれも修正は数行）。残りは Low（コメント陳腐化・tx 透過漏れ・deploy スクリプトの失敗握りつぶし・テストの値不変アサーション欠落等）で、品質を一段上げる任意改善。マージブロッカーは無いが、上記 Medium 2件は本 PR 内での対応を推奨する。
