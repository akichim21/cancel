---
issue: 3
date: 2026-06-04
repos:
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: feature/GTSS-13
    toBranch: feature/GTSS-13-vitest
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: feature/GTSS-13
    toBranch: feature/GTSS-13-vitest
---

# レビュー結果: #3

## 概要

**Issue:** #3 管理画面に自動テスト基盤(Vitest + Playwright)を導入し申請審査/キャンセル請求を担保

管理画面（admin）に Vitest unit + Playwright E2E 基盤を新規導入し、REQ-2/3/4 の審査・フィルタ・キャンセル請求ロジックを JSX 直書きから純関数（`src/constants/{applicationStatus,cancellationStatus}.ts`）へ**挙動不変で抽出**したうえで単体/E2E テストを追加。あわせて api 側は GTSS-13 スキーマ移行に追従して既存 e2e テストへ移行カラムの expect を補完（テストファイルのみ）。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| admin | `feature/GTSS-13` | `feature/GTSS-13-vitest` | 2 | 28（うち package-lock.json 含む） |
| api | `feature/GTSS-13` | `feature/GTSS-13-vitest` | 1 | 8 |

> 注: base（`feature/GTSS-13`）はこの PR の分岐点より先に進んでいる（schema refactor の merge）。本レビューは三点リーダ diff（`base...toBranch`）= GitHub PR と同じ差分を対象にしている。マージ前に base へ追従（rebase/merge）すると Invoice 型リネーム等との整合確認が別途必要。

## 変更ファイル一覧

### admin

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `vitest.config.ts` | +33 | 0 | Added |
| `playwright.config.ts` | +49 | 0 | Added |
| `tsconfig.vitest.json` | +17 | 0 | Added |
| `tsconfig.json` | +7 | 0 | Modified |
| `src/test/setup.ts` | +21 | 0 | Added |
| `src/test/utils.tsx` | +61 | 0 | Added |
| `src/constants/applicationStatus.ts` | +69 | 0 | Modified |
| `src/constants/applicationStatus.test.ts` | +99 | 0 | Modified |
| `src/constants/cancellationStatus.ts` | +111 | 0 | Added |
| `src/constants/cancellationStatus.test.ts` | +142 | 0 | Added |
| `src/components/ApplicationDetail.tsx` | +~25 | -~17 | Modified（抽出） |
| `src/components/ApplicationList.tsx` | +~15 | -~11 | Modified（抽出） |
| `src/components/CancellationManagement.tsx` | +~30 | -~45 | Modified（抽出） |
| `src/components/__tests__/ApplicationDetail.test.tsx` | +88 | 0 | Added |
| `src/components/__tests__/ApplicationList.test.tsx` | +102 | 0 | Added |
| `src/components/__tests__/CancellationManagement.test.tsx` | +89 | 0 | Added |
| `src/components/__tests__/Dashboard.test.tsx` | +50 | 0 | Added |
| `src/components/__tests__/LoginPage.test.tsx` | +86 | 0 | Added |
| `e2e/fixtures.ts` | +111 | 0 | Added |
| `e2e/helpers/auth.ts` | +33 | 0 | Added |
| `e2e/auth.setup.ts` | +14 | 0 | Added |
| `e2e/auth.spec.ts` | +29 | 0 | Added |
| `e2e/application.spec.ts` | +84 | 0 | Added |
| `e2e/cancellation.spec.ts` | +69 | 0 | Added |
| `package.json` | +15 | -? | Modified |
| `CLAUDE.md` | +? | -? | Modified |
| `.gitignore` | +6 | 0 | Modified |
| `package-lock.json` | 大量 | 大量 | Modified（依存追加） |

