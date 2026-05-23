---
name: lesson-update
description: "`.claude/lessons.md` と各 skill の `lesson.md` を更新する時に使用する skill。"
---

# Lesson Update Workflow

レビュー指摘や学んだパターンをlesson.mdに記録するワークフローです。

## ARGUMENTS
- `DESCRIPTION`: 記録する内容の説明

## 手順

### 1. 内容の分類

ARGUMENTSの内容から、以下のどのファイルに該当するか判断する:
- `.claude/skills/vitest/lesson.md` — テスト（Jest / Vitest）関連
- `.claude/skills/playwright/lesson.md` — Playwright E2E関連
- `.claude/skills/issue/lesson.md` — Issue仕様記述関連
- `.claude/lessons.md` — 上記に分類できないもの（全般）

複数に該当する場合は、それぞれに追記する。

### 2. 既存内容の確認

該当するlesson.mdを読み、重複がないか確認する。
既存のパターンと類似する場合は、既存パターンの更新（補足追記）を検討する。

### 3. 更新案の作成

以下の形式で追記する:

```markdown
### パターン名
- **問題**: 何が問題だったか
- **正しい対応**: どうすべきか
- **例**: 具体的なコード例やIssue記述例（あれば）
```

### 4. 実行

更新案をユーザーに提示し、承認後にlesson.mdを更新する。
