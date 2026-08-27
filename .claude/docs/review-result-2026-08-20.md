---
issue: 72
date: 2026-08-20
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: origin/main
    toBranch: origin/feature/GTSS-72
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: origin/main
    toBranch: origin/feature/GTSS-72
  - repo: cancel
    repoDir: .
    baseBranch: origin/main
    toBranch: origin/feature/GTSS-72
---

# レビュー結果: #72

## 概要

**Issue:** #72 feat: 管理画面に管理者ユーザー管理を追加（一覧/作成/更新・メールリンクでのパスワード設定/再設定/変更）＋ requireAdmin の即時失効化とヘッダー刷新

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 | 追加/削除 |
|-----------|-------------|------------|----------|------------|---------|
| api | `origin/main` | `origin/feature/GTSS-72` | 4 | 35 | +2356 / -95 |
| admin | `origin/main` | `origin/feature/GTSS-72` | 4 | 34 | +3239 / -87 |
| cancel（docs のみ） | `origin/main` | `origin/feature/GTSS-72` | 1 | 8 | +317 / -26 |

### テスト実行結果（レビュー時にブランチ上で実行して確認）

| 対象 | コマンド | 結果 |
|---|---|---|
| api（unit のみ / docker 無し） | `npm run test:unit` | **62 files / 983 tests passed** |
| api（unit + e2e + migration） | `npm test` | **116 files / 1796 tests passed** |
| admin（typecheck + vitest） | `npm test` | **24 files / 370 tests passed** |

Playwright（admin e2e）は未実行。

> **注意: 全件グリーンだが、指摘 1 の欠陥はこのテスト群では検出できない**（後述の実測参照）。

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `package.json` | +1 | -1 | Modified |
| `scripts/upsert-admin-user.ts` | +5 | -0 | Modified |
| `src/__tests__/e2e/admin-password.test.js` | +529 | -0 | Added |
| `src/__tests__/e2e/admin-users.test.js` | +482 | -0 | Added |
| `src/__tests__/e2e/email-verify.test.js` | +9 | -2 | Modified |
| `src/__tests__/e2e/process-stripe-account-integration.test.js` | +4 | -2 | Modified |
| `src/__tests__/e2e/repository-columns.test.js` | +6 | -1 | Modified |
| `src/__tests__/e2e/webhook-reissue-fallback.test.js` | +3 | -1 | Modified |
| `src/__tests__/global-setup.ts` | +7 | -0 | Modified |
| `src/__tests__/helpers/db.js` | +39 | -2 | Modified |
| `src/__tests__/migration/migrate-dynamodb-to-aurora.test.ts` | +3 | -1 | Modified |
| `src/__tests__/unit/application-service.test.js` | +40 | -0 | Modified |
| `src/__tests__/unit/notification-service.test.js` | +4 | -4 | Modified |
| `src/__tests__/unit/process-stripe-account.test.js` | +7 | -7 | Modified |
| `src/__tests__/unit/pure-logic.test.js` | +71 | -9 | Modified |
| `src/db/migrations/0027_admin_user_password_tokens.sql` | +18 | -0 | Added |
| `src/db/migrations/meta/_journal.json` | +7 | -0 | Modified |
| `src/db/migrations/rollback/0027_admin_user_password_tokens.down.sql` | +5 | -0 | Added |
| `src/db/schema.ts` | +16 | -3 | Modified |
| `src/handlers/admin-users.handler.ts` | +50 | -0 | Added |
| `src/handlers/applications.handler.ts` | +6 | -6 | Modified |
| `src/handlers/auth.handler.ts` | +34 | -1 | Modified |
| `src/handlers/index.ts` | +2 | -0 | Modified |
| `src/middleware/auth.ts` | +88 | -14 | Modified |
| `src/repositories/users.repository.ts` | +99 | -1 | Modified |
| `src/schemas/admin-user.schema.ts` | +97 | -0 | Added |
| `src/services/admin-account.service.ts` | +34 | -0 | Added |
| `src/services/admin-auth.service.ts` | +401 | -0 | Added |
| `src/services/admin-user.service.ts` | +240 | -0 | Added |
| `src/services/application.service.ts` | +4 | -2 | Modified |
| `src/services/auth.service.ts` | +22 | -20 | Modified |
| `src/services/cancellation-send.service.ts` | +1 | -1 | Modified |
| `src/services/cancellation.service.ts` | +6 | -6 | Modified |
| `src/services/notification.service.ts` | +7 | -2 | Modified |
| `src/services/salonboard-auth.service.ts` | +9 | -9 | Modified |

### admin

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `CLAUDE.md` | +7 | -1 | Modified |
| `e2e/admin-password.spec.ts` | +75 | -0 | Added |
| `e2e/admin-users.spec.ts` | +136 | -0 | Added |
| `e2e/auth.spec.ts` | +9 | -0 | Modified |
| `e2e/fixtures.ts` | +159 | -0 | Modified |
| `e2e/header-menu.spec.ts` | +87 | -0 | Added |
| `e2e/header-mobile.spec.ts` | +35 | -0 | Added |
| `e2e/helpers/auth.ts` | +7 | -1 | Modified |
| `playwright.config.ts` | +7 | -4 | Modified |
| `src/App.tsx` | +106 | -29 | Modified |
| `src/__tests__/App.test.tsx` | +162 | -0 | Added |
| `src/components/AdminUserForm.tsx` | +224 | -0 | Added |
| `src/components/AdminUserList.tsx` | +161 | -0 | Added |
| `src/components/ChangePasswordPage.tsx` | +187 | -0 | Added |
| `src/components/ForgotPasswordPage.tsx` | +104 | -0 | Added |
| `src/components/Header.tsx` | +180 | -34 | Modified |
| `src/components/LoginPage.tsx` | +14 | -10 | Modified |
| `src/components/SetPasswordPage.tsx` | +192 | -0 | Added |
| `src/components/__tests__/AdminUserForm.test.tsx` | +224 | -0 | Added |
| `src/components/__tests__/AdminUserList.test.tsx` | +101 | -0 | Added |
| `src/components/__tests__/ChangePasswordPage.test.tsx` | +138 | -0 | Added |
| `src/components/__tests__/ForgotPasswordPage.test.tsx` | +62 | -0 | Added |
| `src/components/__tests__/Header.test.tsx` | +117 | -6 | Modified |
| `src/components/__tests__/LoginPage.test.tsx` | +44 | -0 | Modified |
| `src/components/__tests__/SetPasswordPage.test.tsx` | +120 | -0 | Added |
| `src/constants/adminUserStatus.ts` | +32 | -0 | Added |
| `src/instrument.ts` | +8 | -0 | Modified |
| `src/services/ApiService.ts` | +200 | -2 | Modified |
| `src/services/__tests__/ApiService.test.ts` | +105 | -0 | Modified |
| `src/test/setup.ts` | +11 | -0 | Modified |
| `src/test/utils.tsx` | +36 | -0 | Modified |
| `src/types/AdminUser.ts` | +30 | -0 | Added |
| `src/utils/__tests__/sentryScrub.test.ts` | +88 | -0 | Added |
| `src/utils/sentryScrub.ts` | +71 | -0 | Added |

