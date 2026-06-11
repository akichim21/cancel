---
issue: 13
date: 2026-06-04
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: feature/GTSS-13
    toBranch: feature/GTSS-13-vitest
---

# レビュー結果: #13（テスト追加コミット）

## 概要

**Issue:** #13 [API] DynamoDB → Aurora Serverless v2 (PostgreSQL) + RDS Data API 移行（Drizzle ORM / Terraform）

> 注: `/review-pr` の第1引数は `4` でしたが、Issue #4 は LP の Vitest/Playwright 基盤導入で本差分とは無関係です。レビュー対象ブランチ（`feature/GTSS-13-vitest` / base `feature/GTSS-13`）・manifest・追加指示「`main..feature/GTSS-13` で修正してるカラムは全て expect」のいずれも **#13（Aurora 移行）** を指すため、#13 を仕様コンテキストとして採用しました。

本 PR は base `feature/GTSS-13`（DynamoDB → Aurora/PostgreSQL + Drizzle 移行）の上に **「移行カラムの挙動レベル expect を補完」する 1 コミット**を積んだもの。移行で新規/変更した DB カラムが、round-trip だけでなく **実フローで書き込まれる値（挙動）まで** テストでアサートされるよう、既存 E2E に `expect` を追記している。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `feature/GTSS-13` | `feature/GTSS-13-vitest` | 1 | 8（すべてテスト） |

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/__tests__/e2e/applications.test.js` | +12 | -2 | Modified |
| `src/__tests__/e2e/auth.test.js` | +2 | -0 | Modified |
| `src/__tests__/e2e/cancellations-invoices.test.js` | +11 | -3 | Modified |
| `src/__tests__/e2e/db-defaults.test.js` | +41 | -0 | Added |
| `src/__tests__/e2e/monthly-sales-id.test.js` | +4 | -0 | Modified |
| `src/__tests__/e2e/process-stripe-account-integration.test.js` | +5 | -0 | Modified |
| `src/__tests__/e2e/response-contract.test.js` | +17 | -5 | Modified |
| `src/__tests__/e2e/stripe-pay.test.js` | +20 | -0 | Modified |

## 「全カラム expect」要件の充足状況（追加指示への回答）

`main..feature/GTSS-13` で導入・変更された全カラム（5 テーブル / 計 82 列）は、以下 3 層で **漏れなくアサート済み**であることを確認した。

| テーブル（列数） | 永続化 round-trip（全列） | DDL（NOT NULL/FK/index/default） | 本コミットが追加した挙動 expect |
|---|---|---|---|
| applications（26） | `repository-columns.test.js:27-63` | `schema.test.js`（deleted_at 列+idx, email UNIQUE, status/stripe idx） | `entityType`/`entityTypeLabel`（list/detail/PUT status） |
| application_users（11） | `repository-columns.test.js:65-83` | `schema.test.js`（FK→applications CASCADE, email UNIQUE, reset_token idx） | `status`/`mustChangePassword` default, `userActivatedAt`/`status` 有効化時 |
| users（9） | `repository-columns.test.js:85-100` | `schema.test.js`（email UNIQUE, role idx） | `password` 非露出（admin-login） |
| cancellations（30） | `repository-columns.test.js:102-149` | `schema.test.js`（application_id NOT NULL, 2 FK, idx 群） | `paidAt`/`paidAmount`, `updatedAt`, monthly 加算連動 |
| monthly_sales（6） | `repository-columns.test.js:151-167` | `schema.test.js`（application_id NOT NULL, FK CASCADE） | `total`/`invoiceCount` default, `monthYear`/`lastUpdated` upsert |

**最重要の担保**: `repository-columns.test.js` は各テーブルで
`expect(Object.keys(full).sort()).toEqual(colKeys(table))`（`colKeys = getTableColumns(table)` のキー集合）を持つため、**schema.ts に列を足して往復確認を足し忘れると必ず落ちる**。つまり「全カラムが最低でも persistence レベルで expect される」ことが構造的に保証されている。本コミットはその上に、移行で挙動が変わった列（enum 正規化・default・決済フロー書き込み）の**実フロー値**を追加検証するもの。

リネーム（`user_id`→`application_id`）の回帰は `schema.test.js:54-56`（旧 `*_user_id_idx` の不在）でも担保。round-trip 以外の挙動が要る 3 列（`deletedAt` 論理削除フィルタ / `createdByApplicationUserId` 作成時セット / `requirementsNotificationSentAt` 24h 抑止）も**ベースブランチで挙動レベル検証済み**（下記「確認済み」参照）。

→ **追加指示の要件は充足**。以下は test hardening の改善提案（いずれも Low / ブロッカーではない）。

## 指摘一覧

- [x] 対応する

### [Test Coverage / Security] サロンログイン正常系に `password` 非露出ガードが無い（admin-login のみ追加）

**ファイル:** `api/src/__tests__/e2e/auth.test.js:44`（追加箇所） / `api/src/__tests__/e2e/auth.test.js:88-105`（欠落箇所）
**重要度:** Medium

**該当コード（変更後 — admin-login にだけガード追加）:**
```javascript
// auth.test.js POST /auth/admin-login 正常系
expect(res.status).toBe(200);
const body = await res.json();
expect(body.data.user).toMatchObject({ id: adminId, email: 'admin@y.com', role: 'admin', name: '運営', isActive: true });
// ↓ 本コミットで追加された機微カラム非露出ガード（admin-login のみ）
expect(body.data.user).not.toHaveProperty('password');
expect(adminId).toMatch(UUID_RE);
```

```javascript
// auth.test.js POST /auth/login（サロンユーザー）正常系 — 同等のガードが無い
expect(res.status).toBe(200);
const body = await res.json();
expect(body.success).toBe(true);
expect(body.data.user).toMatchObject({
  id: applicationUserId,
  // ... toMatchObject（非厳密マッチ）のみ。password 非露出の明示アサート無し
});
```

**問題:** サロン login の `userData`（`src/services/auth.service.ts:85-94`）も現状は allowlist で `password` を含めない実装だが、テストが `toMatchObject`（非厳密）だけのため、**将来 `login` 実装が `appUser` を spread するリファクタで `password`/`resetToken`/`resetTokenExpiry` が混入してもテストは緑のまま通過する**。`application_users.password` は admin より機微度が高い実クレデンシャルで、回帰ガードが admin 側だけに偏っている。3 つの subagent（code-reviewer / codex-reviewer）が独立に同一指摘。

**修正提案:** サロン login 正常系（`auth.test.js:88` 付近）に admin と同じ 1 行を追加する。あわせて `resetToken`/`resetTokenExpiry` も縛るとより堅い。
```javascript
expect(body.data.user).not.toHaveProperty('password');
expect(body.data.user).not.toHaveProperty('resetToken');
expect(body.data.user).not.toHaveProperty('resetTokenExpiry');
```

---

### [Test Coverage] タイムスタンプ列の `expect.any(String)` が既存 `ISO_RE` 規約より緩い（4 箇所）

**ファイル:**
- `api/src/__tests__/e2e/cancellations-invoices.test.js:60`（`updatedAt`）
- `api/src/__tests__/e2e/process-stripe-account-integration.test.js:142`（`userActivatedAt`）
- `api/src/__tests__/e2e/stripe-pay.test.js:208`（`paidAt`）/ `:219`（`sales.lastUpdated`）

**重要度:** Low

**該当コード（変更後）:**
```javascript
// cancellations-invoices.test.js — updateStatus は updatedAt を更新して返す
const body = await res.json();
expect(body).toMatchObject({ id: 'c1', status: 'paid' });
expect(body.updatedAt).toEqual(expect.any(String));   // ← ISO フォーマットまでは縛らない
```

```javascript
// stripe-pay.test.js — 決済フローで paidAt が書き込まれる
expect(persisted.paidAt).toEqual(expect.any(String));  // ← 同上
// ...
expect(sales.lastUpdated).toEqual(expect.any(String)); // ← 同上
```

**問題:** これらはいずれも実装が `new Date().toISOString()` で生成する値（`cancellations.repository.ts:107` / `application.service.ts:553` / `webhook.service.ts:106,125`）。`expect.any(String)` は空文字や非 ISO 文字列でも通過するため「ISO8601 が正しく書き込まれた」ことまでは保証しない。`vitest` lesson（`.claude/skills/vitest/lesson.md`）の `expect.any(String)` 許容例外は **`id` 等のランダム生成値のみ**を明記しており、日時列はその例外に明示列挙されていない。既存テストには `ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/`（`mask-application-pii.test.js:10`）で `toMatch(ISO_RE)` する規約が既にある。

**修正提案:** 上記 4 箇所を既存規約に揃える（型崩れ・空値混入も捕捉できる）。
```javascript
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/;
expect(body.updatedAt).toMatch(ISO_RE);
expect(persisted.paidAt).toMatch(ISO_RE);
expect(sales.lastUpdated).toMatch(ISO_RE);
```

---

## 確認済み（問題なし — メイン + 3 subagent で cross-file 裏取り）

追加された `expect` は **すべて実装挙動と一致**し、false/vacuous アサートは無い。

- **`stripe-pay.test.js`**: `paidAmount=7000` / monthly_sales `total=7000`/`invoiceCount=1`/`type='monthly_sales'` は seed（`amount:7000`, `monthYear:'2026-05'`, stripe-pay.test.js:41）+ webhook フロー（`webhook.service.ts:112-130`）と整合。**`monthYear` は seed 固定で today 非依存**（id `sales_app_1_2026-05` も成立。今日 2026-06 でも誤検知しない）。
- **`entityType`/`entityTypeLabel`**（applications/response-contract）: `serializeApplication`（`application-enums.ts:107-121`）が `'entityType' in item` の時のみラベル付与する実装に対し、各テストが seed で `entityType:'法人'/'個人'`（例 `applications.test.js:139`）を投入しており corporate/individual + ラベルは一致。
- **`auth.test.js:44`（admin-login）**: `userData`（`auth.service.ts:177-185`）は allowlist 構築で `password`/`lastLogin` を含めない → `not.toHaveProperty('password')` は有効な回帰ガード。コメント「lastLogin はアプリで更新しない」も実装と整合。
- **`db-defaults.test.js`（新規）**: `applicationUsersRepo.create` の `toRow` が未指定キーを INSERT から除外するため、DB の `.default('active')`/`.default(false)`/`.default(0)` が確かに発火（vacuous でない）。`.toBe('active')`/`.toBe(false)`/`.toBe(0)` の具体値検証で lesson にも沿う。
- **`process-stripe-account-integration.test.js`**: `status='active'`/`userActivatedAt` は有効化フロー（`application.service.ts:551-553` の `!existingUser` create パス）と整合。
- **`monthly-sales-id.test.js`**: `onConflictDoUpdate`（`monthly-sales.repository.ts:51-57`）が `lastUpdated` のみ上書き・`monthYear` 据え置き → `lastUpdated:'now2'` / `monthYear:'2026-05'` と整合。
- **挙動アサートの抜けは無し（ベースで担保済み）**: `deletedAt` 一覧除外（`applications.test.js:401-417`）/ `createdByApplicationUserId` 作成時セット（`cancellations-invoices.test.js:277`、書込元 `invoice.service.ts:157`/`cancellation.service.ts:46`）/ `requirementsNotificationSentAt` 24h 抑止（`branches.test.js:219,222`）。
- **テスト隔離**: 全テスト `beforeEach` の `truncateAll()`（CASCADE）で隔離。新規 `db-defaults.test.js` も同パターン。

### 棄却した指摘（記録）

- **codex の「`src/middleware/auth.ts` の requireAuth 検証ロールバック」は事実誤認のため不採用**。本 PR の変更は**テスト 8 ファイルのみ**で `auth.ts` を含まず（`git diff ... -- src/middleware/auth.ts` は空）、当該検証はブランチ HEAD（`auth.ts:145-146`）に健在、「削除済み JWT→401」テストも `cancellations-invoices.test.js:104-116` に現存。引用行番号も実ファイルと不一致。別セッション/捏造差分と判断し破棄（codex-reviewer 自身が再検証済み）。

## 総評

**承認可。** 本コミットは「移行で挙動が変わった DB カラムの実フロー値を E2E に固定する」目的に対し、追加された `expect` がすべて実装と一致しており、false assertion・vacuous assertion・隔離不足は無い。追加指示「`main..feature/GTSS-13` で修正してるカラムは全て expect」は、`repository-columns.test.js` の `colKeys` ガード（全 82 列の往復網羅＋列追加時の強制 fail）＋ `schema.test.js`（DDL）＋本コミットの挙動 expect により**構造的に充足**している。

残課題は test hardening 2 件のみ（いずれも現状コードは安全で、回帰検出力の改善）:
1. サロン login への `password` 非露出ガード追加（Medium / 機微度が admin より高い側が無防備）
2. タイムスタンプ 4 箇所を `expect.any(String)` → `toMatch(ISO_RE)` へ（Low / 既存規約への統一）

なお本レビューは静的検証のみ。`npm test` はローカル Postgres（docker, 5439）起動を要するため未実行。マージ前に `npm test` green の確認を推奨。
