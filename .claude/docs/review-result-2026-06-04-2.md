---
issue: 2
date: 2026-06-04
repos:
  - repo: user
    repoDir: cancel-billing-service
    baseBranch: feature/GTSS-13
    toBranch: feature/GTSS-13-vitest
---

# レビュー結果: #2

## 概要

**Issue:** #2 ユーザーポータルにテスト基盤(Vitest + Playwright)を整備し主要フローを担保

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| user | `feature/GTSS-13` | `feature/GTSS-13-vitest` | 1 | 26（うち実質テスト/設定25, package-lock.json 1） |

このPRは **テストコードと設定の新規追加のみ** で、プロダクトコードの挙動変更はありません（テストが現行挙動を固定化する方針）。
レビューにあたり全テストファイルのアサーションを対応プロダクトコード（`AuthContext.tsx` / `App.tsx` / `Dashboard.tsx` / `InvoiceList.tsx` / `InvoiceForm.tsx` / `SettingsPage.tsx` / `LoginPage.tsx` / `ResetPasswordPage.tsx` / `ForgotPasswordPage.tsx` / `api.ts`）と突き合わせて検証しました。**誤った期待値でバグを固定しているテスト・空アサーション・確実なフレークは検出されませんでした。** High/ブロッカー級の指摘はありません。

## 変更ファイル一覧

### user

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `.gitignore` | +6 | -0 | Modified |
| `CLAUDE.md` | +9 | -0 | Modified |
| `package.json` | +14 | -1 | Modified |
| `vitest.config.ts` | +28 | -0 | Added |
| `playwright.config.ts` | +47 | -0 | Added |
| `tsconfig.app.json` | +7 | -1 | Modified（test 除外） |
| `tsconfig.vitest.json` | +16 | -0 | Added |
| `src/test/setup.ts` | +21 | -0 | Added |
| `src/test/utils.tsx` | +77 | -0 | Added |
| `src/__tests__/ProtectedRoute.test.tsx` | +77 | -0 | Added |
| `src/contexts/__tests__/AuthContext.test.tsx` | +183 | -0 | Added |
| `src/services/__tests__/api.test.ts` | +140 | -0 | Added |
| `src/components/__tests__/LoginPage.test.tsx` | +69 | -0 | Added |
| `src/components/__tests__/ChangePasswordPage.test.tsx` | +128 | -0 | Added |
| `src/components/__tests__/ResetPasswordPage.test.tsx` | +94 | -0 | Added |
| `src/components/__tests__/ForgotPasswordPage.test.tsx` | +50 | -0 | Added |
| `src/components/__tests__/InvoiceForm.test.tsx` | +249 | -0 | Added |
| `src/components/__tests__/InvoiceList.test.tsx` | +219 | -0 | Added |
| `src/components/__tests__/Dashboard.test.tsx` | +100 | -0 | Added |
| `src/components/__tests__/SettingsPage.test.tsx` | +119 | -0 | Added |
| `e2e/auth.setup.ts` | +15 | -0 | Added |
| `e2e/auth.spec.ts` | +78 | -0 | Added |
| `e2e/invoice.spec.ts` | +97 | -0 | Added |
| `e2e/fixtures.ts` | +95 | -0 | Added |
| `e2e/helpers/auth.ts` | +41 | -0 | Added |
| `package-lock.json` | +1516 | -? | Modified（依存追加, レビュー対象外） |

## 指摘一覧

- [x] 対応する

### [Test Coverage] SettingsPage の E2E が「保存後の反映」を検証せずトースト確認で止まっている

**ファイル:** `user/e2e/invoice.spec.ts:385`
**重要度:** Medium

**該当コード（新規ファイル）:**
```typescript
test('アカウント設定で T番号 を保存できる [GTSS-13]', async ({ page }) => {
  await mockApi(page);
  await page.goto('/settings');

  await expect(page.getByRole('heading', { name: 'アカウント設定' })).toBeVisible();
  await page.getByPlaceholder('T1234567890123').fill('T1234567890123');
  await page.getByRole('button', { name: '保存する' }).click();

  await expect(page.getByText('保存しました')).toBeVisible();   // ← ここで終了。保存値の反映を verify していない
});
```

**問題:**
プロジェクトの lesson（`.claude/skills/playwright/lesson.md`「CRUD操作テストはデータが実際に更新されたことまで確認する」）に照らすと、本テストは入力→保存→**成功トーストのみ** を確認しており、保存した `T1234567890123` が永続・反映されたことを検証していません。
ただし unit 側（`src/components/__tests__/SettingsPage.test.tsx:3503`）が `updateProfile({tRegistrationNumber:'T9876543210987'})` のペイロードと `refreshUser` 呼出を厳密検証しているため、ロジック検証はカバー済みです。E2E 単体での「反映」担保のみが弱い状態です。

