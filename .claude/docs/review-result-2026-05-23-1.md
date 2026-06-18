---
issue: 6
date: 2026-05-23
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: feature/GTSS-1
    toBranch: feature/GTSS-6
---

# レビュー結果: #6

## 概要

**Issue:** #6 cancel-billing-service-api を TypeScript 化する（esbuild バンドル）

Epic「Honoモダン化ロードマップ」の一部。#1（Hono移行＋Vitest基盤）完了後に着手。**挙動不変が原則**で、差分は「拡張子変更・CJS→ESM 構文変換・最小型注釈・ビルド/デプロイ構成」に限定される。構造化リファクタ・クエリ改善・バリデーション改善・strict 引き上げは後続 Issue。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `feature/GTSS-1` | `feature/GTSS-6` | 1 | 11（+ package-lock.json） |

### 挙動不変の検証（自前 + codex-reviewer による実機実行で確認済み）

- `npm run typecheck`（tsc --noEmit）: **エラー0**
- `npm test`（vitest）: **10 files / 129 tests 全 green**（テストは `'../../lambda.js'` 拡張子のまま、Vitest リゾルバが `.ts` へ解決）
- `node build.mjs`: **成功**（単一 CJS バンドル `dist/src/lambda.js` 生成、`handler` export を含む）
- handler 参照 `src/lambda.handler` 不変、runtime `nodejs18.x` と esbuild `target: node18` 一致
- `require('stripe')(key)` → `new Stripe(key)`（stripe v18 で等価）、`module.exports.X` → `export { X }`（named import 互換）、`__setTestClients` の `let` 差し替えセマンティクスも維持

**ブロッカー級（High）の挙動差異・欠陥は検出されませんでした。** 以下は主に堅牢性・保守性の指摘。

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `CLAUDE.md` | +17 | -7 | Modified |
| `build.mjs` | +33 | -0 | Added |
| `deploy-api.sh` | +9 | -12 | Modified |
| `package.json` | +11 | -3 | Modified |
| `serverless.yml` | +3 | -0 | Modified |
| `src/dev-server.ts` (rename) | +4 | -4 | Renamed |
| `src/dynamodb-setup.ts` (rename) | +4 | -4 | Renamed |
| `src/lambda.ts` (rename) | +38 | -32 | Renamed |
| `src/simple-lambda.ts` (rename) | +1 | -1 | Renamed |
| `tsconfig.json` | +27 | -0 | Added |
| `vitest.config.js` | +2 | -2 | Modified |

## 指摘一覧

- [x] 対応する

### [Code Quality] deploy 時に esbuild（devDependency）が欠落しうる

**ファイル:** `cancel-billing-service-api/deploy-api.sh:73-80`
**重要度:** Medium

**該当コード:**
```bash
# 依存関係の確認とインストール
log_info "依存関係を確認しています..."
if [ ! -d "node_modules" ]; then
    log_info "依存関係をインストールしています..."
    npm install --legacy-peer-deps          # ← 全依存（devDeps含む）を install
else
    log_info "依存関係は既にインストール済みです"   # ← 既存なら install をスキップ
fi
...
npm run build -- --outdir "$DEPLOY_DIR"       # ← esbuild(devDep) が必須に
```

**問題:** TS 化に伴いデプロイがビルドステップ（`npm run build` = esbuild）に依存するようになった。`esbuild` / `tsx` / `typescript` は `devDependencies`。このガードは `node_modules` が既に存在する場合は install をスキップするため、**何らかの理由で `node_modules` が prod-only 状態（例: CI キャッシュ復元、過去に `npm install --only=production` を手動実行）だと `esbuild not found` でデプロイが失敗する**。
※ 補足: 通常の dev/fresh-checkout フローでは line 78 が `--only=production` ではない全 install を行うため esbuild は揃う。旧 `--only=production` は削除済みの `DEPLOY_DIR` コピー内でのみ走っていた。したがって**現実的な発生確率は低い**が、ビルド依存が増えた以上ガードの堅牢化が望ましい。

**修正提案:** `npm ci`（lockfile 準拠で devDeps 含む）に統一するか、`node_modules/.bin/esbuild` の存在チェックを追加して不足時に再 install する。

---

### [Performance] esbuild `external: []` で aws-sdk まで丸ごとバンドル

