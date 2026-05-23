# API ビルド / デプロイ構成（cancel-billing-service-api）

> 対象: `cancel-billing-service-api`（Hono / AWS Lambda）。Issue #6 で JavaScript から
> **TypeScript** へ移行し、Lambda へは **esbuild バンドル**で成果物を生成する構成に切り替えた。
> TS 化はロジックの振る舞いを変えない（構造化リファクタ・クエリ/バリデーション改善は後続 Issue）。

## 全体像

```
src/*.ts（TypeScript ソース, CommonJS 相当の ESM import/export）
  │
  ├─ 型チェック ── npm run typecheck（tsc --noEmit）……… CI ゲート（挙動は出力しない）
  │
  ├─ ローカル ──── npm run dev（tsx watch src/dev-server.ts → @hono/node-server）
  │
  └─ デプロイ ──── npm run build（build.mjs / esbuild）→ dist/src/lambda.js（依存同梱・単一 CJS）
                    └─ deploy-api.sh が dist を zip 化 → Lambda（handler: src/lambda.handler）
```

TypeScript の役割は **型による安全性とレビュー効率の向上**のみ。実行時の挙動は #1 で構築した
Vitest E2E（`app.request()`）が TS 化後も全 green であることで担保する（→ `api-testing.md`）。

## ファイル / スクリプト

| ファイル | 役割 |
|---------|------|
| `tsconfig.json` | TS コンパイラ設定。`module: commonjs` / `noEmit`（型チェック専用） |
| `build.mjs` | esbuild バンドルスクリプト。`src/lambda.ts` → `dist/src/lambda.js` |
| `deploy-api.sh` | dev/prod デプロイ。内部で `npm run build` を呼びバンドル成果物を zip 化 |
| `serverless.yml` | `handler: src/lambda.handler`（参照不変）。Serverless v4 はネイティブ esbuild |

### npm scripts

| script | 内容 |
|--------|------|
| `npm run typecheck` | `tsc --noEmit -p tsconfig.json`。型エラー0 が CI ゲート |
| `npm run build` | `node build.mjs`。`dist/src/lambda.js` を生成。`-- --outdir <dir>` で出力先上書き |
| `npm run dev` | `tsx watch src/dev-server.ts`。TS のままローカル起動 |
| `npm start` | `tsx src/dev-server.ts` |

## tsconfig の方針（段階導入）

- `module: commonjs` / `target: ES2020` / `esModuleInterop: true`。Lambda nodejs18.x に合わせる。
- `noEmit: true`：tsc は型チェックのみ。実行コードの生成は esbuild が担う（責務分離）。
- `strict: false` / `noImplicitAny: false` / `strictNullChecks: false`：
  3,500 行規模の単一ファイルを一括 strict 化しないための**段階導入**。
  最終的に `any` 濫用を避ける方針で、strict 引き上げは後続 Issue（構造化・バリデーション改善）で行う。
- `exclude: src/__tests__`：テストは Vitest（esbuild トランスパイル）が処理するため型チェック対象外。

## esbuild バンドル（build.mjs）

```js
build({
  entryPoints: ['src/lambda.ts'],
  bundle: true,
  platform: 'node',
  target: 'node18',     // serverless.yml の runtime: nodejs18.x と一致
  format: 'cjs',
  outfile: '<outdir>/src/lambda.js',  // handler 参照 src/lambda.handler を維持
  external: [],         // @aws-sdk / stripe / twilio / hono 等も同梱（旧方式と等価）
});
```

- **依存も含めて単一 CJS にバンドル**する。旧方式（`src/*` をコピー + `npm install --only=production`）と
  等価な「依存同梱」を維持し、挙動を不変に保つ。
- 出力を `dist/src/lambda.js`（`src/` 配下）にすることで、`handler: src/lambda.handler` が
  zip 内でそのまま解決される（serverless.yml / `deploy-api.sh --handler` 双方で参照不変）。

## デプロイ（deploy-api.sh）

利用方法は **不変**（`./deploy-api.sh dev` / `./deploy-api.sh prod`）。内部処理のみ変更:

| 旧 | 新 |
|----|----|
| `cp -r src/* $DEPLOY_DIR/src/` + `npm install --only=production` | `npm run build -- --outdir $DEPLOY_DIR`（esbuild バンドル） |

zip 化・`aws lambda update-function-code`・環境変数設定・API Gateway デプロイ・ヘルスチェックは従来どおり。
本番デプロイは人間が手元で実行する（`.claude/settings.json` で `./*.sh prod*` は deny）。

### デプロイ成果物は Git 管理しない

`dist/`・`lambda-deployment-*.zip` などのバンドル/zip 成果物は **ローカル生成のみ**で、Git にはコミットしない。
`.gitignore` に `dist/` と `lambda-deployment-*.zip` を登録済み（Issue #10 で過去にコミットされていた zip 12個を追跡停止）。
成果物は `deploy-api.sh` 実行時に都度生成されるため、リポジトリにバイナリを増やさない。

## 検証ゲート

| ゲート | コマンド | 合格条件 |
|--------|----------|---------|
| 型健全性 | `npm run typecheck` | エラー0 |
| 挙動不変 | `npm test`（Vitest E2E） | #1 の全スイートが green |
| バンドル | `npm run build` | `dist/src/lambda.js` 生成・`handler` export 解決 |
| dev 疎通 | `./deploy-api.sh dev` 後にスモーク | 主要エンドポイント応答（人力・実 AWS） |
