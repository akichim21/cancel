---
issue: 13
date: 2026-05-23
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: main
    toBranch: feature/GTSS-13
  - repo: infra
    repoDir: infra/cancel-billing-service-infra
    baseBranch: main
    toBranch: feature/GTSS-13 (commit 148b7f0, REQ-1)
---

# レビュー結果: #13

## 概要

**Issue:** #13 [API] DynamoDB → Aurora Serverless v2 (PostgreSQL) + RDS Data API 移行（Drizzle ORM / Terraform）

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `main` | `feature/GTSS-13` | 2 | 51 |
| infra | `main` | `148b7f0`（REQ-1） | 1 | 7 |

> infra の GTSS-13 作業（REQ-1）は既に `main` に取り込み済み（main と feature/GTSS-13 が同一コミット 148b7f0 を指す）。レビューは REQ-1 コミット `148b7f0` を親と比較して実施。

中核要件（冪等性3層ガード・JOIN による N+1 解消・snake_case↔camelCase の挙動不変・売上二重計上防止・SQL インジェクション安全・IAM 最小化・閉域構成）はいずれも正しく実装されている。確度の高い指摘は下記のとおり。

## 変更ファイル一覧（主要）

### api

| ファイル | 種別 |
|---------|------|
| `deploy-api.sh` | Modified |
| `src/config.ts` | Modified |
| `src/db/client.ts` / `schema.ts` / `migrations/*` | Added |
| `src/clients.ts` | Modified |
| `src/repositories/*.repository.ts`（applications/cancellations/users/monthly-sales） | Modified/Added |
| `src/repositories/table-setup.ts` | Deleted |
| `src/services/*.service.ts`（application/auth/cancellation/invoice/stripe/webhook） | Modified |
| `scripts/migrate.ts` / `migrate-dynamodb-to-aurora.ts` | Added |
| `src/__tests__/**`（e2e / unit / helpers / global-setup） | Modified/Added |

### infra

| ファイル | 種別 |
|---------|------|
| `modules/aurora-data-api/{main,outputs,variables}.tf` | Added |
| `dev/main.tf` / `prod/main.tf` | Modified |
| `modules/api-compute/outputs.tf` | Modified |
| `README.md` | Modified |

## 指摘一覧

- [x] 対応する

### [Code Quality / デプロイ] deploy-api.sh が AURORA_* 環境変数を投入しておらず、デプロイ後に全 DB 操作が実行時失敗する

**ファイル:** `cancel-billing-service-api/deploy-api.sh:219-233`
**重要度:** High

**該当コード（変更後・feature/GTSS-13）:**
```bash
ENV_VARS_FILE="${SCRIPT_DIR}/env-vars-${TIMESTAMP}.json"
cat > "$ENV_VARS_FILE" << EOF
{
    "Variables": {
        "NODE_ENV": "${ENVIRONMENT}",
        "DYNAMODB_TABLE_NAME": "${DYNAMODB_TABLE_NAME}",
        "STRIPE_SECRET_KEY": "${STRIPE_SECRET_KEY}",
        ... (AURORA_RESOURCE_ARN / AURORA_SECRET_ARN / AURORA_DATABASE が無い)
        "TWILIO_MESSAGING_SERVICE_SID": "${TWILIO_MESSAGING_SERVICE_SID}"
    }
}
EOF
# ...
aws lambda update-function-configuration \
    --function-name "$LAMBDA_FUNCTION" \
    --environment "file://${ENV_VARS_FILE}" \
    --profile "$AWS_PROFILE"
```

```typescript
// src/config.ts:24-40（変更後）— NODE_ENV=dev/prod では aws-data-api を選び AURORA_* を参照
export const resolveDbDriver = (): DbDriver =>
  process.env.NODE_ENV === 'prod' || process.env.NODE_ENV === 'dev'
    ? 'aws-data-api'
    : 'node-postgres';

export const auroraConfig = {
  get resourceArn(): string { return process.env.AURORA_RESOURCE_ARN as string; },
  get secretArn(): string { return process.env.AURORA_SECRET_ARN as string; },
  get database(): string { return process.env.AURORA_DATABASE as string; },
};
```

**問題:** `deploy-api.sh` の env-vars JSON ブロックに `AURORA_RESOURCE_ARN` / `AURORA_SECRET_ARN` / `AURORA_DATABASE` が含まれていない（worktree 全体 grep で deploy-api.sh の AURORA 参照は 0 件）。`aws lambda update-function-configuration --environment file://...` は**環境変数セット全体を置換**（マージではない）するため、デプロイ後の Lambda は `NODE_ENV=dev/prod` で `resolveDbDriver()` が `aws-data-api` を選ぶ一方、`auroraConfig.resourceArn/secretArn/database` がすべて `undefined` となり、RDSDataClient の全クエリが実行時失敗する。infra README は「output を deploy-api.sh の env へ投入（REQ-8）」と記載するが、投入先の JSON キー自体が存在しないため手で追記しない限り反映されない。

