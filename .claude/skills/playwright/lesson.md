# Playwright Lesson - レビュー指摘パターン集

> このファイルはPlaywright E2E関連のレビュー指摘や実装中に学んだパターンを記録します。
> Playwrightテスト作成時に自動で読み込まれ、同じミスの再発を防ぎます。

## パターン一覧

### 画面に表示される変数値は可能な限りexpectで検証する（必須）
- **問題**: 画面遷移やボタンの存在確認だけでは、表示されている金額・日時・件数などの値が正しいか検証できない。管理画面の表やフォームの計算ミスを見逃す
- **正しい対応**: 動的に表示される値（金額、日付、件数、ステータス、サロン名など）は `expect(locator).toHaveText()` / `toContainText()` で検証する
- **対象例**:
  - テーブル行: 各カラムの値（金額、日付、ステータス、名前）
  - 詳細画面: フォームフィールドの値、計算結果
  - ダッシュボード: 集計値、件数表示
  - キャンセル請求一覧: 金額、決済方法、ステータス
- **例**:
  ```typescript
  // NG: 要素の存在だけ確認
  await expect(page.locator('.cancellation-row')).toBeVisible();

  // OK: 表示値まで検証
  const row = page.locator('.cancellation-row').first();
  await expect(row.locator('.total-price')).toHaveText('¥8,800');
  await expect(row.locator('.status')).toHaveText('決済完了');
  await expect(row.locator('.payment-method')).toHaveText('クレジットカード');
  await expect(row.locator('.salon-name')).toContainText('テストサロン');

  // テーブルの行数も検証
  await expect(page.locator('.cancellation-row')).toHaveCount(3);
  ```
- **原則**: 「画面が表示された」「要素が存在する」だけでは不十分。表示されている数字・テキストが正しいことまで検証する

### CRUD操作テストはデータが実際に更新されたことまで確認する（必須）
- **問題**: 作成・編集モーダルの表示やボタンクリックだけ確認し、実際にデータが作成・更新されたかを検証しないテストはバグを見逃す
- **正しい対応**: モーダルで入力→保存→一覧に戻った後、作成/更新されたデータが画面上に反映されていることをexpectで確認する
- **例**:
  ```typescript
  // NG: モーダルの表示確認だけ
  await page.getByText('追加').click();
  await expect(page.locator('.ant-modal-content')).toBeVisible();

  // OK: 作成→保存→一覧で新しいデータを確認
  await page.getByText('追加').click();
  await page.getByLabel('名前').fill('テストサロン');
  await page.getByText('保存').click();
  await expect(page.getByRole('dialog')).not.toBeVisible();
  await expect(page.getByText('テストサロン')).toBeVisible();

  // OK: 編集→保存→更新後の値を確認
  await page.getByText('編集').first().click();
  await page.getByLabel('名前').clear();
  await page.getByLabel('名前').fill('更新後の名前');
  await page.getByText('保存').click();
  await expect(page.getByText('更新後の名前')).toBeVisible();
  ```

### 一覧・詳細テストはseedデータの実際の値を検証する（必須）
- **問題**: カラムヘッダーやラベルの存在だけ確認し、テーブルセルや詳細フィールドに表示される実際のデータ値を検証しないと、APIからのデータ取得やレンダリングのバグを見逃す
- **正しい対応**: ラベル確認に加え、seedで投入したデータの具体的な値（名前、金額、ステータス等）がテーブル行や詳細画面に表示されていることを検証する
- **例**:
  ```typescript
  // NG: カラムヘッダーだけ確認
  await expect(page.getByText('サロン名')).toBeVisible();
  await expect(page.getByText('申請ステータス')).toBeVisible();

  // OK: ヘッダー + seedデータの実際の値を確認
  await expect(page.getByText('サロン名')).toBeVisible();
  const row = page.getByRole('row').nth(1);
  await expect(row).toContainText('E2Eテストサロン');
  await expect(row).toContainText('利用中');

  // 詳細画面でも同様
  await expect(page.getByText('E2Eテストサロン')).toBeVisible();
  await expect(page.getByText('5,000')).toBeVisible();
  ```

