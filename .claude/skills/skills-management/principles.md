# スキル設計の原則

## SKILL.md は薄くする

- SKILL.md には概要とリファレンス（他ファイルへのリンク）だけを書く
- 詳細な手順・ルール・パターンは別ファイル（同ディレクトリ内）に分割する
- issue/SKILL.md が理想的な構造の参考例

### 良い例（issue/SKILL.md）

```markdown
---
name: issue
description: Issue の作成・更新時に使用する共通ガイド集。
---

# Issue スキル

## 書き方ガイド

| ガイド | 内容 |
|--------|------|
| [writing-spec.md](./writing-spec.md) | 詳細仕様の書き方 |
| [writing-acceptance.md](./writing-acceptance.md) | 受け入れ条件の書き方 |
```

### 悪い例

SKILL.md に全ルール・全パターンを直接書く → ファイルが肥大化し、メンテナンスが困難になる。

## ディレクトリ構成

```
.claude/skills/{skill-name}/
├── SKILL.md          # エントリポイント（薄く）
├── lesson.md         # 過去の指摘パターン（任意）
└── {detail}.md       # 詳細ガイド（必要に応じて複数）
```

## スキルの作成ルール

1. **1スキル1ディレクトリ**: `.claude/skills/{skill-name}/SKILL.md` に配置する
2. **フロントマター必須**: `name` と `description` を必ず記述する
3. **description は具体的に**: いつ使うか・何をするかが description だけで判断できるようにする
4. **既存スキルとの重複を避ける**: 新規作成前に既存スキルを確認し、既存に追記できないか検討する
5. **lesson.md を活用する**: 過去の指摘パターンがあれば lesson.md に記録し、SKILL.md からリンクする

## スキルの更新ルール

1. **SKILL.md を肥大化させない**: 詳細が増えたら別ファイルに分割する
2. **フロントマターを最新に保つ**: description がスキルの実態と乖離しないようにする
3. **不要になったスキルは削除する**: 使われなくなったスキルは放置せず削除する
