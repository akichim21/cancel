---
issue: 17
date: 2026-05-28
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: feature/GTSS-13
    toBranch: api-schema-refactor
  - repo: user
    repoDir: cancel-billing-service
    baseBranch: main
    toBranch: api-schema-refactor
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: main
    toBranch: api-schema-refactor
---

# レビュー結果: #17

## 概要

**Issue:** #17 [API] application_users 分離 / users PK の UUID 化 / userId→applicationId リネーム + schema 制約強化

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `feature/GTSS-13` | `api-schema-refactor` | 2 | 37 |
| user | `main` | `api-schema-refactor` | 1 | 2 |
| admin | `main` | `api-schema-refactor` | 1 | 1 |

## 変更ファイル一覧

### api（cancel-billing-service-api）

| ファイル | 変更種別 |
|---------|---------|
| `src/db/schema.ts`, `src/db/migrations/0000_init.sql`, `meta/0000_snapshot.json`, `meta/_journal.json` | Modified |
| `src/repositories/application-users.repository.ts` | Added |
| `src/repositories/{applications,users,cancellations,monthly-sales}.repository.ts` | Modified |
| `src/services/{auth,application,cancellation,invoice,stripe,webhook}.service.ts` | Modified |
| `src/middleware/auth.ts` | Modified |
| `src/handlers/auth.handler.ts` | Modified |
| `scripts/migrate-dynamodb-to-aurora.ts` | Modified |
| E2E/unit テスト多数（schema/constraints/auth/cancellations-invoices/process-stripe-account-integration/monthly-sales-id/response-contract/filters/repository-columns/pure-logic 等） | Added/Modified |
| `src/__tests__/migration/migrate-dynamodb-to-aurora.test.ts` | Modified |

### user（cancel-billing-service）

| ファイル | 変更種別 |
|---------|---------|
| `src/types/index.ts` | Modified |
| `src/components/InvoiceForm.tsx` | Modified |

### admin（cancel-billing-service-admin）

| ファイル | 変更種別 |
|---------|---------|
| `src/types/Cancellation.ts` | Modified |

## 指摘一覧

---

- [x] 対応する

### [Security] createCancellation で applicationId / createdByApplicationUserId をリクエストボディから上書きできる（認可バイパス）

**ファイル:** `api/src/services/cancellation.service.ts:34-45`
**重要度:** High

**該当コード（変更後 = toBranch）:**
```ts
export const createCancellation = async (event, cancellationData, corsHeaders) => {
  const authCheck = await requireAuth(event, corsHeaders);
  if (authCheck.error) return authCheck.response;

  try {
    const cancellationId = `cancellation_${Date.now().toString()}`;
    const cancellation = {
      id: cancellationId,
      applicationId: authCheck.decoded.application_id,
      createdByApplicationUserId: authCheck.decoded.sub,
      ...cancellationData,        // ← 後ろに来るので applicationId / createdByApplicationUserId を上書き可能
      status: 'pending',
      createdAt: new Date().toISOString()
    };
    await cancellationsRepo.create(cancellation);
```

**問題:** JS のオブジェクトリテラルは後勝ち。`cancellationData` に攻撃者が `applicationId: "victim_app_id"` を入れて POST すると、別サロンの applicationId に紐づく cancellation を作成できる。`createdByApplicationUserId` も同様に詐称可能。`requireAuth` で「自身の application が ACTIVE か」は検証されるが、書き込み先の applicationId 検証はされない。さらに `id` / `status` / `createdAt` はあとで上書きしているのに対し、認可由来の 2 フィールドはガードされていない。

なお `invoice.service.ts` の `createInvoice` 等は `invoiceData.X` を明示参照しているため同種の問題はなし。

**修正提案:**
```ts
const cancellation = {
  ...cancellationData,                                  // 先にクライアントデータ
  id: cancellationId,                                   // 以降は上書き禁止フィールド
  applicationId: authCheck.decoded.application_id,
  createdByApplicationUserId: authCheck.decoded.sub,
  status: 'pending',
  createdAt: new Date().toISOString()
};
```
加えて入力 zod スキーマで `applicationId` / `createdByApplicationUserId` / `id` / `status` / `createdAt` を `strict()` 拒否する。回帰テストとして「ボディに `applicationId: 'other_app'` を入れて POST しても DB の applicationId が JWT 由来であること」を `cancellations-invoices.test.js` に追加。

---

- [x] 対応する

### [Security] Stripe webhook 並行配信で DB に保存されていないパスワードを顧客に送信し得る（冪等性レイヤの欠陥）