### フィルターテストは実際にフィルター結果が変化したことを確認する（必須）
- **問題**: フィルターUIの存在確認やクリック操作だけでは、フィルターが実際にデータを絞り込んでいるか検証できない
- **正しい対応**: フィルター適用前後で、表示される行数や内容が変化していることを確認する。フィルター条件に一致するデータが表示され、一致しないデータが非表示になることを検証する
- **例**:
  ```typescript
  // NG: フィルターUIの存在だけ確認
  await expect(page.locator('.ant-select')).toBeVisible();

  // OK: フィルター前の行数を記録→フィルター適用→結果が変化
  const rowsBefore = await page.locator('.ant-table-row').count();
  await page.locator('.ant-select').click();
  await page.getByText('PAYMENT_SUCCESS').click();
  await page.getByText('検索').click();
  await page.waitForLoadState('networkidle');
  // フィルター後は結果のステータスがすべて一致
  const rows = page.locator('.ant-table-row');
  const count = await rows.count();
  for (let i = 0; i < count; i++) {
    await expect(rows.nth(i)).toContainText('PAYMENT_SUCCESS');
  }
  ```

### admin ログイン用の運営管理者ユーザーが seed に必要
- **問題**: Playwright e2eテスト（admin login）が管理者アカウントを使うが、seed データに運営管理者ロールのユーザーがなくログインに失敗する
- **正しい対応**: seed スクリプトに運営管理者ロールの admin ユーザーを追加する
- **例**: `{ email: 'admin@example.com', password: '...', role: 'OPERATOR', status: 'ACTIVE' }`

### seed スクリプトのworktreeパス問題
- **問題**: seed スクリプトが相対パスで API リポジトリを解決すると、worktree 内ではパスが壊れて `cancel-billing-service-api` が見つからない
- **正しい対応**: `git rev-parse --show-toplevel` で元リポジトリのルートを取得し、そこから `cancel-billing-service-api` を探すフォールバックを入れる

### storageState: undefined は親設定を継承する（重要）
- **問題**: `test.use({ storageState: undefined })` はプロジェクトレベルの `storageState` をクリアせず**継承する**。別ユーザーでログインするテスト（例: AMアカウント）がADMINセッションのまま実行され、権限テストが全て失敗する
- **正しい対応**: ストレージを明示的にクリアするには `test.use({ storageState: { cookies: [], origins: [] } })` を使う
- **影響**: 同じユーザー（ADMIN）でログインするテストでは問題にならないため発見が遅れやすい。別ユーザーでのテストのみ顕在化する

### antdボタンのCJK文字間スペース
- **問題**: antdがボタン内の漢字2文字の間に自動でスペースを挿入する（例: "検索" → "検 索"）。`getByRole('button', { name: '検索' })` が一致しない
- **正しい対応**: 正規表現を使う: `getByRole('button', { name: /検.*索/ })`

### getByText()のstrict mode違反
- **問題**: `getByText('管理者')` のような短いテキストがサイドバー・ページヘッダー・テーブルカラムなど複数要素にマッチし、strict mode違反になる
- **正しい対応**: 以下の優先順で対処する
  1. スコープを限定: `page.locator('main').getByText('管理者')` や `page.getByRole('complementary').getByText('管理者')`
  2. `.first()` を付与
  3. `{ exact: true }` を指定
  4. より具体的なロケーター（`getByRole('columnheader', { name: '...' })`等）を使う

### auto-auth fixtureパターン（storageStateセッション切れ対策）
- **問題**: storageStateで保存したセッションが85-120秒程度で期限切れになり、後半のテストでログインページが表示されて失敗する
- **正しい対応**: `test.extend` でauto-authフィクスチャを作成し、ページ遷移時にサイドバーが見えなければ自動で再認証する。全テストファイルでこのフィクスチャを `import { test } from './fixtures'` で使用する

### seedデータのフィルター除外に注意
- **問題**: seed サロンがデフォルトの除外フィルター対象だったため、一覧に表示されず、テストが失敗した
- **正しい対応**: テスト対象のseedデータがデフォルトフィルターで除外されないか確認する。除外される場合はURL queryパラメータでフィルターを無効化する（例: `?ex=false`）

### 申請ステータスの全ライフサイクルを考慮する（重要）
- **問題**: 件数集計関数が一部の申請ステータスのみカウントし、`利用中`（利用開始済み）をカウントしなかった。ローカルの新規seedデータ（審査中 only）ではテストが通るが、本番/dev環境では大半の申請が利用中になっているため集計が合わなかった
- **正しい対応**: 申請ステータスでフィルター/カウントする際は、申請のライフサイクル全体を考慮する:
  - `GTSS審査中` → `Stripe登録待ち` → `オンボーディング待ち` → `利用中`: 集計対象に含めるか個別に判断する
  - `却下済み`: 通常は集計対象外
