---
issue: 17
date: 2026-06-04
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

GTSS-13（DynamoDB → Aurora/PostgreSQL 移行）で持ち越した schema の歪みを是正する破壊的リファクタ。applications から認証カラムを `application_users`（1:N）へ分離、users/application_users の PK を UUID 化、`cancellations/monthly_sales.user_id` → `application_id` リネーム、`created_by_application_user_id`（nullable FK）追加、JWT クレーム改訂、auth フローの application_users 経由化、FK/UNIQUE/index 制約、DynamoDB→PostgreSQL 移行スクリプト改修（孤児ハンドリング含む）。**prod 未リリースの GTSS-13 ブランチ上のため後方互換不要**。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `feature/GTSS-13` | `api-schema-refactor` | 2 | 37 |
| user | `main` | `api-schema-refactor` | 2 | 7 |
| admin | `main` | `api-schema-refactor` | 1 | 1 |

> **ベースブランチ解決メモ**: 引数 `--baseBranch=feature/GTSS-13` は API のみ存在。user portal / admin には `feature/GTSS-13` が存在しないため manifest 記載どおり `main` をベースに採用（GTSS-13 は API のみ変更のため意味的に等価）。

## 変更ファイル一覧

### api（主要のみ）

| ファイル | 変更 | 種別 |
|---------|------|------|
| `src/db/schema.ts` | +113/-? | Modified |
| `src/db/migrations/0000_init.sql` | +47 | Modified（再生成） |
| `src/repositories/application-users.repository.ts` | +105 | Added |
| `src/repositories/{applications,users,cancellations,monthly-sales}.repository.ts` | — | Modified |
| `src/services/{auth,application,cancellation,invoice}.service.ts` | — | Modified |
| `src/middleware/auth.ts` | +27 | Modified |
| `scripts/migrate-dynamodb-to-aurora.ts` | +220 | Modified |
| `src/__tests__/**`（e2e/unit/migration/helpers） | — | Added/Modified |

### user

| ファイル | 種別 |
|---------|------|
| `src/types/index.ts`, `src/components/InvoiceForm.tsx`, `src/contexts/AuthContext.tsx`, `src/services/api.ts` | Modified |
| `src/components/SettingsPage.tsx`, `src/App.tsx`, `src/components/Header.tsx` | Added/Modified（スコープ外・後述） |

### admin

| ファイル | 種別 |
|---------|------|
| `src/types/Cancellation.ts` | Modified |

---

## 指摘一覧

> 全指摘はメインエージェントが worktree 実コードを Read して cross-file 再検証済み（codex / code-reviewer / lessons-reviewer の3エージェント出力を精査）。

- [x] 対応する

### [Code Quality] Stripe webhook で「status=ACTIVE だが application_user 未作成」の復旧不能状態が発生する

**ファイル:** `api/src/services/application.service.ts:496-566`, `api/src/services/webhook.service.ts:217-225`
**重要度:** High

**該当コード（toBranch / application.service.ts:521-543）:**
```js
  } catch (dbError) {
    // 冪等性レイヤ3: DB エラー時はステータスのみ強制 ACTIVE 化するフォールバックを実行してから再 throw。
    console.error('Error updating application status:', dbError);
    try {
      await applicationsRepo.update(applicationData.applicationId, {
        status: APPLICATION_STATUS.ACTIVE,   // ← user 作成前に ACTIVE 化
        updatedAt: new Date().toISOString()
      });
    } catch (fallbackError) {
      console.error('Fallback update also failed:', fallbackError);
    }
    throw dbError;                            // ← user 未作成のまま再 throw
  }
  ...
  if (!existingUser) {
    try {
      await applicationUsersRepo.create({ ... });   // ← ここに到達しない / または失敗
```

**該当コード（toBranch / webhook.service.ts:217-225）— 唯一の呼び出し元:**
```js
        if (account.charges_enabled) {
          // ステータスが APPROVED または STRIPE_PENDING の場合に ACTIVE に更新
          if (application.status === APPLICATION_STATUS.APPROVED || application.status === APPLICATION_STATUS.STRIPE_PENDING) {
            try {
              await processStripeAccountUpdated(application);
            } catch (error) {
              console.error('Error processing Stripe account update:', error);
            }
          }
        }
```