**ファイル:** `cancel-billing-service-api/build.mjs:96-99`
**重要度:** Low

**該当コード:**
```javascript
  format: 'cjs',
  // handler 参照 `src/lambda.handler` を維持するため src/ 配下に出力
  outfile: `${outdir}/src/lambda.js`,
  // 依存（@aws-sdk / stripe / twilio / hono 等）も含めて単一ファイルにバンドルする。
  // 旧方式の「本番 node_modules 同梱」と等価に保つ（挙動不変）。
  external: [],
```

**問題:** Lambda nodejs18.x ランタイムは `@aws-sdk/*` を標準同梱しているため、これをバンドルに含めると zip サイズ増大（codex 計測で約 10MB）と、ランタイム同梱版と異なる aws-sdk バージョンが実行される可能性がある。ただし旧方式（`npm install --only=production` で aws-sdk を node_modules に同梱）でも同様だったため「挙動不変」としては正当であり、コメントにも意図が明記されている。

**修正提案:** 任意改善。軽量化・起動高速化を狙うなら後続 Issue で `external: ['@aws-sdk/*']` を検討（挙動不変を最優先する本 Issue では現状維持で可）。

---

### [Code Quality] テストの import 拡張子 `.js` が Vitest リゾルバ依存

**ファイル:** `cancel-billing-service-api/src/__tests__/**/*.test.js`（`import { app } from '../../lambda.js'`）
**重要度:** Low

**問題:** テストは `.js` 拡張子のまま実体 `lambda.ts` を import しており、Vitest（vite/esbuild）の解決に依存して green になっている。挙動不変のため「テストを変更しない」判断は妥当だが、素の Node 解決とは異なるため将来 runner を変えると壊れうる脆い参照。

**修正提案:** 任意。後続 Issue で拡張子なし import へ揃える方針をコメントに残すと意図が明確。

---

### [Code Quality] その他軽微（いずれも Low / 任意）

**ファイル:** `cancel-billing-service-api/package.json:5,32,41`、`src/simple-lambda.ts`、`serverless.yml:54-57`
**重要度:** Low

- `package.json:5` の `"main": "src/lambda.ts"` — Lambda の handler 解決は `serverless.yml` / `--handler src/lambda.handler` 経由で `main` を使わないため実害なし。整合性のため `dist/src/lambda.js` 等にするか削除推奨。
- `@types/nodemailer@^8.0.0` と `nodemailer@^7.0.10` のメジャー不一致（`package.json:32,41`）。`strict:false`/`any` 運用下で実害は小さいが整合確認推奨。`stripe`/`twilio` は own types を持つため未追加で正しい。
- `src/simple-lambda.ts` はどのデプロイ設定からも handler 参照されないデッドコード。後続 Issue で削除検討。
- `serverless.yml` 経路（SF v4 ネイティブ esbuild）と `build.mjs` 経路（target/format/external 明示）でビルド設定が二重定義。実運用は `deploy-api.sh`（build.mjs）なので影響限定的だが、将来 `serverless deploy` を使う場合の保守性として一本化が望ましい。

---

## 総評

**Issue #6 のスコープ（挙動不変の TS 化 + esbuild バンドル）を規律よく満たした良質な PR。** 差分は拡張子変更・CJS→ESM 変換・最小型注釈・ビルド構成に限定され、ロジック変更は検出されず、typecheck 0 / 129 テスト全 green / バンドル生成成功で挙動不変が実証されている。型注釈の `any` 多用も段階導入方針（`strict:false`）の範囲内で過剰ではない。

ブロッカーはなく、最もフォロー価値があるのは **deploy-api.sh の esbuild（devDep）欠落リスク（Medium）**。残りは任意改善。

**マージ前の必須確認（自動化不可・AC-1.3/AC-2.1）:** CLAUDE.md の方針どおり、esbuild バンドル経路は E2E（TS ソース直接評価）で走らないため、`./deploy-api.sh dev` での実機スモークと `@hono/node-server` ローカル疎通を完了させること。

**lessons 照合:** TS 化・ビルド構成・デプロイ・モジュール変換に該当する既存 lesson はなく、過去パターンへの違反は検出されませんでした。dev デプロイ green 確認後に「esbuild 全依存同梱の前提・確認手順」を lesson 化しておくと後続の TS 化作業で再利用可能。