### api（テストファイルのみ・プロダクションコード変更なし）

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/__tests__/e2e/db-defaults.test.js` | +41 | 0 | Added |
| `src/__tests__/e2e/stripe-pay.test.js` | +14 | 0 | Modified |
| `src/__tests__/e2e/response-contract.test.js` | +18 | -4 | Modified |
| `src/__tests__/e2e/applications.test.js` | +12 | -2 | Modified |
| `src/__tests__/e2e/cancellations-invoices.test.js` | +4 | -1 | Modified |
| `src/__tests__/e2e/monthly-sales-id.test.js` | +4 | 0 | Modified |
| `src/__tests__/e2e/process-stripe-account-integration.test.js` | +3 | 0 | Modified |
| `src/__tests__/e2e/auth.test.js` | +2 | 0 | Modified |

## 指摘一覧

- [x] 対応する

> 重大バグ・セキュリティ問題は検出されませんでした（High なし）。純関数抽出は3エージェント + メインで base と 1:1 照合し**挙動不変を確認**、api の expect 追加もプロダクションコード（`webhook.service.ts` / `serializeApplication` / repository）と突き合わせて**実挙動一致を確認**。以下はすべて Medium / Low の堅牢性・テスト強化提案です。

---

### [Code Quality] テストコードが型チェックの対象外で、test/e2e の型エラーが CI をすり抜ける

**ファイル:** `admin/tsconfig.json`, `admin/tsconfig.vitest.json`, `admin/package.json`
**重要度:** Medium

**該当コード:**
```jsonc
// tsconfig.json — test/e2e は exclude、references は node のみ
"exclude": [
  "src/**/*.test.ts", "src/**/*.test.tsx",
  "src/**/__tests__/**", "src/test/**", "e2e/**"
],
"references": [{ "path": "./tsconfig.node.json" }]   // ← tsconfig.vitest.json は未登録
```
```jsonc
// package.json — build は tsconfig.json を使う tsc。tsconfig.vitest.json を呼ぶ script が無い
"build": "tsc && vite build",
"test": "vitest run",            // vitest は型チェックしない（esbuild トランスパイル）
// （typecheck:test / tsc -p tsconfig.vitest.json 相当が無い）
```

**問題:** `tsconfig.vitest.json` は作られているが、(1) `tsconfig.json` の `references` に登録されておらず、(2) いずれの npm script からも `tsc -p tsconfig.vitest.json` で呼ばれず、(3) `vitest.config.ts` に `typecheck` ブロックも無い。結果、テスト/E2E コードは**どのコマンドでも型チェックされない**（`build` の `tsc` は test を exclude、`vitest run` は型を見ない）。`tsconfig.vitest.json` が実質デッドコンフィグになり、テストの型エラーが静かに通る。

**修正提案:** `package.json` に `"typecheck:test": "tsc --noEmit -p tsconfig.vitest.json"` を追加し、`test` か CI ゲートに組み込む（あるいは `tsconfig.json` の `references` に追加して `tsc -b` で拾わせる）。

---

### [Test Coverage] Playwright の webServer が `VITE_API_URL` を固定しておらず、E2E が共有 dev API（実環境）へ向く構成

**ファイル:** `admin/playwright.config.ts:41-47`, `admin/.env.development`, `admin/e2e/fixtures.ts`
**重要度:** Medium

**該当コード:**
```ts
// playwright.config.ts — webServer.env は BROWSER しか渡さない
webServer: {
  command: `npm run dev -- --port ${port} --strictPort`,
  url: baseURL,                 // http://localhost:3004
  reuseExistingServer: !isCI,
  timeout: 120_000,
  env: { BROWSER: 'none' },     // ← VITE_API_URL を baseURL に固定していない
},
```
```bash
# .env.development（コミット版）— dev サーバはこれをロードする
VITE_API_URL=https://dev.api.cancel.co.jp   # ← baseURL(localhost:3004) と cross-origin、かつ共有実 dev API
```

**問題:** `webServer` が `npm run dev` を development モードで起動するため Vite は `.env.development` をロードし、`ApiService` は `https://dev.api.cancel.co.jp`（共有 dev 実環境・cross-origin）を base に使う。E2E は `page.route` で `**/auth/admin-login` `**/applications/*` `**/cancellations/*` 等を mock するが、**mock グロブに当たらないリクエストは fallback されず実 dev API に到達し得る**（共有環境への副作用リスク）。加えて cross-origin + JSON/Authorization の preflight を mock 側が CORS ヘッダ付きで返さないため、環境依存で preflight が壊れる潜在的脆さもある（Completion では 10/10 passed と報告されており現状の作者環境では成立しているが、env 依存で不安定になりうる）。

**修正提案:** `webServer.env`（または `use.env` 相当）で `VITE_API_URL` を `baseURL` と同一オリジンに固定する。これにより (a) 未 mock リクエストが共有 dev API に漏れない、(b) cross-origin preflight 起因の env 依存 fragility を解消できる。

---

### [Test Coverage] Playwright のサマリー件数/バッジを Tailwind 配色クラスで特定しており、スタイル変更に脆い

**ファイル:** `admin/e2e/cancellation.spec.ts:18-19`（および `CancellationManagement.tsx:152,156`）
**重要度:** Low

