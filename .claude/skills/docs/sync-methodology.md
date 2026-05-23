# Docs Sync 方法論

## 情報収集フェーズ（入力に応じて自動選択）

入力コンテキストに応じて、以下のパターンから適切なフローを選択する。

### パターン A: Full Sync（引数なし）

シナリオを検出し、Bootstrap or Sync Flow を実行する。

1. `docs/product/` と `docs/tech/` の状態を確認する:
   - **Bootstrap Mode**: ディレクトリが空、またはコアファイル（`product-overview.md`, `ux-patterns.md`, `implementation-patterns.md`, `api-conventions.md`）が不足
   - **Sync Mode**: コアファイルが存在
2. Bootstrap → [Bootstrap Flow](#bootstrap-flowコアファイル不足時) へ
3. Sync → [Sync Flow](#sync-flowコアファイル存在時) へ

### パターン B: Git Diff 分析

`git diff` / `git log` / `git status` から変更内容を把握し、関連docsを更新する。

1. `git diff`・`git log --oneline -20` で既存ファイルの変更を把握し、`git status` で新規ファイルも含めた差分を確認する
2. 変更に関連する `docs/product/` / `docs/tech/` ファイルを特定
3. [機能別ドキュメント更新フロー](#機能別ドキュメント更新フロー) に従って更新

### パターン C: Issue + 実装コンテキスト

Issue内容 + 実装サマリー + 変更ファイルから機能別docs更新する。

1. Issue内容の把握（`gh issue view {ISSUE_NUMBER} --repo akichim21/cancel --json title,body,labels`）
2. 実装サマリー（[Completion] コメントで整理した変更内容）を参照
3. 変更ファイル一覧から対象機能を特定
4. [機能別ドキュメント更新フロー](#機能別ドキュメント更新フロー) に従って更新

### パターン D: 調査リクエスト

指定された機能/領域を調査し、docs更新する。

1. 指定された機能・領域のコードを探索
2. 既存docsとの差分を確認
3. 必要に応じて [機能別ドキュメント更新フロー](#機能別ドキュメント更新フロー) で更新

---

## Bootstrap Flow（コアファイル不足時）

### 1. コードベース分析

以下を読み込んで製品・技術の全体像を把握する:

1. `CLAUDE.md`, `.claude/rules/` — プロジェクトのルールと概要
2. `docs/cancel-billing-service-*/` — 既存の各リポジトリ固有ドキュメント
3. 主要ディレクトリ構造（`cancel-billing-service-api/src/`, `cancel-billing-service-admin/src/`, `cancel-billing-service/src/`, `cancel-billing-service-lp/src/`）を探索し、APIハンドラ・画面構成を把握
4. `package.json` 等から技術スタックを確認

### 2. パターン抽出

**リストではなくパターン**を抽出する。網羅的なファイル一覧やAPI一覧は作成しない。

- `docs/product/product-overview.md`: 製品概要、コア機能、ユーザー種別（サロン/運営管理者）、主要な業務フロー
- `docs/product/ux-patterns.md`: 共通UXパターン（エラー表示、ローディング、確認ダイアログ、トースト通知等）
- `docs/tech/implementation-patterns.md`: 実装パターン（Express APIハンドラ設計、コンポーネント設計、命名規則等）
- `docs/tech/api-conventions.md`: API設計規約（エンドポイント命名、レスポンス形式、エラーコード等）

### 3. ファイル生成

テンプレートは [templates.md](./templates.md) の「コアパターンファイル テンプレート」を参照。

### 4. レビュー用サマリー提示

生成した各ファイルの概要をターミナルに出力し、ユーザーのレビューを求める。

---

## Sync Flow（コアファイル存在時）

### 1. 既存内容の読み込み

`docs/product/`, `docs/tech/` の全ファイルを読む。

### 2. コードベースの変更分析

最近の変更（`git log --oneline -20` 等）を確認し、新しいパターンや規約の変化を検出する。

### 3. ドリフト検出

- **Docs → Code**: Docsに記載されているがコードに反映されていないパターン → 警告
- **Code → Docs**: コードに存在するがDocsに未記載の新パターン → 更新候補

### 4. 機能別ドキュメントの棚卸し

`docs/product/` 内の機能別ドキュメント（コアパターンファイル以外）を棚卸しする:

- **未文書化の検出**: 最近の Issue / PR から、`docs/product/` に対応するドキュメントがない機能を検出し、作成候補をリストアップする
- **陳腐化の検出**: 既存の機能別ドキュメントと現在のコードを照合し、仕様が乖離しているファイルを検出する

### 5. 更新提案

- **REWRITE原則**: ドキュメントの更新は追記ではなく書き換え（REWRITE）で行う。常に最新の仕様が反映された状態を維持する
- ユーザーの手動追記セクションは保護する
- 更新案をターミナルに提示し、承認を得てから反映する

---

## 機能別ドキュメント更新フロー

### 更新判断基準

- **対象**: 新機能追加・既存機能の仕様変更を含むIssue → `docs/product/{feature}.md` を作成 or REWRITE
- **対象外**: テキスト修正・リファクタリング・バグ修正で仕様変更を伴わないもの

### docs/product/{feature}.md の作成・REWRITE

1. Issueの対象機能を特定し、適切なファイル名（`{feature}.md`）を決定する
2. テンプレートは [templates.md](./templates.md) の「機能別ドキュメント テンプレート」を参照
3. 既存ファイルがある場合はREWRITE（丸ごと書き直し）する

### docs/tech/{feature}.md への分割判断

以下に該当する場合は `docs/tech/{feature}.md` に技術的説明を分割する:

**分割する**:
- 複雑なクエリロジック（MongoDB集計、複数コレクションJOIN等）
- 外部サービス連携の詳細（API仕様、認証フロー等）
- パフォーマンス最適化の詳細

**分割しない**:
- 標準的なCRUD操作
- 既存パターンに従った実装

分割した場合はクロスリンクを設定する（テンプレートは [templates.md](./templates.md) の「技術ドキュメント テンプレート」参照）。

### コアパターンファイル更新判断

- `docs/product/product-overview.md`, `docs/product/ux-patterns.md`, `docs/tech/implementation-patterns.md`, `docs/tech/api-conventions.md`
- 判断基準:「このパターンは今後3回以上参照されそうか？」
- YES → コアパターンファイルをREWRITE
- NO → lesson.md か Issue コメントに留める

### REWRITE原則

- ドキュメントの更新は差分追記ではなく、丸ごと書き直す
- 常にファイル全体が最新の仕様を反映した状態にする
- 過去の仕様履歴は git log で追跡する

---

## Granularity Principle

### コアパターンファイル（product-overview, ux-patterns, implementation-patterns, api-conventions）

> 「新しいコードが既存パターンに従っているなら、Docsの更新は不要」

パターンと原則を記録する。網羅的リストは作成しない。

**Bad**: ディレクトリツリーの全ファイルを列挙する
**Good**: 組織化パターンを例とともに記述する

### 機能別ドキュメント（{feature}.md）

> 「ほぼすべてのIssueでユースケース・詳細仕様・簡易実装設計を蓄積する」

機能単位の具体的な仕様を記録する。コアパターンファイルとは粒度が異なる。

**Bad**: コアパターンファイルに個別機能の仕様を書く
**Good**: 機能別ファイルに具体的な仕様を書き、コアパターンは横断的なルールに留める
