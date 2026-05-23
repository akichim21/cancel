---
name: playwright-best-practices
description: Playwright end-to-end testing best practices and conventions. Use this skill whenever writing, reviewing, or debugging Playwright tests — including test structure, locator strategy, assertions, CI configuration, and debugging. Trigger on any mention of Playwright, e2e tests, browser testing, or test automation with Playwright, even if the user just says "write tests for this page" or "why is my Playwright test flaky."
---

# Playwright Best Practices

## 最重要ルール（MUST ALWAYS FOLLOW）

以下のルールは E2E テスト作成・修正時に**必ず**遵守すること。違反したテストはレビューで差し戻す。
過去の Playwright 監査で「カバー率は高いがバグを検出できない spec」が大量発見されたため、ルールを拡張した。

### 1. 表示系は変数の表示を可能な限り網羅すること
- 画面遷移やボタンの存在確認だけでは不十分。表示されている値（金額、日付、件数、ステータス、名前など）を `expect` で網羅的に検証する
- ラベルだけでなく、実際のデータ値を検証する
- フィルター適用後は、結果の件数と内容が正しいことまで検証する
- **`tableText.toContain('keyword')` のような「全テキスト contains」は禁止**。行 / 列 / セルの位置を保証できないため。`row.locator('td').nth(N).toHaveText(...)` か `getByRole('cell', { name: ... })` でセル単位検証する
- 詳細画面ではフィールド表示値（数値・日付・ステータス・カテゴリ）を expect で網羅する。ラベルの存在のみは禁止

### 2. 作成/更新/削除はサーバー側の反映まで検証すること
- フォーム送信後の成功トーストだけでは不十分
- **inputの更新はフロントエンドのキャッシュとして残ることがあるため、サーバー側で実際に更新されたことまで検証する**
- 作成・更新後は一覧画面や詳細画面に遷移（ページリロードまたは再取得）して、保存された値が正しく表示されていることを確認する
- 削除後は一覧から消えていること、または詳細ページにアクセスできないことを検証する
- **作成/更新フォームに多数のinputがある場合は、全てのinputの作成/更新が反映されていることをテストすること**（一部のフィールドだけ検証して終わらない）
- **「データを壊さないために保存せずキャンセルする」CRUD テストは禁止**。fixture で seed → 操作 → verify → fixture teardown の構造に統一する。キャンセル動作の verify は別テストで分離する
- **更新時は変更したフィールドだけでなく「未変更フィールドが保持されていること」も verify する**（部分update バグ検出のため）
- **「ボタンの存在確認だけ」「モーダル表示のみ」「『いいえ』を押して閉じる」で終わる CRUD テストは禁止**。実際にアクションを実行し、結果を後続画面で verify する

### 3. テストデータの後始末は fixture でセットアップとセットで管理する
- 前提データを `request.post` で作る、UI 経由で作成したレコードを後で消す、といった「作って消す」処理は **`test.extend` の custom fixture** に閉じ込める
- `await use(value)` の前で setup、後で teardown を書くことで、テスト失敗時も確実にクリーンアップが走る
- `test.afterEach` で散らかった ID を query で探して消す方式は、並列実行で他テストのデータを巻き込みうるので避ける。fixture が把握している objectId だけを消す、または「テスト前に存在した ID」を記録して差分だけ消す方式にする
- **fixture 設計の模範例**: seed → 操作 → verify → teardown を fixture に閉じ込めた `seedSnapshots` / `cleanSlate` / `cleanupCreatedSnapshots` パターン

```ts
// e2e/helpers/foo-fixture.ts
export const test = base.extend<{ fooSeed: { id: string } }>({
  fooSeed: async ({ request }, use) => {
    const id = await createFoo(request, { ... });
    await use({ id });            // テスト本体
    await deleteFoo(request, id); // 失敗時も走る
  },
});

// 使う側: import先を差し替えるだけ
test('...', async ({ page, fooSeed }) => { ... });
```

### 4. フィルター / ソート / ページネーションは前後比較で動作を検証する
- フィルター: 適用前 `rowsBefore = await rows.count()` を記録 → 適用 → `rowsAfter` と比較し、**残った全行が条件に一致**することを verify
- ソート: 「データが空でない」「順序が変わった」だけでは不十分。**隣接セル値を比較**して昇順 / 降順を検証
- ページネーション: 1 ページ目 / 2 ページ目で **異なる行が表示されていること**を verify
- `expect(rowsAfter).toBeLessThanOrEqual(rowsBefore)` のような弱い不等号比較は禁止（フィルター効いていなくても通る）

