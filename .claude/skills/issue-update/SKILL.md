---
name: issue-update
description: "Issue を更新・洗練する時に使用する skill。"
---

# Issue Refinement Workflow
このプロンプトは、指定されたGitHub Issueの内容を分析し、ドキュメントやコードベースの文脈を反映して、より実行可能（Actionable）な状態に更新するためのものです。
## ARGUMENTS
- `ISSUE_NUMBER`: 対象のGitHub Issue番号

## IMPORTANT
- **Planモードに入ることを禁止する。** このワークフローはPlanモードを使わず、直接実行すること。

### ビジネス共有issueの昇格（コードマッピングメモがある場合）
Step 1 で取得した本文末尾に `🔧 開発者用：コードマッピングメモ` の折りたたみ（`<details>`）がある場合、そのissueは `issue-biz-create` で作成されたビジネス共有用issueである。実装フェーズへ昇格させるため、以下の特別扱いをする:
- **メモを変換テーブルとして優先活用する**: Step 2 でコードを調べ直す前に、折りたたみメモの「用語↔コード対応表 / REQ→想定変更箇所 / AC→想定テスト」を読み、実装設計・技術的な考慮事項・テスト担保方針の生成材料として使う（不足分のみ追加調査する）。
- **共有部分を壊さない**: 概要 / ユースケース / 詳細仕様 は日本語・コード参照なしのまま維持する（対象画面/対象ラベル/対象項目/対象ロジックの表現を保つ）。
- **ACはQA手順を保ったまま拡張する**: 既存の受け入れ条件（人間QA手順）は残し、その直下に T-N / テスト種別（Playwright/Jest）のチェックボックスを追記する形で実装向けに拡張する。
- **昇格後にメモを削除してよい**: 実装設計・技術考慮・テスト担保へ展開し終えたら、役割を終えた折りたたみメモは本文から削除してよい（残す場合はユーザーに確認）。

## 手順 (Steps)

### 0. 進捗確認と再開

**進捗ファイル**: `.claude/tmp/${REPO_NAME}-${ISSUE_NUMBER}-issue-update.json`

1. `.claude/tmp/` 配下に `${REPO_NAME}-${ISSUE_NUMBER}-issue-update.json` ファイルが存在するか確認する
2. 存在する場合:
   - ファイルを読み込む
   - `steps` の各ステップの `status` を確認し、`completed` のステップをスキップする
   - `context` に保存された中間結果を復元して、未完了ステップから再開する
   - ユーザーに「前回の進捗を検出しました。Step N から再開します」と報告する
3. 存在しない場合:
   - 新規の進捗ファイルを作成する: `.claude/tmp/${REPO_NAME}-${ISSUE_NUMBER}-issue-update.json`
4. 各ステップ完了時に進捗ファイルを更新する

**進捗JSONスキーマ:**
```json
{
  "command": "issue-update",
  "repo": "${REPO_NAME}",
  "issue_number": "${ISSUE_NUMBER}",
  "started_at": "ISO 8601",
  "updated_at": "ISO 8601",
  "steps": {
    "step_1": { "status": "pending", "completed_at": null },
    "step_2": { "status": "pending", "completed_at": null },
    "step_3": { "status": "pending", "completed_at": null },
    "step_4": { "status": "pending", "completed_at": null },
    "step_4a": { "status": "pending", "completed_at": null },
    "step_5": { "status": "pending", "completed_at": null }
  },
  "context": {
    "issue_body": "",
    "step_2_teammate_results": {},
    "step_3_results": "",
    "step_4_draft": "",
    "step_4a_review_results": {}
  }
}
```

### 1. 現状の把握
まず、以下のコマンドを実行してIssueの現在の内容を取得してください。
$ gh issue view ISSUE_NUMBER --repo akichim21/cancel
加えて、関連するIssueやPRがないか確認する。
$ gh issue view ISSUE_NUMBER --repo akichim21/cancel --json title,body,labels,comments,projectItems
下記は複雑な仕様な場合に確認する
$ gh search issues --repo akichim21/cancel "関連キーワード" --limit 5
$ gh search prs --repo akichim21/cancel "関連キーワード" --limit 5
重複や関連issueがあればリンクし、過去の議論で得られた知見を反映する。
### 2. 並列分析（1チームメイト + リーダー）

Step 1 の把握結果を元に、以下の分析チームメイトを **エージェントとして生成** する。
リーダー（Main Agent）自身は調査項目を並行して実施する。

