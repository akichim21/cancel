# PR 作成の禁止事項・規約

## 禁止事項（MUST NOT）

| ルール | 理由 |
|--------|------|
| テスト未実行・red のまま PR を作成しない | レビュー前に自動テスト green が前提 |
| `--no-verify` / `--no-gpg-sign` などの hook スキップフラグを使用しない | pre-commit / pre-push hook はスキップ禁止 |
| `--force` / `--force-with-lease` push は明示的な指示なしに使用しない | 共有ブランチを破壊しない |
| クロスリポジトリな Issue 参照（`Closes #N`、外部メタトラッカ URL、`akichim21/cancel` の Issue メンション）を本文・コメントに含めない | PR は対象サブリポジトリ単体で完結すること。詳細は `cross-repo-reference` skill |
| 機密情報（API キー、内部 URL、個人情報など）を本文に含めない | リポジトリ公開範囲が広がる前提で書く |
| 保護ブランチ（`master` / `main` / `develop`）を `--head` にして PR を作らない | 専用作業ブランチからのみ PR を作る |
| 自動コミット禁止 | 未コミット変更があれば必ずユーザーに確認してから |

## タイトル規約

- Conventional Commits 風プレフィックス: `feat:` / `fix:` / `refactor:` / `docs:` / `test:` / `chore:` / `perf:` / `style:`
- 70 文字以内
- 動詞は現在形・命令形
- 末尾にピリオドを付けない

## ベースブランチ規約

- manifest の `baseBranch`（または `--base` で確認した値）を使用する
- 既定値は `master`
- ブランチ方向の検証: `git log --oneline origin/${baseBranch}..HEAD` でコミットがあること

## レビュアー指定

- 既定では未指定で作成する
- ユーザーから指示がある場合のみ `--reviewer` / `--assignee` を付ける

## 作業ディレクトリ

- すべての `git` / `gh` 操作は対象サブリポジトリの worktree（または元ディレクトリ）内で実行する
- worktree が存在する場合は manifest の `worktreePath` を使う
