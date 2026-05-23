# Playwright テスト実行方法 (cancel Web アプリ)

## 基本方針

**Playwright e2e テストは対象 Web アプリ（cancel-billing-service / -admin / -lp）のローカル開発環境で実行する**。
バックエンドに cancel-billing-service-api（ローカル Express）、フロントエンドに対象アプリの Vite dev サーバーを起動し、Playwright を Chromium で実行する。

外部依存（Stripe / DynamoDB / SES / Twilio）は API 側でモックするか、`page.route` で API レスポンスを mock してテストデータを準備する。**Docker は不要**（必要なら DynamoDB Local のみ）。

## 前提条件

- 対象アプリの依存パッケージがインストール済み (`npm install`)
- cancel-billing-service-api で `npm install` 済み
- `npx playwright install chromium` 済み（初回のみ）

## ⚠️ Worktreeでの追加セットアップ

worktreeから e2e を実行する場合、以下を必ず確認:

1. **slot ベースのポート割当**: `.claude/worktree-manifests/{N}.json` の `ports` を参照し、API / フロントエンドが他 worktree と競合しないポートを使う
2. **port override / 環境変数**:
   - cancel-billing-service-api worktree: `.env` または `.env.development` の `PORT` を割当ポートにする
   - フロントエンド worktree: `.env.local` に API URL（`VITE_API_BASE_URL`（admin）/ `VITE_API_URL`（lp 等））と `PLAYWRIGHT_BASE_URL` を書く
3. **API に worktree が無い場合**は、メイン `cancel-billing-service-api` を割当ポートで起動して共有する

## ローカル実行手順

### Step 1: API 起動 (cancel-billing-service-api)

ターミナルで:

```bash
# worktree の場合: そのworktreeで起動
cd cancel-billing-service-api/.worktrees/{worktreeDir} && PORT={api} npm run dev

# worktree が無い場合: メインで起動
cd cancel-billing-service-api && PORT={api} npm run dev
```

### Step 2: フロントエンド起動 (対象アプリ)

別ターミナルで対象アプリの dev サーバーを起動:

```bash
cd cancel-billing-service-admin/.worktrees/{worktreeDir}
PORT={web} npm run dev
```

✅ 起動完了:
```
VITE v6.x   ready in XXXms
➜  Local:   http://localhost:{web}/
```

### Step 3: Playwright 実行

別ターミナルで Playwright を起動:

```bash
cd cancel-billing-service-admin/.worktrees/{worktreeDir}
PLAYWRIGHT_BASE_URL=http://localhost:{web} \
  npx playwright test --reporter=list

# 特定の spec ファイルのみ
npx playwright test e2e/application.spec.ts --reporter=list

# 特定の test name で grep
npx playwright test -g "申請一覧" --reporter=list

# Trace を残してデバッグ
npx playwright test --trace=on

# UI モード (対話的にテスト選択 / 実行)
npx playwright test --ui
```

スナップショット更新（CSS 等の意図的な変更で screenshot diff が発生したとき）:
```bash
npx playwright test --update-snapshots
```

## 環境変数の役割

| 変数 | 説明 |
|------|------|
| `VITE_API_BASE_URL` / `VITE_API_URL` | フロントエンドが叩く API のベース URL（admin は `VITE_API_BASE_URL`、lp は `VITE_API_URL`） |
| `PLAYWRIGHT_BASE_URL` | テスト対象アプリの URL |
| `PORT` | 各サーバーのリッスンポート |

## ポート競合 / クリーンアップ

worktree のポート (slot 番号) は `.claude/worktree-manifests/{N}.json` の `ports` を参照。

前回の実行が残っている場合:
```bash
lsof -i :{api} -t | xargs kill 2>/dev/null
lsof -i :{web} -t | xargs kill 2>/dev/null
```

テスト終了後（必須）:
```bash
# フロントエンド / API プロセスを停止
lsof -i :{web} -t | xargs kill 2>/dev/null
lsof -i :{api} -t | xargs kill 2>/dev/null

# テスト結果ログ・スクリーンショット削除（蓄積するため）
rm -rf test-results/
```

## npm scripts

### cancel-billing-service-api
| スクリプト | 説明 |
|-----------|------|
| `npm run dev` | ローカル Express サーバー起動 |
| `npm test` | Jest（Unit + ハンドラ統合テスト = e2e 相当） |

### フロントエンド (cancel-billing-service / -admin / -lp)
| スクリプト | 説明 |
|-----------|------|
| `npm run dev` | Vite dev サーバー起動 |
| `npm run e2e` | Playwright 実行（`playwright test`） |
| `npm run e2e:debug` | Playwright Inspector で対話的デバッグ |
| `npm run e2e:report` | 直近の HTML レポートを表示 |

## 実行フロー早見表

```
┌─────────────────────────────────────────────────────────────┐
│ Terminal 1: API (cancel-billing-service-api)                │
│   cd cancel-billing-service-api (or .worktrees/...)         │
│   PORT={api} npm run dev                                    │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│ Terminal 2: フロントエンド (Vite dev)                       │
│   cd cancel-billing-service-admin/.worktrees/...            │
│   PORT={web} npm run dev                                    │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│ Terminal 3: Playwright                                       │
│   cd cancel-billing-service-admin/.worktrees/...            │
│   PLAYWRIGHT_BASE_URL=http://localhost:{web} \              │
│     npx playwright test --reporter=list                     │
└─────────────────────────────────────────────────────────────┘
```

## トラブルシューティング

### `connect ECONNREFUSED`
フロントエンドが API に到達できていない。`VITE_API_BASE_URL` / `VITE_API_URL` が起動中の API ポートを指しているか確認する。

### Vite が `PORT` を反映しない
`.env.local` に `PORT={web}` を書くか、`PORT={web} npm run dev` のように環境変数経由で渡す。

### スクリーンショット diff
`--update-snapshots` で baseline を更新する。CSS 修正の意図的な変更なら期待通り。CI と差分が出る場合は OS / Chromium バージョンを揃える。

### Playwright がブラウザを見つけられない
```bash
npx playwright install chromium --with-deps
```

## 関連ドキュメント

- [SKILL.md](./SKILL.md) — Playwright のベストプラクティス（locator / assertion / 構造）
- [lesson.md](./lesson.md) — 過去のレビュー指摘パターン
- `.claude/skills/setup-local-dev/SKILL.md` — worktree のセットアップ全般
- `.claude/skills/worktree/SKILL.md` — worktree のポート割当ルール