##### チームメイト 1: codebase-explorer
- `.claude/agents/codebase-explorer.md` の定義に従う
- **入力**: {Issue本文} + キーワード・対象機能
- **自身の分析**:
  - 関連ファイルパス、参照すべき既存パターン、影響範囲を調査
  - `.claude/skills/qa-patterns/` を読み、テスト計画を策定（予想されるテスト計画、AC確定前なので暫定版）
- **出力**: 関連コード・影響範囲レポート + 暫定テスト計画

**チームメイト生成:**
- codebase-explorer: エージェント定義ファイルの内容 + Issue本文

**リーダーの並行タスク:**
チームメイトの分析完了を待つ間に、以下の調査を実施する:
1.  **ドキュメント検索**: `docs/` を検索し、関連する仕様や設計方針を確認する。
2.  **変更履歴の確認**: 関連ファイルの `git log` を確認し、最近の変更意図や経緯を把握する。
3.  **Docs読み込み**: `docs/product/` と `docs/tech/` を読み、製品仕様・技術パターンを把握する。
4.  **Lesson確認**: `.claude/skills/issue/lesson.md` を読み、過去の指摘パターンを回避する。

**結果統合:**
- チームメイトの完了を待ち、リーダー自身の調査結果と統合する
- チームメイトが失敗/タイムアウトした場合は、リーダー自身の分析で代替する（graceful degradation）
- チームメイト由来の項目には出典タグを付ける（例: `[+codebase-explorer@2]`）

### 3. 分析と具体化 (Analysis)
収集した情報を元に、以下の点を分析してください。
* **具体性**: Issueの内容は具体的か？抽象的な表現の場合、具体的な現象や再現手順が必要。
* **変更対象の特定**: 新規作成（新ページ/バッチ/API等）か既存改修かを判定する。既存改修の場合、対象のページ/バッチ/APIとその変更箇所を具体的に特定する。入力文書で曖昧な場合はコードを調査して補完し、それでも判断できない場合はユーザーに質問する。
* **ユースケース分析**: 新規ユーザーフローの導入を伴うか判定する。
* **仕様の網羅性**: 画面/機能ごとに以下の観点を漏れなく洗い出す — 表示仕様、条件分岐、バリデーション、エッジケース。
* **対象アプリの明記**: スタイリストアプリ / カスタマーアプリ / 管理画面 / サーバー のどれが対象か明確にする。
* **技術的考慮事項**: 既存のコードへの影響範囲、依存関係、エッジケースは何か。
* **セキュリティ・データ整合性**: 認証・認可、入力バリデーション、データマイグレーションの有無。
* **難易度/規模感 (Calibration)**:
    * *Low*: 単なるテキスト修正や軽微なバグ修正 → シンプルな構成にする。
    * *High*: 新機能、リファクタリング、複雑なロジック変更 → 詳細な仕様、AC、考慮事項を網羅する。スコープが大きすぎる場合はサブissueへの分割を提案する。
* **テストケースの洗い出し** .claude/skills/qa-patterns/のベストプラクティスを確認し、今回のissueでテストすべきパターンを洗い出す
    * **フロント（サロンポータル/管理画面/LP）の画面表示・操作に関するACには、必ず Playwright または人力テストを1つ以上含めること**。API の Jest だけでは画面の結合テストとみなさない。
* **要件番号付与**: 詳細仕様の各機能/画面ブロックにREQ-N（REQ-1, REQ-2...）を付与する。
* **Docs影響**: この変更で `docs/product/` や `docs/tech/` に追加・REWRITE すべきドキュメントがあるか評価する。

### 4. 更新案の作成 (Drafting)
以下のセクションを含む更新用テキストを作成してください。**Markdown形式**で出力すること。
#### 構成案
1.  **概要 (Overview)**: 何をするタスクなのか、なぜ必要なのか。
2.  **前提条件 / 関連ドキュメント**: `docs/` から見つけた関連情報へのリンクや要約。関連Issue/PRがあればリンクする。
3.  **ユースケース (Use Cases)**: 新しいユーザーフローを導入する場合のみ詳細記述する。
4.  **詳細仕様 (Detailed Specification)**: 画面/機能単位の仕様を日本語散文で記述する。**REQ-N番号を付与**する。**対象アプリを明記**する。
5.  **実装設計 (Implementation Design)**: コードレベルの変更方針を集約する。**関連REQ列を含める**。
6.  **技術的な考慮事項 (Technical Considerations)**: ドキュメントとコードの乖離があれば明記する。
7.  **受け入れ条件 (Acceptance Criteria)**: EARS形式を参考にしたチェックボックス形式（`- [ ]`）。REQ参照を含める。
8.  **Docs Updates (Proposed)**: docs/product/ 更新（ほぼ全Issue）、docs/tech/ 更新（該当時）、コアパターン更新（該当時）を記載する。
9.  **未解決の質問 (Open Questions)**: （※内容が抽象的で決定できない場合のみ作成）
10. **元の文章 (Original Text)**: 更新前のIssue本文をそのまま記載する。ただし、issue-createで作成された構造化済みIssue（概要・詳細仕様・受け入れ条件等のセクション構成を持つ）の場合は、このセクションは追加しない。

