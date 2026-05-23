# Docs テンプレート集

## コアパターンファイル テンプレート

Bootstrap時に生成する各ファイルの基本構成:

```markdown
# [タイトル]

> このファイルは docs-sync で生成・管理されるドキュメントです。
> issue-create / issue-start 時に自動で読み込まれます。

## [セクション]
[パターンと原則を記述。具体例を1-2個含める]
```

### 生成対象ファイル

| ファイル | 内容 |
|---------|------|
| `docs/product/product-overview.md` | 製品概要、コア機能、ユーザー種別（スタイリスト/カスタマー/運営管理者/施設管理者）、主要な業務フロー |
| `docs/product/ux-patterns.md` | 共通UXパターン（エラー表示、ローディング、確認ダイアログ、トースト通知等） |
| `docs/tech/implementation-patterns.md` | 実装パターン（Cloud関数設計、コンポーネント設計、命名規則等） |
| `docs/tech/api-conventions.md` | API設計規約（Cloud関数命名 m_/web_、レスポンス形式、エラーコード等） |

---

## 機能別ドキュメント テンプレート（docs/product/{feature}.md）

```markdown
# {機能名}

> このファイルは機能別ドキュメントです。issue-start 完了時に生成・更新されます。
> 更新原則: 追記ではなく書き換え（REWRITE）

## 概要
[機能の目的・背景を1-2段落で記述]

## ユースケース
[主要なユーザーフローを記述]

## 詳細仕様
[画面/機能単位の仕様を記述。条件分岐・バリデーション・エッジケースを含む]

## 実装設計（簡易）
- **関連ファイル**: [主要なファイルパス]
- **モデル**: [関連Parse Classとリレーション]
- **API**: [関連Cloud関数]
```

---

## 技術ドキュメント テンプレート（docs/tech/{feature}.md）

`docs/product/{feature}.md` から技術的説明を分割する場合に使用する。

```markdown
# {機能名} — 技術詳細

> 製品仕様は [docs/product/{feature}.md](../product/{feature}.md) を参照

## [技術トピック]
[複雑なクエリロジック、外部サービス連携、パフォーマンス最適化等の詳細]
```

### クロスリンク設定

分割した場合は、双方向のクロスリンクを設定する:

```markdown
<!-- docs/product/{feature}.md 内 -->
> 技術的な詳細は [docs/tech/{feature}.md](../tech/{feature}.md) を参照

<!-- docs/tech/{feature}.md 内 -->
> 製品仕様は [docs/product/{feature}.md](../product/{feature}.md) を参照
```