- **教訓**: ローカルテストで「審査中」だけ使って通っても、実環境では「利用中」が大半。**ステータスのフィルター条件はドメインロジックに照らして全ステータスをレビューする**
- **関連**: 同じ status 条件を持つ別関数も同様の問題が起きうる。片方だけ修正すると不整合が生じるので、status条件を持つ全関数を横断チェックする

---

## 監査で抽出したパターン（Playwright spec 監査）

過去の UI ライブラリ メジャーアップグレードで発生したリグレッションのうち約 60% が **既存 spec で検出できなかった** ことが判明。原因は以下のパターンが spec に蔓延していたためなので、新規 spec / リファクタ時には絶対に避ける。

### 「保存せずキャンセルする」CRUD テスト禁止（最重要）
- **問題**: 「データを壊さないために保存せずキャンセル」する CRUD テストが多数存在しがち。**保存後の反映が一切 verify されておらず、CRUD バグを完全に見逃す構造**になる
- **正しい対応**: fixture で seed → 保存 → reload → 全フィールド verify → fixture teardown のフルフロー。fixture が teardown を保証するので「データを壊す」心配はない
- **悪い例**:
  ```ts
  // ❌ NG: 値を入力したのにキャンセルで終わる
  await modal.getByLabel('サロン名').fill('テスト');
  await modal.getByRole('button', { name: 'キャンセル' }).click();
  await expect(modal).toBeHidden();
  ```
- **良い例**:
  ```ts
  // ✅ OK: fixture seed + 保存 + reload + verify
  test('サロン作成', async ({ page, salonFixture }) => {
    await modal.getByLabel('サロン名').fill('テスト');
    await modal.getByRole('button', { name: /保.*存/ }).click();
    await page.reload();
    await expect(page.getByRole('row').filter({ hasText: 'テスト' })).toBeVisible();
    // teardown は salonFixture が担当
  });
  ```

### `tableText.toContain('keyword')` 全文 contains 禁止
- **問題**: `await element.textContent()` してから `.toContain('foo')` する書き方が蔓延しがち。**行 / 列 / セルの位置を保証できず、間違った行に値が出ていても PASS する**
- **正しい対応**: `row.locator('td').nth(N).toHaveText(...)` か `getByRole('cell', { name: ... })` でセル単位検証
- **悪い例**:
  ```ts
  // ❌ NG: 全テキストに含まれていれば PASS（位置不問）
  const tableText = await page.getByRole('table').textContent();
  expect(tableText).toContain('salon2@example.com');
  expect(tableText).toContain('テストサロン');
  ```
- **良い例**:
  ```ts
  // ✅ OK: 特定の行・特定セルで verify
  const row = page.getByRole('row').filter({ hasText: 'salon2@example.com' });
  await expect(row.getByRole('cell', { name: 'テストサロン' })).toBeVisible();
  await expect(row.locator('td').nth(3)).toHaveText('利用中');
  ```

### `if (...isVisible.catch).toFalse → test.skip` 濫用禁止
- **問題**: 「seed データが無いと skip → PASS」になり、リグレッション隠蔽の false positive 量産機になりがち
- **正しい対応**: seed 必須なら `fixtures.ts` か seed スクリプトで投入を保証して無条件 expect。環境依存（外部 API 接続テストなど）で正当に skip する場合は `test.skip(condition, 'reason')` で理由明示
- **悪い例**:
  ```ts
  // ❌ NG: seed が入っていないだけで test.skip → PASS
  if (!(await editButton.isVisible({ timeout: 3_000 }).catch(() => false))) {
    test.skip();
    return;
  }
  ```
- **良い例**:
  ```ts
  // ✅ OK: fixture で seed 強制 + 無条件 expect
  test('サロン編集', async ({ page, salonSeed }) => {
    const editButton = page.getByRole('button', { name: '編集' }).first();
    await expect(editButton).toBeVisible();
    await editButton.click();
  });
  ```