#### 書き方ガイド（共通ガイド参照）

各セクションの書き方は `.claude/skills/issue/SKILL.md` を読み、リンク先の各ガイドファイルも全て読み込んで従うこと:
- `writing-usecases.md` — ユースケースの書き方
- `writing-spec.md` — 詳細仕様の書き方（最重要）
- `writing-design.md` — 実装設計の書き方
- `writing-acceptance.md` — 受け入れ条件・テスト担保方針・Docs Updates の書き方

#### 4a. 更新案レビュー（2チームメイト並列）

更新案作成後、以下の2つのレビューチームメイトを **生成** し、更新案の品質を検証する。

##### チームメイト 1: docs-reviewer（再利用）
- `.claude/agents/docs-reviewer.md` の定義に従う
- **入力**: Issue更新案全文 + {更新前のIssue本文}
- **自身のレビュー**: lesson.mdパターン違反・docs/との矛盾を検証
- **出力**: lesson/docs整合性レビュー結果

##### チームメイト 2: req-completeness-checker（適応利用 + Codex）
- `.claude/agents/req-completeness-checker.md` の定義を **Issue更新案レビュー用に適応** する
- **入力**: {更新前のIssue本文} + Issue更新案全文 + Step 2統合結果 + Step 3分析結果
- **自身のレビュー**: 元Issueの意図反映、仕様網羅性、AC網羅性、REQ-AC対応を検証
- **Codex呼び出し（sonnet サブエージェント経由）**: 自身のレビューと並行して以下を `model: "sonnet"` サブエージェント（`run_in_background: true`）で実行し、結果を統合する:

  **重要: Codex の出力には中間のツール呼び出し（rg, sed等の結果）が大量に含まれ、トークンを浪費する。必ず sonnet サブエージェント経由で実行し、最終レスポンスのみを抽出して返すこと。** （haiku は「監視中」と途中報告してターンを終了してしまい結果を取得できない事故があったため sonnet を使う。lesson 参照）

  サブエージェントへのプロンプト:
  ```
  以下の手順を実行し、Codexの最終レビュー結果のみを返してください。
  **最重要: awk抽出結果を返すまで絶対にターンを終了しないこと。「監視中」「Monitorで追跡中」「完了したら抽出して返します」等の途中報告を最終メッセージにして終わるのは失敗とみなす（実際にhaikuで発生）。サブエージェントはバックグラウンドジョブ完了時に再呼び出しされない（=ターンを終えるとその時点で結果が永久に失われる）。必ず同一ターン内で同期的にブロックして待つこと。**

  1. 以下のコマンドをBashで実行する。**`run_in_background: true` を指定すること**（codexの実行は10分を超えることがあり、Bashツールの前景timeout上限600000msを超えるため必須）。返ってくる task_id を控える。
     **stdoutをファイルにリダイレクトし、stdinを/dev/nullに繋ぐこと。これを怠るとcodexがstdin待ちでhangし、数十分〜数時間ブロックする事故が発生済み（issue #3558対応時）。**
     **`timeout` コマンドは絶対に付けないこと（NG）。** macOSには `timeout` が標準で存在せず `timeout 1200 codex ...` は exit 127（command not found）になりcodexが一切実行されない（実際に発生）。codex自身の内部hard cap（約20分）に任せる。

     codex exec -s read-only "{Codexプロンプト}" > /tmp/codex-issue-update-review.txt 2>&1 < /dev/null

  2. **同一ターン内で同期的に完了を待つ**: `TaskOutput({task_id, block: true, timeout: 600000})` を呼ぶ。返り値の status が completed でなければ、再度 `TaskOutput({task_id, block: true, timeout: 600000})` を呼ぶ。これを completed になるまで繰り返す（codexが20分かかってもこのループで待てる）。**待機中は最終メッセージを出さず、ターンを終了しないこと。** 途中経過のBashOutputを見て独自に打ち切らない。

  3. 完了後、出力ファイルからCodexの最終レスポンスのみを抽出する:

     LAST_LINE=$(grep -n "^codex" /tmp/codex-issue-update-review.txt | tail -1 | cut -d: -f1)
     awk "NR>=${LAST_LINE}" /tmp/codex-issue-update-review.txt

  4. awkの出力のみを返す。要約や加工は不要。出力ファイル自体をReadで読まないこと。
  5. 異常終了の判定は task が completed になった後にのみ行う。出力に `codex` から始まる最終応答ブロックが無く、かつ exit code が 127 の場合は「Codex unavailable（codexコマンド未検出。PATHを確認）」と返す。それ以外で最終応答が無い場合は出力末尾のエラー行をそのまま返す。無理に再試行しない。
  ```

  Codexプロンプト:
  ```
  ⚠️ READ-ONLY: ファイルの作成・編集・削除は絶対に行わないこと。レビューコメントをテキストで報告するのみ。
  以下のGitHub Issue更新案をレビューしてください。まずAGENTS.mdを読んでリポジトリ構造を把握すること。また `.claude/skills/qa-patterns/` と `.claude/skills/issue/` 配下のファイルが存在する場合は読み、レビュー基準として活用すること。
  【Issue内容（更新前）】{更新前のIssue本文}
  【Step 2: コンテキスト収集結果（統合済み）】{統合結果}
  【Step 3: 分析結果】{分析結果}
  【Issue更新案】{更新案全文}
  【レビュー観点】
  - 元のIssueの意図が正しく反映されているか
  - 詳細仕様の具体性・網羅性
  - 受け入れ条件の網羅性とテスト可能性
  - 実装設計の妥当性
  - 見落としている要件
  ```
