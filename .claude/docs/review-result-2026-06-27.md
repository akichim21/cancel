---
issue: 31
date: 2026-06-27
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-836
    toBranch: GTSS-842
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: GTSS-836
    toBranch: GTSS-842
  - repo: lp
    repoDir: cancel-billing-service-lp
    baseBranch: GTSS-836
    toBranch: GTSS-842
---

# レビュー結果: #31

## 概要

**Issue:** #31 feat: LP申込にメール認証を追加（仮登録(未認証)ステータス新設・認証メール/完了画面・admin表示&審査通過ロック）

LP 申込を `unverified`（仮登録（未認証））で保存し認証メールを送信、認証URL（`/verify-email?token=`）タップで `pending`（審査中）へ遷移＋管理者通知メールを送る二段階フローを追加する変更。未認証の上書き再送、admin の審査アクションロック（UI＋API 二重防御）、メール送信タイミング移設を含む。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-836` | `GTSS-842` | 1 | 11 |
| admin | `GTSS-836` | `GTSS-842` | 1 | 4 |
| lp | `GTSS-836` | `GTSS-842` | 1 | 7 |

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/services/application.service.ts` | +180 | -67 | Modified |
| `src/__tests__/e2e/email-verify.test.js` | +151 | -0 | Added |
| `src/__tests__/e2e/applications.test.js` | +69 | -26 | Modified |
| `src/repositories/applications.repository.ts` | +13 | -0 | Modified |
| `src/__tests__/unit/application-enums.test.js` | +12 | -0 | Modified |
| `src/handlers/applications.handler.ts` | +10 | -0 | Modified |
| `src/db/migrations/0017_gtss842_email_verification.sql` | +9 | -0 | Added |
| `src/db/schema.ts` | +8 | -0 | Modified |
| `src/db/migrations/meta/_journal.json` | +7 | -0 | Modified |
| `src/constants/application-enums.ts` | +6 | -0 | Modified |
| `src/__tests__/e2e/repository-columns.test.js` | +3 | -0 | Modified |

### admin

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `e2e/application.spec.ts` | +29 | -0 | Modified |
| `src/components/__tests__/ApplicationList.test.tsx` | +16 | -2 | Modified |
| `src/constants/applicationStatus.test.ts` | +11 | -2 | Modified |
| `src/constants/applicationStatus.ts` | +7 | -1 | Modified |

### lp

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/components/EmailVerify.jsx` | +179 | -0 | Added |
| `src/components/__tests__/EmailVerify.test.jsx` | +91 | -0 | Added |
| `src/App.jsx` | +16 | -10 | Modified |
| `src/__tests__/applicationForm.test.jsx` | +6 | -6 | Modified |
| `src/__tests__/routing.test.jsx` | +7 | -0 | Added |
| `src/__tests__/agentCodeForm.test.jsx` | +2 | -2 | Modified |
| `src/__tests__/birthDate.test.jsx` | +2 | -2 | Modified |

## 指摘一覧

- [x] 対応する

### [Security] 公開 `POST /applications` レスポンスに認証トークンが漏洩し、メール認証を受信箱なしでバイパスできる

**ファイル:** `api/src/services/application.service.ts:240`（新規パス）/ `:186`（上書きパス）、根因 `api/src/constants/application-enums.ts:119`
**重要度:** High

**該当コード:**
```typescript
// api/src/constants/application-enums.ts:119 — serializeApplication は全カラムを spread（除外なし）
export const serializeApplication = <T extends Record<string, any>>(
  item: T | null | undefined,
): T | null | undefined => {
  if (!item || typeof item !== 'object') return item;
  const out: Record<string, any> = { ...item };   // ← verificationToken / verificationTokenExpiry もそのまま含む
  if ('status' in item) { /* status / statusLabel 付与のみ */ }
  if ('entityType' in item) { /* ... */ }
  return out as T;
};
```

```typescript
// api/src/services/application.service.ts — 新規パス（application は token を own property で保持）
  const application = {
    applicationId, ...applicationData,
    status: APPLICATION_STATUS.UNVERIFIED,
    verificationToken,            // ← レスポンスに乗る
    verificationTokenExpiry,
    createdAt: now
  };
  // ...
  await sendVerificationEmail(application, verificationToken);
  return { statusCode: 201, headers: corsHeaders, body: JSON.stringify(serializeApplication(application)) };
