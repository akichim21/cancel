---
issue: 43
date: 2026-07-25
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: develop
    toBranch: GTSS-852
  - repo: user
    repoDir: cancel-billing-service
    baseBranch: develop
    toBranch: GTSS-852
---

# レビュー結果: #43

## 概要

**Issue:** #43 [GTSS-852] 初回ログイン時のパスワード変更フロー改善: 再ログイン廃止 + 完了バナー（変更APIのトークン再発行・発行条件の厳格化 / 失敗時エラー文言の是正を含む）

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `develop` | `GTSS-852` | 1 | 3 |
| user | `develop` | `GTSS-852` | 1 | 24 |

差分は三点リーダ diff（`origin/develop...origin/GTSS-852`）で取得。レビュー中に `origin/develop` が
`3fb3d3c` → `fc6eaf5`（GTSS-851 のマージ）へ進んだが、merge-base 基準のため本 PR の差分内容は不変。

### テスト実行結果（レビュー時に実際に実行）

| 対象 | コマンド | 結果 |
|---|---|---|
| user portal ユニット | `npm test`（typecheck + vitest） | **17 files / 187 tests すべて green** |
| user portal E2E（フル） | `npx playwright test` | **26 tests すべて green**（setup + login 12 + chromium 13。新規 GTSS-852 分 8 件を含む） |
| api E2E | `npx vitest run src/__tests__/e2e/auth.test.js src/__tests__/e2e/response-contract.test.js` | **56 tests すべて green** |

> api E2E は初回実行時に多数の失敗が出たが、原因は**別 worktree（GTSS-850）で並行実行されていた `npm test` が
> 同名の Docker コンテナ（`cancel-billing-api-test-postgres-test-1`）を共有して `truncateAll()` / `db:test:down` と
> 衝突していたため**。並行実行が終わった状態でコンテナを作り直して再実行すると 56/56 green。
> base（`fc6eaf5`）でも 3 回連続 green で、本 PR に起因する不安定さではないことを確認済み。

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/services/auth.service.ts` | +95 | -23 | Modified |
| `src/__tests__/e2e/auth.test.js` | +183 | -0 | Modified |
| `src/__tests__/e2e/response-contract.test.js` | +35 | -0 | Modified |

### user

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/contexts/FlashContext.tsx` | +79 | -0 | Added |
| `src/components/SuccessBanner.tsx` | +49 | -0 | Added |
| `src/__tests__/PasswordChangeFlow.test.tsx` | +191 | -0 | Added |
| `src/contexts/__tests__/FlashContext.test.tsx` | +144 | -0 | Added |
| `src/components/__tests__/SuccessBanner.test.tsx` | +64 | -0 | Added |
| `src/contexts/AuthContext.tsx` | +25 | -0 | Modified |
| `src/components/ChangePasswordPage.tsx` | +38 | -4 | Modified |
| `src/components/LoginPage.tsx` | +11 | -1 | Modified |
| `src/services/api.ts` | +34 | -5 | Modified |
| `src/App.tsx` | +14 | -5 | Modified |
| `src/types/index.ts` | +9 | -0 | Modified |
| `src/test/utils.tsx` | +13 | -6 | Modified |
| `e2e/auth.spec.ts` | +154 | -2 | Modified |
| `e2e/fixtures.ts` | +52 | -1 | Modified |
| `e2e/helpers/auth.ts` | +43 | -0 | Modified |
| `src/services/__tests__/api.test.ts` | +103 | -0 | Modified |
| `src/components/__tests__/ChangePasswordPage.test.tsx` | +85 | -14 | Modified |
| `src/contexts/__tests__/AuthContext.test.tsx` | +71 | -1 | Modified |
| `src/components/__tests__/LoginPage.test.tsx` | +29 | -1 | Modified |
| `src/__tests__/ProtectedRoute.test.tsx` | +5 | -1 | Modified |
| `src/components/__tests__/{Dashboard,InvoiceForm,SettingsPage,StoreManagement}.test.tsx` | +4 | -0 | Modified |

## 指摘一覧

- [x] 対応する

### [Security] パスワード変更後も変更前に発行された JWT が失効しない

**ファイル:** `api/src/services/auth.service.ts:359-377`
**重要度:** Medium（本 Issue のスコープ外。フォローアップ Issue を推奨）

**該当コード:**

```typescript
// developBranch側（変更前）— トークンを一切発行していなかった
    const hashedNewPassword = hashPassword(newPassword);
    await applicationUsersRepo.update(decodedToken.sub, {
      password: hashedNewPassword,
      mustChangePassword: false,
      updatedAt: new Date().toISOString()
    });

    return {
      statusCode: 200,
      headers: corsHeaders,
      body: JSON.stringify({
        success: true,
        message: 'パスワードが正常に変更されました'
      })
    };
```

```typescript
// GTSS-852側（変更後）— 新トークンを発行するが、旧トークンの無効化は行わない
    const hashedNewPassword = hashPassword(newPassword);
    const updatedAppUser = await applicationUsersRepo.update(decodedToken.sub, {
      password: hashedNewPassword,
      mustChangePassword: false,
      updatedAt: new Date().toISOString()
    });

    // 変更時点から有効期限を取り直した新トークンと、更新後のユーザー情報を返す。
    // 発行対象は常にトークンの持ち主自身（decodedToken.sub の application_user）に限る。
    return {
      statusCode: 200,
      headers: corsHeaders,
      body: JSON.stringify({
        success: true,
        message: 'パスワードが正常に変更されました',
        data: {
          token: signSalonToken(updatedAppUser, jwtSecret),
          user: buildSalonUserData(updatedAppUser, application)
        }
      })
    };
```

**問題:**
新トークンの発行は仕様どおりだが、**変更前に発行済みのトークンは失効しない**。`src/middleware/auth.ts:16-27`
の `verifyToken` は署名と `exp` しか見ておらず、失効の仕組み（denylist / `tokenVersion` / `password_changed_at`
と `iat` の突き合わせ）はコードベースに存在しない（`grep` で確認済み）。

このフローは**仮パスワードをメールで配布する**運用が前提のため、影響が机上の話に留まらない。仮パスワードが
第三者に渡り先にログインされていた場合、正規のサロンがパスワードを変更しても**第三者のトークンは最大 24 時間
有効なまま**で、締め出せない。一般的なパスワード変更は他セッションを無効化する挙動が期待される。

なお REQ-1 は「このエンドポイントをトークン発行口にしない」ために 403 の状態検証を追加しており、その
セキュリティ意図とは整合しない残件である。**本 Issue の受入条件は満たしているため本 PR のブロッカーにはしない。**

**修正提案:**
本 PR では対応せず、フォローアップ Issue を起票する。`application_users` に `password_changed_at`（または
`token_version`）を持たせ、`verifyToken` / `requireAuth` で `decoded.iat < password_changed_at` のトークンを
拒否する方式が最小。**#41（パスワードハッシュを scrypt/argon2 へ移行）が同じ `changePassword` を触るため、
そこに相乗りするのが効率的。**