**ファイル:** `api/src/services/application.service.ts:543-595` (processStripeAccountUpdated)
**重要度:** Critical

**該当コード（変更後 = toBranch）:**
```ts
if (!existingUser) {
  try {
    await applicationUsersRepo.create({
      id: randomUUID(),
      applicationId: applicationData.applicationId,
      email: applicationData.email,
      password: hashedPassword,        // ← この request 固有の hash
      ...
    });
  } catch (createError: any) {
    const recheck = await applicationUsersRepo.findFirstByApplicationId(applicationData.applicationId);
    if (!recheck) throw createError;
    console.log('application_user creation lost the race but row exists (idempotent):', ...);
    // ← existingUser はまだ null のまま
  }
}
...
// 「今回新規に application_user を作成した」回のみ実行すべきだが…
if (!existingUser) {                   // ← race 敗者でも null のため true
  await stripe.accounts.update(...);
  await sendCredentialsEmail(applicationData.email, initialPassword, ...);  // ← 自分の initialPassword（DB に保存されていない値）を送信
  // 管理者通知メールも追加で送信される
}
```

**問題:** 並行 webhook 配信時のレース。
1. A・B が同時刻に `findFirstByApplicationId → null`
2. A が先に `create()` 成功（DB に A の hash）
3. B の `create()` が UNIQUE 違反 → catch → `recheck` で行発見 → 握りつぶす
4. **B 側の `existingUser` は最初の null のまま**
5. 副作用ブロック `if (!existingUser)` に突入し、**B 側の `initialPassword`（DB に保存されていない値）を顧客に送信**
6. 顧客が届いたパスワードでログイン試行 → 認証失敗、サポート問合せに発展

加えて管理者通知メールが二重送信される。コメントは「今回新規に application_user を作成した回のみ実行」と書いているが、実装が一致していない（lessons の cross-file 整合性違反）。

**修正提案:**
```ts
let createdNow = false;
if (!existingUser) {
  try {
    await applicationUsersRepo.create({ ... });
    createdNow = true;
  } catch (createError: any) {
    const recheck = await applicationUsersRepo.findFirstByApplicationId(applicationData.applicationId);
    if (!recheck) throw createError;
    existingUser = recheck;            // ← 副作用判定に反映
  }
}
...
if (createdNow) {                      // ← 「今回作成した」のみ副作用
  await stripe.accounts.update(...);
  await sendCredentialsEmail(...);
  ...
}
```
テストとして並行（`Promise.all`）で `processStripeAccountUpdated` 2 回呼び → `sendCredentialsEmail` モックが 1 回のみ呼ばれることを `process-stripe-account-integration.test.js` に追加（現状 2568-2584 の race テストは順次実行 + 副作用未検証）。

---

- [x] 対応する

### [Code Quality / Reliability] deleteApplication の非トランザクション + cancellations RESTRICT で部分更新が残る

**ファイル:** `api/src/services/application.service.ts:920-993`
**重要度:** High

**該当コード（変更後）:**
```ts
export const deleteApplication = async (applicationId, corsHeaders) => {
  try {
    const application = await applicationsRepo.getById(applicationId);
    if (!application) return { statusCode: 404, ... };

    // 1) 未決済 invoice を canceled に
    const pendingInvoices = await cancellationsRepo.findUnpaidByApplicationId(applicationId);
    for (const invoice of pendingInvoices) {
      ...
      await cancellationsRepo.update(invoice.id, { status: 'canceled' });   // ← コミット済み
    }

    // 2) application_users 全件削除
    try {
      await applicationUsersRepo.deleteByApplicationId(applicationId);     // ← コミット済み
    } catch (err) {
      console.warn('Failed to delete application_users:', err);
    }

    // 3) applications を削除 — paid cancellation が残っていれば RESTRICT で 500
    await applicationsRepo.delete(applicationId);                          // ← ここで失敗
```

`schema.ts:169-172`:
```ts
foreignKey({
  name: 'cancellations_application_id_fk',
  columns: [t.applicationId],
  foreignColumns: [applications.applicationId],
}).onDelete('restrict'),
```

**問題:** paid 状態の cancellation が 1 件でも残っていれば、step 3 が PG 23503（FK violation）で必ず失敗する。しかしトランザクション境界が無いため step 1 / step 2 はコミット済み:
- **未決済 invoice が canceled 化** されたまま残る
- **application_users が全件削除** された状態で applications が残る → ユーザーはログイン不可
- API レスポンスは 500 で「申請の削除に失敗しました」だけ返り、運用復旧手段が見えない