### 5. 条件分岐 / ステータス / ロールは全パターンを網羅する
- ステータス enum (`BOOKING_STATUS`, `PAYMENT_STATUS` 等) は **全ライフサイクル**を verify する。1 値だけ通っても本番の大半が別ステータスならバグを検出できない
- 必要に応じて `page.route` で各ステータスを mock するか、seed データで多様な行を投入する
- 権限ロール（ADMIN / AM / SALON_OPERATOR 等）の出しわけは「画面遷移できる」だけでなく「**できる操作 / できない操作**」を verify する
- 0 件 / 大量件数 / null / undefined / ロード中 / エラー状態のエッジケースを verify する

### 6. バリデーションエラーは正常系と同じ重みでテストする
- CRUD フォームには必ず以下のテストを入れる:
  - 必須未入力 → 必須エラー表示 verify
  - 形式違反 (メール / 電話番号 / URL / 郵便番号) → エラーメッセージ verify
  - 文字数オーバー → エラーメッセージ verify
  - 数値範囲外 (負数 / 上限超え) → エラーメッセージ verify
- 正常系の input 2-3 個だけ fill して終わらない。**全 input** のバリデーションを網羅する
- `expect(value.length).toBeGreaterThan(0)` のような「中身があれば PASS」の弱検証は禁止。具体値（fixture の seed 値）と一致するか verify する

## 禁止パターン一覧（NG List）

監査で頻出した **絶対禁止** のパターン。新規 spec / リファクタ時にこれらを書いてはいけない。レビューで見つけたら差し戻す。

| 禁止パターン | 理由 | 正しい書き方 |
|------------|-----|------------|
| `await page.waitForTimeout(NNNN)` | 固定待機。CI では timing 依存でフレーキー化 | `await expect(...).toBeVisible()` か `waitForResponse` |
| `expect(await locator.isVisible()).toBe(true)` | 即時 check で auto-wait しない | `await expect(locator).toBeVisible()` |
| `if (!(await x.isVisible(...).catch(() => false))) { test.skip(); return }` | seed が無くても PASS してしまう false positive 量産 | fixture で seed 必須化し、無条件 expect |
| `expect(tableText).toContain('foo')` の全文 contains | 行 / 列 / セルの位置を保証しない | `row.locator('td').nth(N).toHaveText(...)` か `getByRole('cell')` |
| `expect(value.length).toBeGreaterThan(0)` | 「中身があれば PASS」で値が間違っていても通る | 具体値で verify (`toHaveValue('expected')`) |
| **保存せずにキャンセル**するだけの CRUD テスト | CRUD のサーバー反映を保証していない | fixture seed → 保存 → reload → verify → teardown |
| 「ボタン存在のみ」「モーダル表示のみ」で終わるテスト | ユーザー価値を保証していない | 実行 → 結果を後続画面で verify |
| `page.locator('.ant-modal-content')` 等 UI ライブラリ内部 CSS 依存 | ライブラリのメジャーアップで壊れる | `getByRole('dialog')` 等の user-facing locator |
| `getByText('管理者')` 等の短文 strict mode 違反 | 複数要素にマッチして strict mode error | `page.locator('main').getByText(...)` でスコープ限定 or 具体ロケータ |
| `test.use({ storageState: undefined })` | 親プロジェクトの storageState を **継承する**罠 | `test.use({ storageState: { cookies: [], origins: [] } })` |
| 「キャンセル押下 → 編集モード解除」だけ verify するテスト | 確定 (commit) パスを通っていない | キャンセル / 確定 を別テストで両方 verify |
| `if (rowCount > 0) { ... } else { ... }` で分岐 | seed あり前提なら無条件 expect、空状態は別テスト | seed 強制 + 空状態は fixture で別テスト |
| `expect(rowsAfter).toBeLessThanOrEqual(rowsBefore)` 弱い不等号 | フィルター効いていなくても通る | 厳密な期待値 (`toEqual` 等) と残存行の条件一致 verify |
| **CSV 出力ボタン存在のみ** verify | 実 download / 内容が壊れていてもパス | `page.waitForEvent('download')` でファイル取得 → ヘッダー + 1 行 verify |
| **ボタンを順番に試して何かクリック**するパターン | 何が押されたか不確定で再現性なし | 期待する操作パスを明示し、見つからなければ test fail |
| ハードコードされた seed ID への直接遷移 (`detail/abc123`) | seed 変動でテストが壊れる | fixture で seed して動的 ID を取得 |
| `toHaveScreenshot` を機能テスト spec に混在 | フォントレンダリング差で false positive 多発 | `e2e/visual/*.spec.ts` に分離して visual regression 専用に |

## Locator Strategy (Priority Order)

Always prefer user-facing locators over CSS/XPath selectors. DOM structure changes break CSS/XPath; user-facing attributes are resilient.

**重要**: `.ant-xxx` などの UI ライブラリ内部 CSS クラスへの依存は **メジャーアップで一斉に壊れる** ため避ける。