### cancel（親リポジトリ / ドキュメントのみ）

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `CLAUDE.md` | +2 | -1 | Modified |
| `docs/README.md` | +1 | -0 | Modified |
| `docs/cancel-billing-service-admin/README.md` | +41 | -10 | Modified |
| `docs/product/admin-users.md` | +121 | -0 | Added |
| `docs/product/application-flow.md` | +8 | -1 | Modified |
| `docs/product/overview.md` | +1 | -1 | Modified |
| `docs/tech/api-testing.md` | +24 | -0 | Modified |
| `docs/tech/auth.md` | +119 | -13 | Modified |

## 指摘一覧

指摘は **High 1 / Medium 5 / Low 9** 件。重要度順に並べている。

- [x] 対応する

### [Security] 「有効な管理者が0人になる無効化」の防止が成立していない（READ COMMITTED の write skew）

**ファイル:** `api/src/repositories/users.repository.ts:121-140`（`deactivateIfOtherActiveAdminExists`）
**重要度:** High（発生条件は稀。ただし AC-1.11・docs の明文の保証が満たされていない）

**該当コード:**

```ts
// baseBranch 側（変更前）— この関数自体が存在しない（新規追加）
```

```ts
// toBranch 側（変更後）— users.repository.ts:121-140
  deactivateIfOtherActiveAdminExists: async (id: string, patch: Record<string, any>) => {
    const other = alias(users, 'other_admin');
    const rows = await getDb()
      .update(users)
      .set(toRow({ ...patch, status: 'inactive' }))
      .where(
        and(
          eq(users.id, id),
          eq(users.role, 'admin'),
          exists(
            getDb().select({ one: sql`1` }).from(other)
              .where(and(ne(other.id, id), eq(other.role, 'admin'), eq(other.status, 'active'))),
          ),
        ),
      )
      .returning();
    return first(rows);
  },
```

**問題:**
技術的考慮 9 は「条件を UPDATE 文自体に含めて単一ステートメントで実行するので**追加のロック・
トランザクションは不要**」としているが、これは成り立たない。

単一ステートメント化が防ぐのは**同一行**に対する lost update であって、
A が行 B を・B が行 A を更新する本ケースは**ターゲット行のロックが競合しない**。
PostgreSQL の READ COMMITTED では、並行更新されたターゲット行に対してのみ WHERE が再評価される
（EvalPlanQual）ため、ターゲットが別行の本ケースでは再評価が発動しない。
`EXISTS` 副問い合わせは各文の開始時スナップショットで評価され、走査行をロックもしない。
結果、**両方が「相手はまだ active」と見て両方成功する**（典型的な write skew）。

同じ保証は `users.repository.ts:114-119` のコメント、`admin-user.service.ts:197-199`、
`docs/product/admin-users.md` にも明文で書かれており、いずれも実装が持たない保証を宣言している。

**実測（テスト用 Postgres で確認）:**

`users` を空にして active な admin を A・B の 2 名だけにし、
`deactivateIfOtherActiveAdminExists` と同一の SQL を 2 接続から `Promise.all` で同時発行:

| 実装 | 試行 | 両方成功 | 有効な管理者が 0 人 |
|---|---|---|---|
| **現行（EXISTS のみ）** | 200 | **101** | **101** |
| 修正案（CTE + `FOR UPDATE`） | 200 | 0 | 0 |

約 50% の確率で 0 人化する。
（`pg_advisory_xact_lock` を UPDATE の WHERE 内に置く形も試したが、ロック取得前にスナップショットが
確定するため 148/200 で素通りした。ロック対象は「有効な admin 行の集合」でなければならない。）

**なぜ既存テストで捕まらないか:**
`admin-users.test.js:296` の T-19 は `usersRepo` を直接呼ぶが**逐次実行**で、WHERE 条件の存在確認しかしていない。
`:316` の並行テストは API 経路（`app.request`）を使い、`expect(remaining).toHaveLength(1)` で
不変条件を見ているので**再現すれば落ちる**。しかしレビュー時に同一シナリオを **40 回**回したところ
`200/400` が 39 回・`200/401` が 1 回で、0 人化は **0 回**だった。
`requireAdmin`（DB 参照）→ `getById`（対象取得）→ 条件付き UPDATE と DB 往復が挟まるため、
**単一 Node イベントループ内では 2 リクエストが事実上直列化する**ためで、ガードが効いた結果ではない。
本番では 2 リクエストが**別々の Lambda 実行**として Aurora に届くのでこの直列化は起こらない。
つまり T-19 は現実的にこの欠陥を検出できない。

**影響:**
全管理者が inactive になると管理画面から誰もログインできず `GET /admin/users` も 401 になるため、
**画面からの復旧が不可能**になる。復旧手段は `scripts/upsert-admin-user.ts` を本番 DB 接続で叩くことだけ
（本 PR がまさに解消しようとした運用）。本 PR が同スクリプトを「緊急復旧手段」として位置づけ直したことで
復旧経路自体は用意されている。

**修正提案:**
「有効な admin 行の集合」をロックしてから判定する。実測で 0/200 を確認した形:

```sql
WITH locked AS (
  SELECT id FROM users
  WHERE role = 'admin' AND status = 'active'
  ORDER BY id
  FOR UPDATE
)
UPDATE users SET status = 'inactive', ...
WHERE id = $1 AND role = 'admin'
  AND EXISTS (SELECT 1 FROM locked WHERE locked.id <> $1)
RETURNING *;
```

両者が同じ行集合をロックするため後発が待たされ、先発のコミット後に `FOR UPDATE` が再評価されて
相手の inactive 化が見える。単一ステートメントのままなので RDS Data API でも明示トランザクション不要。
Drizzle で表現しづらければ `sql` テンプレートの生クエリで構わない。

**テストも直す:** 現状の並行テストはハーネスの直列化で緑になるため、
`usersRepo.deactivateIfOtherActiveAdminExists` を**リポジトリ層で 2 本同時に**呼ぶ形にし
（`Promise.all` で `admin_a` / `admin_b` を相互指定）、`listAdmins()` の active が 1 名残ることを固定する。
修正前は落ち、修正後に通ることを確認すること。

**実装を変えない判断をする場合**は、`users.repository.ts:114-119` のコメント・
`admin-user.service.ts:197-199`・`docs/product/admin-users.md` から
「A と B が互いを同時に無効化する競合も防ぐ」という保証を**必ず外すこと**。
実装が持たない保証がドキュメントに残るほうが有害。

---

- [x] 対応する

### [Security] パスワード変更画面が全ての 401 を「打ち間違い」扱いし、`Unauthorized` を画面に出したままセッションを残す

**ファイル:** `admin/src/services/ApiService.ts:824-830`, `admin/src/components/ChangePasswordPage.tsx:87-88`, `api/src/middleware/auth.ts:138-145`
**重要度:** Medium

**該当コード:**

```ts
// toBranch 側（変更後）— middleware/auth.ts:138-145。requireAdmin の 401 は英語キーの本文
      return {
        error: true,
        response: {
          statusCode: 401,
          headers: corsHeaders,
          body: JSON.stringify({ error: 'Unauthorized', message: 'このアカウントは無効です' })
        }
      };
```

