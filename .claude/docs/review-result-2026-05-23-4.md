---
issue: 10
date: 2026-05-23
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: feature/GTSS-9
    toBranch: feature/GTSS-10
---

# レビュー結果: #10

## 概要

**Issue:** #10 cancel-billing-service-api その他改善（デプロイ成果物/デッドコード/設定整合の整理）

整理タスク（リポジトリ衛生・デッドコード削除・設定整合）であり、機能変更を伴わない。削除されたコードはいずれも参照元がなく安全に削除できていることを確認した。テストも全 green（`npm test` → **153 passed / 13 files**）。**ブロッカーはなし。** 注目すべき指摘は2件、どちらも diff 外だが本 Issue の REQ-1/REQ-3 と同一スコープの取りこぼし。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `feature/GTSS-9` | `feature/GTSS-10` | 1 | 17 |

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `lambda-deployment-prod-2025*.zip`（12個） | - | - | Deleted (binary) |
| `old/index.js` | +0 | -1196 | Deleted |
| `src/services/application.service.ts` | +0 | -118 | Modified（未使用 `createSampleData` 削除） |
| `src/simple-lambda.ts` | +0 | -22 | Deleted |
| `vitest.config.js` | +1 | -1 | Modified（coverage exclude から `simple-lambda.ts` 除去） |
| `README.md` | +2 | -2 | Modified（エントリポイント `.js`→`.ts` 是正） |

## 検証済み（問題なし）

- **デッドコード削除の安全性**: `createSampleData` / `src/simple-lambda.ts` / `old/index.js` はソース・テスト・ビルドスクリプトのいずれからも参照されていない（GTSS-10 worktree 内 grep で 0 件）。`application.service.ts` 自体は handlers / webhook.service / lambda.ts から現役で使われており、削除されたのは未参照 export のみ。
- **AC-1.1（追跡 zip）**: `git ls-files | grep .zip` → 0件。現役デプロイ `deploy-api.sh` が生成する `lambda-deployment-${ENV}-${TIMESTAMP}.zip` は `.gitignore:61` の `lambda-deployment-*.zip` で確実にカバー（`git check-ignore` で確認）。
- **AC-2.1（テスト全 green）**: メインエージェントが GTSS-10 worktree で `npm test` を実行し **153 passed (13 files)** を確認。回帰なし。
- **AC-3.1（エントリポイント整合）**: `package.json` `main: src/lambda.ts` / scripts `src/dev-server.ts` / `build.mjs entryPoints: src/lambda.ts` で一貫。README の `.js`→`.ts` 是正も実態と一致。`src/index.js` 等の不存在参照は 0 件。
- **テストの `import '../../lambda.js'`**: TS/ESM の拡張子指定規約（実体 `src/lambda.ts`）であり broken 参照ではない。削除した `old/index.js` とは無関係。

## 指摘一覧

- [x] 対応する

### [Code Quality] `.gitignore` が `create-zip.sh` の出力 `lambda-deployment.zip` を除外しない

**ファイル:** `api/.gitignore:61`
**重要度:** Medium

**該当コード:**
```gitignore
# Lambda deployment packages
lambda-deployment-*.zip
```

**問題:** パターン `lambda-deployment-*.zip` は `deployment` の直後にハイフンを要求するため、`create-zip.sh` が生成する **ハイフンなし** の `lambda-deployment.zip` にマッチしない（`git check-ignore lambda-deployment.zip` → NOT IGNORED を実証）。`deploy-api.sh` の `lambda-deployment-prod-….zip` はマッチするが、`create-zip.sh` 経由の成果物はすり抜けてコミットされ得る。AC-1.1「今後もコミットされないこと」がこのスクリプト出力に対しては成立しない。

**修正提案:** パターンを `lambda-deployment*.zip`（ハイフン削除）に変更し、接尾辞あり・なし両方を網羅する。

---

### [Code Quality] `create-zip.sh` が削除対象から漏れた孤立スクリプト（存在しないハンドラを案内）

**ファイル:** `api/create-zip.sh:7,26`
**重要度:** Medium

**該当コード:**
```bash
zip -r lambda-deployment.zip . \
  -x "node_modules/aws-sdk/*" \
  ...
echo "   - Handler: src/lambda.handler"
echo "3. Upload lambda-deployment.zip"
```

**問題:** `create-zip.sh` はリポジトリ直下を esbuild バンドルせず生のまま zip 化し、`Handler: src/lambda.handler` を案内する手動デプロイ用スクリプト。本 PR 後、直下の実体は `src/lambda.ts` のみで `src/lambda.js` は存在しない（ビルド時のみ `dist/src/lambda.js` 生成）。このスクリプトで作った zip を手動アップロードすると Lambda がハンドラを解決できない。`deploy-api.sh` やドキュメントから一切参照されていない孤立スクリプト（grep で自己参照のみ）で、本 PR が削除した `old/index.js` / `simple-lambda.ts` と同系統の旧成果物。AC-3.1「存在しないエントリポイント参照0件」の観点では取りこぼし。

**修正提案:** `create-zip.sh` を削除する（推奨。デプロイは `deploy-api.sh` + `build.mjs` に一本化済み）。残す場合は `npm run build` 後の `dist/` を zip 化する形に直し、ハンドラ案内を実態に合わせる。

---

## 総評

整理タスクとして妥当で品質も高い。削除対象はすべて未参照のデッドコード／成果物で、現役の `application.service.ts` の export は維持されており、テストも 153 件全 green。受け入れ条件 AC-1.1〜AC-3.1 は本 PR の diff 範囲では満たされている。

ただし、本 Issue の趣旨（デプロイ成果物の Git 管理停止・デッドコード/設定整合の整理）から見ると、孤立スクリプト `create-zip.sh` が取りこぼされており、それが (1) gitignore でカバーされない `lambda-deployment.zip` を生成し、(2) 存在しない `src/lambda.handler` を案内する、という2点で REQ-1/REQ-3 のスコープに残課題がある。いずれも本 PR をブロックする必要はなく、`create-zip.sh` の削除（または gitignore パターンの `lambda-deployment*.zip` への緩和）でフォローアップ対応すれば足りる。