---

### [Documentation] Issue が更新必須とした docs 3 点が未コミットのまま、無関係ブランチに混在している

**ファイル:** 親リポジトリ `docs/tech/auth.md` / `docs/product/application-flow.md` / `docs/cancel-billing-service/README.md`
**重要度:** Medium

**該当コード:**

```
# 変更前（HEAD）: docs/product/application-flow.md L99-104
- 入口: `https://user.cancel.co.jp/`（`cancel-billing-service`）
- 初回ログイン: 申請メールアドレス + 初期パスワード（運営メール記載）
- ログイン後: JWT を localStorage に保存（有効期限 24 時間）
- 初期パスワード変更を推奨（`ChangePasswordPage.tsx`）
```

```
# 変更後（作業ツリー・未コミット）
- ログイン後: JWT を localStorage に保存（有効期限 24 時間）
- **初期パスワード変更は必須**（推奨ではない）。`application_users.must_change_password = true` の間は
  `ProtectedRoute` が `/change-password`（`ChangePasswordPage.tsx`）へ強制遷移させ、他の保護画面には入れない
- **変更成功後は再ログイン不要**（GTSS-852 / #43）。API が新しい JWT と更新後ユーザー情報を返し、
  ポータルはログイン状態を保ったまま**ダッシュボードへ着地**し、上部に「パスワードを変更しました」完了バナーを
  8 秒間表示する（×で即座に閉じられる）。ログイン後の自発的な変更では遷移せず変更画面に留まり、同じバナーを出す。
```

**問題:**
Issue の「前提条件 / 関連ドキュメント」表が **`docs/tech/auth.md` / `docs/product/application-flow.md` /
`docs/cancel-billing-service/README.md` の 3 点を「本 Issue で更新が必要」と明記**している。**内容は 3 点とも
正確に書かれている**（auth.md はトークン再発行・403 検証・`requireAuth` を付けない理由・localStorage キーの
誤記修正まで網羅、README は FlashContext / SuccessBanner / Provider ネスト順まで記載）。

問題は置き場所である。これらは `akichim21/cancel` の**作業ツリーに未コミット**で、しかも無関係な作業ブランチ
`GTSS-817-store` 上に `docs/tech/batch-fargate.md` などの別件変更と混在している。GTSS-852 の PR には含まれない
ため、レビュー対象にもリリース単位にも乗らず、失われるリスクがある。

（実際、本レビュー中の git 操作でこの作業ツリーの未コミット変更が一度消えかけた。復旧できたが、未コミットで
置いておくこと自体がリスクであることの実例。）

**修正提案:**
親リポジトリで GTSS-852 用のコミットを分けて作る。他ブランチの変更を巻き込まないよう対象ファイルを明示する:

```bash
cd ~/cancel
git add docs/tech/auth.md docs/product/application-flow.md docs/cancel-billing-service/README.md
git commit -m "docs(GTSS-852): パスワード変更後の再ログイン廃止・完了バナー・トークン再発行の仕様を反映"
```

---

### [Security] `makeRequest` の console.log がログイン JWT を出力し、Sentry の console breadcrumb で外部送信され得る

**ファイル:** `user/src/services/api.ts:40`
**重要度:** Low（既存の問題。本 PR は同経路を改善している側）

**該当コード:**

```typescript
// 変更前・変更後とも同一（makeRequest 内。本 PR では未変更）
      if (!response.ok) {
        const errorText = await response.text();
        console.error(`[ApiService] HTTP error: ${response.status} - ${errorText}`);
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }

      const result = await response.json();
      console.log(`[ApiService] Response data:`, result);   // ← login のレスポンス = JWT を含む
      return result;
```

```typescript
// GTSS-852 で追加された changePassword は makeRequest を経由せず、レスポンスをログ出力しない（改善）
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        const isClientError = response.status >= 400 && response.status < 500;
        return {
          success: false,
          error: isClientError && body?.error ? body.error : 'パスワード変更に失敗しました',
        };
      }
      return body;
```

**問題:**
`login()` は `makeRequest` を通るため、**発行された JWT がそのままブラウザコンソールへ出力される**。
GTSS-858 で導入された Sentry（`src/instrument.ts`）は `beforeBreadcrumb` を設定しておらず、**Sentry ブラウザ
SDK は console breadcrumb を既定で有効にする**ため、エラー送信時にこの JWT がイベントに添付されて Sentry へ
送られ得る。Replay の `maskAllText` は DOM テキストのマスクであり、breadcrumb には効かない。

本 PR で追加された `changePassword` は `makeRequest` を通さずレスポンスをログしないため、**新トークンは
この経路に載らない**。つまり本 PR が作った問題ではなく、むしろ改善側である。ただし本 Issue がトークンの
取り扱いを厳格化した文脈なので、既存分も併せて潰す価値がある。

**修正提案:**
本 PR のスコープ外としてフォローアップ。最小対応は `makeRequest` のレスポンス全文ログを削除するか、
`instrument.ts` に `beforeBreadcrumb` を足して `category === 'console'` を落とす。

---

### [Code Quality] `makeRequest` のエラー本文握り潰しは他エンドポイントに残ったまま（3 例目の個別バイパス）

**ファイル:** `user/src/services/api.ts:168-190`
**重要度:** Low

**該当コード:**

```typescript
// develop側（変更前）
  async changePassword(currentPassword: string, newPassword: string, confirmPassword: string): Promise<ApiResponse<void>> {
    return this.makeRequest('/auth/change-password', {
      method: 'POST',
      body: JSON.stringify({ currentPassword, newPassword, confirmPassword }),
    });
  }
