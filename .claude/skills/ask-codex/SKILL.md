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
2. `timeout 1200` で wall-clock 強制終了（codex の hard cap = 20分）
3. **Bash ツールは `run_in_background: true` で起動する**。Bash ツールの前景 timeout 上限は 600000ms = 10分なので、20分 cap を効かせるには background 実行が必須。完了通知を待ってから出力ファイルを読む

### ⚠️ サブエージェントが「早すぎる誤タイムアウト報告」をしないためのルール（実害発生済み）

過去の事故: Haiku サブエージェントが `BashOutput` のストリーミングを途中で見て「Web 検索を連発していて hung している」と早とちりし、開始から **2 分** で `Codex timed out` を誤報告した。実際には codex プロセスはまだ生きており、その後 10〜15 分かけて正常に応答していた。

**「タイムアウト」と判定してよいのは以下のいずれかが満たされた場合のみ**:

1. **Bash background ジョブの完了通知が `<task-notification>` で届き、かつ exit code が 124（timeout コマンドの強制終了コード）である**
2. **`ps -p <PID>` でプロセスが存在せず、かつ出力ファイル末尾に Codex の最終応答（`^codex` 行から始まるブロック）が存在しない**

それ以外は **判定保留** とし、必ず完了通知まで待つ。具体的には:

- ❌ `BashOutput` で取得した途中経過に「web search:」「searching ...」が連発していても、それは codex の正常動作。打ち切らない。
- ❌ 出力が数十秒〜1 分静かでも、Web 検索のレスポンス待ちや内部処理。打ち切らない。
- ❌ サブエージェント自身の判断で「もう諦めて報告しよう」としない。`run_in_background: true` の完了通知（または明示的に `wait`）まで動かない。
- ✅ どうしても生存確認したいなら `ps -p <PID>` で生きているか、`ls -la <output_file>` でサイズが増え続けているか確認する。サイズが増えていれば書き込み中 = 動いている。

**hang vs 正常動作の見分け方**:

| 兆候 | 判定 |
|------|------|
| 出力ファイルサイズが定期的に増えている | 動いている。待つ |
| `ps -p <PID>` でプロセスがある | 動いている。待つ |
| `ps` で State が `S`/`SN`（sleeping） | 通常状態（I/O 待ち）。hang ではない |
| 完了通知未着 & プロセスは生きてる | 待つ |
| `<task-notification>` の `status: completed` が来た | 判定可。exit code を確認 |
| exit code 124 | timeout で強制終了（タイムアウト確定） |
| exit code 0 で出力ファイルに `^codex` の最終応答ブロックあり | 正常完了 |

### サブエージェントプロンプトテンプレート

```
以下の手順を実行し、Codexの最終結果のみを返してください。

1. 以下のコマンドをBashで実行する。**`run_in_background: true` を指定すること**（Bashツールの前景timeout上限10分を超えるため必須）。
   **stdoutをファイルにリダイレクト + stdinを/dev/nullに繋ぐこと。これを怠るとcodexがstdin待ちでhangする。**

   timeout 1200 codex exec {options} "{prompt}" > /tmp/codex-{task-name}.txt 2>&1 < /dev/null

2. **Bash background ジョブの完了通知（`<task-notification>` の `status: completed`）が届くまで何もしない。途中経過の BashOutput を見て判断しないこと。**
   - Web 検索を 5-10 回連発するのは codex の正常動作。各検索 1-2 分 × 数回で 10〜15 分かかることがある。
   - 出力が一時的に静かでも、ファイルサイズが増え続けていれば動いている（`ls -la` で確認可能）。
   - 完了通知前に「タイムアウトした」と判定してはいけない（事故再発防止）。

3. 完了通知後、exit code を確認:
   - exit code 124 → `Codex timed out (20min hard cap reached)` とだけ返す。
   - exit code 0 → 出力ファイルからCodexの最終レスポンスのみを抽出する:

     LAST_LINE=$(grep -n "^codex" /tmp/codex-{task-name}.txt | tail -1 | cut -d: -f1)
     awk "NR>=${LAST_LINE}" /tmp/codex-{task-name}.txt

   - その他の exit code → exit code と出力ファイル末尾 30 行を返す。

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

逆に Web 検索が必要な質問（最新ライブラリの API、仕様確認など）は時間がかかるのが前提なので、`timeout 1200` の上限を覚悟して待つこと。

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
