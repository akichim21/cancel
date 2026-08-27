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
- **各チームメイトの起動プロンプト末尾に「結果は必ず `SendMessage({to: "team-lead", ...})` で送ること。最終メッセージに書くだけでは届かない」を明記する**（Step 4a の「チームメイトの報告は自動では返ってこない」を参照）

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

##### チームメイト 2: req-completeness-checker（適応利用）
- `.claude/agents/req-completeness-checker.md` の定義を **Issue更新案レビュー用に適応** する
- **入力**: {更新前のIssue本文} + Issue更新案全文 + Step 2統合結果 + Step 3分析結果
- **レビュー観点**: 元Issueの意図反映、仕様網羅性、AC網羅性、REQ-AC対応を検証
- **出力**: 品質レビュー結果
- ⚠️ **このエージェントに Codex 起動を依頼しないこと。** サブエージェントはバックグラウンド完了で再呼び出しされず、ターンを終えた時点で結果が失われる（実際に依頼してレビューが丸ごと欠落した事故あり）

##### Codex（リーダー自身が起動）
- 手順は **`.claude/skills/issue/running-codex.md` に従うこと**（固定パス禁止・`run_in_background: true`・`< /dev/null`・`timeout` 禁止・最終レスポンスのみ awk 抽出）
- 下記の Codex プロンプトをスクラッチパッドにファイルとして書き出し、`"$(cat ...)"` で渡す

  Codexプロンプト:
  ```
  ⚠️ READ-ONLY: ファイルの作成・編集・削除は絶対に行わないこと。レビューコメントをテキストで報告するのみ。
  以下のGitHub Issue更新案をレビューしてください。まずAGENTS.md（無ければCLAUDE.md）を読んでリポジトリ構造を把握すること。また `.claude/skills/qa-patterns/` と `.claude/skills/issue/` 配下のファイルが存在する場合は読み、レビュー基準として活用すること。

  Issue更新案の全文は {更新案ファイルの絶対パス} を読むこと。
  ※ 更新案は数万文字になるためプロンプトに埋め込まず、ファイルパスで渡す

  【Issue内容（更新前）】{更新前のIssue本文}
  【ユーザーが確定済みの設計判断（変更提案しないこと）】{ユーザーに確認して決めた事項}
  【Step 2: コンテキスト収集結果（統合済み）】{統合結果}
  【Step 3: 分析結果】{分析結果}
  【レビュー観点】
  - 元のIssueの意図が正しく反映されているか
  - 詳細仕様の具体性・網羅性
  - 受け入れ条件の網羅性とテスト可能性
  - 実装設計の妥当性（実際のコードを読んで、提案されている変更が破綻しないか検証すること）
  - 見落としている要件・エッジケース
  【出力形式】
  重大度(High/Medium/Low) / 該当箇所 / 問題 / 修正案 の形式で列挙すること。問題が無い観点は「指摘なし」と明記。
  ```

**⚠️ チームメイトの報告は自動では返ってこない（必ず守る）**

`Agent` ツールに `name` を付けて起動したエージェントは **in_process_teammate** になり、**最終メッセージがリーダーへ自動的に返らない**。エージェントはレポートを書き上げても、`SendMessage` で送らなければ idle 通知だけを出して終わる。リーダーに届くのは「idle になった」という通知だけで、**レポート本文は本人のトランスクリプトに残ったまま失われる**。

実際の事故（2026-08-26、tabi #4019 / hotel-infra #170 の作成時。issue-create での事例だが本フローも同じ構造）: `docs-reviewer` と `req-completeness-checker` の2体が、それぞれ5,000字超の完全なレビューを書き上げていたにもかかわらず `SendMessage` を **0回**しか呼ばず、リーダーには何も届かなかった。同時起動した `codebase-explorer` だけが `SendMessage` を1回呼んで届いた。**催促しても直らない**（2体とも催促後に再び無言で idle になった）。失われかけたレポートには、作成済み Issue を壊す High 指摘（CI 設定の削除行範囲が誤りで YAML が壊れる／本番の PDF 変換は Lambda 側で動くため人力テストが担保にならない）が含まれていた。

守ること:

1. **起動プロンプトの末尾に必ず次の1文を入れる**（レビュー系・分析系すべてのチームメイト共通）:
   > 結果は必ず `SendMessage({to: "team-lead", ...})` で送ること。最終メッセージにテキストを書くだけでは届かない。ファイル出力も不可。
2. **idle 通知＝完了ではない。** 「レポート本文を受け取ったか」で判定する。idle 通知だけでレポートが無ければ**失敗として扱う**。
3. **催促は1回まで。** それでも届かなければトランスクリプトから直接回収する（`SendMessage` が0回なら本文は確実に残っている）:
   ```bash
   D=~/.claude/projects/<project>/<session-id>/subagents
   python3 -c "
   import json,sys
   txts=[]
   for line in open(sys.argv[1]):
       try: d=json.loads(line)
       except: continue
       m=d.get('message') or {}
       if m.get('role')!='assistant': continue
       for b in (m.get('content') or []):
           if isinstance(b,dict) and b.get('type')=='text' and b.get('text','').strip(): txts.append(b['text'])
   print(txts[-1] if txts else '(なし)')
   " "$D"/agent-a<agent-name>-*.jsonl
   ```
4. **回収もできない場合は、その担当分をリーダー自身が代替実施する。** 機械照合（AC ↔ T-N ↔ REQ、担保根拠テーブルの過不足）と書き方ガイド準拠チェック（詳細仕様へのコード参照混入、人力テストの理由記載漏れ）はスクリプトで代替できる。**レビュー未実施のまま Issue を作成してはならない。**

**レビュー結果の処理:**
- **事実主張は自分で裏を取ってから反映する。** 「実装がこうなっている」という指摘は、レビューエージェントでも Codex でも誤ることがある（実際に双方で事実誤認が発生）。該当ファイルを読んで確認してから更新案に反映する
- 妥当な指摘は更新案に反映し、出典タグを付ける（例: `[~docs-reviewer@4a]`、`[~req-checker@4a]`、`[~Codex@4a]`）
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