```ts
// toBranch 側（変更後）— ApiService.ts:824-830（新規）
    if (!response.ok) {
      // 5xx はサーバー内部の情報を画面に出さず汎用文言へ統一する。
      const message =
        response.status >= 500
          ? 'エラーが発生しました。しばらく時間をおいて再度お試しください。'
          : data?.error || 'パスワードの変更に失敗しました'   // ← 401 もここに来る
      throw new Error(message)
    }
```

**問題:**
`POST /auth/admin-change-password` は `requireAdmin` を**先に**通る（`auth.handler.ts:69-72`）。
したがってこの API の 401 は「現在のパスワードの打ち間違い」だけではなく、
**トークン期限切れ / 不正 JWT / 無効化済み / `last_password_change` による失効**も含む。
ところが実装は 401 を一律「打ち間違い」と決め打ちして `fetchWithoutRedirect` で
共通の 401 処理を全面的に迂回しているため、2 つの問題が同時に起きる。

1. **画面に `Unauthorized` がそのまま出る。** `requireAdmin` の 401 本文は
   `{ error: 'Unauthorized', message: '...' }` で、日本語は `message` 側にある。
   `ApiService.ts:829` は `data?.error` を読むので、赤いアラートに文字列 **`Unauthorized`** が表示される
   （`パスワードが変更されています。再度ログインしてください` のケースも同じく `Unauthorized` になる）。
2. **セッションが破棄されない。** 共通処理を通らないので `clearStoredSession()` が呼ばれず、
   無効化された管理者がパスワード変更画面に留まり続ける。REQ-14 / AC-4.5 の
   「401 では authToken と adminUser の両方を破棄する」が、この経路だけ成立しない。

`fetchWithoutRedirect` を使う判断自体（打ち間違いでログアウトさせない）は正しい。
問題は「401 = 打ち間違い」という前提が、先行ガードの存在によって崩れていること。

なお `docs/tech/auth.md` の一覧が `admin-change-password → 403` としている点も、
実際には `requireAdmin` が先に 401 を返すため通常経路では 403 に到達しない
（`admin-auth.service.ts:329` の 403 はガードとのレース用の保険）。

**修正提案:**
最も明確なのは**現在のパスワード不一致を 401 ではなく 400（または 422）にする**こと。
そうすれば「401 = セッションの問題」「400 = 入力の問題」で層が分かれ、フロントは
401 のときだけ `clearStoredSession()` + `/login` へ、400 はその場でメッセージ表示、と単純に書ける。
REQ-6 の文言指定を変えたくない場合は、応答に `code`（例 `WRONG_CURRENT_PASSWORD`）を足して識別し、
それ以外の 401 は破棄+遷移にする。いずれの場合も、表示する文言は `data?.error ?? data?.message` の
順で拾うようにして `Unauthorized` が画面に出ないようにすること。

---

- [x] 対応する

### [Security] Sentry Replay の録画データは `beforeSend` を通らないため、REQ-15 のスクラブが掛からない

**ファイル:** `admin/src/instrument.ts:23, 28-31`, `admin/src/utils/sentryScrub.ts`
**重要度:** Medium

**該当コード:**

```ts
// toBranch 側（変更後）— instrument.ts:22-32
    tracesSampleRate: Number(import.meta.env.VITE_SENTRY_TRACES_SAMPLE_RATE ?? 0) || 0,
    replaysSessionSampleRate: 0.1,
    replaysOnErrorSampleRate: 1.0,
    // 除去処理は純関数（utils/sentryScrub）に切り出して単体テストで固定する。
    beforeSend: (event) => scrubEvent(event),
    beforeSendTransaction: (event) => scrubEvent(event),
    beforeBreadcrumb: (breadcrumb) => scrubBreadcrumb(breadcrumb),
```

**問題:**
event / transaction / breadcrumb については純関数 + 単体テストで正しく固定されており、
AC-4.8 の文面（「イベント・breadcrumb に含まれない」）は字義どおり満たしている。

しかし **Replay の録画データはこれらのフックを通らない**。
`node_modules/@sentry/replay` を確認したところ、Replay は `createReplayEnvelope` で独自エンベロープを
組んで送信しており、`beforeSend` の経路とは別（録画イベント用に `beforeAddRecordingEvent` という
専用フックが用意されていること自体がその裏付け）。
`replaysSessionSampleRate: 0.1` / `replaysOnErrorSampleRate: 1.0` なので、
`/set-password?token=<32バイトの16進>` を開いたセッションは一定割合で録画対象になる。
`maskAllText` はテキストノードのマスクで URL には効かない、という REQ-15 の前提がそのまま当てはまり、
`instrument.ts:5-7` と `sentryScrub.ts:3-5` のコメント自身が Replay を脅威として挙げているのに、
その経路だけ塞げていない構図になっている。

**検証の切り分け（正直に）:** 「Replay が `beforeSend` を経由しない」ことは SDK を読んで確認済み。
「録画データに実際に `?token=` が残るか」は本レビューでは確定できていない
（codex-reviewer は rrweb の Meta event の `href` と `replay_event.urls[]` に載ると指摘しているが、
こちらでは裏取りしていない）。

**修正提案:**
SDK 内部の挙動を確定させなくても閉じられる方法を採るのが早い。
**トークンを URL から即座に消す**のが最も確実で副作用が小さい:
`SetPasswordPage` はマウント時に `searchParams` からトークンを読んで state に持てるので、
その直後に `window.history.replaceState({}, '', location.pathname)` を呼べば、
Replay・breadcrumb・`document.referrer`・ブラウザ履歴のいずれからも消える
（`sentryScrub` は多層防御として残す）。
代替として、公開ルートでは Replay を初期化しない（`replaysSessionSampleRate: 0`）方法もある。

---

- [x] 対応する

### [Security] DB 例外時のログにパスワードハッシュとトークンダイジェストが平文で残る

**ファイル:** `api/src/services/admin-auth.service.ts:285, 367`, `api/src/services/admin-user.service.ts:131`
**重要度:** Medium

**該当コード:**

```ts
// toBranch 側（変更後）— admin-auth.service.ts:270-285
    const changedAt = new Date().toISOString();
    const updated = await usersRepo.consumeResetToken(hash, {
      password: hashPassword(newPassword),      // ← params に載る
      lastPasswordChange: changedAt,
      updatedAt: changedAt,
    });
    if (!updated) return fail(400, ADMIN_RESET_MESSAGES.invalidLink);
    ...
  } catch (error) {
    console.error('Admin reset password error:', error);   // ← Error 全体を出力
```

```js
// node_modules/drizzle-orm/errors.js（drizzle-orm ^0.45.2）
class DrizzleQueryError extends Error {
  constructor(query, params, cause) {
    super(`Failed query: ${query}
params: ${params}`);          // ← message に SQL と**バインド値**が入る
```

**問題:**
drizzle-orm 0.45 は `pg-core/session.js` の **6 箇所**でクエリ失敗を `DrizzleQueryError` にラップし、
その `message` に SQL 文と**バインドパラメータ**を連結する。`pg-core` は `node-postgres` と
`aws-data-api/pg` の**共通層**なので、本番（Data API）でも同じ。