**修正提案:** env-vars JSON に 3 変数を追加し `.env.development` / `.env.production` から読み込む。撤去済みの `DYNAMODB_TABLE_NAME` はランタイム未参照のため削除してよい。

---

### [Performance / 整合性] webhook の月次売上 upsert 失敗が過少計上として固定化する（二重計上防止と表裏）

**ファイル:** `cancel-billing-service-api/src/services/webhook.service.ts`（checkout.session.completed 処理 / おおむね 83-106行）
**重要度:** Medium

**該当コード（変更後・概略）:**
```typescript
const updated = await cancellationsRepo.markPaidIfNotPaid(id, ...); // ne(status,'paid') ガード
if (updated) {
  try {
    await monthlySalesRepo.upsertMonthly(...); // ON CONFLICT (id)
  } catch (salesError) {
    // ログのみで握りつぶし
  }
}
```

**問題:** `markPaidIfNotPaid` で invoice を先に paid 化し、その後 `monthlySalesRepo.upsertMonthly` を別クエリ＋try/catch 握りつぶしで実行している。集計 upsert が失敗すると invoice は paid のまま残り、webhook 再配信時は `markPaidIfNotPaid` が影響行数 0 で skip されるため**売上が永久に加算されない**（過少計上の固定化）。本 PR の二重計上防止（AC-5.4）と表裏一体のトレードオフ。

**修正提案:** paid 更新と集計を同一トランザクションに入れる、もしくは集計失敗時に未集計フラグ／補償再処理を持たせる。最低限 `salesError` を握りつぶさず可観測なアラート対象にする。

---

### [Code Quality] ローカル DB 既定ポートが docker-compose と不一致（5432 vs 5439）

**ファイル:** `cancel-billing-service-api/src/config.ts:43-44` / `docker-compose.test.yml`（host 5439）/ `drizzle.config.ts`（5432）
**重要度:** Medium

**該当コード（変更後）:**
```typescript
// src/config.ts:43-44
export const localDatabaseUrl = (): string =>
  process.env.DATABASE_URL || 'postgres://postgres:postgres@localhost:5432/cancel_test';
```

**問題:** `localDatabaseUrl()` と `drizzle.config.ts` の既定ポートは `5432` だが、`docker-compose.test.yml` / テストヘルパー（`global-setup.ts` / `helpers/db.js`）/ `scripts/migrate.ts` は `5439`。テスト経路は `setup.js` が `DATABASE_URL`(5439) を明示するため green になるが、`DATABASE_URL` 未設定でローカル開発サーバ起動や `npm run migrate:local` を叩くと `5432` を見にいき docker の Postgres(5439) に繋がらず原因不明の接続失敗を招く footgun。

**修正提案:** 既定値を `5439` に統一するか、README に明記する。

---

### [Code Quality] resetToken の jsonb 浅マージと旧 DynamoDB REMOVE の非互換（実害なし・記録）

**ファイル:** `cancel-billing-service-api/src/repositories/applications.repository.ts`（update / おおむね 84-91行）
**重要度:** Low

**問題:** jsonb 浅マージのため `resetToken: null` を渡しても `data` 内に `"resetToken": null` キーが残る（旧 DynamoDB の `REMOVE`＝キー削除とは異なる）。ただし `findByResetToken` は typed 列 `reset_token`（mirror で NULL 化）で検索するため、トークン無効化（AC-5.5）は正しく機能し、`auth.service.resetPassword` の挙動は保たれる。**セキュリティ上の実害なし**。レスポンスに `resetToken: null` キーが露出し得る点のみ記録。

---

### [Code Quality] 初期 admin ユーザーの自動シードが消失

**ファイル:** `cancel-billing-service-api/src/repositories/table-setup.ts`（削除）
**重要度:** Low

**問題:** 旧実装は users テーブル初回作成時に admin（`a.hayashida@...`）を自動投入していた。移行スクリプトが既存 admin を移送する前提のため既存環境では問題ないが、空の新規環境（dev アカウント移設後など）では admin が不在となり管理画面ログイン不能になる。

**修正提案:** dev/prodは今のdynamodbを移行する。locale devのpostgresqlでseedを入れるタイミングがあれば入れるようにする(script実行を初回のみ手動でするでも良い)

---

### [Test Coverage] DELETE /applications/:id で userId を持つ ACTIVE 申請の users 行削除が未検証

**ファイル:** `cancel-billing-service-api/src/services/application.service.ts`（deleteApplication）/ `src/__tests__/e2e/...`（DELETE テスト）
**重要度:** Low