### `expect(value.length).toBeGreaterThan(0)` 弱検証禁止
- **問題**: 「中身があれば PASS」で値が間違っていても通る検証が混入しがち
- **正しい対応**: 具体値（fixture の seed 値）と一致するか verify
- **悪い例**: `expect(salonNameValue.length).toBeGreaterThan(0);`
- **良い例**: `await expect(salonNameInput).toHaveValue('E2Eテストサロン');`

### `toHaveScreenshot` は機能テストから分離する
- **問題**: 機能テスト spec に screenshot を混在させがち。**フォントレンダリング差で false positive が頻発**してフレーキー
- **正しい対応**: visual regression は `e2e/visual/*.spec.ts` に集約。機能テストでは boundingBox / computed style assertion を使う
- **例**: `await expect(page.getByRole('button')).toHaveCSS('color', 'rgb(255, 255, 255)')`

### CRUD は更新フィールド以外も「保持」を verify する（部分update バグ）
- **問題**: ロール変更後にロール列だけ verify しがち。**他のフィールド（氏名 / メール / サロン）が壊れていても検出できない**
- **正しい対応**: 更新時は変更したフィールドだけでなく、変更していないフィールドが保持されていることも verify
- **理由**: 過去に「ロール変更時に他フィールドが消える」バグが発生したが、既存 spec では検出不能だった

### CSV / 印刷 / 画像アップロード等の「副作用」機能はボタン存在のみ NG
- **問題**: CSV ボタンが見えるだけ verify しがち。**実 download / 内容が壊れていても PASS**
- **正しい対応**: `page.waitForEvent('download')` でファイル取得 → ヘッダ行 + 1 行以上の内容 verify
- **画像アップロード**: 固定画像を fixture で配置してアップロード → プレビュー → 保存 → 詳細表示 verify

### フィルター / ソートは前後比較で動作検証
- **問題**: rowsBefore を取得しているが **未使用**のまま、というケースが起きがち。フィルター効いていなくても通る
- **正しい対応**: 適用前 rowCount を記録 → 適用 → rowsAfter と比較 + **残った全行が条件に一致**することを verify
- **ソート**: 「データが空でない」だけでは NG。**隣接セル値を比較**して昇順 / 降順を検証

### `expect(rowsAfter).toBeLessThanOrEqual(rowsBefore)` 弱い不等号
- **問題**: 「以下」しか確認していない → フィルター効いていなくても通る
- **正しい対応**: 厳密な期待値（`toEqual` 等）か、最低でも残存行のフィルター条件一致 verify

### antd 内部 CSS クラス (`.ant-xxx`) 依存セレクタ禁止
- **問題**: `.ant-modal-content`, `.ant-table-tbody`, `.ant-btn:has(.anticon-edit)` 等の UI ライブラリ内部クラス依存。**ライブラリのメジャーアップグレードでクラス名変更で実際に壊れた**
- **正しい対応**: `getByRole('dialog')`, `getByRole('row')`, `getByRole('button', { name: ... })` に置換
- **理由**: ライブラリのメジャーアップで一斉に壊れる脆弱性

### ハードコードされた seed ID への直接遷移禁止
- **問題**: ハードコードした ID（例: `cancellationId='d1dtJ0dzUB'`）への直接遷移。**seed 変動 / 環境差でテストが壊れる**
- **正しい対応**: fixture で seed して動的 ID を取得して遷移する

### 「ボタンを順番に試して何かクリック」する不安定なパターン禁止
- **問題**: 複数ボタンを順番に試して `addClicked` フラグで判定する書き方。**何が押されたか不確定で再現性なし**
- **正しい対応**: 期待する操作パスを spec に明示し、見つからなければ test fail にする

### 独自 login() と auto-auth fixture の二重構造を避ける
- **問題**: fixtures.ts の auto-auth と並行して spec ごとに独自 login() を持つ → メンテ時の挙動差が予測不能
- **正しい対応**: `fixtures.ts` を `roleLogin('OPERATOR' | 'SALON')` のような可変ロール対応に拡張して統一する

### 巨大 spec ファイル（1000 行超）は機能別に分割する
- **問題**: 1 つの spec に複数機能（一覧 / 詳細 / 編集 / 検索 / フィルター 等）を詰め込みがち。CI 並列度低下 + メンテ性悪化
- **正しい対応**: ファイル単位 parallel default なので、機能別 spec に分割する
