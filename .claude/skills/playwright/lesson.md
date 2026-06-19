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

## Playwright 自動化（ブラウザ駆動クライアント）実装パターン

> 上記は E2E テスト作成のパターン。以下は Playwright をスクレイピング/自動化クライアント
> （例: `SalonboardPlaywrightClient`）として使う実装で学んだパターン。

### 成功判定を「最終ページ」で読むとアカウント種別差で false-negative になる（必須）
- **問題**: ログイン等の成功シグナル（例: `userid : '...'`）を **遷移後の最終ページ HTML** から読むと、アカウント種別で着地ページが異なる場合に取りこぼす。実例（GTSS-817 #22）: pure HTTP 実装は doLogin 応答から `userid` を直接読んでいたが、Playwright 移植時に「クリック→遷移後の `page.content()`」から読むようにしたところ、**会社アカウントは login 後 `/CNC/groupTop/`（userid あり）だが、単一店舗アカウントは `/CLP/bt/top/`（店舗トップ・userid なし）へ遷移**するため、ログイン成功なのに `ok:false`（false-negative）になった。実機 T-11 で初めて顕在化（unit fake では会社アカウントの着地ページしか模していなかった）。
- **正しい対応**: 成功シグナルが載る **中間レスポンス（doLogin 等）を `page.on('response')` で捕捉**して判定する。最終ページにも残る場合があるのでフォールバックとして併用する。
  ```ts
  let body = '';
  page.on('response', async (resp) => {
    try {
      if (String(resp.url()).includes('/CNC/login/doLogin/')) {
        const t = await resp.text();
        if (t) body = t; // 途中 redirect 等で複数発火しても最終本文を採用
      }
    } catch { /* 個別応答の本文取得失敗は無視 */ }
  });
  await page.click('a.loginBtnSize');
  await page.waitForLoadState('networkidle').catch(() => {});
  await page.waitForTimeout(1200); // response handler(async text) の settle 待ち
  const finalHtml = await page.content();
  const userId = parseUserId(body) || parseUserId(finalHtml); // 中間応答 → 最終ページの順
  ```
- **補足**: `page.waitForResponse(predicate)` は「最初にマッチした応答」を返すため、途中 redirect で複数発火するフローでは目的の本文を取り逃すことがある（実際に最初これで詰まった）。`page.on('response')` で最後にマッチした本文を保持する方が確実。
- **テストの教訓**: pure 関数（成功判定）は単体テストできても、**「どのページから読むか」はアカウント種別ごとに着地が変わる**ため fake だけでは漏れる。fake には「成功シグナルが中間応答のみにあり最終ページには無い」ケース（単一店舗）も必ず含める（回帰テスト T-1b）。

### 実ブラウザ自動化は「実機 1 本」を必ず通す（pure 関数の単体テストだけでは足りない）
- **問題**: ブラウザ駆動クライアントはセレクタ・遷移・Akamai 等の bot 保護・アカウント種別差など、fake では再現しきれない要素が多い。pure ヘルパー（パース・判定）の単体テストが green でも、実機で初めて壊れる（上記 login false-negative も実機 T-11 で発覚）。
- **正しい対応**: CI では fake + fixture で論理を担保しつつ、**実アカウント・実プロキシでの「login → 一覧 → 詳細」最低 1 本を人手 PDCA で必ず通す**。外部・bot 保護下で CI 不可なら人手確認を受け入れ条件に明示する。

### 取得結果は「生 HTML/JSON」で返し、パースは純粋関数へ分離する
- **問題**: ブラウザ内で DOM 抽出までやると transport と parse が密結合になり、fixture 単体テストが書けず HTTP 実装との挙動差も出る。
- **正しい対応**: クライアントは `page.content()` / ページ内 `fetch` の **生レスポンスをそのまま返し**、解析は純粋関数（`parseReservationList` 等）へ委譲する。これで HTTP/Playwright どちらの transport でも同一パーサ・同一 fixture テストを共有でき、実機で採取した HTML をそのまま fixture 化できる（PII は置換）。

### フォーム検索が「サイレント0件」なら submit 先 URL（action+method）を疑う（必須）
- **問題**: Struts/jQuery 等のフレームワークでは、検索ボタンの click handler が **form の action にメソッド名を付与して** submit することがある。例: SalonBoard キレイは `$.shuhari.formSubmit("reserveList","search")`（`formSubmit = (id, method) => { $form.attr('action', action + method); $form.submit(); }`）で、action `/KLP/reserve/reserveList/` ＋ `search` → 実際は **`POST /KLP/reserve/reserveList/search`** へ送られる。form の action 属性（base パス）にそのまま `fetch`/`form.submit()` で POST すると、**サーバは検索を実行せず初期フォーム（0件）を返す**。例外も 4xx も出ず「正常に0件」に見えるため、フィルタ条件や日付範囲のせいだと誤診しやすい（実際この案件で「広い期間・状態無指定でも0件」を当初フィルタの問題と取り違えた）。
- **正しい対応**:
  - `form.submit()` / action への raw POST を鵜呑みにせず、**検索ボタンの実 handler（バンドル JS の click handler）を読んで** 実際の submit 先 URL・追加パラメータ・hidden flag を確認する。`href="javascript:void(0)"` のボタンは必ず JS handler 経由。
  - **「広い条件でも0件」なら submit が効いていない可能性をまず疑う**（フィルタではなく送信先）。初期フォーム GET と検索 POST のレスポンスを比較（サイズ／結果テーブルの有無）して、検索が実行されたか確認する。
  - 修正は HTTP / Playwright **両トランスポートに同じ submit 先**を反映する（片方だけ直すと取り違える）。
- **教訓（実構造は実データで確定する）**: 実機で「行が出る条件」をユーザー/実機で1本通してから、一覧行・詳細のパース構造を確定する。**推定構造は実構造とズレる**: 今回は (1) 列見出しの `<br>` 由来の空白（「ステー タス」でラベル不一致）、(2) 来店日時が `MM/DD`（年なし→取得期間から補完が必要）、(3) 氏名セルに「(予約番号)」混入、(4) 金額の二段表記（先頭値のみ採用）が、いずれも実 HTML で初めて判明した。0件店舗の推定 fixture だけでテストを green にすると、実データで壊れる。