**問題:** 新コードは `application.userId` が存在する時のみ `usersRepo.delete(userId)` を呼ぶよう旧バグ（`delete({applicationId})` のキー名不一致）を是正している（正しい修正）。ただし e2e は `userId` を持たない申請でのみ検証しており、「`userId` を持つ ACTIVE 申請 → users 行も実際に削除される」ケースの verify がない。1 ケース追加が望ましい。

---

### [Codex / Infra] prod クラスタに deletion_protection / final snapshot 保護がない

**ファイル:** `infra/cancel-billing-service-infra/modules/aurora-data-api/main.tf`（aws_rds_cluster.this / おおむね 87-112行）
**重要度:** Medium

**該当コード（新規）:**
```hcl
resource "aws_rds_cluster" "this" {
  # deletion_protection 未指定（= false）
  skip_final_snapshot = true
  # ...
}
```

**問題:** `deletion_protection` 未指定（= false）かつ `skip_final_snapshot = true` のため、本番データストアが `terraform destroy` や設定ミスで保護なしに削除され、最終スナップショットも残らず復旧不能となり得る。

**修正提案:** 環境別変数（prod=true / dev=false）を導入し、prod は `deletion_protection = true` + `skip_final_snapshot = false`。

---

### [Codex / Infra] バックアップ保持・PITR が未明示

**ファイル:** `infra/cancel-billing-service-infra/modules/aurora-data-api/main.tf`（aws_rds_cluster.this）
**重要度:** Medium

**問題:** `backup_retention_period` / `preferred_backup_window` / `copy_tags_to_snapshot` 未指定。Aurora 既定 1 日保持に依存し、本番 DB としての保持方針が明示されていない。

**修正提案:** prod で `backup_retention_period`（例 7〜14 日）を明示し、`skip_final_snapshot=false` と併用。

---

### [Codex / Infra] CloudWatch ログ / Performance Insights 未設定（運用観点）

**ファイル:** `infra/cancel-billing-service-infra/modules/aurora-data-api/main.tf`
**重要度:** Low

**問題:** `enabled_cloudwatch_logs_exports`（postgresql）/ `performance_insights_enabled` 未設定で障害調査の可観測性が限定的。

**修正提案:** 少なくとも prod で `enabled_cloudwatch_logs_exports = ["postgresql"]` を検討。

---

### [Codex / Infra] dev の管理ロールに DynamoDB/SES FullAccess が残存（作者認識済み）

**ファイル:** `infra/cancel-billing-service-infra/dev/main.tf:37-42` / `modules/api-compute/variables.tf`
**重要度:** Low

**問題:** dev で新規作成されるロールに `AmazonSESFullAccess` / `AmazonDynamoDBFullAccess` が付く。本 PR の Data API ポリシーは最小化されているが、同居する既存マネージドポリシーは過剰。コード内コメントで follow-up 縮小を宣言済み。

---

## 判断保留（要人間確認）

- **prod の Aurora インスタンス 1 台（writer のみ）**: `aws_rds_cluster_instance.this`（114-124行）。データ極小・移行段階では妥当だが、prod の AZ 障害時フェイルオーバー方針が仕様に明記なし。
- **engine_version の perpetual diff**: `aws_rds_cluster_instance` に `engine_version` を明示しているため、マイナーバージョン自動アップグレード時に instance 側で恒久 diff が出る可能性。`ignore_changes` 検討。
- **scale-to-zero 実効性**: dev min ACU 0 が ap-northeast-1 / engine 16.6 で実際に受理されるかは apply 時まで未検証。T-2 人力スモークで確認推奨。

## 不採用（誤読・既存・スコープ外）

- **deleteApplication の識別子混在（Codex: Medium）**: invoice は `userId = applicationId`、users PK は email で別テーブルの別キー。Issue が明示要求した旧バグ是正そのもので、意図どおり正しい。
- **SMTP 認証情報のハードコード（Codex: High）**: `src/clients.ts` のデフォルト値は `main` に既存で本 PR の追加ではない（別途キーローテーションは推奨だが本 PR スコープ外）。
- **sendCredentialsEmail 失敗時の再送不可（Codex: High?）**: 旧 `main` も同一構造で本 PR の回帰ではない。挙動不変方針に忠実。運用課題として別 Issue。

## 総評

DynamoDB → Aurora/Drizzle 移行として非常に質が高い。jsonb を read ソースにして camelCase ドメインオブジェクトを保持する設計でレスポンス契約の不変性を担保し、冪等性3層ガード・売上二重計上防止・JOIN による N+1 解消・SQL インジェクション安全を実 Postgres E2E で検証している。lessons の既知パターン再発も無し。

**最優先は High の deploy-api.sh の AURORA_* 欠落**（デプロイ後に全 DB 操作が失敗する実害）。次いで Medium の月次売上過少計上の固定化リスク、ローカルポート不一致、infra の prod 削除保護・バックアップ保持。infra の中核（閉域・パブリックアクセス無効・IAM 最小化・アカウント分離）は重大な違反なし。