**問題:**
`processStripeAccountUpdated` は「status を ACTIVE 化 → application_users を作成」の順で動く。次の2経路で「application は ACTIVE だが application_user が存在しない」状態が残る:
1. **レイヤ3フォールバック**: `updateStatusIfIn` が DB エラーで throw すると、フォールバックが status を強制 ACTIVE 化してから再 throw する（user 作成コード 543 行に到達しない）。
2. **create 失敗**: `updateStatusIfIn` 成功後に `applicationUsersRepo.create` が落ち、recheck でも行が見つからなければ再 throw（status は既に ACTIVE 化済み）。

唯一の呼び出し元（webhook.service.ts:219）は `status === APPROVED || STRIPE_PENDING` のときだけ処理関数を呼ぶため、status が ACTIVE になった後の **再配信 webhook はこの分岐に入らず、二度と user 作成パスへ到達しない**。結果、ログインユーザーが永久に作られないサロンが残る（=ログイン不能）。`application.service.ts:503-505` の「冪等性レイヤ2a: status ACTIVE でも user 無しなら user 作成のみ再試行する」というコメントは、呼び出し元のゲートにより**実行されないデッドコード**になっている。

**修正提案:**
status 更新と application_users 作成を transaction 化し、user 作成失敗時は status を ACTIVE に進めない（Stripe に再配信させ、次回正規パスで status 遷移 + user 作成を一括成功させる）。あるいは呼び出し元のゲートに「`charges_enabled && status===ACTIVE && application_user 不在`」の復旧分岐を追加する。少なくともレイヤ3フォールバックの「status だけ ACTIVE 化」はやめ、APPROVED/STRIPE_PENDING のまま再 throw する。

---

### [Code Quality] 並行 webhook の UNIQUE 競合敗者が「DB 未保存の初期パスワード」をメール送信する

**ファイル:** `api/src/services/application.service.ts:499,506,543-566,573-590`
**重要度:** High

**該当コード（toBranch / application.service.ts:499-590 抜粋）:**
```js
  const initialPassword = generatePassword();             // 499: 各実行で別パスワード生成
  ...
  const existingUser = await applicationUsersRepo.findFirstByApplicationId(applicationData.applicationId); // 506
  ...
  if (!existingUser) {
    try {
      await applicationUsersRepo.create({ id: randomUUID(), ..., password: hashedPassword }); // 545
    } catch (createError: any) {
      const recheck = await applicationUsersRepo.findFirstByApplicationId(applicationData.applicationId); // 559
      if (!recheck) { throw createError; }
      console.log('application_user creation lost the race but row exists (idempotent):', ...); // 敗者: throw せず継続
    }
  }
  ...
  if (!existingUser) {                                     // 573: existingUser は 506 のまま null
    ...
    await sendCredentialsEmail(applicationData.email, initialPassword, applicationData.partnerName); // 590: 敗者の未保存パスワードを送信
```

**問題:**
同一 `account.updated` が並行配信され、2スレッドとも `existingUser === null`（506）で create に入る。勝者が INSERT 成功、敗者は UNIQUE 違反 → recheck で勝者の行を見つけ `throw` せず継続する。しかし `existingUser` は 506 で取得した値のまま更新されないため、副作用ブロック `if (!existingUser)`（573）が**真のまま実行**され、敗者が生成した（=DB に保存されていない）`initialPassword` で `sendCredentialsEmail` を送る。サロンは**使えない初期パスワードのメール**を受け取る（勝者が保存したパスワードとは別物）。

**検証（テストがバグ挙動を追認）:** `api/src/__tests__/unit/process-stripe-account.test.js:153-169` がこの経路をテストしているが、`sendCredentialsEmail` が呼ばれないことを**アサートしておらず**、L168 コメントが「recheck で行が見つかれば後続の副作用は実行される」と明記してバグ挙動を許容している。対照的に、直前の「重複配信（既に ACTIVE + existingUser 有り）」テスト L149 では `expect(sendCredentialsEmail).not.toHaveBeenCalled()` をアサートしている。

