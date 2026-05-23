#!/bin/bash
set -euo pipefail

# Stop hook: capture transcript delta and generate worklog entry via Claude
# Runs async after each Claude response (rally)

# Read hook event data from stdin
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Validate inputs
if [[ -z "$SESSION_ID" || -z "$TRANSCRIPT_PATH" || -z "$CWD" ]]; then
  exit 0
fi
if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

# Get GitHub username (cached for performance)
GITHUB_USER_CACHE="${HOME}/.cache/claude-worklog-github-user"
if [[ -f "$GITHUB_USER_CACHE" ]]; then
  GITHUB_USER=$(cat "$GITHUB_USER_CACHE")
else
  GITHUB_USER=$(gh api user -q .login 2>/dev/null || whoami)
  mkdir -p "$(dirname "$GITHUB_USER_CACHE")"
  echo "$GITHUB_USER" > "$GITHUB_USER_CACHE"
fi

# Worklog directory in the project (per-user)
WORKLOG_DIR="$CWD/.worklog/$GITHUB_USER"
mkdir -p "$WORKLOG_DIR"

# Find existing worklog for this session
SESSION_SHORT="${SESSION_ID:0:8}"
WORKLOG_FILE=""
for f in "$WORKLOG_DIR"/*-"$SESSION_SHORT".md; do
  if [[ -f "$f" ]]; then
    WORKLOG_FILE="$f"
    break
  fi
done

# Create new worklog file if not exists
if [[ -z "$WORKLOG_FILE" ]]; then
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  WORKLOG_FILE="$WORKLOG_DIR/${TIMESTAMP}-${SESSION_SHORT}.md"

  BRANCH=$(cd "$CWD" && git branch --show-current 2>/dev/null || echo "unknown")
  GIT_STATUS=$(cd "$CWD" && git status --short 2>/dev/null | head -20 || echo "")
  RECENT_COMMITS=$(cd "$CWD" && git log --oneline -5 2>/dev/null || echo "")

  {
    echo "---"
    echo "session_id: $SESSION_ID"
    echo "started_at: $(date +%Y-%m-%dT%H:%M:%S%z)"
    echo "branch: $BRANCH"
    echo "git_status: |"
    echo "$GIT_STATUS" | sed 's/^/  /'
    echo "recent_commits: |"
    echo "$RECENT_COMMITS" | sed 's/^/  /'
    echo "---"
    echo ""
    echo "<!-- transcript_offset: 0 -->"
  } > "$WORKLOG_FILE"
fi

# Get current transcript offset
OFFSET=$(sed -n 's/.*<!-- transcript_offset: \([0-9][0-9]*\) -->.*/\1/p' "$WORKLOG_FILE" | tail -1)
OFFSET=${OFFSET:-0}

# Get current transcript size
CURRENT_SIZE=$(wc -c < "$TRANSCRIPT_PATH" | tr -d ' ')

# No new content
if [[ "$OFFSET" -ge "$CURRENT_SIZE" ]]; then
  exit 0
fi

# Extract transcript delta to temp file
DELTA_FILE=$(mktemp)
PROMPT_FILE=$(mktemp)
trap 'rm -f "$DELTA_FILE" "$PROMPT_FILE"' EXIT

tail -c +$((OFFSET + 1)) "$TRANSCRIPT_PATH" > "$DELTA_FILE"

# Truncate delta if too large (keep last 200KB for context relevance)
DELTA_SIZE=$(wc -c < "$DELTA_FILE" | tr -d ' ')
if [[ "$DELTA_SIZE" -gt 200000 ]]; then
  TRUNCATED_FILE=$(mktemp)
  tail -c 200000 "$DELTA_FILE" > "$TRUNCATED_FILE"
  mv "$TRUNCATED_FILE" "$DELTA_FILE"
fi

# Read existing worklog for context (truncate if too large)
EXISTING_WORKLOG=$(head -c 50000 "$WORKLOG_FILE")

# Build prompt
cat > "$PROMPT_FILE" << 'PROMPT_HEADER'
あなたはClaude Codeの作業ログ記録係です。
以下の「既存worklog」と「新しいトランスクリプト差分」を元に、worklogに追記するエントリを生成してください。
追記するMarkdownテキストのみを出力し、他のテキストは出力しないでください。

## トランスクリプトのパースルール
- type: "system", "file-history-snapshot" → スキップ
- type: "user" → message.content からユーザーのプロンプトテキストを抽出（<system-reminder>等のXMLタグは除去）
- type: "assistant" → message.content の各ブロック:
  - {type: "text"} → 応答テキスト
  - {type: "tool_use"} → ツール名と対象ファイル/コマンド
- type: "tool_result" → エラーの場合のみ記録
- 差分内に複数のラリー（user→assistant）が含まれる場合は、それぞれ別のRallyとして出力

## カテゴリ定義（複数選択可。該当するもの全てを付与）
- "feedback": ユーザーやCodex等の他AIがAIの出力を修正・訂正・レビューしている。
  例: 「そうじゃなくて〜」「ここは〜に変えて」「Codexのレビューで指摘された」
- "background": ユーザーが技術的な背景・制約・仕様変更の理由を説明している。
  例: 「MSCのAPIが変わって〜」「法的要件で〜が必要」
- "decision": 重要な技術的意思決定が行われた。
  例: 「UseCase+Formパターンを採用」「カラム名はmsc_voyage_idにする」
- "error": エラーが発生し、原因究明や修正が行われた。
  例: テスト失敗の原因特定、本番バグの調査
- 上記に該当しない通常の作業はカテゴリなし（★マーカーなし）

## 出力フォーマット（既存worklogに追記する部分のみ）

---

## Rally N (HH:MM:SS) ★ category1 ★ category2

### Prompt
ユーザープロンプトの要点

### Response Summary
Claudeが何をしたかの簡潔な要約（2-3文）

### Key Content
（カテゴリがある場合のみ。結晶化時に価値がある知見の要約。
feedbackなら何が間違いで何が正しいか。backgroundなら背景の要点。
decisionなら何をなぜ選んだか。errorなら原因と対策。）

### Tools
- Edit: app/models/foo.rb
- Bash: bundle exec rspec (exit: 0)

### Files Changed
- app/models/foo.rb

## 既存worklog（セッションの文脈）
PROMPT_HEADER

echo "$EXISTING_WORKLOG" >> "$PROMPT_FILE"
echo "" >> "$PROMPT_FILE"
echo "## 新しいトランスクリプト差分（JSONL形式）" >> "$PROMPT_FILE"
cat "$DELTA_FILE" >> "$PROMPT_FILE"

# Generate entry using Claude CLI (haiku for speed/cost)
ENTRY=$(claude -p --model haiku < "$PROMPT_FILE" 2>/dev/null) || exit 0

# Skip if Claude returned empty or error-like response
if [[ -z "$ENTRY" || ${#ENTRY} -lt 10 ]]; then
  exit 0
fi

# Remove old offset marker
sed -i '' '/<!-- transcript_offset:.*-->/d' "$WORKLOG_FILE"

# Append new entry with updated offset
printf '%s\n\n<!-- transcript_offset: %s -->\n' "$ENTRY" "$CURRENT_SIZE" >> "$WORKLOG_FILE"