`filters.test.js:113` で `expect([200, 500]).toContain(res.status)` と弱アサーションされている事実が、この壊れた挙動を黙示的に追認してしまっている（別指摘で詳述）。

**修正提案（いずれか）:**
- (a) paid cancellation の存在チェックを先に行い、>0 なら 409 で拒否（「決済済み請求がある申請は削除できません」）。
- (b) `cancellationsRepo.deleteByApplicationId` を `applicationsRepo.delete` の直前に明示実行する（履歴も一掃する仕様にする）。
- (c) 全体を `db.transaction` で囲み、step 3 失敗時に step 1/2 をロールバック。
- 加えて `applicationUsersRepo.deleteByApplicationId` の明示呼び出しは外し、`ON DELETE CASCADE` に任せる（二重防御不要、トランザクション崩れの一因）。

---

- [x] 対応する

### [Code Quality / Reliability] AuthContext が /auth/me レスポンスから applicationId / id を反映していない（旧 localStorage 状態で空キー書き込み）

**ファイル:** `user/src/contexts/AuthContext.tsx:32-49, 86-93`、`api/src/services/auth.service.ts:207-222`
**重要度:** Medium

**該当コード（user 側、変更後）:**
```ts
const checkAuthStatus = async () => {
  try {
    const token = localStorage.getItem('auth_token');
    const storedUser = localStorage.getItem('user');
    if (token && storedUser) {
      const result = await apiService.getCurrentUser();
      if (result.success && result.data) {
        const stored = JSON.parse(storedUser);
        const merged = { ...stored, tRegistrationNumber: result.data.tRegistrationNumber ?? null };
        setUser(merged);
        ...
```

**該当コード（api 側 getMe レスポンス）:**
```ts
body: JSON.stringify({
  success: true,
  data: {
    applicationId,
    email: application.email,
    businessName: application.partnerName,
    tRegistrationNumber: application.tRegistrationNumber || null
    // ← id（application_user.id）が無い
  }
})
```

**問題:**
- `getMe` レスポンスは `applicationId, email, businessName, tRegistrationNumber` のみ返し、**`id` (application_user.id) が欠落**
- `checkAuthStatus` の `merged` は `tRegistrationNumber` 以外をすべて `stored` から取る → API レスポンスから applicationId を取り入れる経路がない
- 結果として:
  1. 旧 localStorage（applicationId 無）でログイン状態のテスター / 開発者がリロード → `stored.applicationId` が undefined → `merged.applicationId` も undefined
  2. 後段の `InvoiceForm` で `user?.applicationId || ''` が空文字になり、`invoice_shop_info_`（末尾空）共有キーに書き込み（次指摘）
- Issue は「破壊的変更可（GTSS-13 ブランチ）」と明記しているため prod ユーザー影響はないが、AC-9.2 の「AuthContext が JWT decode 後の user.applicationId / user.id を区別して扱う」を満たしていない。dev/test の DX も悪化（手動 localStorage クリアが必要）。

**修正提案:**
1. `getMe` レスポンスに `id: application_user.id` を追加（applicationId とは別の identifier）。
2. AuthContext の merge を `const merged = { ...stored, ...result.data }` に変え、API レスポンスを優先反映。
3. `applicationId` または `id` が欠ける場合は `localStorage.removeItem` で破棄し再ログイン要求（旧スキーマからの自然移行）。
4. AC-9.2 の T-26（AuthContext unit テスト）も追加実装する。

---

- [x] 対応する

### [Code Quality] InvoiceForm が applicationId 不在時に空文字フォールバック → 共有キーに shop info を書き込み

**ファイル:** `user/src/components/InvoiceForm.tsx:40, 84-86`
**重要度:** Medium

**該当コード（変更後）:**
```ts
const getShopInfoKey = (applicationId: string) => `invoice_shop_info_${applicationId}`;
...
const savedShopInfo = loadShopInfo(user?.applicationId || '');
...
saveShopInfo(
  user?.applicationId || '',
  shopName,
  shopAddress,
);
```

**問題:** `user?.applicationId || ''` のフォールバックで applicationId が無い場合に `invoice_shop_info_`（末尾空）共通キーへ書き込む。前指摘の AuthContext バグまたは何らかの理由で `applicationId` が空になると、異なるサロンが同一キーに上書きしあい shop info が混在する。AC-9.1 の「サロン単位キャッシュ」前提を壊す。