`console.error('...', error)` は Error の message + stack を出力するため、
DB エラーが起きた瞬間に CloudWatch へ次が平文で残る。

- `admin-auth.service.ts:285`（`adminResetPassword`）… 新パスワードのハッシュ + トークンダイジェスト
- `admin-auth.service.ts:367`（`adminChangePassword`）… 新パスワードのハッシュ
- `admin-user.service.ts:131`（`createAdminUser`）… メールアドレス等

**なぜ Low ではなく Medium か**（2 つの増幅要因）:

1. **ハッシュがソルト無し SHA-256**（技術的考慮 4 / Issue #41）。
   ソルトが無いので、ログを読める者はレインボーテーブルで実パスワードへ戻せる可能性が高い。
   「ハッシュだからログに出ても平気」が成り立たない。
2. **この環境では DB エラーが例外的な事象ではない。** dev/prod の Aurora は min ACU 0 で
   オートポーズするため復帰待ちのエラーが現実に起きる（`getDb` にリトライがあるのは
   まさにそのため）。リトライを使い切れば catch に到達する。

トークンダイジェストの方は、リンクの利用にはダイジェストではなく平文（プリイメージ）が要るので
それ単体で乗っ取りには使えない。主たるリスクはパスワードハッシュ側。

**修正提案:**
この 3 箇所の catch で `error` オブジェクトをそのまま渡さない。
操作名と分類可能な情報だけに絞る:

```ts
  } catch (error) {
    // DrizzleQueryError の message には SQL とバインド値（パスワードハッシュ等）が入るため出さない
    console.error('Admin reset password failed:', (error as any)?.cause?.code ?? (error as any)?.name);
```

同種の catch が他にもあるため、横断的に潰すなら「Error をそのまま `console.error` しない」
ヘルパを 1 つ用意して置き換えるのが確実。

---

- [x] 対応する

### [Security] メールアドレス正規化が書き込み側だけで、ログインと「パスワードを忘れた」が大小文字を区別する

**ファイル:** `api/src/services/admin-auth.service.ts:202`, `api/src/services/auth.service.ts:146`, `admin/src/components/LoginPage.tsx:39`
**重要度:** Medium

**該当コード:**

```ts
// toBranch 側（変更後）— 書き込み側は正規化する（admin-user.schema.ts:56-61）
const emailField = z
  .string({ ... })
  .transform((v) => v.trim().toLowerCase())
```

```ts
// toBranch 側（変更後）— admin-auth.service.ts:202。読み出しは完全一致
    const user = await usersRepo.findByEmail(email.trim().toLowerCase());
```

```ts
// baseBranch / toBranch とも同じ — auth.service.ts:146。生入力で完全一致
    const user = await usersRepo.findByEmail(email);
```

```tsx
// toBranch 側（変更後）— LoginPage.tsx:39。trim も lowercase もしない
        body: JSON.stringify({ email, password })
```

**問題:**

**(a) 既存の大文字混じり行は「パスワードを忘れた」で永久に見つからない。**
本 PR は「既存の本番行に大文字が含まれている場合」を前提に `findAllByEmailInsensitive` を新設している
（`users.repository.ts:70-78` / REQ-2・技術的考慮 8）。実際 `scripts/migrate-dynamodb-to-aurora.ts` は
DynamoDB の値をそのまま写すため大文字混じり行は実在し得る。
ところが `adminForgotPassword` は**入力だけ**小文字化して完全一致で引くので、
`users.email = 'Ops@Example.com'` の行はどの入力表記でもヒットしない。
REQ-4 どおりレスポンスは常に 200 なので、**完全にサイレントな失敗**になる。

**(b) 本 PR で作った管理者は必ず小文字保存なのに、ログインは生入力で完全一致。**
利用者がメールアドレスに大文字を 1 文字でも混ぜる（またはコピペで前後に空白が付く）と
401「ユーザーが見つかりません」になる。`LoginPage.tsx:39` は `trim()` も `toLowerCase()` もせず
送信しているので救済が無い。CLI（`upsert-admin-user.ts:52`）も以前から小文字保存だったので
厳密には新規の回帰ではないが、**本 PR で管理者の作成経路が画面に移り母数が増えるぶん顕在化しやすくなる**。

技術的考慮 8 が「変更しない」と決めたのは `adminLogin` の**照合ロジック**で、
理由は「入力の小文字化は既存の大文字行の管理者を締め出す」というもの。
(b) の最小対応（フロントで `trim().toLowerCase()`）はサーバーの照合を変えないので、その判断とは競合しない。
…と考えたが、**フロントで小文字化すると大文字保存の既存行の管理者がログインできなくなる**ため、
(a) を先に直して保存値・照合の双方を小文字前提に揃えるほうが安全。順序に注意すること。

**関連する運用上の落とし穴:**
新しい編集フォームは氏名だけ直しても `email` を同送するため（`AdminUserForm.tsx:78-82`）、
誰かが一度その行を編集した瞬間に保存値が小文字へ正規化される。
それまで `Ops@Example.com` でログインできていた本人は、以後同じ入力では入れなくなる
（小文字なら入れるし、正規化後は忘れた導線も機能するので恒久ロックアウトにはならないが、
本人には理由が分からない）。

**テストも片側だけ:** `admin-password.test.js:104-107` の T-32 は
「大文字入力 → 小文字保存の行にヒットする」だけを検証しており、
**壊れている方向（保存値側に大文字）が未検証**。

**修正提案:**
1. `adminForgotPassword` を `usersRepo.findAllByEmailInsensitive(email)` ベースにし、
   `isActiveAdmin` を満たす行を選ぶ（本 PR で用意済みの関数。常に 200 とも両立する）。
2. リリース前に本番の大文字混じり行を確認し（技術的考慮 8 のチェックに
   「大文字を含む admin 行が無いこと」も含める）、無ければ `adminLogin` 側も
   `email.trim().toLowerCase()` へ寄せて (b) を閉じる。あれば先に行を正規化する。
3. テストに「`users.email` が大文字で保存された有効な admin へ小文字入力で送ると 1 通届く」を追加。

---

- [x] 対応する

### [Code Quality] 起動時の `admin-me` 取得結果が localStorage へ書き戻されず、一覧画面の「自分自身の行」判定が無効化されることがある

**ファイル:** `admin/src/App.tsx:99-113`, `admin/src/components/AdminUserList.tsx:30`
**重要度:** Medium

**該当コード:**

```tsx
// baseBranch 側（変更前）— App.tsx の起動時検証。adminUser という概念自体が無い
    const verifyToken = async () => {
      const token = localStorage.getItem('authToken')
      if (token) {
        try {
          await ApiService.getApplications()
          setIsAuthenticated(true)
        } catch (error) {
```

```tsx
// toBranch 側（変更後）— App.tsx:99-113
      try {
        const me = await ApiService.getAdminMe()
        setAdminUser(me)                    // ← React state にだけ入れる
        setIsAuthenticated(true)            //    setStoredAdminUser(me) が無い
      } catch (err) {
        const status = (err as { status?: number })?.status
        if (status === 401) {
          clearStoredSession()              // 破棄側は両方消している（非対称）
          setAdminUser(null)
          setIsAuthenticated(false)
        } else {
```

