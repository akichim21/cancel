---
name: ask-codex
description: Asks Codex CLI for coding assistance. Use for getting a second opinion, code generation, debugging, or delegating coding tasks.
allowed-tools: Bash(codex *)
---

# Ask Codex

Executes the local `codex` CLI to get coding assistance.

**Note:** This skill requires the `codex` CLI to be installed and available in your system's PATH.

## Quick start（簡単なクエリ向け）

Run a single query with `codex exec`. **必ず `< /dev/null` でstdinを閉じること**（後述の hang 防止参照）:

```bash
codex exec "Your question or task here" < /dev/null
```

## 推奨: Haiku サブエージェント経由の実行

**問題**: `codex exec` の出力には中間のツール呼び出し結果（rg, sed等）が大量に含まれ、親Claudeのコンテキストトークンを浪費する。

**解決策**: `model: "haiku"` サブエージェントで実行し、stdoutをファイルにリダイレクトし、最終レスポンスのみ抽出して返す。

### ⚠️ 必ず守る起動オプション（hang 防止）

`codex exec` は **prompt を引数で渡しても stdin が open だと「stdin block」として追加読み込みを試みる**（`codex exec --help` 参照）。Claude Code の Bash ツールから起動すると stdin が close されないため、EOF を待ち続けて **数十分〜数時間 hang する事故が実際に発生した**（issue #3558 対応時）。

**必ず以下を全部適用すること:**

1. `< /dev/null` で stdin を即 EOF にする
2. **`timeout` コマンドで wall-clock タイムアウトを付けない（NG）**。理由は下記「タイムアウト禁止」セクション参照。codex 自身の内部 hard cap（約20分）に任せる
3. **Bash ツールは `run_in_background: true` で起動する**。Bash ツールの前景 timeout 上限は 600000ms = 10分なので、codex の長時間実行を許容するには background 実行が必須。完了通知を待ってから出力ファイルを読む

### 🚫 タイムアウト禁止（NG）

**`timeout NNN codex exec ...` のように外側から wall-clock タイムアウトを掛けることは禁止。**

理由:
- 過去事故: Haiku サブエージェントが途中経過を見て早とちりし、開始から **2 分** で `Codex timed out` を誤報告した。実際には codex プロセスはまだ生きており、その後 10〜15 分かけて正常に応答していた。
- Web 検索を 5-10 回連発するのは codex の正常動作で、合計 10〜20 分かかることは珍しくない。外側からの timeout 124 で殺すと、正常な調査の途中で結果を失う。
- 「待てるだけ待つ」が正解。codex 自身に内部 hard cap があるので、無限 hang にはならない。

**適用すべきこと:**

- `timeout` コマンドを **付けない**。
- Bash は **必ず `run_in_background: true`** で起動し、完了通知（`<task-notification>` の `status: completed`）を待つ。
- 「タイムアウトした」と判定してよいのは、**完了通知が届いた上で**、codex プロセスが終了済み（`ps -p <PID>` で不在）かつ出力ファイルに最終応答（`^codex` 行から始まるブロック）が存在しない場合のみ。
- 途中経過の `BashOutput` を見て独自判断で打ち切らない。

### hang vs 正常動作の見分け方

| 兆候 | 判定 |
|------|------|
| 出力ファイルサイズが定期的に増えている | 動いている。待つ |
| `ps -p <PID>` でプロセスがある | 動いている。待つ |
| `ps` で State が `S`/`SN`（sleeping） | 通常状態（I/O 待ち）。hang ではない |
| 完了通知未着 & プロセスは生きてる | 待つ |
| `<task-notification>` の `status: completed` が来た | 判定可。exit code を確認 |
| 完了通知あり & プロセス不在 & 出力に `^codex` ブロック無し | 異常終了。出力末尾を確認 |
| exit code 0 で出力ファイルに `^codex` の最終応答ブロックあり | 正常完了 |

### サブエージェントプロンプトテンプレート

```
以下の手順を実行し、Codexの最終結果のみを返してください。

1. 以下のコマンドをBashで実行する。**`run_in_background: true` を指定すること**（codexの実行は10分を超えることがあり、Bashツールの前景timeout上限を超えるため必須）。
   **stdoutをファイルにリダイレクト + stdinを/dev/nullに繋ぐこと。これを怠るとcodexがstdin待ちでhangする。**
   **`timeout` コマンドは絶対に付けないこと（NG）。** 外側から強制終了すると正常な長時間調査の途中結果を失う。codex自身の内部hard capに任せる。

   codex exec {options} "{prompt}" > /tmp/codex-{task-name}.txt 2>&1 < /dev/null

2. **Bash background ジョブの完了通知（`<task-notification>` の `status: completed`）が届くまで何もしない。途中経過の BashOutput を見て判断しないこと。**
   - Web 検索を 5-10 回連発するのは codex の正常動作。各検索 1-2 分 × 数回で 10〜20 分かかることがある。
   - 出力が一時的に静かでも、ファイルサイズが増え続けていれば動いている（`ls -la` で確認可能）。
   - 完了通知前に「タイムアウトした」と判定してはいけない（事故再発防止）。

3. 完了通知後、exit code を確認:
   - exit code 0 → 出力ファイルからCodexの最終レスポンスのみを抽出する:

     LAST_LINE=$(grep -n "^codex" /tmp/codex-{task-name}.txt | tail -1 | cut -d: -f1)
     awk "NR>=${LAST_LINE}" /tmp/codex-{task-name}.txt

   - 0 以外 → exit code と出力ファイル末尾 30 行を返す。

4. awkの出力のみを返す。要約や加工は不要。出力ファイル自体を Read で全体読み込みしないこと（トークン浪費）。
```

### いつ使うか

- **簡単な質問**（短い回答が期待される） → 直接 `codex exec ... < /dev/null` で OK（stdin redirect は必須）
- **コードレビュー、コードベース分析、複数ファイル調査等** → 必ずサブエージェント経由

### Web 検索を抑制したい場合

Codex は判断材料が足りないと Web 検索を多用する。それが時間を食う主因。検索を抑制したい場合はプロンプトで明示する:

- 「Web 検索は最大 1 回まで」
- 「Web 検索は禁止。手元の知識とリポジトリのみで判断」
- 親 Claude 側で先に `WebFetch` してドキュメントを取得し、その内容をプロンプトに埋め込んで渡す（最も確実で速い）

Web 検索が必要な質問（最新ライブラリの API、仕様確認など）は時間がかかるのが前提。外側から `timeout` で打ち切らず、完了通知が来るまで待つこと。

## Common options

| Option | Description |
|--------|-------------|
| `-m MODEL` | Specify model |
| `-C DIR` | Set working directory |
| `--full-auto` | Enable automatic execution with workspace-write sandbox |

> For all available options, run `codex exec --help`

## Examples

**Ask a coding question:**

```bash
codex exec "How do I implement a binary search in Python?" < /dev/null
```

**Analyze code in a specific directory:**

```bash
codex exec -C /path/to/project "Explain the architecture of this codebase" < /dev/null
```

**Let Codex make changes automatically:**

```bash
codex exec --full-auto "Add error handling to all API endpoints" < /dev/null
```

## Notes

- Codex runs non-interactively with `exec` subcommand
- By default, output goes to stdout and no files are modified without approval
- Use `--full-auto` for automatic execution within sandbox constraints
- The command inherits the current working directory unless `-C` is specified
- **`timeout` コマンドを外側から付けるのは NG**。codex の内部 hard cap に任せる
