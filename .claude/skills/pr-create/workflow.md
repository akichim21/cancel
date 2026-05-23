# PR 作成の手順

## 引数パース

`$ARGUMENTS` を以下の形式で解釈する。

- **数値（GTSS 番号）**: `.claude/worktree-manifests/GTSS-{N}.json` から対象リポジトリ・worktree パス・ブランチ・ベースブランチを解決する
- **省略**: 現在の作業ディレクトリから対象リポジトリと現在のブランチを判別する

## Step 1: 対象リポジトリと worktree パスの解決

### GTSS 番号が指定された場合

```bash
MANIFEST=.claude/worktree-manifests/GTSS-{N}.json
test -f $MANIFEST || { echo "manifest が見つかりません: $MANIFEST"; exit 1; }

jq -r '
  .repos
  | to_entries[]
  | select(.value.hasWorktree == true)
  | [.key, .value.worktreePath, .value.branch, .value.baseBranch]
  | @tsv
' $MANIFEST
```

各エントリ `(repo, worktreePath, branch, baseBranch)` ごとに Step 2 以降を実施する。

### 引数が省略された場合

```bash
git rev-parse --show-toplevel               # 対象リポジトリのルート
git rev-parse --abbrev-ref HEAD             # 現在のブランチ
git symbolic-ref refs/remotes/origin/HEAD --short 2>/dev/null \
  | sed 's|^origin/||'                      # 既定のベースブランチ
```

ベースブランチが取れない場合は `main` を仮置きし、ユーザーに確認してから次に進む。

## Step 2: ブランチ状態の確認

```bash
cd ${worktreePath}

git status --porcelain                                       # 未コミットの変更
git fetch origin
git log --oneline origin/${baseBranch}..HEAD                 # コミット数
git diff origin/${baseBranch}...HEAD --stat                  # 差分ファイル一覧
```

判定:

- **未コミットの変更がある**: 自動コミットしない。ユーザーに状態を報告し、コミット作成の指示を仰いでから次に進む
- **コミットが 0 件**: PR を作成せず、警告を出して中断する
- **ブランチ名が `main` / `master` 等の保護ブランチ**: PR を作成せず、専用ブランチへの切替をユーザーに促す

## Step 3: テスト green の最終確認

PR 作成前に、対象リポジトリで自動テスト（API: jest / フロントエンド: vitest / Web e2e: Playwright）が green であることを確認する。

- 直近の実行ログがあればそれを参照
- ない場合は対応するテストコマンドを再実行して green を確認

**テスト未実行・red のまま PR を作成することは禁止する。**

## Step 4: ブランチプッシュ

```bash
cd ${worktreePath}

# 追跡が未設定なら -u を付ける
git push -u origin ${branch}

# 既に追跡済みなら通常 push
git push origin ${branch}
```

`--force` / `--force-with-lease` / `--no-verify` は明示的な指示がない限り使用しない。

## Step 5: PR 本文の生成

[body-template.md](./body-template.md) のテンプレートに従って本文を組み立てる。

差分の根拠は以下から得る:

```bash
git log --oneline origin/${baseBranch}..HEAD
git diff origin/${baseBranch}...HEAD
```

**最新の 1 コミットだけを見ない。** ブランチが分岐してから現在までの全コミットの差分を要約する。

## Step 6: PR 作成

```bash
cd ${worktreePath}

gh pr create \
  --base ${baseBranch} \
  --head ${branch} \
  --title "<タイトル>" \
  --body "$(cat <<'EOF'
<本文>
EOF
)"
```

`--base` `--head` は manifest（または Step 1 で確認した値）から渡す。

## Step 7: 結果報告

各リポジトリの PR URL を一覧で報告する。

```
PR 作成完了:
- cancel-billing-service-api: <PR URL>
- cancel-billing-service-admin: <PR URL>
- ...
```

人力テスト待ちの項目が残っている場合は、リスト末尾に「人力確認待ち」として明記する。