**該当コード:**
```ts
// e2e/cancellation.spec.ts
const paidCount    = (page) => page.locator('p.text-green-600.text-3xl');
const pendingCount = (page) => page.locator('p.text-yellow-600.text-3xl');
```
```tsx
// CancellationManagement.tsx（参照先・現状は一意に一致する）
<p className="text-yellow-600 text-3xl ...">{summary.pending}</p>
<p className="text-green-600 text-3xl ...">{summary.paid}</p>
```

**問題:** 配色ユーティリティクラス（`text-green-600` / `text-3xl`）にロケータが強結合。現状はクラスが一意で**テストは正しく通る**（cross-file 確認済み）が、配色やサイズを1つ変えると機能無傷でも E2E が落ちる。

**修正提案:** サマリーカードに `data-testid="summary-paid"` 等を付与（表示不変）し `getByTestId` で参照する。テスト容易化のための最小 DOM 追加は許容範囲。

---

### [Test Coverage] api の動的タイムスタンプ assertion が `expect.any(String)` で緩く、回帰を取り逃す（3箇所）

**ファイル:** `api/src/__tests__/e2e/stripe-pay.test.js:52,65` / `process-stripe-account-integration.test.js:58` / `cancellations-invoices.test.js:160`
**重要度:** Low

**該当コード:**
```js
// stripe-pay.test.js — paidAt と sales.lastUpdated は同一 paymentDate 由来（webhook.service.ts で確認）
expect(persisted.paidAt).toEqual(expect.any(String));
...
expect(sales.lastUpdated).toEqual(expect.any(String));
```
```js
// process-stripe-account-integration.test.js — コメントは「ISO 文字列」だが assert は任意文字列
expect(users[0].userActivatedAt).toEqual(expect.any(String));
```
```js
// cancellations-invoices.test.js — 「updatedAt を更新して返す」と言うが、更新の事実を証明できない
expect(body.updatedAt).toEqual(expect.any(String));
```

**問題:** いずれも実装は ISO タイムスタンプを書き込む（プロダクションコードで裏取り済み）が、`expect.any(String)` は非 ISO 文字列・タイムスタンプ誤り・「更新されていない既存値」を検出できない。コメントが主張する契約（ISO 形式・更新の発生）を assertion が担保していない。

**修正提案:**
- ISO 形式の正規表現で検証（例: `expect(x).toMatch(/^\d{4}-\d{2}-\d{2}T.*Z$/)`）。
- `stripe-pay`: `expect(sales.lastUpdated).toBe(persisted.paidAt)` を追加し、両者が同一 `paymentDate` 由来であることを固定。
- `cancellations-invoices`: seed 時に古い `updatedAt` を投入し `expect(body.updatedAt).not.toBe(oldUpdatedAt)` で「更新の発生」を担保。

---

### [Test Coverage] 詳細画面「承認」(confirm 承諾) の Playwright ケースが無い（Vitest では担保済み）

**ファイル:** `admin/e2e/application.spec.ts`
**重要度:** Low

**問題:** E2E は「一覧から承認(確認なし)」「詳細から却下(確認あり)」「Stripe送信」「フィルタ」をカバーするが、**詳細画面の「審査通過（Stripe登録へ）」(window.confirm 承諾) → `Stripe登録待ち`** の経路は E2E に無い。ただしこの confirm 経路は `ApplicationDetail.test.tsx`（Vitest）で `window.confirm` mock true により担保されており、AC-2.2 にマップされる T-6 は「一覧の承認」を指すため**機能未担保ではなく E2E レイヤの観点漏れ**。

**修正提案（任意）:** pending 申請を詳細で開き「審査通過（Stripe登録へ）」→ dialog accept → バッジ `Stripe登録待ち` を検証する Playwright ケースを1本追加すると、詳細側 confirm 経路まで結合担保できる。

---

### [Code Quality] Issue/AC が参照する `npm run e2e` が存在せず `test:e2e` のみ（実装内では一貫）

**ファイル:** `admin/package.json:14-15`
**重要度:** Low

**該当コード:**
```jsonc
"test:e2e": "playwright test",
"test:e2e:ui": "playwright test --ui"
// "e2e": ... は無い
```

**問題:** Issue の REQ-1 / AC-1.1 / Docs Updates は `npm run e2e` を要求するが、実際の script は `test:e2e`。`npm run e2e` は失敗する。ただし PR の `CLAUDE.md` も `npm run test:e2e` に更新済みで**実装内では一貫**しており、Issue 側の文言だけが旧称。

**修正提案:** `package.json` に `"e2e": "playwright test"` エイリアスを足すか、Issue/AC の文言を `test:e2e` に揃える（どちらでも可）。

---

### [Test Coverage] 純関数テストの軽微な境界漏れ（任意）

