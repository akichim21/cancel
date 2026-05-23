# Worklog結晶化（Crystallization）

未処理のworklogから知見を抽出し、`.claude/skills/` や `.claude/lessons.md` に統合してください。

## 手順

### 0. マイグレーションクリーンアップ（前回の結晶化済みworklog削除）

1. GitHubユーザー名を取得: `gh api user -q .login`
2. `.worklog/<github_user>/migrations/` ディレクトリを確認
3. マイグレーションファイルが存在する場合:
   - 各マイグレーションファイルに記載されたworklogファイルを `.worklog/<github_user>/` から削除
   - 処理済みのマイグレーションファイル自体も削除
   - 削除したファイル数を記録（レポート用）
4. マイグレーションファイルが存在しない場合: スキップ
5. レガシー: `.worklog/<github_user>/.crystallized` が存在する場合、記載されたファイルを削除し、`.crystallized` 自体も削除する

### 1. 未処理worklogの特定

1. `.worklog/<github_user>/` ディレクトリ内の全 `.md` ファイルをリストアップ（`migrations/` 配下は除外）
2. 存在するファイルが全て結晶化対象

### 2. worklogの分析

未処理worklogを全て読み込み、以下を優先的に分析:

- **★ feedback マーカー付きラリー**: ユーザーやレビューアーからの修正・フィードバック
- **★ background マーカー付きラリー**: 技術的背景・制約・仕様の説明
- **★ decision マーカー付きラリー**: 重要な技術的意思決定
- **★ error マーカー付きラリー**: エラーパターンと対策

### 3. 陳腐化チェック

各知見について、以下のフローで有効性を判断:

```
worklogエントリ
  ├→ 参照コードが存在する？
  │    ├→ YES → 内容がまだ有効？ → 結晶化
  │    └→ NO  → 原則レベルの知見を含む？
  │              ├→ YES → 原則部分のみ抽出して結晶化
  │              └→ NO  → スキップ（削除対象）
  └→ コード参照なし → 一般的な知見として結晶化
```

- 参照されているファイル・コードがまだ存在するか `Glob` / `Grep` で確認
- 一時的なワークアラウンドは、元のバグが修正済みなら破棄
- 不変の原則はそのまま結晶化

### 4. 知見の分類と統合

テーマ別にグループ化し、適切な場所に追加:

| 知見の種類 | 統合先 |
|-----------|--------|
| テスト関連（API: jest / フロントエンド: vitest） | `.claude/skills/vitest/lesson.md` |
| Playwright E2E関連（Web フロントエンド） | `.claude/skills/playwright/lesson.md` |
| コーディング規約 | `.claude/skills/coding-standards/lesson.md` |
| Issue仕様記述関連 | `.claude/skills/issue/lesson.md` |
| 汎用的な知見 | `.claude/lessons.md` |
| Agent Skill | `.claude/skills` |
| 仕様や技術構成 | `docs` |


### 4.1. worklogの改善(オプション)
- worklog単体で理解できないことがあった場合や必要と思われる情報の追加、いらない情報の削除をするために.claude/hooks/worklog-*を改善する
  - 問題なければskip

### 5. マイグレーション記録の作成

結晶化したworklogファイルを**即時削除せず**、マイグレーションファイルに記録する。

1. `.worklog/<github_user>/migrations/` ディレクトリを作成（存在しない場合）
2. `YYYYMMDD-HHMMSS.md` 形式のマイグレーションファイルを作成:

```markdown
# Crystallization Migration
# Created: <ISO 8601 timestamp>

<crystallized_file_1.md>
<crystallized_file_2.md>
...
```

3. 結晶化したファイルは削除しない（次回の `crystallize workflow` 実行時に Step 0 で削除される）

> **Note**: これにより結晶化結果を確認する猶予が生まれる。問題があればマイグレーションファイルから該当行を削除すれば、次回削除を防げる。

### 6. 結果レポート

結晶化の結果を以下の形式で報告:

- 処理したworklogファイル数
- 抽出した知見の数（カテゴリ別）
- 統合先ファイルのリスト
- スキップした知見とその理由
- 陳腐化により破棄した知見

## 注意事項

- 既存のlesson.mdに重複する内容がないか確認してから追加すること
- 知見は具体的かつ再利用可能な形で記述すること（「Xのときは Y する」の形式）
- cancel は複数サブリポジトリ構成（cancel-billing-service-api, cancel-billing-service, cancel-billing-service-admin, cancel-billing-service-lp）なので、知見がどのリポジトリに関連するかも記録すること
