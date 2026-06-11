---
issue: 19
date: 2026-06-04
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: api-schema-refactor
    toBranch: feature/GTSS-19
---

# レビュー結果: #19

## 概要

**Issue:** #19 [GTSS-17 追加] application を論理削除化（PII マスク）+ cancellations/monthly_sales.application_id NOT NULL 化 + 移行スクリプト孤児スキップ

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `api-schema-refactor` | `feature/GTSS-19` | 1 | 14 |

全体として REQ-1〜5 は適切に実装され、テストカバレッジ（unit + e2e + 実 Postgres 統合）も厚く、`not.toHaveProperty` / `toBeNull()` の使い分けも正しい。PII マスク網羅性・drizzle 4 ファイル整合・cancellation 側の孤児スキップ・`softDelete` の空 patch 早期 return 回避はいずれも問題なし。指摘は **移行スクリプトの monthly_sales 孤児判定の非対称（要対応）** を筆頭に、論理削除後の認証残存（中）、および既存スコープのセキュリティ観察（参考）。

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `scripts/migrate-dynamodb-to-aurora.ts` | +10 | -15 | Modified |
| `src/__tests__/e2e/applications.test.js` | +191 | -18 | Modified |
| `src/__tests__/e2e/cancellations-invoices.test.js` | +5 | -3 | Modified |
| `src/__tests__/e2e/constraints.test.js` | +28 | -0 | Modified |
| `src/__tests__/e2e/repository-columns.test.js` | +1 | -0 | Modified |
| `src/__tests__/e2e/schema.test.js` | +26 | -0 | Modified |
| `src/__tests__/migration/migrate-dynamodb-to-aurora.test.ts` | +10 | -12 | Modified |
| `src/__tests__/unit/mask-application-pii.test.js` | +52 | -0 | Added |
| `src/db/migrations/0000_init.sql` | +5 | -3 | Modified |
| `src/db/migrations/meta/0000_snapshot.json` | +24 | -3 | Modified |
| `src/db/migrations/meta/_journal.json` | +1 | -1 | Modified |
| `src/db/schema.ts` | +8 | -2 | Modified |
| `src/repositories/applications.repository.ts` | +18 | -3 | Modified |
| `src/services/application.service.ts` | +25 | -2 | Modified |

## 指摘一覧

### [Code Quality] 移行スクリプト: monthly_sales の孤児判定が null applicationId を取りこぼし、NOT NULL 化で migrate 全体がクラッシュしうる

- [x] 対応する

**ファイル:** `api/scripts/migrate-dynamodb-to-aurora.ts:311-323`
**重要度:** Medium

**該当コード:**
```typescript
// monthly_sales 側（本 PR では未編集。base 由来）
for (const c of dump.cancellations) {
  if (isMonthlySales(c)) {
    // monthly_sales 集計の applicationId も孤児 → 投入そのものをスキップ（集計に意味がないため）。
    const sourceAppId = c.applicationId ?? c.userId ?? null;
    if (sourceAppId && !knownApplicationIds.has(sourceAppId)) {   // ← sourceAppId が null/空だと skip されない
      console.warn(`[migration] 孤児 monthly_sales をスキップ: id=${c.id} sourceApplicationId=${sourceAppId}`);
      stats.orphans++;
      continue;
    }
    await getDb().insert(monthlySales).values(toMonthlySalesRow(c));  // ← applicationId=null のまま insert
    stats.monthlySales++;
  } else {
    const row = toCancellationRow(c);
    // 孤児（親 application 不在）は NOT NULL 化により投入できない → スキップして orphans に計上（REQ-5）。
    if (!row.applicationId || !knownApplicationIds.has(row.applicationId)) {  // ← cancellation 側は null も skip（本 PR で修正済み）
      console.warn(`[migration] 孤児 cancellation をスキップ: id=${c.id} ...`);
      stats.orphans++;
      continue;
    }
    await cancellationsRepo.create(row);
    stats.cancellations++;
  }
}
```

**問題:**
本 PR は cancellation 側の孤児判定を `!row.applicationId || !known.has(...)` に修正し「null/空 applicationId も skip」へ正した（diff 反映済み）。一方 monthly_sales 側の判定は `sourceAppId && !known.has(sourceAppId)` のままで、`applicationId`（旧 `userId`）が `null`/`undefined`/空文字の monthly_sales 行は **skip されず** `toMonthlySalesRow(c)`（`applicationId: null`）が insert に進む。

