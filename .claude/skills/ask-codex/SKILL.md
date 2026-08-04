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

## 推奨: Sonnet サブエージェント経由の実行

**問題**: `codex exec` の出力には中間のツール呼び出し結果（rg, sed等）が大量に含まれ、親Claudeのコンテキストトークンを浪費する。

**解決策**: `model: "sonnet"` サブエージェントで実行し、stdoutをファイルにリダイレクトし、最終レスポンスのみ抽出して返す。

> **なぜ haiku ではなく sonnet か**: haiku サブエージェントは「Monitorで監視中。完了したら抽出して返す」と途中報告してターンを終了してしまう事故が複数回発生した。**サブエージェントはバックグラウンドジョブ完了時に再呼び出しされない**（完了通知＝`<task-notification>` で再起動されるのは親=メインループのみ）。サブエージェントがターンを終えるとその時点で結果は永久に失われる。したがって (1) モデルを sonnet にし、(2) 後述のとおり**同一ターン内で同期的にブロック**して待つ。

### ⚠️ 必ず守る起動オプション（hang 防止）

`codex exec` は **prompt を引数で渡しても stdin が open だと「stdin block」として追加読み込みを試みる**（`codex exec --help` 参照）。Claude Code の Bash ツールから起動すると stdin が close されないため、EOF を待ち続けて **数十分〜数時間 hang する事故が実際に発生した**（issue #3558 対応時）。

**必ず以下を全部適用すること:**

1. `< /dev/null` で stdin を即 EOF にする
2. **`timeout` コマンドで wall-clock タイムアウトを付けない（NG）**。理由は下記「タイムアウト禁止」セクション参照。codex 自身の内部 hard cap（約20分）に任せる
3. **Bash ツールは `run_in_background: true` で起動する**。Bash ツールの前景 timeout 上限は 600000ms = 10分なので、codex の長時間実行を許容するには background 実行が必須。task_id を控える
4. **同一ターン内で同期的に完了を待つ**: 完了通知（`<task-notification>`）による再呼び出しに頼らない（サブエージェントには届かない）。`TaskOutput({task_id, block: true, timeout: 600000})` を status が completed になるまで繰り返し呼んでブロックする。**待機中にターンを終了したり「監視中」等の途中メッセージを返さない**

### 🚫 タイムアウト禁止（NG）

**`timeout NNN codex exec ...` のように外側から wall-clock タイムアウトを掛けることは禁止。**

理由:
- 過去事故: Haiku サブエージェントが途中経過を見て早とちりし、開始から **2 分** で `Codex timed out` を誤報告した。実際には codex プロセスはまだ生きており、その後 10〜15 分かけて正常に応答していた。
- Web 検索を 5-10 回連発するのは codex の正常動作で、合計 10〜20 分かかることは珍しくない。外側からの timeout 124 で殺すと、正常な調査の途中で結果を失う。
- 「待てるだけ待つ」が正解。codex 自身に内部 hard cap があるので、無限 hang にはならない。

**適用すべきこと:**

- `timeout` コマンドを **付けない**。
- Bash は **必ず `run_in_background: true`** で起動し、`TaskOutput({task_id, block: true, timeout: 600000})` を status が completed になるまで繰り返し呼んで**同一ターン内で同期的にブロックして待つ**（`<task-notification>` の再呼び出しに頼らない＝サブエージェントには届かず、ターンを終えると結果が失われる）。
- 「タイムアウトした」と判定してよいのは、**TaskOutput が completed を返した上で**、出力ファイルに最終応答（`^codex` 行から始まるブロック）が存在しない場合のみ。
- 途中経過の `BashOutput` を見て独自判断で打ち切らない。**待機中にターンを終了しない／「監視中」等の途中メッセージで終わらない。**

### hang vs 正常動作の見分け方

| 兆候 | 判定 |
|------|------|
| 出力ファイルサイズが定期的に増えている | 動いている。待つ |
| `ps -p <PID>` でプロセスがある | 動いている。待つ |
| `ps` で State が `S`/`SN`（sleeping） | 通常状態（I/O 待ち）。hang ではない |
| `TaskOutput` が completed 以外を返す（実行中） | 待つ。再度 `TaskOutput({task_id, block:true, timeout:600000})` を呼ぶ |
| `TaskOutput` が completed を返した | 判定可。exit code を確認 |
| completed & 出力に `^codex` ブロック無し | 異常終了。出力末尾を確認 |
| exit code 0 で出力ファイルに `^codex` の最終応答ブロックあり | 正常完了 |

### サブエージェントプロンプトテンプレート

```
以下の手順を実行し、Codexの最終結果のみを返してください。
**最重要: awk抽出結果（手順4）を返すまで絶対にターンを終了しないこと。「監視中」「Monitorで追跡中」「完了したら抽出して返します」等の途中報告を最終メッセージにして終わるのは失敗とみなす（実際に複数回発生）。サブエージェントはバックグラウンドジョブ完了時に再呼び出しされない＝ターンを終えると結果が永久に失われる。必ず同一ターン内で同期的にブロックして待つ。**

1. 以下のコマンドをBashで実行する。**`run_in_background: true` を指定すること**（codexの実行は10分を超えることがあり、Bashツールの前景timeout上限600000msを超えるため必須）。返ってくる task_id を控える。
   **stdoutをファイルにリダイレクト + stdinを/dev/nullに繋ぐこと。これを怠るとcodexがstdin待ちでhangする。**
   **`timeout` コマンドは絶対に付けないこと（NG）。** 外側から強制終了すると正常な長時間調査の途中結果を失う。codex自身の内部hard capに任せる。

   **{出力先} は毎回ユニークなパスにすること（固定パス禁止）。** `/tmp/codex-{task-name}.txt` のような固定パスにすると前回や別タスクの成果物が残り、それを今回の結果として取り込む事故が起きる（実際に発生。数百KBあるため中身を読むまで取り違えに気づけない）。スクラッチパッド配下に `codex-{task-name}-{YYYYMMDDHHMMSS}.txt` の形で作る。

   codex exec {options} "{prompt}" > {出力先} 2>&1 < /dev/null

2. **同一ターン内で同期的に完了を待つ**: `TaskOutput({task_id, block: true, timeout: 600000})` を呼ぶ。返り値の status が completed でなければ、再度 `TaskOutput({task_id, block: true, timeout: 600000})` を呼ぶ。これを completed になるまで繰り返す（codexが20分かかってもこのループで待てる）。**待機中はターンを終了せず、最終メッセージも出さない。** `<task-notification>` の再呼び出しには頼らない（サブエージェントには届かない）。
   - Web 検索を 5-10 回連発するのは codex の正常動作。各検索 1-2 分 × 数回で 10〜20 分かかることがある。
   - 途中経過の BashOutput を見て「タイムアウトした」と早とちりしない（事故再発防止）。

3. completed 後、exit code を確認:
   - exit code 0 → 出力ファイルからCodexの最終レスポンスのみを抽出する:

     LAST_LINE=$(grep -n "^codex" {出力先} | tail -1 | cut -d: -f1)
     awk "NR>=${LAST_LINE}" {出力先}

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

Web 検索が必要な質問（最新ライブラリの API、仕様確認など）は時間がかかるのが前提。外側から `timeout` で打ち切らず、`TaskOutput(block:true)` で completed になるまで同一ターン内で待つこと。

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