```tsx
// toBranch 側（変更後）— AdminUserList.tsx:29-30。参照先は state ではなく localStorage
  // 自分自身の行では status セレクトを非活性にするため、保持しているログイン中の管理者 ID を使う。
  const currentAdminId = getStoredAdminUser()?.id ?? null
```

**問題:**
`adminUser` を localStorage へ書くのは `LoginPage`（ログイン時）と `ChangePasswordPage`（変更成功時）だけで、
起動時の `getAdminMe()` は **state にしか反映しない**。一方 `AdminUserList` は props ではなく
`getStoredAdminUser()` を直接読むため参照元が分岐している。
破棄側（`clearStoredSession`）は両方消しているのに、書き込み側だけ非対称。

具体的な失敗シナリオ:
本 PR デプロイ前からログイン中の管理者は `authToken` はあるが `adminUser` キーを持たない。
このトークンは `users.last_password_change` が NULL のため REQ-7 の失効判定に掛からず**有効なまま**
（`middleware/auth.ts:149`。T-54 がこの挙動を固定している）。
この管理者が `/admin-users` を開くと、ヘッダーには `getAdminMe()` の正しい氏名・メールが出るのに
`currentAdminId` は `null` のままなので、**自分自身の行でもステータスセレクトが活性**で
「自分自身を無効化することはできません」の注記も出ない。
「無効」を選んで保存すると API 側（`admin-user.service.ts:187`）が 400 で拒否するため
**サーバー側の多層防御は無傷**だが、UI は「必ず失敗する操作」を提示することになり
REQ-10 / AC-1.10 の画面側要件を満たさない。
副次的に、氏名・メールを変更された後も localStorage 側は再ログインまで古い値のまま残る。

テストでも捕まらない: `AdminUserForm.test.tsx:123` は `currentAdminId` を props で直接渡して検証しており、
`AdminUserList.test.tsx:13` は `beforeEach` で `localStorage.clear()` するため
常に `currentAdminId === null` の経路しか通らない。`App.test.tsx` の T-53（200 系）も
ヘッダー表示だけを見て localStorage を検証していない。

**修正提案:**
`App.tsx` の成功時に `setStoredAdminUser(me)` を併せて呼ぶ（`clearStoredSession` と対称になる）。
あわせて `AdminUserList` へ `adminUser` を props で降ろし localStorage 直読みをやめると参照元が 1 本化する。
回帰テストとして「`adminUser` 未保持 + `getAdminMe` 成功 → 自分の行が `disabled`」を 1 本追加する。

---

- [x] 対応する

### [Code Quality] 招待した管理者が「メール到達を確認する前に」有効な運営通知の宛先になる

**ファイル:** `api/src/services/admin-user.service.ts:105-116`, `api/src/repositories/users.repository.ts:46-56`
**重要度:** Low（Issue の確定した設計判断に沿った挙動。緩和策の要否は著者判断）

**該当コード:**

```ts
// toBranch 側（変更後）— admin-user.service.ts:105-116
    const created = {
      id: randomUUID(), name, email,
      role: ADMIN_ROLE,
      status: ADMIN_USER_STATUS.ACTIVE,      // ← 作成時点で即 active
      password: null,
      ...
```

```ts
// toBranch 側（変更後）— users.repository.ts:46-56
  // パスワード未設定（招待直後）の管理者は正規の運営メンバーなので**含める**（password は見ない）。
  findActiveAdmins: async () => {
    const rows = await getDb().select().from(users)
      .where(and(eq(users.role, 'admin'), eq(users.status, 'active')));
```

**問題:**
作成した瞬間に `status='active'` になり、`findActiveAdmins` は password の有無を見ないため、
**招待メールが本人に届いたことを確認する前に**そのアドレスが運営通知の宛先に入る。
運営通知の本文にはサロンの事業者名・代表者名・メールアドレス等の個人情報が含まれる
（`docs/product/application-flow.md`）。
宛先を 1 文字打ち間違えると、(1) 無関係な第三者にサロンの個人情報が届き続け、
(2) その第三者は届いた設定リンクから**完全な管理者権限**を取得できる。

無効化済みの宛先を「個人情報の継続的な送信にあたる」という理由で除外する本 PR の方針と、
所有未確認のアドレスを最初から宛先に入れる扱いは非対称に見える。

ただし「作成＝即 active」は Issue の確定した設計判断であり、
招待メール自体が本人確認を兼ねるのは一般的なパターンでもあるため、
**コード欠陥ではなく設計上のトレードオフ**として報告する。

**修正提案（採るなら最小のもの）:**
作成モーダルの保存時に、宛先を明示した確認ダイアログを出す
（編集画面のメール送信ボタンには既に `window.confirm` がある。`AdminUserForm.tsx:100-106`）。
より踏み込むなら、パスワード未設定の間は通知宛先から外す（`findActiveAdmins` に `password IS NOT NULL` を足す）
選択肢もあるが、これは `users.repository.ts:49` の明文の判断を覆すので Issue 側での合意が要る。

---

- [x] 対応する

### [Code Quality] 保存とパスワードメール送信が相互排他になっていない

**ファイル:** `admin/src/components/AdminUserForm.tsx:192, 214`
**重要度:** Low

**該当コード:**

```tsx
// toBranch 側（変更後）— AdminUserForm.tsx:189-196（メール送信ボタン）
              <button
                type="button"
                onClick={() => void handleSendPasswordEmail()}
                disabled={sendingEmail || isInactive}        // ← saving を見ていない
```

```tsx
// toBranch 側（変更後）— AdminUserForm.tsx:212-215（保存ボタン）
            <button
              type="submit"
              disabled={saving}                              // ← sendingEmail を見ていない
```

**問題:**
どちらのボタンも相手の実行中フラグを見ていないため、送信中に保存、保存中に送信ができる。
メールアドレス変更を伴う保存は未使用トークンを失効させる（`admin-user.service.ts:171-176`）ので、
「パスワード設定メール送信 → 成功トースト」の直後に PATCH が届くと、
**たった今送ったリンクを殺す**（利用者にはトーストで成功と出ているので原因が分からない）。
逆順だと、確認ダイアログに出した宛先（`adminUser.email`）と実際の送信先が食い違う。

**修正提案:** `const busy = saving || sendingEmail` を作り、両ボタンとも `disabled={busy || ...}` にする。

---

- [x] 対応する

### [Code Quality] 作成時のメール重複が競合すると 409 ではなく 500 になる

**ファイル:** `api/src/services/admin-user.service.ts:102, 116, 131-133`
**重要度:** Low

**該当コード:**

```ts
// toBranch 側（変更後）— admin-user.service.ts:101-116
    const { name, email } = result.data;
    if (await findEmailConflict(email)) return fail(corsHeaders, 409, M.duplicateEmail);   // 事前 SELECT
    ...
    await usersRepo.create(created);        // ← ここで 23505 になると外側 catch → 500
```