**修正提案:**
「今回 insert に成功したか」を表すフラグ（例 `const created = ...`）を導入し、UNIQUE 競合 recheck 成功時は `created=false` として副作用ブロックをスキップする（`Already processed` 相当）。テストに `expect(sendCredentialsEmail).not.toHaveBeenCalled()` を追加する。

---

### [Code Quality] deleteApplication が cancellation 残存時に FK RESTRICT で 500 + application_users 先行削除によるゾンビ申請を残す

**ファイル:** `api/src/services/application.service.ts:920-971`, `api/src/db/schema.ts`（cancellations FK = `onDelete('restrict')`）
**重要度:** High

**該当コード（toBranch / application.service.ts:942-971 抜粋）:**
```js
    // 未決済の請求リンクを無効化（status が sent / pending）
    const pendingInvoices = await cancellationsRepo.findUnpaidByApplicationId(applicationId); // 942
    for (const invoice of pendingInvoices) {
      ...
      await cancellationsRepo.update(invoice.id, { status: 'canceled' }); // 957: 行は残り application_id 参照も残る
    }
    // application_users を全件削除（FK CASCADE と二重防御。applications 削除前に明示削除する）
    await applicationUsersRepo.deleteByApplicationId(applicationId); // 965: 先に user を削除
    // 申請テーブルから削除
    await applicationsRepo.delete(applicationId); // 971: cancellation が1件でも残れば FK RESTRICT で throw → 500
```

**該当コード（toBranch / schema.ts cancellations FK）:**
```js
    applicationFk: foreignKey({
      name: 'cancellations_application_id_fk',
      columns: [t.applicationId],
      foreignColumns: [applications.applicationId],
    }).onDelete('restrict'),
```

**問題:**
`findUnpaidByApplicationId` は `sent/pending` のみ対象で、`status='canceled'` に更新しても**行自体は残り** `application_id` を参照し続ける。paid な cancellation も残る。したがって申請が cancellation を1件でも持つと 971 行で FK RESTRICT 違反（23503）→ 500。このとき **application_users は 965 行で既に削除済み**のため、申請は残るがログインユーザーだけ消えた**ゾンビ状態**になり、`created_by_application_user_id` も SET NULL される。

**検証（空振りアサーション）:** `api/src/__tests__/e2e/filters.test.js:102-118` が paid/sent/pending を持つ申請を DELETE するテストを持つが、`expect([200, 500]).toContain(res.status)`（113行）で成功も 500 も通る**空振り**になっており、application_users が消えた回帰も検出しない。作者も Completion コメントでこの FK RESTRICT 挙動を認識している。

**修正提案:**
FK 方針と API 挙動を一致させる。(a) 削除前に cancellation 件数を確認し、残存時は副作用前に 409 を返す、または (b) 削除を許すなら transaction 内で cancellation の `applicationId` を NULL 化 / 物理削除してから applications を削除する。いずれにせよ application_users 削除を applications 削除と同一 transaction にし、ゾンビ化を防ぐ。`filters.test.js:113` の期待ステータスを確定値に固定する。

---

### [Code Quality] 移行スクリプトに email 重複の事前監査と transaction が無く、途中失敗で再実行不能になる

**ファイル:** `api/scripts/migrate-dynamodb-to-aurora.ts:273-332`
**重要度:** Medium

**該当コード（toBranch / migrate() 抜粋）:**
```js
export async function migrate(dump, opts = {}) {
  const warnings = auditCancellations(dump.cancellations); // 型監査のみ
  if (warnings.length > 0) throw new Error(...);
  const unknown = auditUnknownColumns(dump);               // 未知カラム監査のみ
  if (unknown.length > 0) throw new Error(...);
  await preflightEmpty(opts.force);
  ...
  for (const a of dump.applications) {                     // 302: transaction 無しで逐次 INSERT
    const { applicationRow, applicationUserRow } = splitApplicationDump(a);
    await applicationsRepo.create(applicationRow);
    if (applicationUserRow) await applicationUsersRepo.create(applicationUserRow);
  }
  for (const u of dump.users) { await usersRepo.create(toUserRow(u)); }  // 312
```