**修正提案:**
- 最小対応: 保存後に `await expect(page.getByPlaceholder('T1234567890123')).toHaveValue('T1234567890123')` を追加。
- より堅牢: `page.waitForRequest('**/auth/profile')` で PATCH の受信ボディを検証、または `fixtures.ts` の `mockApi` を「PATCH で受けた値を以降の `GET /auth/me` に反映する」よう拡張し `page.reload()` 後の復元値を verify する。
  - 注: 現状 `mockApi` の `**/auth/me` は固定 `TEST_USER`（`tRegistrationNumber: null`）を返す（`e2e/fixtures.ts:180`, `e2e/helpers/auth.ts:267`）ため、単純な reload-verify は mock 拡張が前提。

---

### [Code Quality] Playwright のデフォルトポートがブランチ固有値(5176)でハードコードされている

**ファイル:** `user/playwright.config.ts:5`
**重要度:** Medium

**該当コード（新規ファイル）:**
```typescript
const isCI = !!process.env.CI;
// worktree ごとにポートが変わるため env で上書き可能にする（このブランチの slot=3 → 5176）。
const port = process.env.PORT || '5176';
const baseURL = process.env.PLAYWRIGHT_BASE_URL || `http://localhost:${port}`;
// ...
  webServer: {
    command: `npm run dev -- --port ${port} --strictPort`,
    url: baseURL,
    reuseExistingServer: !isCI,
    timeout: 120_000,
  },