**問題:**
`findEmailConflict`（SELECT）と `usersRepo.create`（INSERT）の間に同じメールが挿入されると
`users_email_unique_idx` 違反になり、外側 catch が拾って `500 管理者の作成に失敗しました` を返す。
画面には汎用エラーが出るだけで、利用者は「重複していた」ことが分からない。
最上位の指摘と同じ read-then-write だが、こちらは DB の一意制約が最終防衛線として効くので
データ不整合は起きず、応答コードだけの問題。

**修正提案:** `create` を try で囲み、PostgreSQL の `23505`（unique_violation。
`error?.cause?.code`）を 409 `M.duplicateEmail` へ畳む。

---

- [x] 対応する

### [Code Quality] 通信エラーが汎用文言へ正規化されず `Failed to fetch` が画面に出る

**ファイル:** `admin/src/services/ApiService.ts:824-830, 855-864`, `admin/src/components/ChangePasswordPage.tsx:88`, `admin/src/components/SetPasswordPage.tsx:69`
**重要度:** Low

**該当コード:**

```ts
// toBranch 側（変更後）— ApiService.ts のコメント（adminResetPassword）
   * 失敗時は**サーバーが返した日本語メッセージをそのまま**画面へ出す（トークン不正・期限切れ・
   * アカウント無効を区別して伝えるため）。5xx・通信エラーだけ汎用文言にする。
```

```tsx
// toBranch 側（変更後）— ChangePasswordPage.tsx:87-89
    } catch (err) {
      setError(err instanceof Error ? err.message : 'パスワードの変更に失敗しました')
    } finally {
```

**問題:**
コメントは「5xx・**通信エラー**だけ汎用文言にする」と契約を書いているが、
実際に変換しているのは `Response` を受け取れた場合の 5xx だけ。
`fetch` 自体が reject する（オフライン・DNS 失敗・CORS）ケースは
`ApiService` を素通りして `ChangePasswordPage` / `SetPasswordPage` の catch に届き、
`err.message` すなわち **`Failed to fetch`** が赤いアラートに出る。
`ForgotPasswordPage.tsx:36` は catch で汎用文言に固定しているので、3 画面で挙動が揃っていない。

**修正提案:**
`ApiService` 側の各メソッドを try/catch で包み、`Response` を得られなかった例外を
`'エラーが発生しました。しばらく時間をおいて再度お試しください。'` に正規化する
（コメントの契約を実装に合わせる）。もしくはコメントを実態に合わせて直す。

---

- [x] 対応する

### [Test Coverage] 更新経路のマスアサインメント・期限境界・大小文字の逆方向が未固定、マッチャの無いアサーションが 1 行

**ファイル:** `api/src/__tests__/e2e/admin-users.test.js:137`, `api/src/__tests__/e2e/admin-password.test.js:109, 173`
**重要度:** Low

**該当コード:**

```js
// toBranch 側（変更後）— admin-users.test.js:137-140。**作成経路のみ**
  it('T-9: 許可外キーのマスアサインメントを防ぐ（8 種）', async () => {
    const res = await createUser({          // ← createUser のみ。patchUser 版が無い
      name: '新人', email: 'mass@example.com',
      password: 'InjectedPassword1!',
      role: 'superadmin',
```

```js
// toBranch 側（変更後）— admin-password.test.js:107-111
    const mail = sesMock.commandCalls(SendEmailCommand)[0].args[0].input;
    expect(mail.Subject === undefined);                       // ← マッチャが無く常に pass
    expect(mail.Message.Subject.Data).toBe('[キャンセル請求便] 管理画面のパスワード再設定のご案内');
```

```js
// toBranch 側（変更後）— admin-password.test.js:173-176
    // 境界: 有効期限が「ちょうど今より少し先」なら有効
    await seedWithToken({
      ...
      resetTokenExpiry: new Date(Date.now() + 2000).toISOString(),   // ← 境界ではなく単なる未来
```

**問題:**

1. **更新側のマスアサインメントが未固定。** REQ-2 は作成だけでなく更新にも「許可外キーを一切書き込まない」
   を要求しているが、`PATCH /admin/users/:id` に `role` / `password` / `lastPasswordChange` /
   `resetTokenHash` を混ぜるケースが無い。実装は zod の strip で塞がれているので**現状バグではない**が、
   `adminUserUpdateSchema` に `.passthrough()` が付いたりフィールドが増えたときに気付けない。
2. **T-28 の「境界」が境界になっていない。** テスト名は「有効期限ちょうどは有効」だが、
   値は `Date.now() + 2000` で単なる未来。実装 `new Date(user.resetTokenExpiry) < new Date()` の
   等値分岐（`<` か `<=` か）は一度も通らない。
3. **T-32 が大小文字の片方向だけ**（上の Medium 指摘に記載）。
4. **マッチャの無いアサーション。** `expect(mail.Subject === undefined)` は `expect(true)` を呼んで
   捨てているだけで、`mail.Subject` が何であっても緑。「検証済み」と読める行が増えるだけ。

**修正提案:**
T-9 と対になる PATCH 版を 1 本追加し、`role='superadmin'` / `password` / `lastPasswordChange` /
`resetTokenHash` を送っても DB が変わらないことを固定する。
T-28 はテスト名を実態（「期限内なら有効」）に合わせるか、期限判定を純関数化して
等値ケースを unit で固定する。
`expect(mail.Subject === undefined)` は `expect(mail.Subject).toBeUndefined()` にするか削除する。

---

- [x] 対応する

### [Test Coverage] 新しい Playwright spec だけ「保存」ボタンの locator が未スコープ

**ファイル:** `admin/e2e/admin-users.spec.ts:62, 88, 130`
**重要度:** Low

**該当コード:**

```ts
// toBranch 側（変更後）— admin-users.spec.ts:62 / 88 / 130
    await page.getByRole('button', { name: '保存' }).click();
```

```ts
// 既存 spec はすべてコンテナへスコープ済み（例）
// store-list.spec.ts:46
    await form.getByRole('button', { name: '保存' }).click();
// company-detail-context.spec.ts:164
    await page.getByTestId('salonboard-confirm').getByRole('button', { name: '保存' }).click();
```

**問題:**
既存 spec の「保存」locator 12 箇所はすべて `form.` / `getByTestId(...)` でスコープされているのに、
新規の 3 箇所だけ `page` 直下から取っている。
`.claude/skills/playwright/lesson.md` の「同ラベルのボタンを共有画面に追加したら
未スコープ locator が壊れる」で明文化されているパターン。
`AdminUserForm` のモーダル（`AdminUserForm.tsx:122-124`）に `role="dialog"` も `data-testid` も無く、
**そもそもスコープする手段が無い**のが根因。
現状は画面に「保存」が 1 つしか無いので緑だが、`getByRole` の name は部分一致なので
将来「保存して閉じる」等が増えた時点で strict mode violation になる。

**修正提案:**
モーダル外枠に `data-testid="admin-user-form"`（または `role="dialog" aria-modal="true"`）を付け、
spec 側を `page.getByTestId('admin-user-form').getByRole('button', { name: '保存' })` にする。

---

- [x] 対応する

### [Code Quality] `docs/tech/auth.md` の `requireAdmin` 呼び出し数が実数と合わない（22 → 実測 28）

**ファイル:** `cancel/docs/tech/auth.md:230-232`
**重要度:** Low