**問題:**
新 schema では `applications.email` / `application_users.email` / `users.email` がいずれも UNIQUE。だが移行前監査は型（`auditCancellations`）と未知カラム（`auditUnknownColumns`）のみで、**email 重複チェックが無い**。`migrate()` は transaction 無しで逐次 INSERT するため、prod dump に重複 email があるとループ途中で UNIQUE 違反（23505）→ **一部だけ投入された状態で停止**。再実行は `preflightEmpty` が「空でない」を検出して弾くため、手動 TRUNCATE が必要になる。Issue 本文「技術的考慮事項 > email UNIQUE と既存データ」で email 重複監査の追加が要求されていたが未実装。

**修正提案:**
`migrate()` 冒頭に applications.email / application_users 採用 email / users.email の重複を集合で事前検出して中止する監査関数を追加する。可能なら migrate 全体を transaction 化し、失敗時に空状態へロールバックする。

---

### [Code Quality] seed-local-admin.ts が users UUID PK 化に未追従（リネーム漏れ・PR 差分外）

**ファイル:** `api/scripts/seed-local-admin.ts:30,36-37`（`package.json` の `npm run seed:local-admin`）
**重要度:** Medium

**該当コード（toBranch / seed-local-admin.ts:30-45）:**
```js
  const existing = await usersRepo.getById(email);   // 30: getById は users.id(UUID) 検索 → email では永久に null
  if (existing) { console.log(`✅ admin already exists, skip: ${email}`); return; }

  await usersRepo.create({
    userId: email,    // 37: userId は新 schema に無く toRow で破棄される
    email,            // id(UUID, NOT NULL, default 無し) 未指定 → NOT NULL 違反で create 失敗
    name, password: hashPassword(password), role: 'admin', status: 'active',
    createdAt: new Date().toISOString(), lastLogin: null,
  });
```

**問題:**
本ファイルは PR diff に含まれていない（未変更）が、PR が `usersRepo` の契約を変えたことで壊れる。`usersRepo.getById(email)`（repo は `eq(users.id, id)` 検索）は UUID PK 化で email を渡しても見つからず**冪等性チェックが常に false**。続く `usersRepo.create({ userId: email })` は `toRow` が `userId` を破棄し（schema 列に無い）、`id`（`text('id').primaryKey()`、NOT NULL・default 無し）が未指定のため **NOT NULL 違反で INSERT 失敗**。`npm run seed:local-admin` がローカルで動かなくなる。

**修正提案:**
`usersRepo.findByEmail(email)` で冪等確認し、`id: randomUUID()` を渡して作成する（`userId` フィールドは削除）。

---

### [Security] requireAuth が application_user(sub) の実在を検証しないため、削除済みユーザーの有効 JWT で 500 が起きうる

**ファイル:** `api/src/middleware/auth.ts`, 影響先 `api/src/services/cancellation.service.ts` / `invoice.service.ts`
**重要度:** Medium（現状 1 application=1 user のため実害限定／N ユーザー運用開始時は必須対応）

**問題:**
`requireAuth` は `applicationsRepo.getById(decoded.application_id)` でサロンの存在/ACTIVE のみ検証し、`decoded.sub`（作成者 application_user）の実在は確認しない。`createCancellation` / `createInvoice` は `createdByApplicationUserId: decoded.sub` をそのまま INSERT する（FK→`application_users.id`）。application が ACTIVE のまま当該 application_user だけ削除された（将来の複数ユーザー運用で起こりうる）有効期限内 JWT を使うと、FK 違反（23503）で 500 になる。所有判定は `application_id` ベースなので越権にはならないが、エラーハンドリングと監査値の信頼性に欠ける。

**修正提案:**
N ユーザー運用開始時の必須対応として、`requireAuth` で application_user の実在も検証するか、INSERT 前に存在チェックして無ければ `createdByApplicationUserId=null` にフォールバックする。本 Issue 時点では記録に留めてよい。