**修正提案:**
```ts
if (!user?.applicationId) return;  // または親で再ログインへ誘導
const key = getShopInfoKey(user.applicationId);
```
あるいは `getShopInfoKey` に空文字 guard を入れて throw する。

---

- [x] 対応する

### [Test Coverage] filters.test.js の DELETE テストが `[200, 500]` 弱アサーション。仕様変更を追認してしまっている

**ファイル:** `api/src/__tests__/e2e/filters.test.js:111-118`
**重要度:** Medium

**該当コード（変更後）:**
```js
// FK RESTRICT のため applications 削除は失敗 → 500（しかし pending invoice の更新は完了している）
expect([200, 500]).toContain(res.status);

expect((await cancellationsRepo.getById('inv_sent')).status).toBe('canceled');
expect((await cancellationsRepo.getById('inv_pending')).status).toBe('canceled');
```

**問題:** lessons `.claude/skills/playwright/lesson.md` /  `.claude/skills/vitest/lesson.md` の「テストデータを自分で作っているのだから、返り値の具体的な数値・文字列は全て予測可能」「弱い不等号アサーションは避ける」に違反。テスト fixture は paid invoice を含むと自前で作っているため、結果は決定的に 500 になるはず。にも関わらず `[200, 500]` を許容しているのは、`deleteApplication` の部分更新バグ（前指摘）を見過ごす設計。

**修正提案:** `deleteApplication` の挙動を確定させたうえで:
- (a) paid invoice ある場合は 409 (`expect(res.status).toBe(409)`) でアサート
- (b) または 200 + 履歴削除でアサート
の **どちらかに決め打ち**する。`expiredInvoices` も具体値で検証する。

---

- [x] 対応する

### [Test Coverage] process-stripe-account.test.js の UNIQUE-race テストが副作用を検証していない

**ファイル:** `api/src/__tests__/unit/process-stripe-account.test.js:2568-2584`
**重要度:** Medium

**該当コード（変更後）:**
```js
it('UNIQUE 違反 → recheck で行発見 → 冪等にスキップ', async () => {
  ...
  const result = await processStripeAccountUpdated(event);
  expect(result.success).toBe(true);
  expect(applicationUsersRepo.create).toHaveBeenCalledTimes(1);
  // コメント: "後続の副作用は実行される"  ← だが expect 無し
});
```

**問題:** lessons vitest「重要カラム（副作用）は網羅的に expect する」違反。コメントは「後続の副作用は実行される」と書きながら `sendCredentialsEmail` / `stripe.accounts.update` / SES の admin 通知が呼ばれるかどうかを検証していない。前述の Critical 指摘（race で誤パスワードメール送信）と直結する箇所であり、副作用が走るのか走らないのかをテストで固定する必要がある。

**修正提案:** 修正後の挙動（副作用は走らない）を決め打ちでアサート。
```js
expect(sendCredentialsEmail).not.toHaveBeenCalled();
expect(stripe.accounts.update).not.toHaveBeenCalled();
expect(sesMock.commandCalls(SendEmailCommand)).toHaveLength(0);
```

---

- [x] 対応する

### [Security] changePassword が requireAuth を通っておらず active 判定が抜けている

**ファイル:** `api/src/services/auth.service.ts:245-336` (changePassword)
**重要度:** Medium

**該当コード（変更後）:**
```ts
export const changePassword = async (event, corsHeaders) => {
  try {
    const authHeader = event.headers?.authorization || event.headers?.Authorization;
    const token = extractToken(authHeader);
    ...
    const decodedToken = verifyToken(token);     // ← requireAuth ではなく素の verifyToken
    if (!decodedToken) { return 401 }
    ...
    const appUser = await applicationUsersRepo.getById(decodedToken.sub);
    if (!appUser) { return 404 }                  // ← appUser.status / application.status の確認なし
    ...
    if (appUser.password !== hashedCurrentPassword) { return 401 }
    await applicationUsersRepo.update(decodedToken.sub, { password: hashedNewPassword, ... });
```

**問題:** Issue REQ-6 では「アクティブ判定は application.status (ACTIVE) と application_user.status (active) の両方を満たす必要あり」と明示。`login` はこれを満たしているが、`changePassword` は素の `verifyToken` のみで、JWT 有効期間中はサロンが SUSPEND されてもパスワード変更が通る。また `application_id` クレームの存在確認もしていない（middleware は `requireAuth` で行っているがここはバイパス）。現パスワード検証はあるので即セキュリティ事故にはならないが、整合性として直すべき。

