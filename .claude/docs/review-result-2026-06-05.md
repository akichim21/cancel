---
issue: 4
date: 2026-06-05
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: feature/GTSS-13
    toBranch: feature/GTSS-13-vitest
  - repo: user
    repoDir: cancel-billing-service
    baseBranch: feature/GTSS-13
    toBranch: feature/GTSS-13-vitest
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: feature/GTSS-13
    toBranch: feature/GTSS-13-vitest
  - repo: lp
    repoDir: cancel-billing-service-lp
    baseBranch: feature/GTSS-13
    toBranch: feature/GTSS-13-vitest
---

# レビュー結果: #4

## 概要

**Issue:** #4 `cancel-billing-service-lp` に自動テスト基盤（Vitest + Playwright）を導入する

> 注: 引数で指定されたブランチ `feature/GTSS-13-vitest`（base `feature/GTSS-13`）は **4 リポジトリ横断**でテスト基盤を束ねたブランチ。Issue #4 は LP のみを対象とするが、本ブランチには user(GTSS-2) / admin(GTSS-3) / api(GTSS-13) のテスト基盤・テスト追加も含まれるため、4 リポジトリすべてをレビュー対象とした。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数（lockfile 除く） |
|-----------|-------------|------------|----------|------------|
| api | `feature/GTSS-13` | `feature/GTSS-13-vitest` | 4 | 14 |
| user | `feature/GTSS-13` | `feature/GTSS-13-vitest` | 2 | 26 |
| admin | `feature/GTSS-13` | `feature/GTSS-13-vitest` | 3 | 27 |
| lp | `feature/GTSS-13` | `feature/GTSS-13-vitest` | 1 | 10 |

**ブランチ方向検証:** 各リポジトリで `git log feature/GTSS-13..feature/GTSS-13-vitest` がコミットを持つことを確認済み（方向は正しい）。

**性質:** 大半が「テストの新規追加 / assertion 補完」。**production コード変更は admin のみ**で、内容は `ApplicationDetail.tsx` / `ApplicationList.tsx` / `CancellationManagement.tsx` の inline ロジックを純関数（`src/constants/applicationStatus.ts` / `cancellationStatus.ts`）へ抽出する**挙動不変リファクタ**。抽出純関数すべてを元 inline 実装と逐語照合し、**挙動差異なし**を確認した（ボタン label/variant/順序、CSV ヘッダ/エスケープ/BOM/日付/ファイル名、フィルタ境界）。

**codex-reviewer について:** admin / lp の codex-reviewer はサンドボックス環境要因（exit 144 / xcrun の temp・cache I/O エラー）で 2 回とも完走せず、採用可能な Codex 指摘は **0 件**。別セッション混入・無関係ブランチ指摘は発生していない（Codex の中間調査は対象ブランチ・実ファイルを正しく読んでおり、私の独立検証と矛盾なし）。下記指摘はすべて私の cross-file 再検証で裏取り済み。

## 変更ファイル一覧（抜粋）

### admin（production 変更を含む唯一のリポジトリ）

| ファイル | 種別 | 概要 |
|---------|------|------|
| `src/constants/applicationStatus.ts` | 新規(+69) | `getAvailableStatusActions` / `normalizeStatusFilter` / `filterApplications` を純関数化 |
| `src/constants/cancellationStatus.ts` | 新規(+111) | `summarizeCancellations` / `filterCancellations` / `buildCancellationCsv` / `cancellationCsvFilename` / 配色・ラベルを純関数化 |
| `src/components/ApplicationDetail.tsx` | 改修(+42/-?) | status 遷移ボタンを `getAvailableStatusActions().map()` 化 |
| `src/components/ApplicationList.tsx` | 改修 | フィルタを `normalizeStatusFilter`/`filterApplications` に委譲 |
| `src/components/CancellationManagement.tsx` | 改修 | 集計/CSV/フィルタを純関数に委譲 + `data-testid` 付与 |
| `src/constants/*.test.ts`, `src/components/__tests__/*.test.tsx` | 新規 | 上記純関数 + コンポーネントの unit テスト |
| `vitest.config.ts` / `tsconfig.vitest.json` / `src/test/*` / `playwright.config.ts` / `e2e/*` | 新規 | テスト基盤 |

### user / api / lp

- **user**: Vitest + Playwright 基盤新規（`vitest.config.ts` / `tsconfig.vitest.json` / `playwright.config.ts` / `e2e/*` / `src/test/*`）+ 主要画面の unit テスト（Auth/Invoice/Settings/Password/ProtectedRoute）。`deploy.sh` にテストゲート追加。production ロジック変更なし。
- **api**: 既存 E2E/unit への assertion 補完（移行カラム・手数料・webhook タイムスタンプ ISO 厳格化・enum helper 境界・clients lazy-init）。production 変更なし。
- **lp**: Vitest 単体テスト基盤新規（`vitest.config.js` / `src/test/*`）+ 申請フォーム/ルーティング/StripeSuccess/生年月日の unit テスト。production 変更なし（**Issue #4 本体**）。

