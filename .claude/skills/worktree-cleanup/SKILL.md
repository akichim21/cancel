---
name: worktree-cleanup
description: "Issue 用 worktree をクリーンアップする時に使用する skill。"
---

Issue #$ARGUMENTS のworktreeをクリーンアップしてください。

## 手順

### 1. manifest読み込み

`.claude/worktree-manifests/GTSS-$ARGUMENTS.json` を読み込み、対象のworktree情報を取得する。

manifestが存在しない場合はエラーメッセージを表示して終了:
```
.claude/worktree-manifests/GTSS-$ARGUMENTS.json が見つかりません。worktreeは既に削除済みか、issue-startで作成されていない可能性があります。
```

manifestから以下の情報を取得する:
- `branchName`: ブランチ名（ローカルブランチ削除に使用）
- `worktreeDir`: worktreeディレクトリ名
- `ports`: ポート情報（プロセス停止に使用）

### 2. ポート関連プロセスの停止

manifestの `ports` フィールドからポート情報を読み取り、使用中のプロセスを停止する:

```bash
# manifestからポート情報を読み取り
API_PORT=$(jq -r '.ports.api' .claude/worktree-manifests/GTSS-{N}.json)
ADMIN_PORT=$(jq -r '.ports.admin' .claude/worktree-manifests/GTSS-{N}.json)
USER_PORTAL_PORT=$(jq -r '.ports.userPortal' .claude/worktree-manifests/GTSS-{N}.json)
LP_PORT=$(jq -r '.ports.lp' .claude/worktree-manifests/GTSS-{N}.json)

# ポート使用中のプロセスを停止
lsof -i :$API_PORT -t | xargs kill 2>/dev/null
lsof -i :$ADMIN_PORT -t | xargs kill 2>/dev/null
lsof -i :$USER_PORTAL_PORT -t | xargs kill 2>/dev/null
lsof -i :$LP_PORT -t | xargs kill 2>/dev/null
```

### 3. worktree削除

manifestから `branchName` と `worktreeDir` を取得し、`hasWorktree: true` の各リポジトリについて:

```bash
# manifestからブランチ名とworktreeディレクトリ名を取得
BRANCH_NAME=$(jq -r '.branchName' .claude/worktree-manifests/GTSS-{N}.json)
WORKTREE_DIR=$(jq -r '.worktreeDir' .claude/worktree-manifests/GTSS-{N}.json)

cd /Users/aki/cancel/{repo}

# worktreeに未コミットの変更がないか確認
cd .worktrees/${WORKTREE_DIR}
git status --porcelain
cd ../..

# 未コミットの変更がある場合は警告し、続行するか確認する

# worktree削除
git worktree remove .worktrees/${WORKTREE_DIR}

# ローカルブランチ削除（マージ済みの場合）
git branch -d ${BRANCH_NAME}

# 未マージの場合は警告を表示し、強制削除するか確認する
# git branch -D ${BRANCH_NAME}
```

**注意**: このワークフローは指定されたIssueのworktreeのみ削除する。他のIssueのworktreeには一切影響しない。

### 4. manifest削除

該当Issueのmanifestファイルのみ削除する:

```bash
rm /Users/aki/cancel/.claude/worktree-manifests/GTSS-{N}.json
```

ディレクトリ内に他のmanifestが残っていれば `.claude/worktree-manifests/` は削除しない。

### 5. 結果報告

削除したworktreeの一覧を表示:
```
Worktree cleanup complete for GTSS-{N}:
- cancel-billing-service-api: worktree removed, branch deleted (branch: {BRANCH_NAME})
- cancel-billing-service-admin: no worktree (skipped)
- ...
Ports released: api={API_PORT}, admin={ADMIN_PORT}, userPortal={USER_PORTAL_PORT}, lp={LP_PORT}
Remaining active manifests: GTSS-XXX, GTSS-YYY (or "none")
```
