#!/bin/bash
set -uo pipefail

# PreToolUse hook: サブリポジトリの CLAUDE.md に「親リポジトリ（akichim21/cancel）への参照」を書かせない。
#
# 背景: サブリポジトリ（GO-TODAY-SHAiRE-SALON/cancel-billing-service-*）は単体で clone / CI 実行される。
#       そこから親リポジトリの docs/ を指しても読み手には解決できず、実際 `docs/tech/ci-cd.md` のような
#       存在しないパスへの dangling reference が 4 リポジトリに増殖した。CLAUDE.md は自リポジトリ内で
#       完結させる。
#
# 対象: Edit / Write / MultiEdit の書き込み先 basename が CLAUDE.md、かつ「サブリポジトリ配下」のとき。
#       親リポジトリ（akichim21/cancel）の CLAUDE.md は自リポジトリの docs/ を指してよいので対象外。
#
# 判定（新しく書き込まれるテキストのみを検査。既存行は対象外なので段階的な修正を妨げない）:
#   1. 「親リポジトリ」「親リポ」「parent repo」等の明示的な文言
#   2. 親リポジトリの絶対/ホーム相対パス（~/cancel, /Users/*/cancel）
#   3. リポジトリ外へ出る相対参照（../docs, ../CLAUDE.md 等）
#   4. `docs/...` 参照のうち、自リポジトリ内に実体が無いもの（= 親の docs/ を指している）
#
# ブロックは exit 2（stderr の内容が Claude へフィードバックされる）。

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
case "$TOOL" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
[[ -n "$FILE_PATH" ]] || exit 0
[[ "$(basename "$FILE_PATH")" == "CLAUDE.md" ]] || exit 0

# ── サブリポジトリ判定 ────────────────────────────────────────────────
# origin が GO-TODAY-SHAiRE-SALON/cancel-billing-service-* のリポジトリのみを対象にする。
# 新規作成で親ディレクトリが未作成のケースに備え、存在する祖先まで遡ってから git に問い合わせる。
DIR=$(dirname "$FILE_PATH")
while [[ ! -d "$DIR" && "$DIR" != "/" && "$DIR" != "." ]]; do DIR=$(dirname "$DIR"); done
REPO_ROOT=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)
ORIGIN=$(git -C "$DIR" config --get remote.origin.url 2>/dev/null || true)

if [[ -n "$ORIGIN" ]]; then
  [[ "$ORIGIN" == *"cancel-billing-service"* ]] || exit 0
else
  # git 情報が取れない場合はパスで判定する（worktree / 未 clone の退避経路）。
  [[ "$FILE_PATH" == *"/cancel-billing-service"* ]] || exit 0
fi
[[ -n "$REPO_ROOT" ]] || REPO_ROOT=$(dirname "$FILE_PATH")

# ── 検査対象テキスト（新規に書き込まれる内容のみ） ──────────────────────
NEW_TEXT=$(printf '%s' "$INPUT" | jq -r '
  [ .tool_input.content? // empty,
    .tool_input.new_string? // empty,
    ( .tool_input.edits? // [] | .[].new_string? // empty )
  ] | join("\n")
')
[[ -n "${NEW_TEXT//[[:space:]]/}" ]] || exit 0

VIOLATIONS=()

if printf '%s' "$NEW_TEXT" | grep -qiE '親リポ|parent repo|ルートリポジトリ'; then
  VIOLATIONS+=("「親リポジトリ」への言及")
fi

if printf '%s' "$NEW_TEXT" | grep -qE '~/cancel(/|[[:space:]]|`|$)|/Users/[^/]+/cancel(/|[[:space:]]|`|$)'; then
  VIOLATIONS+=("親リポジトリのパス（~/cancel）")
fi

if printf '%s' "$NEW_TEXT" | grep -qE '\.\./(docs|CLAUDE\.md|\.claude)'; then
  VIOLATIONS+=("リポジトリ外へ出る相対参照（../docs 等）")
fi

# `docs/...` 参照のうち自リポジトリ内に実体が無いもの＝親の docs/ を指している。
while IFS= read -r ref; do
  [[ -n "$ref" ]] || continue
  ref="${ref%%[.,、。）)]}"
  [[ -e "$REPO_ROOT/$ref" ]] || VIOLATIONS+=("自リポジトリに存在しないドキュメント参照: $ref")
done < <(printf '%s' "$NEW_TEXT" | grep -oE '\bdocs/[A-Za-z0-9._/-]+' | sort -u)

[[ ${#VIOLATIONS[@]} -eq 0 ]] && exit 0

{
  echo "BLOCKED: サブリポジトリの CLAUDE.md に親リポジトリ（akichim21/cancel）への参照は書けません。"
  echo "  対象ファイル: $FILE_PATH"
  for v in "${VIOLATIONS[@]}"; do echo "  - $v"; done
  echo ""
  echo "対処: 参照で済ませず、必要な内容をこのリポジトリの CLAUDE.md 内に直接書くこと。"
  echo "      分量が多い場合はこのリポジトリ配下に docs/ を作って置き、そこを参照すること。"
} >&2
exit 2
