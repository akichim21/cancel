---
name: pr-review-respond
description: "Pull Request のレビュー指摘へ対応する時に使用する skill。"
---

`.claude/docs/$ARGUMENTS` のレビュー結果ファイルを読み込み、各指摘に対応する。

## 手順

### Step 1: レビュー結果の読み込み

指定されたレビュー結果ファイルを読み込み、frontmatterからメタデータを取得する:
- `repo` / `repoDir`: 対象リポジトリ
- `issue`: Issue番号
- `fromBranch` / `toBranch`: ブランチ情報

### Step 2: Issue読み込み

```bash
gh issue view {issue} --repo akichim21/cancel
gh issue view {issue} --repo akichim21/cancel --comments
```

### Step 3: 作業ブランチの準備

対象リポジトリ（`/Users/aki/cancel/{repoDir}`）に移動し、`toBranch` で作業する。

**toBranchがローカルに存在する場合:**
- そのブランチをcheckoutし、最新化する
  ```bash
  cd /Users/aki/cancel/{repoDir}
  git checkout {toBranch}
  git pull origin {toBranch}
  ```
- ただし、メインのワーキングツリーに未コミットの変更がある場合は、worktreeを使用する:
  ```bash
  cd /Users/aki/cancel/{repoDir}
  git fetch origin
  mkdir -p .worktrees
  git worktree add .worktrees/review-{toBranchのスラッシュをハイフンに置換} {toBranch}
  cd .worktrees/review-{...}
  git pull origin {toBranch}
  ```

**toBranchがローカルに存在しない場合:**
- リモートから取得してcheckoutする
  ```bash
  cd /Users/aki/cancel/{repoDir}
  git fetch origin
  git checkout -b {toBranch} origin/{toBranch}
  ```

### Step 4: 指摘への対応

レビュー結果ファイル内の指摘をフィルタリング:
- `- [x] 対応する` を含む指摘のみ対応対象とする
- `- [ ] 対応する`（未チェック）を含む指摘は無視する
- チェックボックスがない指摘は通常の未解決レビュー指摘として扱う

**作業前に必ずやること**: ファイル全体を通読し、`- [x] 対応する` を含む指摘をすべてリストアップしてから対応を開始する。見落としを防ぐため、対応開始前に「対応対象 N 件」と件数を明示すること。

各対応対象の指摘について:
- 指摘の妥当性を評価
- 妥当な指摘であれば、実装を修正
- 議論が必要な場合は、その旨をユーザーに説明

### Step 5: テスト更新

必要に応じてテストも更新する。

## ルール

- レビュー指摘の意図を正確に理解し、適切に対応する
- 技術的に正しくない指摘の場合は、その理由をユーザーに説明する
- worktreeを使用した場合は、作業完了後にそのパスをユーザーに報告する