```ts
// ✅ Preferred — resilient to DOM changes
page.getByRole('button', { name: 'submit' });
page.getByLabel('Username');
page.getByText('Welcome');
page.getByTestId('status');

// ❌ Avoid — brittle, tied to implementation
page.locator('button.buttonIcon.episode-actions-later');
page.locator('#submit-btn');
page.locator('div > form > button:nth-child(2)');
page.locator('.ant-modal-content');           // antd 内部クラス
page.locator('.ant-btn:has(.anticon-edit)');  // 同上
```

### 優先順位（推奨置き換え順）
1. **CRUD 操作の主要ボタン**（保存 / キャンセル / 追加 / 削除 / 編集）→ `getByRole('button', { name: ... })`。CJK 漢字 2 文字（"検索" 等）は antd が自動でスペース挿入するので正規表現 `/検.*索/` を使う
2. **テーブル行 / セル** → `getByRole('row')` / `getByRole('cell', { name: ... })`
3. **フォーム input** → `getByLabel('店舗名')` / `getByPlaceholder('住所')`
4. それでも難しい場合のみ `data-testid` を実装側に追加して `getByTestId('store-row-0001')`

### Chaining and Filtering

Narrow scope by chaining locators rather than writing complex selectors:

```ts
await page
  .getByRole('listitem')
  .filter({ hasText: 'Product 2' })
  .getByRole('button', { name: 'Add to cart' })
  .click();
```

## Assertions: Always Use Web-First

Web-first assertions auto-wait and retry. Manual assertions check once and return immediately, causing flaky tests.

```ts
// ✅ Web-first — waits for condition
await expect(page.getByText('welcome')).toBeVisible();
await expect(page.getByTestId('status')).toHaveText('Success');

// ❌ Manual — no waiting, instant check, flaky
expect(await page.getByText('welcome').isVisible()).toBe(true);
```

Key rule: `await` goes **before** `expect(...)`, not inside it.

## Soft Assertions

Use `expect.soft()` when you want to collect multiple failures without aborting the test early:

```ts
await expect.soft(page.getByTestId('status')).toHaveText('Success');
await expect.soft(page.getByTestId('count')).toHaveText('3');
// Test continues even if above checks fail; all failures reported at end
```

## Test Isolation

Each test must be fully independent — own storage, cookies, data. Never rely on execution order or shared state between tests.

Use `beforeEach` for shared setup (navigation, auth), not for coupling tests:

```ts
test.beforeEach(async ({ page }) => {
  await page.goto('https://example.com/login');
  await page.getByLabel('Username').fill('user');
  await page.getByLabel('Password').fill('pass');
  await page.getByRole('button', { name: 'Sign in' }).click();
});
```

For heavy auth flows, use Playwright's **setup project** to sign in once and reuse stored state across tests.

## Mock Third-Party Dependencies

Never test external sites or third-party APIs you don't control. Use the Network API to intercept and mock:

```ts
await page.route('**/api/fetch_data_third_party_dependency', route =>
  route.fulfill({ status: 200, body: testData })
);
await page.goto('https://example.com');
```

## Parallelism and Sharding

Tests across files run in parallel by default. To parallelize tests **within** a single file:

```ts
test.describe.configure({ mode: 'parallel' });
```

For CI, shard across machines:

```bash
npx playwright test --shard=1/3
```

## CI Configuration

- **Use Linux on CI** — cheaper and consistent.
- **Install only needed browsers** to save time and disk:
  ```bash
  # ✅ Install only what you test
  npx playwright install chromium --with-deps

  # ❌ Installs all browsers unnecessarily
  npx playwright install --with-deps
  ```
- **Use traces on CI** (configured for first retry of failed tests, not every run — traces are expensive).
- Run `tsc --noEmit` on CI to catch type errors.

## Debugging

- **Local**: Use the VS Code extension — set breakpoints, live-edit locators, inspect matches in the browser.
- **CLI**: `npx playwright test --debug` opens the Playwright Inspector for step-through debugging.
- **Specific test**: `npx playwright test example.spec.ts:9 --debug`
- **CI failures**: Use the **Trace Viewer** (not screenshots/videos). Traces show timeline, DOM snapshots, network requests.
  ```bash
  npx playwright test --trace on        # record traces locally
  npx playwright show-report            # view HTML report with traces
  ```

## Linting

Use TypeScript (`.ts` extension) and enable the ESLint rule `@typescript-eslint/no-floating-promises` to catch missing `await` calls on Playwright API methods.

## Cross-Browser Testing

Configure multiple browser projects in `playwright.config.ts`:

```ts
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],
});
```

## Database Testing

When tests depend on a database, always control the data. Use a staging environment with stable, predictable data. For visual regression tests, pin OS and browser versions.