base 時点では `monthly_sales.application_id` が nullable だったためこの null insert は無害だったが、**本 PR の REQ-4（NOT NULL 化）により、同じ null insert が `23502` で migrate 全体を例外停止させる**。1 行の不正データで一括移行ループ全体が aborts するため、blast radius が大きい。発生確率は低い（通常 monthly_sales には userId がある）が、cancellation 側と防御が非対称で、REQ-5「孤児 monthly_sales も投入しない」の意図（line 313 のコメント）とも矛盾する。

**修正提案:**
cancellation 側と同形に揃える。

```typescript
const sourceAppId = c.applicationId ?? c.userId ?? null;
if (!sourceAppId || !knownApplicationIds.has(sourceAppId)) {
  console.warn(`[migration] 孤児 monthly_sales をスキップ: id=${c.id} sourceApplicationId=${sourceAppId ?? null}`);
  stats.orphans++;
  continue;
}
```

あわせて `applicationId` 欠落 monthly_sales が skip される旨のテスト（既存 T-16 の近傍）を追加すると、cancellation 側（T-15）との対称性が担保される。

---

### [Security] 論理削除後も発行済み JWT（最大24h）が requireAuth を通過し続ける（deletedAt 未チェック）

- [x] 対応する

**ファイル:** `api/src/middleware/auth.ts:121-132`（`requireAuth`）／ `api/src/services/application.service.ts`（`softDelete` は `status` を変えない）
**重要度:** Medium

**該当コード:**
```typescript
// requireAuth（auth.ts:121-132、本 PR では未編集）
const application = await applicationsRepo.getById(applicationId);
if (!application || application.status !== APPLICATION_STATUS.ACTIVE) {
  return { error: true, response: { statusCode: 401, ... 'このアカウントは無効です' } };
}
// ↑ deletedAt も application_users 存在も見ていない
```

**問題:**
本 PR の論理削除設計は「`deletedAt` を削除の唯一の真実とし `applications.status`（例: `利用中`）は変更しない」（Issue 技術考慮事項に明記）。新規ログインは `auth.service.login` が `application_users` を `findByEmail` で引くため、application_users 物理削除により遮断される（OK・検証済み）。

しかし `requireAuth` は `application` 存在 + `status === 利用中` のみを判定し `deletedAt` を見ない。よって**論理削除前に発行済みの JWT（`expiresIn: '24h'`）は削除後も失効まで requireAuth を通過する**。Issue が掲げる「ログイン経路を確実に塞ぐ」は新規ログインには効くが、既発行トークンには効かない残存ウィンドウがある。

実害範囲は限定的: `requireAuth` で保護されているのは `auth.handler.ts` の 2 経路（`/auth/me`・`/auth/profile`）のみ（grep 検証済み。`/cancellations`・`/invoices` ハンドラは requireAuth ガード自体が無く、そもそもサロン JWT で gate されていない）。残存アクセスは「削除済みアカウントの自己情報参照（`/auth/me`、email 等は NULL マスク済み）」と「`/auth/profile` での `tRegistrationNumber` 更新」に限られ、マスク済み PII の再書き込みは不可。

**修正提案:**
`getById` は JOIN 用に削除済みも返す設計なので、`requireAuth` 側で `deletedAt` を弾く。二重防御として `auth.service.login` にも `deletedAt` 拒否を入れると堅い。

```typescript
if (!application || application.deletedAt || application.status !== APPLICATION_STATUS.ACTIVE) {
  return { error: true, response: { statusCode: 401, ... } };
}
```

※ `auth.ts` は本 PR の diff 外（base 既存）。論理削除の導入により初めて「status 保持 + 既存トークン残存」が顕在化するため、本 PR スコープでの対応を推奨。

---

### [Security] DELETE /applications/:id に管理者ガードが無い（※ base 既存・diff 外）

- [x] 対応する（別 Issue 推奨）

**ファイル:** `api/src/handlers/applications.handler.ts:63-64`
**重要度:** Low（※ pre-existing。セキュリティ影響自体は高いが本 PR の変更ではない）

**該当コード:**
```typescript
// send-stripe-link は requireAdmin あり（46行）
app.post('/applications/:id/send-stripe-link', async (c) => {
  const adminCheck = requireAdmin(buildEvent(c), corsHeaders);
  if (adminCheck.error) return toResponse(c, adminCheck.response);
  ...
});

// DELETE は requireAdmin なし（63-64行）
app.delete('/applications/:id', async (c) =>
  toResponse(c, await deleteApplication(c.req.param('id'), corsFromCtx(c))));
```