// 上書きパスも同様に serializeApplication(updated)（updated は DB 行で両カラム非NULL）を 201 で返す
```

**問題:** `POST /applications` は `requireAdmin` の無い**公開エンドポイント**（`applications.handler.ts:33`）。レスポンス（新規・上書き両パス）に `verificationToken` が含まれるため、申込者（=リクエスト送信者）はメールを受信せずに生トークンを取得でき、続けて `POST /applications/verify-email` に渡して `unverified → pending` へ self-verify できる。これはメール認証の目的（他人のメールアドレス・入力ミスの排除。Issue UC-1 / REQ-3）を**根本から無効化**する。トークンはネットワークログ・プロキシにも残る機微情報。`GET /applications` / `GET /applications/:id` も同 serializer で token を返すが、両者は GTSS-836 で `requireAdmin` 済みのため二次的（運営向け露出）。
また既存テスト T-2/T-3 は `toMatchObject`（部分一致）でレスポンスを検証しており、**この余剰キー混入を検知できていない**（緑のまま通過する）。

**修正提案:** 公開レスポンス用に `verificationToken` / `verificationTokenExpiry` を必ず除外する（`serializeApplication` で機微列を落とすか、公開用シリアライザを分離。両 GET でも UI 不要なので除外推奨）。あわせて新規・上書き両パスに `expect(body).not.toHaveProperty('verificationToken')` の回帰アサーションを追加する。

---

### [Security] 無認可 `POST /applications/:id/approve` が未認証ロック（REQ-6/REQ-8）をバイパスする

**ファイル:** `api/src/handlers/applications.handler.ts:56`、`api/src/services/application.service.ts`（`approveApplication`）
**重要度:** High（※認可欠落自体は本PR以前からの既存。ただし本PRの核心要件 REQ-6/REQ-8 が未達になる）

**該当コード:**
```typescript
// api/src/handlers/applications.handler.ts — requireAdmin が無い（他の破壊的操作には付いている）
  app.post('/applications/:id/approve', async (c) =>
    toResponse(c, await approveApplication(c.req.param('id'), corsFromCtx(c))));
  app.post('/applications/:id/stripe-account-link', async (c) => /* ← これも requireAdmin 無し */ );
```
```typescript
// approveApplication は現在ステータスを一切検査せず Stripe アカウント作成 → approved 更新 → 案内メール送信
export const approveApplication = async (applicationId, corsHeaders) => {
  const application = await applicationsRepo.getById(applicationId);
  if (!application) { /* 404 */ }
  const entityType = normalizeEntityType(application.entityType);
  // ...status チェックなしで Stripe Connect アカウント作成・status=approved・「Stripe登録のご案内」送信
};
```

**問題:** 本PRは `updateApplicationStatus`（`PUT /applications/:id/status`）に unverified ガードを追加し「API 直叩きでもロックを突破できない」（REQ-6 / AC-6.2）ことを担保したが、`POST /applications/:id/approve` は別ルートで `requireAdmin` も status ガードも無い。攻撃者は `POST /applications`（任意メール）→ applicationId 取得（指摘1により**同レスポンスでトークンごと**入手可）→ `POST /applications/:id/approve` で `unverified` のまま `approved` へ直行でき、Stripe 登録案内メール送信、さらにオンボーディング webhook（`approved`/`onboarding` をゲート）経由で `active`・仮パスワード発行まで到達し得る。Issue が REQ-8 を「（要確認）」とした「未認証のまま active 化されない」前提が**この経路で破られる**。

**修正提案:** `/applications/:id/approve`（および `/stripe-account-link`）に `requireAdmin` を付与し、`approveApplication` 側でも現在ステータスが `pending` の時のみ承認可とするガードを追加する（既存 `/status`・DELETE と同形）。承認を `updateApplicationStatus` の遷移ガードに一本化するのが安全。※ 既存の認可ギャップだが、本PRのセキュリティ目標達成のため本Issueで是正するのが妥当。

---

### [Security] 入力 `.passthrough()` ＋ `...applicationData` 保存によるマスアサインメント（既存行への注入）

**ファイル:** `api/src/services/application.service.ts`（上書き patch / 新規 object）、`api/src/schemas/application.schema.ts:87`、`api/src/repositories/applications.repository.ts:16`
**重要度:** Medium

**該当コード:**
```typescript
// application.schema.ts:87 — 未知キーを落とさない
    .passthrough()