## 指摘一覧

- [x] 対応する

### [Code Quality] user: テスト用 TS ファイルがどの型検査経路にも乗らない（admin と非一貫）

**ファイル:** `user/tsconfig.json`, `user/tsconfig.app.json`, `user/package.json`, `user/tsconfig.vitest.json`
**重要度:** Medium

**問題:** user リポジトリでは
- `tsconfig.app.json` が今回 test ファイルを **exclude** に追加
```jsonc
// user/tsconfig.app.json（変更後）
  "include": ["src"],
  "exclude": [
    "src/**/*.test.ts",
    "src/**/*.test.tsx",
    "src/**/__tests__/**",
    "src/test/**"
  ]
```
- `tsconfig.vitest.json` は test を include するが、`tsconfig.json` の `references` は app/node のみで**参照されておらず**、`package.json` にも `typecheck:test` 相当が無い
```jsonc
// user/tsconfig.json … vitest を参照していない
  "references": [ { "path": "./tsconfig.app.json" }, { "path": "./tsconfig.node.json" } ]
// user/package.json … test は vitest のみ（型検査なし）
  "test": "vitest run",
  "predeploy": "npm run lint && npm test",
```
- `build`(`tsc -b && vite build`) は app/node のみビルド、`deploy.sh` も `npm test`(=vitest) → `npm run build`。**結果: test の `.ts/.tsx` は build/deploy/test のどこでも型検査されない**（Vitest は esbuild トランスパイルで型を見ない）。

一方 **admin は同じ構成でも `typecheck:test` を用意して `test` に組み込んでおり**、test の型崩れを検知できる：
```jsonc
// admin/package.json（正しい例）
  "typecheck:test": "tsc --noEmit -p tsconfig.vitest.json",
  "test": "npm run typecheck:test && vitest run",
```

「テスト基盤整備」を謳う PR としては user 側だけ型の網が片肺。admin に倣って閉じるべき。

**修正提案:** user `package.json` に admin と同じ
```jsonc
  "typecheck:test": "tsc --noEmit -p tsconfig.vitest.json",
  "test": "npm run typecheck:test && vitest run",
```
を追加する（または `tsconfig.json` の `references` に `tsconfig.vitest.json` を加える）。

---

### [Test Coverage] lp: 暦上不正日（うるう日）の境界テストが計画から欠落

**ファイル:** `lp/src/__tests__/birthDate.test.jsx`、実装 `lp/src/App.jsx:277-300`
**重要度:** Low〜Medium

**問題:** Issue #4 の実装設計（ファイル変更一覧）は `birthDate.test.jsx` を「**境界値: 未来日・不正形式・うるう日**」と定義し、REQ-2 本文も「`2023-02-29` 等の暦上不正日は弾けない可能性があるため、テストは…不正暦日の実挙動を明示して検証する」と明記。しかし実テストは **未来日 NG / 今日 OK / 過去日 OK の 3 ケースのみ**で、不正形式・うるう日ケースが無い。

実装は `day > 31` の範囲チェックしか行わず、`new Date(year, month-1, day)` のロールオーバーで `2023-02-30` 等を受理する（→ Mar 2 にロールし `<= today` で `true`）：
```js
// lp/src/App.jsx:291-300
  if (month < 1 || month > 12 || day < 1 || day > 31) return false;   // 月別日数は見ない
  const inputDate = new Date(year, month - 1, day);                   // 2023-02-30 → Mar 2 にロール
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return inputDate <= today && !isNaN(inputDate.getTime());           // 暦上不正日も true
```
現状はバグではなく「実挙動」だが、固定するテストが無いため**将来この関数を厳密暦チェックに直してもテストが何も検知しない**（回帰検出の穴）。

**修正提案:** `birthDate.test.jsx` に「`2023-02-30` 等の暦上不正日は現状受理されて送信される」を固定するケースと、形式不正（例 `2023/2/1`・`20230201`）が NG になるケースを 1〜2 件追加し、コメントで「※暦チェックは未実装。厳密化時はこのテストを更新」と意図を残す。

---

### [Test Coverage] admin: CSV エクスポートのコンポーネント結合点が未検証

**ファイル:** `admin/src/components/__tests__/CancellationManagement.test.tsx`
**重要度:** Low

**問題:** CSV エクスポートテストは `URL.createObjectURL` と `anchor.click` の呼び出し回数のみ assert し、**「フィルタ後の `filteredInvoices` が CSV に渡っているか」という結合点**を検証していない。CSV 内容自体は `cancellationStatus.test.ts` の `buildCancellationCsv` で網羅されているため致命ではないが、「全件 vs フィルタ後」を取り違える結合バグは捕捉できない。

**修正提案:** 検索/ステータスで 1 件に絞った状態でエクスポートし、`Blob` コンストラクタ引数（または content）にフィルタ後件数ぶんの行のみが含まれることを 1 ケース確認する。

---

