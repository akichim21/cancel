#!/bin/bash
set -euo pipefail

# SessionEnd hook: generate session summary and append to worklog

# Read hook event data from stdin
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Validate inputs
if [[ -z "$SESSION_ID" || -z "$CWD" ]]; then
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

# Find existing worklog for this session
WORKLOG_DIR="$CWD/.worklog/$GITHUB_USER"
SESSION_SHORT="${SESSION_ID:0:8}"
WORKLOG_FILE=""
for f in "$WORKLOG_DIR"/*-"$SESSION_SHORT".md; do
  if [[ -f "$f" ]]; then
    WORKLOG_FILE="$f"
    break
  fi
done

# No worklog found for this session
if [[ -z "$WORKLOG_FILE" ]]; then
  exit 0
fi

PROMPT_FILE=$(mktemp)
trap 'rm -f "$PROMPT_FILE"' EXIT

# Read existing worklog (truncate if very large)
EXISTING_WORKLOG=$(head -c 100000 "$WORKLOG_FILE")

# Build prompt for session summary
cat > "$PROMPT_FILE" << 'PROMPT_HEADER'
あなたはClaude Codeの作業ログ記録係です。
以下のworklogを読み、セッション終了サマリーを生成してください。
サマリーのMarkdownテキストのみを出力し、他のテキストは出力しないでください。

## 出力フォーマット

---

## Session End (HH:MM:SS)

### Summary
- Rallies: N
- Feedback: N件（簡潔な内容リスト）
- Background: N件（簡潔な内容リスト）
- Decision: N件（簡潔な内容リスト）
- Error: N件（簡潔な内容リスト）
- Files changed: N

### Key Takeaways
（このセッションから結晶化すべき最重要の知見を1-3個。なければ省略）

## worklog
PROMPT_HEADER

echo "$EXISTING_WORKLOG" >> "$PROMPT_FILE"

# Generate summary using Claude CLI
SUMMARY=$(claude -p --model haiku < "$PROMPT_FILE" 2>/dev/null) || exit 0

# Skip if empty
if [[ -z "$SUMMARY" || ${#SUMMARY} -lt 10 ]]; then
  exit 0
fi

# Remove transcript_offset marker before appending summary
sed -i '' '/<!-- transcript_offset:.*-->/d' "$WORKLOG_FILE"

# Append session summary
printf '\n%s\n' "$SUMMARY" >> "$WORKLOG_FILE"