## CRUD 検証パターン（推奨ヘルパー）

**全 CRUD spec は次の構造に準拠する**。ヘルパーが無いプロジェクトでは spec ごとに write しても OK だが、3 ファイル以上で繰り返したら `e2e/helpers/crud-verify.ts` に切り出す。

```ts
// 推奨: 「保存→ reload→ 全フィールド verify→ teardown」フルフロー
test('店舗作成', async ({ page, storeSeed }) => {
  await page.goto('/#/department/store');

  // 1. 全 input を fill
  await page.getByRole('button', { name: '店舗追加' }).click();
  const dialog = page.getByRole('dialog');
  await dialog.getByLabel('店舗名').fill('E2E 新規店舗');
  await dialog.getByLabel('住所').fill('東京都渋谷区1-2-3');
  await dialog.getByLabel('郵便番号').fill('1500001');
  // ... 他の必須 input すべて

  // 2. 保存実行
  await dialog.getByRole('button', { name: /保.*存/ }).click();
  await expect(dialog).toBeHidden();

  // 3. 一覧に reload して反映 verify
  await page.reload();
  const newRow = page.getByRole('row').filter({ hasText: 'E2E 新規店舗' });
  await expect(newRow).toBeVisible();
  await expect(newRow.getByRole('cell', { name: '東京都渋谷区1-2-3' })).toBeVisible();

  // 4. 詳細に遷移して全 input 反映 verify（更新時は未変更フィールドの保持も verify）
  await newRow.click();
  await expect(page.getByLabel('店舗名')).toHaveValue('E2E 新規店舗');
  await expect(page.getByLabel('住所')).toHaveValue('東京都渋谷区1-2-3');
  // ... 全 input

  // 5. teardown は fixture が担当
});
```

## CSV ダウンロード検証パターン

**ボタン存在のみ verify は禁止**。download event を待ってファイル内容を verify する。

```ts
test('予約 CSV 出力', async ({ page }) => {
  await page.goto('/#/booking/list');

  const [download] = await Promise.all([
    page.waitForEvent('download'),
    page.getByRole('button', { name: /CSV.*出力/ }).click(),
  ]);

  const path = await download.path();
  const content = await fs.promises.readFile(path!, 'utf8');

  // ヘッダー + 1 行以上の verify が必須
  expect(content.split('\n')[0]).toContain('予約ID,担当者,顧客名');
  expect(content.split('\n').length).toBeGreaterThan(1);
});
```

## ステータス分岐の網羅検証パターン

**全 enum 値を verify する**。1 値だけでは本番大半が別ステータスならバグ検出できない（lesson: BOOKING_STATUS の全ライフサイクル）。

```ts
test.describe('BOOKING_STATUS UI', () => {
  for (const status of ['REQUESTED', 'CONFIRMED', 'COMPLETED', 'CANCELED', 'DECLINED'] as const) {
    test(`${status} の予約は適切なバッジで表示される`, async ({ page }) => {
      await page.route('**/m_getBookings', (route) =>
        route.fulfill({
          status: 200,
          body: JSON.stringify({ bookings: [{ id: 'b1', status }] }),
        }),
      );
      await page.goto('/#/booking/list');
      const row = page.getByRole('row').filter({ hasText: 'b1' });
      await expect(row.getByRole('cell', { name: STATUS_LABEL[status] })).toBeVisible();
    });
  }
});
```
## ローカル実行手順

- [execution.md](./execution.md) — Docker (MongoDB/Redis) + test-server + admin (Vite e2e モード) + Playwright のローカル実行手順。worktree のポート割当・環境変数・トラブルシューティングを含む。

## 過去の教訓

- [lesson.md](./lesson.md) — 過去のレビュー指摘から学んだパターン。テスト作成・修正前に必ず確認すること。

## Key Principles Summary

1. Test **user-visible behavior**, not implementation details.
2. Use **user-facing locators** (role, label, text, testid) — never CSS classes or DOM paths.
3. Always use **web-first assertions** (`await expect(...).toBeVisible()`) — never manual checks.
4. Keep tests **isolated** — no shared state, no ordering dependencies.
5. **Mock** third-party APIs — only test what you control.
6. Keep Playwright **up to date** — test against latest browser versions before public release.
7. Run tests on **every commit/PR** on CI.
8. **Verify, don't tour**: 画面を巡回するだけのテストではなく、CRUD のサーバー反映 / セル単位の値 / 全分岐 / バリデーション / 全 input を verify する。
9. **Fixture seed > 環境依存 skip**: `if (...isVisible.catch).toFalse → test.skip` は seed が無くても PASS してしまうので禁止。fixture で seed を強制する。
10. **Visual regression は機能テストから分離**: `toHaveScreenshot` は `e2e/visual/` に集約する。