// applications.handler.ts:35 — 検証は error 配列を返すのみ。strip されない生 body を渡す
    const applicationData = JSON.parse((await c.req.text()) || '{}');
    const validationErrors = validateApplicationData(applicationData);
    // ...
    return toResponse(c, await createApplication(applicationData, corsHeaders));
```
```typescript
// application.service.ts — 上書きパス（本PR新設）。spread 後に上書きされるのは列挙の数カラムのみ
  const patch = { ...applicationData, entityType, agentCode, status, verificationToken, verificationTokenExpiry, updatedAt };
  const updated = await applicationsRepo.update(existing.applicationId, patch);
// repositories/applications.repository.ts:16 — toRow は「DB既知カラム」の allow-list（編集可カラムの allow-list ではない）
  const toRow = (d) => { const row = {}; for (const k of COLS) if (k in d && d[k] !== undefined) row[k] = d[k]; return ...; };
```

**問題:** 未知キーが `createApplication` まで到達し、`toRow` が許す DB 列（`deletedAt` / `stripeAccountId` / `createdAt` / `applicationId` / `requirementsNotificationSentAt` 等）は spread で素通りする。あるメールが `unverified` の間（最大24h）、無認可の `POST /applications` に同一メール＋例えば `{"deletedAt":"..."}` を送ると、**他人の**未認証申請を論理削除（admin一覧から不可視・PIIマスク無し）したり `stripeAccountId` 汚染ができる。新規パスでは body の `applicationId` が生成値を上書きし、`application_users` 側はローカル生成値を使うため**「application 在り = user 在り」1:1 不変条件が壊れる**（パスワード再設定が無言失敗する原因になり得る）。緩和: 影響は applications テーブル列に限定（toRow が他テーブル/任意SQLは遮断）、`status`/`entityType`/`verification*` 等は spread 後に上書きされ注入不可。

**修正提案:** LP 申込入力から保存可フィールド（`partnerName`/`representativeName`/`birthDate`/`phone`/`entityType`/`agentCode` 等）のみ明示 pick する builder を新規・上書き双方で使用し、`applicationId`/`status`/`deletedAt`/`stripe*`/`verification*`/`createdAt`/`updatedAt` は body から絶対に採用しない。マスアサインメント回帰テストを追加する。

---

### [Code Quality] admin Dashboard の集計が新ステータス `unverified` を考慮していない

**ファイル:** `admin/src/components/Dashboard.tsx:13-19`（本PR差分外・未修正）
**重要度:** Medium

**該当コード:**
```typescript
// Dashboard.tsx — total は全件、バケットは 5 ステータスのみ（unverified バケット無し）
  const stats = {
    total: applications.length,                                                  // ← unverified を含み水増し
    underReview: applications.filter(app => app.status === APPLICATION_STATUS.PENDING).length,
    stripePending: applications.filter(app => app.status === APPLICATION_STATUS.APPROVED).length,
    onboardingPending: applications.filter(app => app.status === APPLICATION_STATUS.ONBOARDING).length,
    active: applications.filter(app => app.status === APPLICATION_STATUS.ACTIVE).length,
    rejected: applications.filter(app => app.status === APPLICATION_STATUS.REJECTED).length,
  }
  const recentApplications = applications.sort(...).slice(0, 5)                   // ← unverified も混入