- **出力**: 自身のレビュー + Codex結果を統合した品質レビュー結果

**レビュー結果の処理:**
- 妥当な指摘は更新案に反映し、出典タグを付ける（例: `[~docs-reviewer@4a]`、`[~req-checker@4a]`、`[~Codex via req-checker@4a]`）
- ユーザーへの提示時に「**エージェントレビューレポート**」セクションを表示:
  - **反映箇所**: エージェント/Codex由来の変更一覧
  - **指摘なし**: 問題が見つからなかったチームメイトを明記

### 5. 実行 (Execution)
1.  作成した更新案をユーザーに提示し、レビューを求める。
2.  ユーザーの承認が得られたら、以下のコマンドでIssueを更新する。
    ```
    $ gh issue edit ISSUE_NUMBER --repo akichim21/cancel --body "$(cat <<'BODY_EOF'
    作成したMarkdownテキスト
    BODY_EOF
    )"
    ```
3.  Issue更新後、`Ready to Develop` ラベルを付与する。
    $ gh issue edit ISSUE_NUMBER --repo akichim21/cancel --add-label "Ready to Develop"
---
## 思考プロセスへの指示 (Guidelines)
* **仕様とコードの分離**: 詳細仕様セクションにファイルパス・クラス名・関数名等のコード参照を含めないこと。コードレベルの情報は実装設計セクションに集約せよ。
* **条件分岐の網羅**: 「適切に処理する」「必要に応じて表示する」等の曖昧表現を禁止する。具体的な条件と、その条件下での結果を明記せよ。
* **画面・機能単位の整理**: 同一画面/機能の仕様が複数箇所に散在しないこと。
* **過剰品質の防止**: 小さなタスクに長大な設計書を書かないこと。タスクのサイズに合わせて出力量を調整せよ。
* **情報の補完**: コードを見て原因の仮説を立てて補記せよ。
* **ドキュメント優先**: `docs/` に仕様がある場合は、コードよりもドキュメントの定義を優先し、乖離がある場合は指摘せよ。
* **元の意図の保持**: 元のIssue作成者の意図やコンテキストを消さないこと。
* **Issue 登録先は `akichim21/cancel` 固定**: Issue は親リポジトリ `akichim21/cancel` に集約する。サブリポジトリ（`GO-TODAY-SHAiRE-SALON/cancel-billing-service-*`）の origin が検出されても、そちらは参照・更新しない。`gh issue` / `gh search` 系は `--repo akichim21/cancel` を明示すること。