**修正提案:**
- `changePassword` を `requireAuth` 経由に揃える（`event` を渡しているので統一可能）
- `appUser.status === 'active'` を明示確認
- 関連テストを `auth.test.js` に追加（SUSPEND された application で changePassword → 403）

---

- [x] 対応する

### [Code Quality] migrate-dynamodb-to-aurora.ts の splitApplicationDump が password 欠落 dump を silent skip

**ファイル:** `api/scripts/migrate-dynamodb-to-aurora.ts:172-189` 周辺
**重要度:** Medium

**該当コード（変更後）:**
```ts
if (!item.applicationId || !item.email || !item.password) {
  return { applicationRow, applicationUserRow: null };
}
```

**問題:** password 欠落の applications dump は application_users 行を作らない → 「ログインできない application」が黙って生成される。`auditUnknownColumns` のような事前検出が無いまま migrate が完走するため、運用で初めて発覚する（ログイン障害として顕在化）。

**修正提案:** migrate の前段（preflight）で「全 applications dump が password を持つこと」を assert する事前監査を追加。許容する場合は `stats.applicationsWithoutUser` カウンタで件数を可視化して、最低限ログに出す。fixture テストにも「password 欠落 → throw」を追加。

---

- [x] 対応する

### [Security] forgotPassword に email 列挙のタイミングサイドチャネルが残る

**ファイル:** `api/src/services/auth.service.ts:386-435` (forgotPassword)
**重要度:** Low

**問題:** `appUser` 不在で即 return する分岐と、存在 → `applicationsRepo.getById` + `update(resetToken)` + email 送信を行う分岐で **応答時間差が大きい**（DB 2 クエリ + token update + SES 送信）。「列挙攻撃対策」を Issue で明示するなら整合性をとるべき。実害は低い（実害より暗号化トークン側で守る）。

**修正提案:** 不在ケースでも `await applicationsRepo.getById(`dummy`).catch(() => null)` や定数時間 sleep を入れる、または応答時間メトリクスを揃える。

---

- [x] 対応する

### [Code Quality] cancellation 移行の孤児ハンドリング（applicationId=NULL）が status に依存しない

**ファイル:** `api/scripts/migrate-dynamodb-to-aurora.ts:260-269, 362-373`
**重要度:** Low

**問題:** 孤児 cancellation を `applicationId=NULL` で投入するロジックは履歴保全には妥当だが、`canceled` 以外（paid 等）の孤児を NULL 化して残すと月次集計や監査と整合しない可能性。

**修正提案:** 孤児を `applicationId=NULL` で残すのは `status='canceled'` のみに限定するか、移行中止 / 警告 + count にする選択を `--allow-orphans` 等のフラグで明示化する。

---

## 総評

**設計と実装の方針は概ね Issue 仕様（REQ-1〜REQ-8 / AC-1.1〜AC-10.2）に沿っており**、特に下記は良質:

- `requireAuth` で旧 JWT（`application_id` クレーム欠落）を明示 401 する分岐と専用テスト（`pure-logic.test.js`）
- FK 制約の `confdeltype` を PG カタログから直接検証する `schema.test.js` の手法
- `repository-columns.test.js` の `Object.keys(full).sort() === colKeys(table)` 機械的整合チェック
- schema レベルでの UNIQUE 制約・FK 制約・CASCADE/RESTRICT/SET NULL の使い分け
- AC ベースのテスト命名（T-1〜T-23）と各テストファイルでの担保

**一方で High/Critical 4 件は merge 前に修正必須**:

1. **createCancellation の認可バイパス**（spread 順）— 即時修正可、回帰テスト追加
2. **Stripe webhook race で誤パスワードメール送信**（冪等性レイヤの欠陥）— `createdNow` フラグ導入で修正
3. **deleteApplication の非トランザクション化 + RESTRICT 競合**— paid 存在チェック or transaction 化
4. **AuthContext + getMe で applicationId 反映なし**— `getMe` に `id` 追加、merge ロジック修正

Medium 以下も次の機会には対応推奨。特に `filters.test.js` の `[200, 500]` 弱アサーションは指摘 #3 の修正と連動して決定的アサーションに直すべきです。

**フロント側 (user / admin)** は型と最小限の追従に留まっており、Issue 仕様で「未整備のため人力テスト」と認められている AC-9.1 / AC-9.2 / AC-9.3 のテストは未実装。Issue ステータスの未完了マークと整合しています。