**問題:**
DELETE には認証ガードが無く、CORS を通過する任意のリクエストで applicationId さえ知れば論理削除（＋未決済請求の `canceled` 化・Stripe セッション expire・application_users 物理削除）を実行できる。追加テスト（`applications.test.js`）自身も `headers: ORIGIN`（Bearer なし）で 200 を期待しており、未認証削除が成立することを裏付ける。

ただし `applications.handler.ts` は**本 PR の diff に含まれず、base ブランチ `api-schema-refactor` と完全に同一**（DELETE 未ガード・send-stripe-link のみ requireAdmin の非対称も base 由来）。したがって本 PR が導入した欠陥ではない。

**修正提案:**
他の破壊的 admin 操作（`send-stripe-link` / `cancellation.service` の `requireAdmin`）と同様に handler 先頭で `requireAdmin` を通す。本 PR で削除の副作用（PII マスク等）が増えたことを踏まえ、**別 Issue でのガード追加を推奨**（diff フォーカスの本レビューでは対応対象外として記録）。

---

### [Security] webhook `account.updated` が論理削除済み申請を更新しうる（任意・低）

- [ ] 対応する（任意）

**ファイル:** `api/src/services/webhook.service.ts`（`findByStripeAccountId`）／ `api/src/repositories/applications.repository.ts`（`findByStripeAccountId` は `deletedAt` 未フィルタ）
**重要度:** Low

**問題:**
`stripeAccountId` はマスク保持対象のため論理削除後も残る。`findByStripeAccountId` は `deletedAt` を見ないため、削除後に遅延到着した `account.updated` webhook が削除済み行の `status` / `stripeOnboardingUrl` を上書きしうる。一覧には出ないため実害は小さいが、「削除後は不活性」の不変条件が崩れる。

**修正提案（任意）:**
webhook 更新前に `application.deletedAt` を確認して no-op にするか、`findByStripeAccountId` を `deletedAt IS NULL` で絞る。

## 総評

- **マージ可否**: 機能要件（REQ-1〜5）とテストは健全。**唯一の要対応は移行スクリプトの monthly_sales 孤児判定の非対称（Medium）** で、本 PR の NOT NULL 化で初めて実害（migrate クラッシュ）になるため、cancellation 側と同形に揃えることを推奨する。
- **認証残存（Medium）**: 論理削除後の既発行 JWT が `requireAuth` を通る点は影響範囲が `/auth/me`・`/auth/profile` に限定されるが、`requireAuth` に `deletedAt` チェックを足すと「ログイン遮断」が即時化し設計意図に沿う。
- **検証で問題なしと確認した点**:
  - PII マスク網羅性（`maskApplicationPii` のマスク対象が schema.ts の applications カラムと突合し、保持指定列以外に未マスク PII 列なし）
  - `toRow` が null を UPDATE 対象に含め undefined を除外 → `softDelete` の NULL 上書きが効く
  - テストの `not.toHaveProperty`（DB 往復後）と `toBeNull()`（純粋関数 patch 直接）の使い分けが正しい（`toDomain` が NULL 列を省く仕様に整合）
  - drizzle 4 ファイル（schema.ts / 0000_init.sql / 0000_snapshot.json / _journal.json）の相互整合、`pg_trgm` gin index・EXTENSION の脱落なし
  - cancellation 側の孤児スキップ・`stats` 加算、T-9 shopName 解決（法人=法人名／個人=屋号 or 不明）
  - NOT NULL 化に対し全作成パス（`createCancellation` / invoice 作成 / `upsertMonthly`）が applicationId を必ず持つ
- **lessons 照合**: 違反なし。むしろ過去指摘（`review-result-2026-05-28.md` の「孤児 cancellation を applicationId=NULL で投入」）に対し、本 PR は「NULL 投入をやめスキップ＋orphans 計上」へ正しく対応しており lesson 準拠。
- **参考（仕様確認・コード変更不要）**: 個人事業主の住所（zip/prefecture/city/address/building）は Issue 要件どおり保持されるが、共通 PII をマスクする方針との整合上、プロダクト判断として明示確認の価値あり。application_users 削除失敗を warn で握りつぶし 200 を返す挙動は base 既存（diff 外）だが、論理削除化で「PII マスク成功・ログイン情報残存」の不整合が起こり得るため、将来トランザクション化 or 失敗時 5xx を別途検討する価値あり。