```

**問題:** api の `getAllApplications` → repo `getAll` は `deletedAt IS NULL` のみで絞るため `unverified` も admin に流入する（`applications.repository.ts:getAll`）。ApplicationList は本PRで `unverified` 対応したが、同じく status を集計する Dashboard は未修正。結果、`total`（全件）に未認証が含まれ**バケット合計 ≠ total** となり、`recentApplications`（最近5件）に「メール確認すらしていない申込」が混入する。過去 lesson「ステータスのフィルター条件はドメインのライフサイクル全体を考慮する」（`.claude/lessons.md`）に該当。

**修正提案:** `unverified` を `total` / `recentApplications` から除外する、もしくは未認証バケットを追加してバケット合計と total が整合するようにする（「未認証を total に含めるか」は製品判断を要確認）。

---

### [Code Quality] `verifyEmail` の read-modify-write 競合で管理者通知が二重送信され得る

**ファイル:** `api/src/services/application.service.ts`（`verifyEmail`）
**重要度:** Low

**該当コード:**
```typescript
// 「検索 → status 判定 → 無条件 update → 管理者通知」。同一トークンの同時実行で両方が unverified を読む
  const application = await applicationsRepo.findByVerificationToken(token);
  // ...status === unverified を通過...
  const updated = await applicationsRepo.update(application.applicationId, { status: PENDING, verificationTokenExpiry: null, ... });
  await sendAdminNewApplicationEmail(updated);   // ← 並行リクエストで 2 通送られ得る
```

**問題:** 認証URL の二重クリック（並行リクエスト）で両リクエストが status チェックを通過し、`pending` 遷移自体は冪等でも**管理者通知が2通**飛び、REQ-3 の「二重に通知再送しない」冪等性を厳密には満たさない。実害は低（運営宛メールの重複1通）。

**修正提案:** 既存の条件付き更新 `applicationsRepo.updateStatusIfIn(applicationId, [UNVERIFIED], {...})`（`applications.repository.ts:110`）を使い、影響行数が1の時のみ通知する形にして単発化する。

---

### [Test Coverage] 決定的長さのトークンに弱いアサーション ＋ 漏洩検知アサーションの欠如

**ファイル:** `api/src/__tests__/e2e/applications.test.js`（T-2）
**重要度:** Low

**該当コード:**
```javascript
    expect(persisted.verificationToken.length).toBeGreaterThan(0);   // ← 中身があれば通る弱検証
```

**問題:** トークンは `randomBytes(32).toString('hex')` で常に64文字。`toBeGreaterThan(0)` は弱い。あわせて指摘1の通り「レスポンスに token が含まれない」アサーションも欠落している。

**修正提案:** `expect(persisted.verificationToken).toHaveLength(64)` に強化し、`expect(body).not.toHaveProperty('verificationToken')` を新規・上書き両パスに追加する。

---

### [Code Quality] verify-email ハンドラの `JSON.parse` が try/catch 外（軽微な不整合）

**ファイル:** `api/src/handlers/applications.handler.ts:50-53`
**重要度:** Low

**問題:** `JSON.parse((await c.req.text()) || '{}')` が `verifyEmail` の try/catch の外にあり、不正JSONボディで throw すると `verifyEmail` 自身の `{ result: 'error' }`（200・CORS付き）ではなくグローバル `app.onError`（CORS付き500）に落ちる。CORS ヘッダは付くため実害は無いが、同エンドポイント内でエラー応答の体裁が分かれる。既存 `POST /applications` 等と同じパターンで UX 影響無し。修正は任意。

## 総評

要件（REQ-1〜8）の機能実装・テスト整備（API 統合 / LP Vitest / admin Vitest+Playwright）は全体に丁寧で、enum 二重定義の双方向追加・`updateApplicationStatus` の unverified 双方向ガード・空トークンの早期 invalid・冪等性の status 判定・マイグレーション（列追加+index、UNIQUE 無し）はいずれも仕様どおりに作られている。LP / admin 差分は文言・出し分け・ロックともに整合しており、ここに重大な問題は無い。

一方で **セキュリティ面に High 2件**がある。(1) `serializeApplication` の spread 透過により公開 `POST /applications` のレスポンスへ認証トークンが漏れ、メール認証を受信箱なしでバイパスできる点（既存の機微フィールド漏洩 lesson に合致。テストも `toMatchObject` で検知できていない）。(2) 無認可 `POST /applications/:id/approve` が status ガードを持たず、本PRが守ろうとした「未認証ロック（REQ-6/REQ-8）」を別ルートで素通りする点（認可欠落は既存だが本機能の安全目標に直結）。この2件は組み合わさると「任意メールで申込→トークン入手→approve 直行→active 化」まで一気通貫で到達し得るため、**マージ前に最優先で対処**することを推奨する。Medium のマスアサインメント（入力の allow-list 化）と Dashboard 集計の `unverified` 取りこぼしも併せて対応したい。
