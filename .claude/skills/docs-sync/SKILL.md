---
name: docs-sync
description: "docs/product と docs/tech を同期する時に使用する skill。"
---

`docs/product/` と `docs/tech/` の外部記憶を生成・同期する。

注: `docs/cancel-billing-service-*/` は各リポジトリ固有docsであり、このワークフローの対象外とする。

## 実行手順

1. `.claude/skills/docs/SKILL.md` とリンク先のサブファイルを読む
2. 引数と現在の状況から適切なフローを選択する:
   - 引数なし → Full Sync（Bootstrap or Sync）
   - Issue番号（例: `$ARGUMENTS`）→ Issue + git diff から機能別docs更新
   - 自由テキスト → 調査リクエストとして処理
3. `.claude/skills/docs/sync-methodology.md` の手順に従って実行する
4. ドキュメント作成・更新時は `.claude/skills/docs/templates.md` のテンプレートを使う
5. 更新案をターミナルに提示し、承認を得てから反映する