```

```typescript
// GTSS-852側（変更後）— makeRequest を通さず自前 fetch し、400 番台のみサーバ文言を透過
    try {
      const response = await fetch(`${API_BASE_URL}/auth/change-password`, {
        method: 'POST',
        headers: this.getAuthHeaders(),
        body: JSON.stringify({ currentPassword, newPassword, confirmPassword }),
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        const isClientError = response.status >= 400 && response.status < 500;
        return {
          success: false,
          error: isClientError && body?.error ? body.error : 'パスワード変更に失敗しました',
        };
      }
      return body;
    } catch {
      return { success: false, error: 'パスワード変更に失敗しました' };
    }
```

**問題:**
実装は REQ-6 の指示（「パスワード変更の呼び出しに限り」「`importCancellations` の先例に倣う」「500 番台と
ネットワークエラーは汎用文言」）に**正確に従っており、それ自体は正しい**。単体テストも 400/401/403/500/
ネットワーク/`error` 欠落の 6 パターンを押さえている。

ただし根本原因である「`makeRequest` が非 2xx のレスポンス本文を読み捨て、`HTTP <status>: <statusText>` に
潰す」は他の全エンドポイントに残る。これで `makeRequest` を迂回する個別実装は `importCancellations`・
`changePassword` の **2 例**になり、今後も「日本語文言を出したい」たびに複製が増える形になっている。

**修正提案:**
本 PR では現状のままでよい（REQ-6 がスコープを限定しているため）。フォローアップで `makeRequest` に
`passthroughClientError?: boolean` のようなオプションを設け、2 箇所の個別実装を集約することを推奨。

---

### [Lessons] 共有レイアウトに「閉じる」ボタンを追加したため、未スコープの e2e locator が将来壊れる

**ファイル:** `user/src/components/SuccessBanner.tsx:39` / `user/src/App.tsx:47`
**重要度:** Low（現時点では壊れない潜在バグ）

**出典 lesson:** `.claude/skills/playwright/lesson.md`
「同ラベルのボタンを共有画面に追加したら他スペックの未スコープ locator を壊す → container スコープ + フル e2e（必須）」

**該当コード:**

```tsx
// GTSS-852側（変更後）— ProtectedRoute の共有レイアウトに描画される
        <button
          type="button"
          onClick={clearFlash}
          aria-label="閉じる"
          className="flex-shrink-0 text-green-700 hover:text-green-900 rounded focus:outline-none focus:ring-2 focus:ring-green-500"
        >
          <XMarkIcon className="h-5 w-5" aria-hidden="true" />
        </button>
```

```typescript
// 既存の未スコープ locator（変更前から存在・本 PR では未変更）
// e2e/invoice.spec.ts:64 / e2e/invoice-store.spec.ts:43
  await page.getByRole('button', { name: '閉じる' }).click();
```

**問題:**
`aria-label="閉じる"` を持つバナーの閉じるボタンが `App.tsx:47` で **ProtectedRoute の共有レイアウト（全保護画面）**
に描画されるようになった。ポータルには同名ボタンが既に 2 つある（`InvoiceForm.tsx:699` / `InvoiceList.tsx:882`、
いずれもモーダルのフッター）。

**現時点では壊れない**ことを裏取り済み: バナーは `flash` が非 null の間だけ描画され、本番コードで `showFlash` を
呼ぶのは `ChangePasswordPage.tsx:62` のみ。invoice 系 spec は `playwright.config.ts:26-37` の `chromium`
プロジェクト（storageState 再利用）で走るためパスワード変更を通らず、バナーは出ない。実際にフル spec を実行
しても現状は緑。

将来 flash を他の画面（請求書送信完了など）で使った瞬間に、`invoice.spec.ts` / `invoice-store.spec.ts` の
未スコープ locator が strict mode violation で落ちる。lesson が記録しているのはまさにこの壊れ方である。

なお lesson が必須としている**フル e2e スイートの実行**はレビュー時に実施済み（`npx playwright test` で
26 tests すべて green。invoice / invoice-store / invoice-board / stores を含む）。現時点での回帰は無い。

**修正提案:**
バナー側に `data-testid="flash-close"` を付けてテストからはそれで掴む。あるいは既存 2 箇所を
`page.getByRole('dialog').getByRole('button', { name: '閉じる' })` にスコープする（後者は既存 spec の修正に
なるため、前者のほうが本 PR の変更範囲に収まる）。

---

### [Lessons] 値が確定しているのに型だけを検証している

**ファイル:** `api/src/__tests__/e2e/auth.test.js:433`
**重要度:** Low

**出典 lesson:** `.claude/skills/vitest/lesson.md`
「`expect.any(...)` / `toBeDefined` は使わない（必須）— 値がわかるなら `.toBe()`」

**該当コード:**

```javascript
// GTSS-852側（変更後）— seedSalonUser で createdAt を固定しているのに型しか見ていない
      expect(body.data.user).toMatchObject({
        id: applicationUserId,
        applicationId,
        email: 'x@y.com',
        businessName: 'サロンA社',   // applications.partnerName 由来
        isActive: true,              // applications.status 由来
        mustChangePassword: false,   // 更新後の値
      });
      expect(typeof body.data.user.createdAt).toBe('string');
      expect(typeof body.data.user.updatedAt).toBe('string');
```

**問題:**
同じ差分の `seedSalonUser`（同ファイル :51）が `createdAt: over.createdAt ?? '2026-01-01T00:00:00.000Z'` を
固定しており、コメントにも「レスポンスの `createdAt` 契約検証で必要」と書かれている。
`application_users.created_at` は `text` 列（`src/db/schema.ts:133`、DB デフォルト無し）なので値がそのまま
往復する。具体値で assert できるのに型検証に留めているため、値が化けても検知できない。

なお同 :434 の `updatedAt` はサーバ生成（`new Date().toISOString()`）のため、型検証のままで妥当。

**修正提案:**

```javascript
expect(body.data.user.createdAt).toBe('2026-01-01T00:00:00.000Z');
expect(typeof body.data.user.updatedAt).toBe('string');  // これは据え置き
```

---

### [Accessibility] 完了バナーの live region を要素ごと条件描画しており、REQ-4 の読み上げ要件を満たさない可能性

**ファイル:** `user/src/components/SuccessBanner.tsx:15-21`
**重要度:** Medium

**該当コード:**

```tsx
// GTSS-852側（変更後）— flash が無い間は role="status" の要素自体が DOM に存在しない
const SuccessBanner: React.FC = () => {
  const { flash, clearFlash } = useFlash();

  if (!flash) return null;

  return (
    <div
      role="status"
      aria-live="polite"
      className="bg-green-50 border-b border-green-200"
    >
```

**問題:**
`aria-live` リージョンは「**先に DOM に存在していて、その中身が後から変化する**」ときに確実にアナウンスされる。
中身が入った状態のリージョンを丸ごと新規挿入する形は、スクリーンリーダーの実装によって読み上げられないことが
ある（よく知られた live region の落とし穴）。

初回変更フローでは `showFlash`（`ChangePasswordPage.tsx:62`）と `navigate('/')` が同一コミットにバッチされ、
遷移先の `ProtectedRoute` レイアウト上に**中身入りのバナーが新規挿入される**ため、必ずこのパターンになる。

Issue の REQ-4 は「支援技術に成功が伝わるよう、バナーはステータス領域として読み上げ対象にする」と明記して
おり、`role="status"` を付けた意図は読み上げそのものである。属性は付いているが目的を達成できない可能性が
残る。

**修正提案:**
`role="status" aria-live="polite"` のラッパーを常時描画し、内側だけ `flash` の有無で出し分ける（非表示時は
中身が空なので視覚的な影響なし）。テスト側は `getByRole('status')` の「非表示時は不在」という前提が変わる
ため、`SuccessBanner.test.tsx:34`（T-21）と e2e の `toHaveCount(0)` 系を「空であること」の検証へ調整する。

---

### [Code Quality] `applicationUsersRepo.update()` の `null` を受けずにトークンを署名している

**ファイル:** `api/src/services/auth.service.ts:359-375`（repo 側は `src/repositories/application-users.repository.ts:84-93`）
**重要度:** Low（競合時のみ・データ不整合は起きない）

**該当コード:**

```typescript
// repository — 0 行なら null を返す
const first = (rows: any[]) => (rows.length > 0 ? toDomain(rows[0]) : null);
  update: async (id: string, patch: Record<string, any>) => {
    const set = toRow(patch);
    if (Object.keys(set).length === 0) return applicationUsersRepo.getById(id);
    const rows = await getDb().update(applicationUsers).set(set)
      .where(eq(applicationUsers.id, id)).returning();
    return first(rows);
  },
```

```typescript
// GTSS-852側（変更後）— null チェック無しで参照している
    const updatedAppUser = await applicationUsersRepo.update(decodedToken.sub, {
      password: hashedNewPassword,
      mustChangePassword: false,
      updatedAt: new Date().toISOString()
    });

    return {
      statusCode: 200,
      /* ... */
        data: {
          token: signSalonToken(updatedAppUser, jwtSecret),   // ← null なら TypeError
          user: buildSalonUserData(updatedAppUser, application)
        }
```

**問題:**
`getById`（:315）と `update`（:359）の間に対象行が消える競合（申請の論理削除は `application_users` を物理削除する）
が起きると `update` が `null` を返し、`signSalonToken(null, ...)` が TypeError を投げて catch に落ち、
**500「パスワード変更処理でエラーが発生しました」**になる。UPDATE は 0 行なのでデータ不整合は起きず実害は
小さいが、本来は 403/404 で返すべき状況が 500 になる。`update` の戻り値を使うのは今回が初めてなので、
この分岐は新設された経路である。

**修正提案:**
`update` 直後にガードを 1 行入れる。すでに定義済みの `inactiveResponse` を再利用すれば分岐は増えない。

```typescript
if (!updatedAppUser) return inactiveResponse;   // 行が消えている = 有効でない
```

---

### [Code Quality] `JWT_SECRET` 未設定時の 500 分岐が到達不能

**ファイル:** `api/src/services/auth.service.ts:347-355`
**重要度:** Low

**該当コード:**

```typescript
// GTSS-852側（変更後）— login からコピーされた防御だが、ここには到達しない
    const jwtSecret = process.env.JWT_SECRET;
    if (!jwtSecret) {
      console.error('JWT_SECRET not configured');
      return {
        statusCode: 500,
        headers: corsHeaders,
        body: JSON.stringify({ success: false, error: 'サーバー設定エラー' })
      };
    }
```

```typescript
// 先に通過する verifyToken（src/middleware/auth.ts:16-27）が JWT_SECRET 未設定なら null を返す
export const verifyToken = (token: any): any => {
  try {
    const jwtSecret = process.env.JWT_SECRET;
    if (!jwtSecret) {
      throw new Error('JWT_SECRET not configured');
    }
    return jwt.verify(token, jwtSecret);
  } catch (error) {
    console.error('Token verification failed:', error.message);
    return null;
  }
};
```

**問題:**
`changePassword` は先頭で `verifyToken(token)` を通す（:279）。`JWT_SECRET` が未設定ならそこで `null` が
返り **401「トークンが無効です」**で抜けるため、後段のこの 500 分岐には決して到達しない。`login` には前段の
`verifyToken` が無いので同じ分岐が生きており、対称性としてコピーされたものと思われる。テストで到達できず、
カバレッジ上の死にコードになる。

**修正提案:**
削除するか、残すなら 1 行コメントを添える（例: `// login との対称性のため残置。verifyToken 通過後なので実際には到達しない`）。

---

### [Test Coverage] リクエストボディで対象ユーザーを指定できないことの回帰テストが無い

**ファイル:** `api/src/__tests__/e2e/auth.test.js:487`（T-6）
**重要度:** Low

**問題:**
REQ-1 は「変更対象は常にトークンの `sub` が指すユーザー自身のみとし、リクエストボディで対象ユーザーを指定する
余地を設けない」と明記している。実装は `const { currentPassword, newPassword, confirmPassword } = body;`
（`auth.service.ts:289`）の明示 destructure なので現状は安全だが、**この性質を固定するテストが無い**。
将来 body を repo へ素通しするリファクタが入っても検知できない。

**修正提案:**
新規テストは不要。既存 T-6 のリクエストボディに無関係なキーを混ぜ、無視されることを固定する。

```javascript
body: JSON.stringify({
  currentPassword: 'oldpw1234567', newPassword: 'newpw1234567', confirmPassword: 'newpw1234567',
  // 以下は無視されること（マスアサインメント防止の回帰）
  email: 'other@x.com', applicationId: 'other_app', userId: 'someone-else', mustChangePassword: true,
}),
```

---

### [Test Coverage] e2e mock の `/auth/me` が実 API に存在しないフィールドを返しており、T-27 の検証が見かけより弱い

**ファイル:** `user/e2e/fixtures.ts:55-57`
**重要度:** Low

**該当コード:**

```typescript
// e2e mock — user をまるごと返すため mustChangePassword も含まれる
  await page.route('**/auth/me', (route) =>
    route.fulfill({ json: { success: true, data: { ...user, tRegistrationNumber } } })
  );
```

```typescript
// 実 API（api/src/services/auth.service.ts:218-227 getMe）— 4 項目のみ。mustChangePassword は返さない
      data: {
        applicationId,
        email: application.email,
        businessName: application.partnerName,
        tRegistrationNumber: application.tRegistrationNumber || null
      }
```

**問題:**
T-27（変更後にリロードしても `/change-password` へ戻されない）で mock の `/auth/me` は `MUST_CHANGE_USER` を
そのまま返すため **`mustChangePassword: true`** を含む。実 API の `getMe` はこのフィールドを返さないので、
mock のほうが実物より「情報が多い」状態になっている。

T-27 が green なのは `AuthContext.tsx:47` が `/auth/me` から `tRegistrationNumber` しか採用せず、それ以外を
捨てているため。テスト自体は正しい振る舞いを見ているが、**mock が実 API と乖離しているぶん、意図を読み違えた
実装変更（例: `/auth/me` の応答で user 全体を上書きするリファクタ）を検知できない**。

**修正提案:**
mock を実 `getMe` と同じ 4 項目（`applicationId` / `email` / `businessName` / `tRegistrationNumber`）に絞る。
これで「`/auth/me` は `mustChangePassword` を返さない」という前提がテスト側にも明示され、上記のリファクタが
入れば T-27 が落ちるようになる。

---

### [Security] パスワード変更の「もう一つの経路」である `resetPassword` には同等の状態検証が無い

**ファイル:** `api/src/services/auth.service.ts`（`resetPassword` / `forgotPassword`）
**重要度:** Low（バイパスではない。フォローアップ推奨）

**問題:**
本 PR は `/auth/change-password` に login 同等の状態検証（appUser active / application 実在・未削除・ACTIVE）を
入れたが、**パスワードを変更できるもう一つの経路である `resetPassword` には状態検証が無い**。`forgotPassword`
も `application.status === ACTIVE` だけを見ており、`deletedAt` と `appUser.status` を見ていない。

結果として、凍結された `application_user` は change-password では 403 になるのに、リセットメール経由では
パスワードを変更できる。**セキュリティバイパスではない**（reset は JWT を発行せず、変更後も `login` が 403 で
止める）が、「パスワード変更経路の状態検証」は半分しか閉じていない状態になる。

**修正提案:**
本 PR のスコープ外。別 Issue で `resetPassword` / `forgotPassword` にも同じ 3 条件を入れて揃える。
`signSalonToken` と同様に検証部分も共通関数へ抽出すると、経路が増えたときの取りこぼしを防げる。

---

### [Codex] 変更 API の応答待ち中にログアウトすると、成功応答がセッションを復活させる

**ファイル:** `user/src/components/ChangePasswordPage.tsx:41-62` / `user/src/contexts/AuthContext.tsx:103-109`
**重要度:** Medium

**該当コード:**

```tsx
// GTSS-852側（変更後）— await の後、セッションがまだ有効かを確認せずに差し替える
      const result = await apiService.changePassword(currentPassword, newPassword, confirmPassword);
      if (result.success) {
        const token = result.data?.token;
        const nextUser = result.data?.user;
        /* ... 旧仕様フォールバック ... */
        replaceSession(token, nextUser);
        showFlash(FLASH_TITLE, FLASH_DESCRIPTION);
```

```typescript
// AuthContext.tsx — localStorage が空でも、クロージャの user へフォールバックして復元してしまう
  const replaceSession = (token: string, nextUser: User) => {
    const stored = JSON.parse(localStorage.getItem('user') || 'null') ?? user ?? {};
    const merged = { ...stored, ...nextUser } as User;
    setUser(merged);
    localStorage.setItem('auth_token', token);
    localStorage.setItem('user', JSON.stringify(merged));
  };
```

**問題:**
`Header` は `ProtectedRoute` 経由で `/change-password` にも表示され、ログアウトボタンが押せる
（`Header.tsx:44` / `:194`）。変更 API の応答待ち中にログアウトすると、以下が起きることを追跡して確認した:

1. `logout()` → `setUser(null)` + localStorage 削除 → `ProtectedRoute` が `<Navigate to="/login" replace />` を
   返し `ChangePasswordPage` がアンマウントされる
2. しかし **`await` の継続処理はキャンセルされない**。成功応答が届くと、アンマウント済みコンポーネントの
   continuation が `replaceSession(token, nextUser)` を呼ぶ
3. `AuthProvider` は `Router` の外側でマウントされたままなので `setUser(merged)` が通り、**ログイン状態が復活**する
4. `App.tsx:64` の `/login` は `isAuthenticated ? <Navigate to="/" replace /> : <LoginPage />` なので、
   **ログイン画面が一瞬見えた後、ダッシュボードへ引き戻される**

さらに `replaceSession` の `?? user ?? {}` フォールバックは、localStorage が空（ログアウト済み）のとき
**クロージャに残ったログアウト前の user** を拾うため、消したはずのユーザー情報が書き戻される。
別タブで別アカウントにログインしていた場合、そのセッションを上書きし得る点も同様に成立する。

窓は API 応答までの数百 ms〜1 秒程度と狭いが、「ログアウトが効かない」はセキュリティ上の不変条件に触れる。
補強材料として、`grep -rn "AbortController|signal:" src`（テスト除く）は **0 件**でリクエストを中断する仕組みは
どこにも無く、`Header.tsx` の `handleLogout`（:43-45）にも変更中かどうかのガードは無いことを確認した。

**修正提案:**
送信時のトークン（またはセッション世代）を控え、一致する場合のみ差し替える。

```typescript
// ChangePasswordPage
const tokenAtSubmit = localStorage.getItem('auth_token');
// ... await の後
if (localStorage.getItem('auth_token') !== tokenAtSubmit) return;  // ログアウト or 別セッションへ切替済み
replaceSession(token, nextUser);
```

併せて「送信 → ログアウト → 成功応答が返っても未認証のまま」を、応答を遅延させたテストで固定する。

---

### [Codex] login と change-password で状態検証が二重実装されており、将来のドリフトで今回塞いだ穴が再発する

**ファイル:** `api/src/services/auth.service.ts:71-89`（login）と `:339-345`（changePassword）
**重要度:** Medium（現時点の挙動は正しい。将来のドリフト risk）

**該当コード:**

```typescript
// login（変更前から存在）
    if (appUser.status !== 'active') {
      return { statusCode: 403, headers: corsHeaders,
        body: JSON.stringify({ success: false, error: 'このアカウントはまだ有効化されていません' }) };
    }
    const application = await applicationsRepo.getById(appUser.applicationId);
    if (!application || application.deletedAt || normalizeApplicationStatus(application.status) !== APPLICATION_STATUS.ACTIVE) {
      return { statusCode: 403, headers: corsHeaders,
        body: JSON.stringify({ success: false, error: 'このアカウントはまだ有効化されていません' }) };
    }
```

```typescript
// changePassword（GTSS-852 で追加）— 条件も文言も手コピーで重複している
    const inactiveResponse = {
      statusCode: 403, headers: corsHeaders,
      body: JSON.stringify({ success: false, error: 'このアカウントはまだ有効化されていません' })
    };
    if (appUser.status !== 'active') {
      return inactiveResponse;
    }
    const application = await applicationsRepo.getById(appUser.applicationId);
    if (!application || application.deletedAt || normalizeApplicationStatus(application.status) !== APPLICATION_STATUS.ACTIVE) {
      return inactiveResponse;
    }
```

**問題:**
本 PR は「login と同一の状態検証を行う」ことをセキュリティ上の不変条件として据えているのに、その不変条件だけが
**共有されず手コピーで二重実装**されている。同じ PR で `jwt.sign` は `signSalonToken` へ、ユーザー情報構築は
`buildSalonUserData` へそれぞれ抽出して共有した一方で、**最もドリフトが危険な部分だけが重複したまま**である。

将来 login 側にだけ条件が追加される（例: アカウントロック、退会猶予期間、`password_changed_at` チェック）と、
`changePassword` が「ログイン条件を迂回するトークン発行口」に戻る。REQ-1 が明示的に塞いだ穴がそのまま再発する
構図で、現行テストは既知 3 条件を個別に固定しているだけなので**両者のポリシー同一性は誰も保証していない**。

**修正提案:**
`appUser` を受け取り「有効な `application`」または 403 レスポンスを返す共通関数へ抽出する。`changePassword` は
後段の `buildSalonUserData` で `application` を使うため、戻り値に `application` を含める必要がある。呼び出し位置は
両方ともパスワード照合の後のままでよく、既存契約は維持できる。

**#41（パスワードハッシュを scrypt/argon2 へ移行）が同じ `changePassword` を触るため、そこで併せて対応するのが
合理的**（Issue 本文の「着手順は #43 → #41」に沿う）。

---

### [Codex] `decodedToken.application_id` と `appUser.applicationId` の一致を検証していない

**ファイル:** `api/src/services/auth.service.ts:315`
**重要度:** Low（多層防御。**現時点で到達可能な悪用経路は無い**）

**該当コード:**

```typescript
// changePassword — sub で引くだけで、トークンの application_id クレームと突き合わせない
    const appUser = await applicationUsersRepo.getById(decodedToken.sub);
    if (!appUser) {
      return { statusCode: 404, /* ... */ error: 'ユーザーが見つかりません' };
    }
```

```typescript
// requireAuth（src/middleware/auth.ts:111-123）は同じ不整合を 401 で拒否する
  const applicationId = decoded.application_id;
  if (!applicationId) {
    return { error: true, response: { statusCode: 401, /* ... */
      message: 'Invalid token: application_id claim missing' } };
  }
```

**問題:**
`requireAuth` は `application_id` クレームの欠落（`middleware/auth.ts:111`）と所属不一致（同 :139 以降）を
どちらも 401 で拒否するが、`changePassword` は `sub` だけで引くためこれらの不整合トークンを受け付ける。
Codex は「以前から弱かった認証がトークン再発行口へ拡張された」と評価した。

**再検証の結果、危険度は Codex の評価より低い。** 悪用経路が成立しない理由:

- 発行される新トークンの `application_id` は **DB 由来**（`signSalonToken` が `updatedAppUser.applicationId` を読む）。
  クレーム側の値は一切使われないため、**他 application 向けトークンの発行は構造的に不可能**
- 前提条件が「被害者の現在パスワードを知っていること」。それがあれば `login` で同じトークンを得られるので利得ゼロ
- `application_users.application_id` を UPDATE する repo メソッドは存在しない。正規発行トークンのクレームが
  DB とズレることはない
- 唯一ズレ得るのは `application_id` を持たないレガシートークンだが、TTL 24h のため実在窓は既に閉じている

**修正提案:**
一貫性・多層防御として入れる価値はある（コスト小）。入れるなら `getById` の後・404 判定の後に
`decodedToken.application_id !== appUser.applicationId` のガードを置けば既存契約は保たれる。
**リリースブロッカーではない。**

---

### [Codex] `application_users.created_at` が NULL の行では `createdAt` キーが消えるが、テストが seed で隠している

**ファイル:** `api/src/services/auth.service.ts:44`（`buildSalonUserData`）/ `src/db/schema.ts:133`
**重要度:** Low（テスト忠実性。本 PR 固有の後退ではない）

**問題:**
`application_users.created_at` は **nullable かつ DB デフォルト無し**（`schema.ts:133`）で、DynamoDB 移行
スクリプトも `createdAt: item.createdAt ?? null` で NULL を保存し得る。repository の `toDomain`
（`application-users.repository.ts:20-25`）は **NULL/undefined 列を落として「属性不在」を再現する**設計のため、
`createdAt: undefined` → `JSON.stringify` でキー自体が消える。テストは seed で必ず日時を入れており
（`auth.test.js:51` の `createdAt` 明示追加はまさにこのため）、この NULL 形状を検証できていない。

**Codex はこれを「REQ-1 の固定キー集合違反」と結論づけたが、その部分は誤り。** REQ-1 が要求するのは
「**login のユーザー情報と同一のキー集合**」であり、`login` と `changePassword` は同じ `buildSalonUserData` を
共有しているため、`created_at` が NULL の行では**両方とも同じくキーが消え、キー集合は一致し続ける**。
この挙動は本 PR の新規混入ではなく login 側に元からあり、フロントも既にこの形を受け入れている。

一方、**採用すべき残りの論点**: 本番に有り得る NULL 形状を契約テストが検知できないという忠実性ギャップは実在する
（`response-contract.test.js` の 8 キー厳密固定も seed 前提）。加えてポータルの `User` 型は
`createdAt: string` を**必須**として宣言している（`user/src/types/index.ts`）ため、API がキーを落とすと型が嘘になる。
実害が出にくいのは `replaceSession` の `{...stored, ...nextUser}` マージが既存値を残すためだが、これは偶然の防御である。

**修正提案:**
本 PR のスコープ外。別 Issue で `application_users.created_at` を backfill して NOT NULL 化するのが筋。
それまでの間、ポータルの `User.createdAt` を `createdAt?: string` にするか否かは、実際の参照箇所を見て判断する。

---

### [Code Quality] 軽微な指摘（まとめ・いずれも任意）

**重要度:** Low

1. **`api.ts:187` — 200 でボディが空/非 JSON だと `{}` を返し「変更済みなのに失敗表示」になる**
   `await response.json().catch(() => ({}))` の結果をそのまま `return body` するため、`result.success` が
   falsy になり `ChangePasswordPage.tsx:74` が汎用エラーを表示する。旧仕様フォールバック（logout → ログイン
   画面）にも入らないため、サーバー側は変更済みなのに画面から出られない。実 API は常に JSON を返すので発生
   確率は極小。`return { success: true, ...body }` にすれば `!token || !nextUser` のフォールバックに乗る。
   併せて `api.ts:184` の `body?.error` は React の子として描画されるため `typeof body.error === 'string'` を
   条件に加えると堅い。

2. **`AuthContext.tsx:104` — `JSON.parse` が素通し**
   壊れた JSON だと throw し、`replaceSession` が `setUser` / `setItem` に到達しないまま
   `ChangePasswordPage.tsx:76` の catch に落ちる。**ただし実際には到達しにくい**: `AuthContext.tsx:46` の
   初期化 `JSON.parse` は try/catch の内側にあり、壊れていればその場で `auth_token` / `user` を削除して
   ログアウトさせるため、破損した状態で `/change-password` に到達できない。別タブがセッション中に破損させた
   場合のみ。try/catch で `stored = user ?? {}` にフォールバックしておけば確実（1 行）。
   ※ サブエージェント 2 体がこれを中程度の不具合として報告したが、上記の初期化ガードを追跡した結果、
   影響度は報告より小さいと判断した。

3. **`FlashContext.tsx:75` — `value` が毎レンダー新規オブジェクト**
   `flash` の変化で購読者の `AuthProvider` が再描画され、`AuthContext` の `value`（`AuthContext.tsx:121-129`）も
   新規化して `useAuth` 消費者が芋づるに再描画される（バナー 1 回につき表示・消灯で 2 回）。規模的に体感差は
   無いが、`AuthProvider` が `FlashProvider` の内側必須という結合を生んでおり、本 PR で `test/utils.tsx` と
   `AuthContext.test.tsx` の修正が必要になった原因でもある。`logout` の呼び出し側で `clearFlash()` を呼ぶ形に
   すれば依存を切れる。

4. **`ChangePasswordPage.tsx:43` / `types/index.ts` — `ChangePasswordData.user` の型が実レスポンスより広い**
   API が返すのは 8 キー（`buildSalonUserData`）だが、`ChangePasswordData.user` は既存の `User` 型を流用して
   おり、`User` は `stripeAccountId: string` と `createdAt: string` を**必須**として宣言している。API はどちらも
   返さない（`stripeAccountId` は元から、`createdAt` は NULL 行のとき）。`PasswordChangeFlow.test.tsx:411` が
   `as ReturnType<typeof makeUser>` の型アサーションでこの差を埋めているのが、契約の不一致を隠している。
   実害が出にくいのは `replaceSession` のマージが既存値を残すためで、偶然の防御である。
   加えて `mustChangePassword?: boolean` は **optional** なので、レスポンスから欠落しても TypeScript は
   検出できず、`AuthContext.tsx:105` のマージで古い `true` が残る余地が型の上では開いている。
   ※ ただし `buildSalonUserData` は `mustChangePassword: appUser.mustChangePassword === true` を**常に**返すため、
   **現行 API でこの往復は発生しない**。防御的堅牢化の位置づけ。
   **修正方針**: Codex は「実行時に `mustChangePassword === false` を検証し、不正なら旧仕様と同じログアウト
   フォールバックに倒す」ことを提案したが、これは**過剰なので採用しない** — 正当だが想定外のレスポンスで
   ユーザーを強制ログアウトさせる副作用のほうが害が大きい。API の実キー集合に沿った**レスポンス専用型**を
   定義し、マージ時に `mustChangePassword` を明示的に `false` 既定にするのが妥当。

5. **`api.ts:186-188` — 500 番台・ネットワーク障害を無記録で握り潰している**
   `catch { return { success: false, error: 'パスワード変更に失敗しました' } }` はログを一切残さず、
   `makeRequest` の `console.error` も迂回する。例外は捕捉済みなので Sentry の React ハンドラにも届かない。
   結果として CORS・通信断・サーバー障害の切り分けが本番でできない。パスワードやレスポンス本文は載せず、
   endpoint・HTTP status・例外種別だけを記録するとよい（上の「console に JWT が載る」指摘と方向は一致する）。

6. **`ChangePasswordPage.tsx:56` — `navigate('/login', { state })` が push**
   `replace: true` が無いため `/login` が履歴に二重に積まれる。直前の `/change-password` は `App.tsx:39` の
   `<Navigate ... replace />` で既に置換済みなので、`replace: true` を足しても戻り先は失われない。
   また `location.state` は履歴エントリに残るため `/login` をリロードすると案内メッセージが再表示される。
   これは `FlashContext.tsx:6-7` が「`navigate(..., { state })` は戻る操作・リロードで復活するため採らない」と
   書いて避けた挙動そのもので、同一 PR 内で方針が割れている。旧 API フォールバック限定の経路なので実害は
   小さい。

---

## 総評

**結論: マージ可。** 実装は Issue の REQ-1〜REQ-6 を機能面ですべて満たしており、設計判断も妥当で、
ハマりどころに対する手当てが丁寧に効いている。**ロジックの誤り・セキュリティホール・既存契約の破壊は
1 件も見つからなかった。**

対応を推奨するのは次の 4 件（うち 2 件は Codex が発見）:

- **応答待ち中のログアウトが取り消される（Medium）** — `await` の継続処理がキャンセルされず、アンマウント後も
  `replaceSession` が走ってログイン状態が復活する。「ログアウトが効かない」に触れるため、窓が狭くても直す価値が
  ある。送信時トークンとの一致チェック 2 行で塞げる。
- **完了バナーの live region（Medium）** — `role="status"` を付けた要素を丸ごと後から挿入しているため、
  REQ-4 が明記する「支援技術に成功が伝わる」という目的を達成できない可能性がある。属性は付いているが
  効かないかもしれない、という点で唯一「要件を満たしきれていない」箇所。修正は数行。
- **状態検証の二重実装（Medium・Codex 指摘）** — 現時点の挙動は正しいが、`signSalonToken` /
  `buildSalonUserData` を共有化した一方で**最もドリフトが危険な状態検証だけが手コピー**で残っている。
  login 側に条件が増えたとき片方だけ更新されると、REQ-1 が塞いだ「トークン発行口」がそのまま再発する。
  **#41 が同じ関数を触るので、そこで併せて共通化するのが合理的。**
- **docs 3 点のコミット（Medium）** — 内容は完成しているので `git commit` するだけ。

残りはすべて Low で、競合時のみ・発生確率が極小・スコープ外のフォローアップ提案である。

自分で追跡して裏取りした主なポイント:

- **403 の状態検証（REQ-1）**: `login`（`auth.service.ts:69-88`）と条件・文言が完全一致していることを両方
  読んで対比。検証は「現在パスワード照合の後・DB 更新の前」に置かれており、既存の 401/404 契約を壊さず、
  かつ検証失敗時に `applicationUsersRepo.update` に到達しない（＝パスワードが変わらない）ことを確認。
  `JWT_SECRET` 欠落時の 500 も更新前に返るため fail-closed。
- **`data.user` のキー集合一致（REQ-1）**: `buildSalonUserData` を `login` と共有しており、テストも
  `Object.keys().sort()` の突き合わせで契約ドリフトを固定している。`applicationUsersRepo.update` は
  `.returning()` の全行を返すため、`signSalonToken(updatedAppUser)` の `sub` / `application_id` / `email` が
  欠落しないことを repository 実装で確認。
- **`tRegistrationNumber` の保持（REQ-2）**: `replaceSession` は `localStorage['user']` を起点にマージする。
  初期化 `useEffect`（`AuthContext.tsx:47-49`）と `refreshUser`（同 115-117）が**マージ結果を localStorage へ
  書き戻している**ため、localStorage が常に最新の上位集合になっており、T番号が落ちないことを確認した。
- **8 秒タイマーの所有者（REQ-4）**: `FlashProvider` は `Router` の外側にあり、タイマーは `showFlash` 呼び出し
  時刻起点で `useRef` に保持。`SuccessBanner` は `ProtectedRoute` 内で画面ごとに再マウントされるが、タイマーは
  張り直されない。テスト T-20 が「4 秒後に遷移 → 合計 7999ms で表示 / 8000ms で消灯」を実測しており、
  Issue が名指しした「遷移でタイマーが延長される」罠を正しく回避している。
- **初回変更の着地先（REQ-3）**: `/invoices` を起点にガード誘導されたケースでも `/` に着地することを結合
  テストが `window.location.pathname` で確認。`isMustChange` が旧レンダのクロージャ値（true）を掴むため、
  `replaceSession` 直後でも分岐が反転しないことを確認した。
- **旧仕様レスポンスのフォールバック（REQ-3）**: `flushSync(() => logout())` → `navigate('/login', { state })`
  の順序が必要な理由（同一バッチだと `/login` の `<Navigate to="/" />` に弾かれて state が失われる）が
  コメントで明示されており、ユニット・E2E 双方で担保されている。
- **バナーの描画箇所（REQ-4）**: `App.tsx:47` の 1 箇所のみ。`/change-password` を含む全保護ルートが同一の
  `ProtectedRoute` を通るため、二重描画もログイン画面への漏れも無いことを `App.tsx` 全体を読んで確認。

テストの質が高い。境界値（12 文字ちょうど / 7999ms・8000ms）、契約固定（キー集合の完全一致）、
機微情報の非混入（レスポンス全文にハッシュが出ないことを `JSON.stringify` で検査）、旧仕様フォールバック、
403 の 3 条件を表駆動で網羅 — いずれも「壊れたら気づける」形になっている。既存の DB 永続化アサーションも
Issue の指示どおり残されている。

### 環境面の注意（本 PR とは無関係・既存）

api の `docker-compose.test.yml` はプロジェクト名が固定のため、**全 worktree が同一のテスト用 Postgres
コンテナ（`cancel-billing-api-test-postgres-test-1`）を共有する**。別 worktree で `npm test` を並行実行すると、
互いの `beforeEach` の `truncateAll()` と終了時の `db:test:down` が衝突し、**無関係なテストが大量に落ちる**
（今回のレビューでも一度 53/56 失敗した）。CI はジョブごとに隔離されるため影響しないが、ローカルで複数
worktree を同時に動かす場合は `COMPOSE_PROJECT_NAME` を worktree 名で分けると安全。

### 再検証のうえ破棄した指摘

- **「ヘッダー導線が `<a href>` のため REQ-4 の『移動しても残り時間だけ表示』が実 UI で成立しない」（Codex 指摘）
  → 破棄（レビュー依頼者の判断）。**
  事実関係自体は裏取り済みで正しい: `Header.tsx:70/113/127/228/257/263` と `InvoiceList.tsx:395/448` は生
  `<a href>` でフルリロードし、`FlashProvider` が作り直されてバナーは 8 秒を待たず消える。`Header.tsx:3` が
  `Link` / `useNavigate` を一切 import していない唯一のコンポーネントであることも確認した。
  一方で REQ-4 には「表示要求はメモリ上にのみ保持し、**ページのリロード時**・ログアウト時に破棄される」とも
  書かれており、フルリロードで消える挙動はこの条文には沿う。**ヘッダーの `<a href>` は本 PR が作ったもの
  ではなく既存の実装**でもある。以上を踏まえ、本 PR では対応しない判断となった。
  （将来ヘッダーを `Link` へ統一する際は、バナーの残存挙動が変わる点だけ留意）

- **「変更必須ガードが localStorage 依存でクライアントから回避できる」→ 破棄（仕様どおり）。**
  Issue の REQ-5 が「このガードは **セキュリティ境界ではなく UX 上の誘導**であり、本 Issue でこの性質は
  変えない」と明記している。API 側に未変更ユーザーを拒否するガードが無いことも Issue が把握済み。
  ただし指摘に付随した提案（トークンを再発行する新仕様になったので `mustChangePassword` を JWT クレームに
  載せればサーバー側で多層防御にできる）は筋が良いので、下のフォローアップ候補に加えた。

- **「`flushSync` は React 18+ の自動バッチ下では不要では」→ 破棄。**
  `ChangePasswordPage.tsx:50-52` のコメントが述べる理由（同一バッチだと認証済みのまま `/login` が評価され
  `<Navigate to="/" />` に弾かれ、そこから保護ルートのガードで `/login` へ再遷移して state が失われる）は
  `App.tsx:64` の `isAuthenticated ? <Navigate to="/" replace /> : <LoginPage />` と突き合わせて成立を確認した。
  自動バッチがあるからこそ `flushSync` が要る形なので、除去は回帰になる。

- **「テスト ID T-8 / T-14 が欠番」（lessons-reviewer からの未検証指摘）→ 破棄。**
  差分中に `T-8` / `T-14` タグが出現しないのは事実だが、Issue のテスト一覧（本文 L447 / L453）は両者を
  **「既存アサーション維持」「既存テスト維持」**と定義しており、新規タグが付かないのが正しい。実体も確認済み:
  T-8 = `auth.test.js:373`「正常 → 200 + application_users.password 更新（applications テーブルは無変更）」
  （`beforeApp` / `afterApp` の比較を含めて保持）、T-14 = `ChangePasswordPage.test.tsx:92`「新旧パスワード
  不一致…」および `:104`「12文字未満…」（いずれも `not.toHaveBeenCalled()` を保持）。**欠落なし。**

### レビュー体制について

`code-reviewer` × 2 / `lessons-reviewer` / `codex-reviewer` × 2 の計 5 エージェントを起動し、全員から結果を回収した。

**Codex は初回 503 障害（`biscuit_baker_service_me_circuit_open`）で実行できず、復旧後に再実行した。**
初回は wss / https 双方でリトライ枯渇しモデル出力ゼロだったため、`codex-reviewer` 2 体は待機中に自前レビューを
返していた（上の指摘の一部はそれ由来）。復旧確認（`codex exec` → `PONG`）のうえ、保存済みプロンプトで再実行:

- **api 側: 実行成功**（gpt-5.6-sol / xhigh / read-only、122,649 tokens）。既知 6 件の再掲は無く新規 3 件を提示。
  引用ファイル・行はすべて worktree `.worktrees/GTSS-852` 内で GTSS-852 の文脈と一致し、別セッション混入は無し。
  3 件とも採用したが、**うち 2 件は Codex の結論を修正して採用している**（`application_id` 不一致は「エスカレーション」→
  「実害の無い多層防御の穴」へ降格、`created_at` NULL は「REQ-1 違反」という結論を破棄してテスト忠実性の論点のみ採用）。
  生ログ: `scratchpad/codex-review-output-api-run3.txt`
- **ポータル側: 実行成功**（197,663 tokens）。既知 7 件の再掲は無く新規 4 件を提示。参照ファイルはすべて
  worktree 内で GTSS-852 の文脈と一致、別セッション混入なし。**1 件を Medium で採用**（応答待ち中のログアウト
  取り消し）、**1 件はレビュー依頼者の判断で破棄**（ヘッダー `<a href>` による REQ-4 不成立 → 上の破棄一覧参照）、
  **2 件は降格・分割して採用**（型忠実性と無記録のエラー握り潰しを「軽微」へ。`mustChangePassword` 欠落
  シナリオは現行 API で発生しないため不採用）。
  生ログ: `scratchpad/codex-review-output-user-run2.txt`

Codex 由来の指摘は、**メイン側で `Header.tsx` の実装（内部リンクが `<a href>` であること）、`App.tsx:64` の
`/login` 分岐、`buildSalonUserData` のキー構築、`User` 型の必須フィールドを実ファイルで確認したうえで**
採否と重要度を決めている。Codex の重要度をそのまま採用したものは 1 件も無い。

各エージェントの指摘はメインエージェントが実ファイル・呼び出しチェーン・Issue 本文で再検証し、裏取りできた
ものだけを採用した。特に `/auth/me`（`getMe`）の実レスポンスが 4 項目のみで `mustChangePassword` を含まない
ことを確認した結果、e2e fixture の指摘は**採用（実 API との乖離が本質）**、`JSON.parse` の指摘は
**影響度を下げて採用**という形で報告内容から評価を変えている。

テスト実行はメインエージェントのみが実施した（`code-reviewer` 2 体はシェル権限が無く、`codex-reviewer` 2 体は
共有テスト DB を落とす懸念から意図的に回避したため、いずれも「静的確認のみ・green 未確認」と申告している）。
本レポートのテスト結果はすべてメインエージェントの実行によるもの。
