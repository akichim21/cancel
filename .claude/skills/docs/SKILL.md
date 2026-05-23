---
name: docs
description: 製品仕様・技術パターンのドキュメント管理スキル。Issue作成・実装時に参照する。
---

# Docs（外部記憶）Skill

Issue作成・実装時に参照する製品仕様・技術パターンの管理スキル。

## ドキュメント構造

### コアパターンファイル
- `docs/product/product-overview.md` — 製品概要・コア機能・ユーザー種別
- `docs/product/ux-patterns.md` — 共通UXパターン
- `docs/tech/implementation-patterns.md` — 実装パターン（Express APIハンドラ設計、コンポーネント設計等）
- `docs/tech/api-conventions.md` — API設計規約（エンドポイント命名、レスポンス形式等）

### 機能別ドキュメント
- `docs/product/{feature}.md` — ユースケース・詳細仕様・簡易実装設計
- `docs/tech/{feature}.md` — 複雑な技術的説明（productからクロスリンク）

注: `docs/cancel-billing-service-*` は各リポジトリ固有のドキュメント（このスキルの対象外）

## 原則
- **REWRITE原則**: 追記ではなく書き換え。常に最新の仕様が反映された状態を維持
- **Granularity**: コアパターンは横断ルール、機能別は具体的仕様

## ワークフロー

| ガイド | 内容 |
|--------|------|
| [docs-sync](../docs-sync/SKILL.md) | docs/product と docs/tech を同期・更新する時 |

## 詳細ドキュメント

| ファイル | いつ読むか |
|---------|----------|
| [sync-methodology.md](./sync-methodology.md) | docs 同期の具体手順・判断基準を確認する時 |
| [templates.md](./templates.md) | ドキュメント新規作成・REWRITE時のテンプレート参照 |