---

### [Test Coverage] webhook 二重配信テストのメール送信数アサーションが緩い

**ファイル:** `api/src/__tests__/e2e/process-stripe-account-integration.test.js:77`
**重要度:** Low

**問題:**
`expect(sesMock.commandCalls(SendEmailCommand).length).toBeLessThanOrEqual(2)` は「2回目で追加送信されない（合計が増えない）」ことを厳密に保証しない（1回目が 1通でも 2通でも pass）。

**修正提案:**
`toBe(2)`、もしくは「1回目実行後にスナップショットを取り 2回目で増分0」を検証する形にして二重メール防止を正しく担保する。

---

### [Test Coverage] 冪等性レイヤ3（DB エラー時フォールバック）のテストが無い

**ファイル:** `api/src/__tests__/e2e/process-stripe-account-integration.test.js`
**重要度:** Low

**問題:**
AC-6.1/6.2（正常 + 二重配信）は検証済みだが、`updateStatusIfIn` が throw した時のフォールバック挙動（上記 High #1 が顕在化するパス）はテストされていない。

**修正提案:**
High #1 の修正と合わせて、フォールバック経路のテストを追加する。

---

### [Code Quality] User portal 差分に Issue#17 と無関係な機能（SettingsPage + T番号）が混入

**ファイル:** `user/src/components/SettingsPage.tsx`（新規）, `src/App.tsx`, `src/components/Header.tsx`, `src/contexts/AuthContext.tsx`, `src/services/api.ts`（commit `5a5262a`）
**重要度:** Low

**問題:**
PR の user portal スコープ（JWT クレーム参照 + localStorage キー切替）に対し、アカウント設定画面と適格請求書登録番号（T番号）編集 UI が同梱されている。`main...api-schema-refactor` の差分にこの commit が含まれるため、レビュー単位・リバート単位が膨らむ。

**検証（問題なし）:** 混入機能のロジックに不具合は見当たらない。`InvoiceForm.tsx` の localStorage キー `invoice_shop_info_${applicationId}` への切替は `getShopInfoKey` / `loadShopInfo` / `saveShopInfo` の全3関数と2呼び出し箇所で一貫しており、リネーム漏れなし。`AuthContext` の `User` 型に `applicationId` が追加され型整合も取れている。

**修正提案:**
GTSS-17 のリネーム作業と、SettingsPage + T番号機能はコミット/PR を分離するのが望ましい。意図的な同梱であれば PR 説明にスコープを明記する。

---

## 総評

全体として設計・命名規約・テストカバレッジは高品質。**userId→applicationId のリネームは service / repository / handler / test の全 call site で漏れなく追従**しており（`git show` で grep 確認）、FK の CASCADE / SET NULL / RESTRICT は schema・migration SQL・constraints.test.js（実 Postgres で 23505/23503/CASCADE を直接検証）で三重に整合確認されている。JWT クレーム改訂（サロン `sub=application_user.id` / `application_id` / 管理者 `sub=users.id(UUID)`）と所有判定 `item.applicationId === decoded.application_id`、`application_id` クレーム欠落の旧 JWT 401 もテストで担保済み。lessons との照合では明確な違反なし。フロント（user portal の applicationId 切替、admin の型リネーム）も末端まで追跡して問題なし。

指摘は主に「**制約導入に伴うエッジ／回復経路／運用**」に集中している。**High 3件はいずれも prod 移行・本番 webhook 障害・申請削除という現実に起こりうる運用で「ログイン不能なサロン」や「使えないパスワードメール」を生む**ため、リリース前の対応を推奨する:
1. webhook の「ACTIVE だが user 未作成」復旧経路（transaction 化 or 復旧分岐）
2. 並行 webhook 競合敗者の認証情報メール送信（created フラグで副作用ガード）
3. deleteApplication の FK RESTRICT 500 + application_users 先行削除ゾンビ（transaction 化 + テスト確定）

Medium の email 重複監査（移行スクリプト）と seed-local-admin の UUID 未追従も、prod 移行時 / ローカル開発時に実害が出るため合わせて対応推奨。