```

**問題:**
デフォルト `5176` は「このブランチの slot=3」前提の固定値です。別 worktree / CI / main にマージした後に `5176` が他プロセスに占有されていると `--strictPort` で `webServer` 起動に失敗します。逆に `reuseExistingServer: !isCI` のため、ローカルで別アプリが 5176 を握っていると **そのサーバに対して E2E を流してしまう** 取り違えリスクもあります。CLAUDE.md には `PORT=5176 npm run test:e2e` の注記がありブロッカーではありませんが、運用上の落とし穴です。

**修正提案:**
Vite 標準ポート（`5173`、CORS 許可ドメイン）を既定に寄せるか、ブランチ固有のポート値は env / CI 設定側に外出しする。少なくとも main マージ時に slot 固有値が残らないよう確認する。

---

### [Test Coverage] Dashboard テストが DOM クラス依存(`.font-medium`)の脆いセレクタで顧客名を取得している

**ファイル:** `user/src/components/__tests__/Dashboard.test.tsx:2662`
**重要度:** Low

**該当コード（新規ファイル）:**
```typescript
function recentRowNames(): string[] {
  const table = screen.getByRole('table');
  return Array.from(table.querySelectorAll('tbody tr')).map(
    (tr) => tr.querySelector('td .font-medium')?.textContent ?? ''   // ← Tailwind クラス依存
  );
}
```

**問題:**
`Dashboard.tsx:285` の `className="text-sm font-medium text-gray-900"` に依存しており、Tailwind クラスのリファクタ（`font-medium` 削除 / `font-semibold` 化）で `null` になり全行が空文字になります。期待値が `['C1'...]` のため誤って緑になる可能性は低いものの、「セレクタ起因の失敗か実バグか」の切り分けが難しくなります。

**修正提案:**
`InvoiceList.test.tsx:3067` の `td div` 方式に揃えるか、より堅牢に `within(row).getByText(name)` の存在確認に寄せる。

---

### [Test Coverage] 請求書作成 E2E の来店予定日が絶対固定日付(2026-07-01)で将来のリグレッションに弱い

**ファイル:** `user/e2e/invoice.spec.ts:333`
**重要度:** Low

**該当コード（新規ファイル）:**
```typescript
await page.locator('#shopName').fill('E2Eサロン');
await page.locator('#staffName').fill('担当太郎');
await page.locator('#appointmentDate').fill('2026-07-01');   // ← 絶対固定日付
await page.locator('#menuName').fill('カット');
```

**問題:**
`appointmentDate` には現状 min/max バリデーションが無い（`InvoiceForm.tsx:335-344`。`min/max` は別フィールド `dueDate` の 445-446 行）ため現行は通ります。ただし同 spec は当月判定を `currentMonthIso`（実行日基準）で生成してフレーク回避しているのに対し、`appointmentDate` のみ絶対日付です。今後 `appointmentDate` に下限バリデーション（過去日不可）が追加されると静かに壊れます。

**修正提案:**
`currentMonthIso` と同様、実行日基準で相対的な日付を生成する形に揃える。

---

### [Code Quality] 共通 setup の `console.error` 無条件 mock が React の警告シグナルを握りつぶす

**ファイル:** `user/src/test/setup.ts:13`
**重要度:** Low

**該当コード（新規ファイル）:**
```typescript
beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});   // ← act/key 警告も消える
});
```

**問題:**
ノイズ抑制の意図は妥当ですが、`act(...)` 警告・key 警告など「テストが緑でも実装に問題がある」シグナルも一律で消えます。テスト基盤としては許容範囲です。

**修正提案:**
将来的には `console.error` を mock しつつ「想定外の呼び出しがあれば fail させる」方式（呼び出し内容を検査）に寄せると回帰検知力が上がる。現状はブロッカーではない。

---

### [Code Quality] ResetPasswordPage テストの microtask flush がハードコードのループ依存

**ファイル:** `user/src/components/__tests__/ResetPasswordPage.test.tsx:3420`
**重要度:** Low

**該当コード（新規ファイル）:**
```typescript
// fetch / json の microtask を flush
await act(async () => {
  for (let i = 0; i < 5; i++) await Promise.resolve();   // ← await 段数に依存した脆い待ち方
});
expect(screen.getByText('パスワードを再設定しました')).toBeInTheDocument();
```

**問題:**
`fake timers` と `userEvent` の干渉を避けるための既知パターンですが、`ResetPasswordPage` の `fetch → response.json() → setTimeout` の await 段が将来増えると 5 回ループでは足りず暗黙に壊れます。

**修正提案:**
結果起点の待機（`await vi.waitFor(() => expect(...).toBeInTheDocument())`）に寄せる方が頑健。現状テストは pass する想定のため必須ではない。

---

### [Code Quality] predeploy にユニットテストが組み込まれていない（Issue Open Question・情報）

**ファイル:** `user/package.json:2324`
**重要度:** Low（情報）

**該当コード:**
```json
"predeploy": "npm run lint"
```

**問題:**
テスト基盤を整備したが、デプロイ経路（`predeploy`）でユニットテストが実行されず、CI も未整備のため「資産としてのテストがゲートに効かない」状態です。**Issue の Open Questions で任意とされている** ためブロッカーではありません。

**修正提案:**
別途 CI 必須化、または `predeploy` への `npm test` 追加を検討（Issue 方針に沿って別判断）。

---

## 検証メモ（誤指摘でないことを確認し、指摘から除外した項目）

- **「未認証で /invoices → /login」E2E が `mockApi` 未設定（codex 提起・未検証）**: `AuthContext.tsx:35` の `if (token && storedUser)` ガードにより、`localStorage` 空（storageState なしの `login` プロジェクト）では `getCurrentUser()` を呼ばず即未認証になる。実 API へ抜けるパスは無く **安全**。指摘から除外。
- **誤アサーションによるバグ固定**: `api.ts` のエラー変換（`HTTP {status}: {statusText}`・ボディ破棄・例外非伝播）、手数料 `floor(amount*0.25)`・サロン受取額（両 fee non-null 時のみ実額 / 欠落時フォールバック）、shop info の `invoice_shop_info_{applicationId}` キー（`user.id` 不使用）、`AuthContext` の login（マージなし）と init/refreshUser（`tRegistrationNumber` のみマージ）の 3 経路差分 — いずれも実ソースと完全一致。除外。
- **時刻依存フレーク**: 当月判定は全て `new Date()` 基準・正午起点で生成し月境界でも安全。`ResetPasswordPage` の 3 秒遷移は fake timers で 2999ms/1ms 境界を厳密検証し `afterEach(vi.useRealTimers())` でリセット。フレーク要因なし。除外。
- **`SettingsPage.test.tsx` が Issue のファイル一覧に無い（codex 提起）**: GTSS-13 追加分として `[Completion]` コメントに記載済みのため doc 上の問題なし。除外。

## クリーンアップ・設定（規約準拠の確認）

- `.gitignore` に `.auth/` / `playwright-report/` / `test-results/` / `coverage/` を追加 → 成果物の混入防止（規約「process/ログが残らないように」を満たす）。
- `src/test/setup.ts` の `afterEach` で `cleanup()` / `localStorage.clear()` / `vi.restoreAllMocks()` / `vi.clearAllMocks()` → テスト間の状態リークなし。
- `tsconfig.app.json`（test 除外）と `tsconfig.vitest.json`（vitest/jest-dom 型）の分離は対応が取れており、本番ビルド型チェックからテストを正しく分離。
- `vitest.config.ts` の include/exclude と Playwright `testDir: './e2e'` は重複なく住み分け。

## 総評

テスト基盤PRとしての完成度は高く、**High/ブロッカー級の指摘はありません**。全テストのアサーションは実装の現行挙動と一致しており、誤った挙動を固定化しているテストや空アサーションは検出されませんでした。E2E の落とし穴対策（`**/auth/me` 成功 mock 併設、`**/invoices` の document/xhr 出し分け `route.fallback()`、POST→一覧反映の結合検証、storageState 戦略）も的確です。

指摘は Medium 2件（SettingsPage E2E の反映未検証 / Playwright ポート固定値）と Low 5件で、いずれもマージブロッカーではなく保守性・運用面の改善提案です。Medium 2件を将来のメンテ性観点で対応いただければ十分マージ可能と判断します。

> 補足: codex-reviewer は Codex CLI 自体がターン上限で最終レポート未出力だったため、当該観点は本メインエージェントの独立照合（diff 全文＋実ソース突き合わせ）で代替済みです。