**該当コード:**

```md
// toBranch 側（変更後）— docs/tech/auth.md:230-232
`authCheck.error` が undefined = falsy になって認可が丸ごと無効になる**。呼び出しは 22 箇所
（`applications.handler.ts` 6 / `cancellation.service.ts` 6 / `salonboard-auth.service.ts` 9 /
`cancellation-send.service.ts` 1）で、全経路の無認証 401 回帰テストも置いている。
```

**問題:**
括弧内の内訳（6 + 6 + 9 + 1 = 22）は「本 PR で async 化した**既存**の呼び出し」の数で、
本 PR が新設した `admin-users.handler.ts` 4 箇所と `auth.handler.ts` 2 箇所が入っていない。
ブランチ上の実測は **28 箇所**:

```
admin-users.handler.ts:4  applications.handler.ts:6  auth.handler.ts:2
cancellation-send.service.ts:1  cancellation.service.ts:6  salonboard-auth.service.ts:9
```

直後に「全経路の無認証 401 回帰テストも置いている」と続くため、
この節を根拠に将来の認可監査をすると**新規 6 経路を見落とす**。
新規 6 経路自体は T-20 と admin-me の 401 テストでカバー済みなので、テスト不足ではなく記述の問題。

**修正提案:** 「28 箇所（… + `admin-users.handler.ts` 4 / `auth.handler.ts` 2）」に直す。

---

- [x] 対応する

### [Code Quality] 未使用のシンボルが 3 つ残っている

**ファイル:** `api/src/services/admin-auth.service.ts:401`, `api/src/repositories/users.repository.ts:39-44`, `admin/src/types/AdminUser.ts`
**重要度:** Low

**該当コード:**

```ts
// toBranch 側（変更後）— admin-auth.service.ts:401（新規ファイル末尾）
export { ADMIN_ROLE };
```

```ts
// toBranch 側（変更後）— users.repository.ts:39-44
  // 全管理者（status を問わない）。既存の運営通知が使っていた経路をそのまま維持する（GTSS-72 / REQ-8）。
  // 通知の宛先には findActiveAdmins を使うこと。こちらは「role='admin' の全件」が要る用途に残す。
  findAdmins: async () => {
    const rows = await getDb().select().from(users).where(eq(users.role, 'admin'));
    return rows.map(toDomain);
  },
```

**問題:**

1. **`export { ADMIN_ROLE }`（`admin-auth.service.ts:401`）が未使用。**
   このシンボルを `admin-auth.service` から import している箇所は無い
   （利用側は `admin-account.service` から直接取っている）。
   `ADMIN_ROLE` の入手先が 2 つあるように見え、「判定と定数は `admin-account.service` に集約する」
   という本 PR の意図を薄める。
2. **`usersRepo.findAdmins` の本番呼び出し元が 0 件。**
   REQ-8 で通知系 3 箇所がすべて `findActiveAdmins` へ移り、一覧 API は `listAdmins` を使うため、
   コメントが言う「「role='admin' の全件」が要る用途」に該当する呼び出し元は存在しない
   （その用途は実際には `listAdmins` が担っている）。
   放置すると、次に運営通知の宛先を触る人が名前だけを見て `findAdmins` を選び、
   REQ-8（無効化済み管理者へ個人情報を送り続けない）がサイレントに巻き戻る。
3. **`AdminUserStatus` 型が API 境界で使われていない。**
   `types/AdminUser.ts` で定義されているのに `ApiService.updateAdminUser` の `status` は `string`。
   書き込み側だけでも `AdminUserStatus` にすると `'inactve'` のような打ち間違いが tsc で落ちる
   （レスポンス側は DB が text で旧値を持ちうるので `string` のままが妥当）。

**修正提案:** 1 は削除、2 は削除（テスト側のモック定義も同時に）か
コメントを「現在は呼び出し元なし。全件が要る場合は `listAdmins`」に修正、3 は書き込み側の型を締める。

---

- [x] 対応する

### [Code Quality] レガシー行に依存する 3 点は、リリース前に実データを 1 回確認しておきたい

**ファイル:** `api/src/schemas/admin-user.schema.ts:29-30`, `api/src/middleware/auth.ts:58-63`, `admin/src/components/AdminUserForm.tsx:45`
**重要度:** Low（参考。コード修正ではなく事前確認）

**該当コード:**

```ts
// db/schema.ts — status は nullable のまま
    status: text('status'),
```

```ts
// toBranch 側（変更後）— middleware/auth.ts:58-63。壊れた日付は fail-open
export const isTokenIssuedBefore = (decoded: any, changedAt: any): boolean => {
  if (!changedAt) return false;
  const changedAtSec = Math.floor(new Date(changedAt).getTime() / 1000);
  if (!Number.isFinite(changedAtSec)) return false;      // ← パースできない値は失効させない
  return typeof decoded?.iat === 'number' && decoded.iat < changedAtSec;
};
```

**問題:**
いずれもテスト・fixture が必ず正常値を入れるため 1 本も通っていない経路。実データ次第で意味が変わる。

1. **`users.status` が NULL / 想定外値のレガシー行。**
   移行スクリプトは値を素通しする（`scripts/migrate-dynamodb-to-aurora.ts:242` の `status: item.status ?? null`）。
   該当行があると、一覧のバッジが**空文字**になり（`adminUserStatusLabel` が `''` を返す）、
   編集モーダルはセレクトを `active` で初期化するので**氏名だけ直して保存すると `active` へ昇格**する。
   さらに REQ-8 の変更でその行は `findActiveAdmins` から外れ、**運営通知の宛先から静かに落ちる**
   （base の `findAdmins` は status を見ずに送っていた）。
   なお `adminLogin` は従来から `status !== 'active'` を弾いていたので**締め出しの回帰は無い**。
2. **`users.last_password_change` の値形式。**
   同じく移行が `item.lastPasswordChange ?? null` を無検証でコピーする。
   ISO としてパースできない値が入っていると `Number.isFinite` が false になり、
   その管理者だけ**失効判定が静かに無効化**される（fail-open）。
3. **無効化と同一秒に発行されたトークンは失効しない。**
   `isTokenIssuedBefore` は秒切り捨て + `<`（同一秒は有効）なので、無効化と同じ秒に発行済みの
   トークンは失効しない。無効化中は `status` チェックで 401 になるが、**再有効化すると exp まで復活する**。
   `docs/product/admin-users.md` の「再有効化しても旧セッションは復活せず」と
   `admin-user.service.ts:191-192` の「恒久的に失効」はこの 1 秒だけ成立しない。

**修正提案:**
コード変更は必須ではない。リリース前に本番で 2 本流して確認する:

```sql
SELECT status, count(*) FROM users WHERE role = 'admin' GROUP BY 1;
SELECT id, last_password_change FROM users WHERE last_password_change IS NOT NULL;
```

前者が `active` / `inactive` のみ、後者が ISO8601 のみなら 1・2 は何もしなくてよい。
3 は docs に「同一秒に発行されたトークンは例外」と 1 行足すか、
恒久失効が要件なら session_version 方式へ（本 PR の範囲外で可）。

## 総評

