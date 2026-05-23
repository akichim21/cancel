---
name: setup-local-dev
description: "ローカル開発用 worktree をセットアップする時に使用する skill。"
---

## ローカル開発環境セットアップ

- **Planモードに入ることを禁止する。** このワークフローはPlanモードを使わず、直接実行すること。

`$ARGUMENTS` をブランチ名（worktree名）として使用する。以降 `{BRANCH}` と表記する。

### Step 1: Manifest読み込み

`.claude/worktree-manifests/{BRANCH}.json` を読み込む。

- **ファイルが存在しない場合**: エラーメッセージを表示して終了:
  ```
  Manifest .claude/worktree-manifests/{BRANCH}.json が見つかりません。
  `.claude/skills/issue-start/SKILL.md` を参照してworktreeを作成するか、ファイル名を確認してください。
  ```

- **ファイルが存在する場合**: manifest情報を取得し、以降のステップで使用する。
  - `branchName`, `worktreeDir`, `repos` を取得する

### Step 2: Worktree確認・作成 & git pull

manifestの `repos` 内で `hasWorktree: true` の各リポジトリについて:

1. **worktreeディレクトリの存在確認**:
   ```bash
   ls {worktreePath}
   ```

2. **worktreeが存在しない場合** → worktreeを作成:
   ```bash
   cd /Users/aki/cancel/{repo}
   git fetch origin
   mkdir -p .worktrees

   # リモートにブランチが存在するか確認
   git ls-remote --heads origin {branchName}

   # リモートにある場合:
   git worktree add .worktrees/{worktreeDir} -b {branchName} origin/{branchName}
   # リモートにない場合:
   git worktree add .worktrees/{worktreeDir} -b {branchName} origin/{baseBranch}
   ```

3. **worktreeが存在する場合** → git pullで最新化:
   ```bash
   cd {worktreePath}
   git pull
   ```

4. **依存パッケージのインストール**（worktreeを新規作成した場合のみ）:
   ```bash
   # cancel-billing-service-api / cancel-billing-service /
   # cancel-billing-service-admin / cancel-billing-service-lp 共通:
   npm install
   ```

### Step 3: 環境ファイルセットアップ

worktreeがあるリポジトリに対して、以下の環境ファイルを設定する。

#### cancel-billing-service-api

`.env` はgitignoreされているためworktreeにはない。メインリポからコピーする:

```bash
cp /Users/aki/cancel/cancel-billing-service-api/.env {worktreePath}/.env
```

ローカルAPIサーバーは `PORT` で待ち受ける（manifest の `ports.api`）。

#### cancel-billing-service（ユーザーポータル）

`.env.local` はgitignoreされているためworktreeにはない。メインリポからコピーし、API URL をローカルに書き換える:

```bash
cp /Users/aki/cancel/cancel-billing-service/.env.local {worktreePath}/.env.local
cd {worktreePath}
sed -i '' 's|^VITE_API_BASE_URL=.*|VITE_API_BASE_URL=http://localhost:{API_PORT}|' .env.local
```

#### cancel-billing-service-admin（管理画面）

`.env.local` はgitignoreされているためworktreeにはない。メインリポからコピーし、API URL をローカルに書き換える（変数名は `VITE_API_BASE_URL`）:

```bash
cp /Users/aki/cancel/cancel-billing-service-admin/.env.local {worktreePath}/.env.local
cd {worktreePath}
sed -i '' 's|^VITE_API_BASE_URL=.*|VITE_API_BASE_URL=http://localhost:{API_PORT}|' .env.local
```

#### cancel-billing-service-lp（LP・申請フォーム）

`.env.development` を流用する。API URL をローカルに書き換える（変数名は `VITE_API_URL`）:

```bash
cd {worktreePath}
sed -i '' 's|^VITE_API_URL=.*|VITE_API_URL=http://localhost:{API_PORT}|' .env.development
```

### Step 4: 実行コマンド表示

セットアップ完了後、以下のフォーマットで各リポジトリの起動コマンドを表示する。
**worktreeがあるリポジトリのみ表示する。**

````
## ローカル開発環境セットアップ完了 ✅

以下のコマンドでローカル環境を起動できます。

### cancel-billing-service-api（APIサーバー起動）
```bash
cd {worktreePath}
npm start
```

### cancel-billing-service（ユーザーポータル / ブラウザ）
```bash
cd {worktreePath}
npm run dev
```

### cancel-billing-service-admin（管理画面 / ブラウザ）
```bash
cd {worktreePath}
npm run dev
```

### cancel-billing-service-lp（LP / ブラウザ）
```bash
cd {worktreePath}
npm run dev
```
````

**注意事項も表示する:**
- `VITE_*` の値はビルド時に埋め込まれる。`.env*` を変更した場合は dev サーバーの再起動が必要。
- フロントエンドは API（`cancel-billing-service-api`）をローカル起動してから接続すること。
- `STRIPE_SECRET_KEY` には公開鍵 (`pk_`) を絶対に入れない。