### [Code Quality] admin: ルート直下 `playwright.config.ts` がどの tsconfig にも含まれず型検査外

**ファイル:** `admin/playwright.config.ts`, `admin/tsconfig.vitest.json`
**重要度:** Low

**問題:** `tsconfig.json` は `include:["src"]`、`tsconfig.vitest.json` は `e2e/**/*` と test glob を include するが、リポジトリ直下の `playwright.config.ts` は**どちらの include にも入らない**。`baseURL`/`projects` 等の型崩れが CI をすり抜ける（user の `playwright.config.ts` も同様）。

**修正提案:** `tsconfig.vitest.json` の include に `"playwright.config.ts"` を追加。

---

### [Code Quality] lp: `console.log` スパイがモジュールスコープで未復元

**ファイル:** `lp/src/test/setup.js:30`
**重要度:** Low

**問題:** `vi.spyOn(console, 'log').mockImplementation(() => {})` がファイル先頭で 1 度張られ `afterEach`/`afterAll` で復元されない（`fetch`/`alert`/`matchMedia` は `beforeEach` でリセットされるのと非対称）。`warn`/`error` は残すため意図（開発用 `console.log` の恒久抑止）は妥当だが、将来 `console.log` 呼び出しを検証したいテストでハマりやすい。

**修正提案:** 恒久抑止が正なら現状維持で可。`setup.js` に「このスイート全体で `console.log` を恒久抑止」のコメントを明記、または vitest config の `onConsoleLog` フィルタへ移行。

---

### [Code Quality] 3 リポジトリで test setup の厳格度が不揃い

**ファイル:** `user/src/test/setup.ts`（厳格） vs `admin/src/test/setup.ts` / `lp/src/test/setup.js`（緩い）
**重要度:** Low

**問題:** user の `setup.ts` は `console.error` に `not wrapped in act` / `unique "key"` / `validateDOMNesting` を含むと `afterEach` で **fail させる**良い仕組みを持つが、admin / lp には同等の警告検出が無い（lp は `console.error` を spy せず素通し）。「緑だが act 漏れ/key 警告」を admin・lp では見逃す。

**修正提案:** user の警告検出を admin / lp の setup にも横展開して統一（任意）。

---

## スコープ外メモ（本 PR の対象ではないが記録）

- **lp `App.jsx`**: ルート分岐の early-return が `useState`/`useForm`/`useEffect` より前にあり Rules of Hooks 上は不適切（`/` 以外は常に return するため現状無害）。Issue #4 でも別 Issue 扱いと明記。追加テストはこの現挙動を正しく固定しており、将来リファクタ時に検知できる。
- **user `src/services/api.ts`**: `!response.ok` 時にサーバ error ボディを読み捨て `HTTP <status>: <statusText>` を throw する実装。テストはこの現挙動を正しく検証しているが、サーバの有用な error メッセージ（`INVALID_CREDENTIALS` 等）がユーザーに届かない難点を仕様として固定する。改善は本 PR スコープ外（Issue 化推奨）。
- **admin サブリポジトリ `CLAUDE.md`**: 親 `CLAUDE.md` は API URL 変数を `VITE_API_BASE_URL`→`VITE_API_URL` に訂正済み（実コードは元から `VITE_API_URL` 参照で訂正は正しい）。サブリポジトリ側 `cancel-billing-service-admin/CLAUDE.md` は未訂正のまま。

## 総評

ブランチの実体は「4 リポジトリ横断の Vitest/Playwright テスト基盤整備」＋「admin の挙動不変リファクタ」。**マージブロッカーは無し。**

- **リファクタの安全性 (admin):** 抽出した全純関数（`getAvailableStatusActions` / `normalizeStatusFilter` / `filterApplications` / `summarizeCancellations` / `filterCancellations` / `buildCancellationCsv` / `cancellationCsvFilename`）を元 inline 実装と逐語照合し、**挙動差異ゼロ**を確認。status 遷移ボタンの label/variant/順序、`approved` での「利用開始 → Stripeリンク送信」描画順、CSV の BOM/エスケープ/日付/ファイル名、フィルタの undefined 行の扱いまで保存されている。
- **テストの実効性:** トートロジー・常時 green・モック自身の検証といった重大問題は検出されず。api 側の「`sales.lastUpdated === persisted.paidAt` 厳密一致」「`application_fee_amount=2104` を実装式から導出」、user 側の認可（ProtectedRoute リダイレクト・401 で localStorage クリア）、lp 側の送信分岐（200/409/500/例外）と StripeSuccess 5 状態など、リグレッション検出力のある assertion が多い。
- **要対応:** 唯一の Medium は user 側の **テスト型検査が build/deploy/test のどこにも乗らない**点（admin の `typecheck:test` 方式に揃えれば 1〜2 行で解消）。その他は Low（lp うるう日テスト追加・CSV 結合点・playwright.config 型検査・console.log 復元・setup 厳格度統一）で、いずれも任意 or 別 Issue 化可能。