**ファイル:** `admin/src/constants/cancellationStatus.test.ts`, `admin/src/constants/applicationStatus.test.ts`
**重要度:** Low

**問題:**
- `cancellationCsvFilename` は固定 `Date` を渡す経路のみ検証し、実コードで実際に使われる**引数省略（`new Date()`）経路**を踏んでいない。
- `filterApplications` の電話検索テストは `phone` 欠落行が phone 検索語にマッチしない境界を固定していない（抽出時に `(app.phone && …)` → `(app.phone ? … : false)` へ書換。OR 連鎖上は等価と確認済みだが境界固定が無い）。

**修正提案（任意）:**
- `expect(cancellationCsvFilename()).toMatch(/^キャンセル請求_\d{4}-\d{2}-\d{2}\.csv$/)` を1件追加。
- `filterApplications(apps, { statusFilter:'all', searchTerm:'09011' })` が phone 欠落行を除外することを1件追加。

---

## 確認したが問題なしだった主要観点（参考）

- **純関数抽出の挙動不変（最重要）**: `getAvailableStatusActions`（pending→[承認/却下], approved→[利用開始], rejected→[再審査], onboarding/active→[], 未知→[]）、`normalizeStatusFilter`（英語 enum allowlist、旧日本語/無効値→`all`）、`filterApplications`、`filterCancellations`（全フィールド undefined 行が空検索でも除外される現挙動の保持）、`summarizeCancellations`、`buildCancellationCsv`（BOM・全セルクォート・`"`→`""`・カンマ/空値・`toLocaleDateString('ja-JP')`・ファイル名）、`getCancellationStatusColor/Label` を base と 1:1 照合し**すべて一致**。一覧「承認」=confirm なし / 詳細「却下」=confirm あり の差異も実 UI と一致。
- **api expect 追加の実挙動一致**: `entityType`/`entityTypeLabel`（`法人→corporate/法人`, `個人→individual/個人`）の正規化契約、決済フロー固定値（`paidAmount:7000` / `monthly_sales.total:7000` / `invoiceCount:1` / `monthYear:'2026-05'`）、`db-defaults.test.js`（`.default('active')`/`false`/`0`）、`auth` の `not.toHaveProperty('password')`（`adminLogin` の allowlist に password 無し）を全てプロダクションコードと突き合わせて確認。`expect.any(String)` はランタイム生成 ISO 値に限定（上記 Low の強化余地はあるが過度に緩くも脆くもない）。
- **既存挙動の追認（スコープ外）**: `buildCancellationCsv` はセル内改行を生 `\n` のまま保持（レコード区切りも `\n`）し Excel 等で行ズレし得るが、これは**base 由来の既存挙動を忠実に保存**したもので本 PR の回帰ではない。CRLF 化は別 Issue 扱いが妥当。
- **lessons 照合**: env 変数（`VITE_API_URL` 採用は実コード/`.env` と一致、ルート `CLAUDE.md` の `VITE_API_BASE_URL` 記述が逆に古い）、ステータス enum 新旧混在（正規化契約の意図的テストで違反なし）、テスト空洞化/モック過剰（外部 I/O 境界のみ mock、件数/金額/ラベルは具体値で検証）いずれも**lesson 違反なし**。
- **設定整合**: `playwright.config.ts` の port 3004 / `--strictPort` / setup→chromium storageState 再利用 / login プロジェクト分離 / `BROWSER:none`、`vitest.config.ts` の jsdom + CSS モック + e2e/dist 除外、いずれも妥当。

## 総評

非常に質の高い PR。コアである「JSX 直書きロジックの純関数抽出」は **3 レビューエージェント + メインが独立に base と 1:1 照合して挙動不変を確認**しており、テストも空洞でなく実挙動（件数・金額・ラベル・ステータス遷移・confirm 経路差・CSV エスケープ）を具体値で固定している。api 側の expect 追加もプロダクションコードと突き合わせて実挙動一致を確認済みで、誤った assertion は無い。

**重大バグ・セキュリティ問題は無く（High なし）、マージ可能水準**。残る指摘は堅牢性/テスト強化の Medium 2 件（テストの型チェック未配線、Playwright が共有 dev API へ向く構成）と Low 5 件で、いずれもブロッカーではない。マージ前に推奨するのは Medium 2 件の対応（特に `VITE_API_URL` の固定は共有 dev 環境への副作用回避の観点で価値が高い）。Low の assertion 強化は余力に応じて。AC-6.1 の人力目視（`npm run dev` でバッジ色/アクション/サマリーが抽出前と一致）は別途残課題。