**設計・実装・テスト・ドキュメントの完成度は高い。** REQ-1〜REQ-15 が 3 点セットで揃っており、
以下は 3 者のレビューを突き合わせたうえで**正しく実装されていることを確認した**。

- **認可の即時失効（REQ-7）**: `requireAdmin` の DB 検証化。`role` クレームの 403 は DB 到達前に判定され
  （`middleware/auth.ts:122`）、`getCancellation` のサロン側ホットパスに往復が増えないことを
  unit テストが spy で固定している。呼び出し **28 箇所すべてが `await` 済み**（grep で確認）。
  戻り値型 `AuthGuardResult` を判別可能ユニオンにして `await` 付け忘れを型検査で落とす設計は、
  `strict:false` の tsconfig 下での対処として的確。
- **トークンの 1 回消費（REQ-5）**: `consumeResetToken` は「ダイジェスト一致行のみ」を WHERE に持つ
  単一 UPDATE で**正しく原子的**。同一行への競合なので最上位の指摘のような write skew は起きない。
  読み取り後に対象が無効化された場合も、無効化がトークンを NULL 化するため 0 行になり安全側に倒れる。
- **状態判定の集約**: `isActiveAdmin` / `findActiveAdmin` へ 6 経路が集約され、手コピーの残りは無い。
- **レスポンス露出**: 管理者行を外へ出すのは `toAdminUserResponse` と `toAdminSessionUser` の 2 本だけで、
  `password` / `resetTokenHash` / `resetTokenExpiry` / `lastPasswordChange` はどちらにも含まれない。
  3 経路のキー集合一致も `Object.keys().sort()` で固定されている。
- **マスアサインメント**: create は `{name,email}`、update は `{name?,email?,status?}` のみ。
  `role` / `status` / `password` はサーバー固定。
- **列挙対策（REQ-4）**: 不在・非 admin・inactive・サロンユーザー・不正 JSON・SES 例外のすべてで
  200 と同一本文。画面側も本文で分岐していない。
  応答時間差による列挙が残る点は `docs/tech/auth.md:243` に既知の残課題として明記済み（新規指摘ではない）。
- **マイグレーション 0027**: 追加列は nullable で既存行に影響なし。
  `last_password_change` が NULL の既存管理者はデプロイでログアウトされない（T-54 が固定）。rollback も対称。
- **公開ルートの分離（技術的考慮 12）**: 期限切れトークンが残っていてもパスワード設定リンクを開ける。

### 最重要

**最上位の指摘（write skew）だけは、マージ前に直すか、リスクとドキュメントの記述を明示的に整理する判断が要る。**
技術的考慮 9 の「単一ステートメントなので追加のロックは不要」という前提が誤っており、
AC-1.11 と docs の明文の保証が実際には満たされていない。
テスト用 Postgres での実測で **200 回中 101 回、有効な管理者が 0 人になった**。
既存の T-19 は再現すれば落ちる書き方になっているが、テストハーネス（単一 Node イベントループ）が
2 リクエストを事実上直列化するため 40 回中 0 回しか再現せず、現実的には検出できない。
修正案（CTE + `FOR UPDATE`）は同条件で 0/200 を確認済み。

残る Medium 4 件はいずれも「片側だけ実装が揃っていない」型で、
サーバー側のガードは効いているため即時のセキュリティホールではないが、
**サイレントに機能しなくなる / 利用者に意味不明な英語が出る**性質なので直す価値がある。

### レビュー体制と結果の信頼性

3 つのサブエージェント（code-reviewer / lessons-reviewer / codex-reviewer）すべてから結果を受領し、
**指摘はメインエージェントが差分・実装・SDK・テストを読み直して裏取りしたものだけを採用した。**

- **実験による確定**: write skew は 3 者のうち 2 者が指摘し、かつ**主張が PR 自身の設計判断と真っ向から
  対立する**ため、テスト用 Postgres で SQL を直接叩いて再現実験を行い確定させた。
  最初の実験は `users` に既存の admin 行が残っていて `EXISTS` が常に真になる汚染があったため、
  `DELETE FROM users` してからやり直している。
- **SDK を読んで確定**: drizzle-orm 0.45 の `DrizzleQueryError` が message に SQL とバインド値を
  連結すること（`node_modules/drizzle-orm/errors.js`）、その throw が `pg-core/session.js` の 6 箇所
  ＝ `node-postgres` と `aws-data-api/pg` の共通層にあること、
  Sentry Replay が `createReplayEnvelope` で `beforeSend` とは別経路を通ることを、
  いずれも実ファイルで確認した。
- **採用しなかった主張**:
  - code-reviewer の「編集で正規化された後は忘れた導線でも救済されず**完全ロックアウト**」。
    正規化後は保存値が小文字なので忘れた導線は機能する。実態に合わせて
    「本人には理由が分からないログイン失敗」として記載した。
  - codex-reviewer の「T-19 は write skew 時に落ちる方向なので静かに緑になる類ではない」。
    落ちる**書き方**であるのは事実だが、実測で 40 回中 0 回しか再現しないため
    「現実的には検出できない」と記載した。
  - codex-reviewer の指摘 12（応答時間差による列挙）は `docs/tech/auth.md:243` に
    既知の残課題として既に明記されているため、新規指摘としては採用していない。
- **重要度の相違**: write skew を codex-reviewer は Medium（`upsert-admin-user.ts` で復旧可能なため）、
  code-reviewer は Medium、Codex 本体は High と評価した。
  本レビューは **High** とした。復旧可能なのは事実だが、
  (1) AC-1.11 と docs の明文の保証が満たされていない、
  (2) 復旧に本番 DB 接続が要り、本 PR がまさに解消しようとした運用に戻る、
  ためリリース前に判断を明示すべき事項と考える。発生確率が低いことは本文に併記した。
- **codex-reviewer の運用上の注意（次回への申し送り）**: codex が参照した作業ディレクトリ
  `/Users/aki/cancel/cancel-billing-service-api` には無関係なブランチが checkout されており
  （対象ブランチは worktree 側にあるため元ディレクトリを切り替えられない）、
  codex の探索途中では `requireAdmin` を**改修前の実装**として読んでいた形跡がある。
  最終結果はエージェント側が `origin/feature/GTSS-72` で再検証して補正しており、
  本レビューでもメイン側で全件裏取りしたうえで採用している。
  次回は codex-reviewer に `repoDir` として **worktree の絶対パス**を渡すこと。
- api / admin の自動テストはブランチ上で実際に実行し、全件グリーンを確認済み（冒頭の表）。

### リリース時の残作業

- 人力テスト M-1〜M-5（dev での実メール受信 → リンク → ログイン、既存パスワード維持の確認など）が未消化。
- 本番データの事前確認 3 本（最後の指摘に記載）:
  - `SELECT status, count(*) FROM users WHERE role='admin' GROUP BY 1;`
  - `SELECT id, last_password_change FROM users WHERE last_password_change IS NOT NULL;`
  - 大文字を含む admin の `email` が無いこと（技術的考慮 8 のチェックに追加）。
- デプロイ順序は **API → 管理画面**（`admin-me` 未デプロイ時の 404 を管理画面が保持情報で吸収する設計）。
