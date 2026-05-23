---
name: verify-testcases
description: "テストケースCSVの担保状況を調査・補完する時に使用する skill。"
---

## スキル参照

このワークフローの実行にあたり、以下のスキルドキュメントを必ず読み込んで判断基準とすること:

- `.claude/skills/qa-patterns/SKILL.md`
- `.claude/skills/qa-patterns/bestpractice.md`
- `.claude/skills/qa-patterns/techniques.md`
- `.claude/skills/vitest/SKILL.md`

## 引数パース

`$ARGUMENTS` をスペース区切りで分割する。

**形式:** `<CSVパス> <Issue番号> <baseBranch指定...> <targetBranch指定...>`

**第1引数（必須）: CSVファイルパス**
- テストケースが記載されたCSVファイルのパス

**第2引数（必須）: Issue番号**
- 数値の場合: そのまま使用（例: `751`）
- GitHub Issue URLの場合: URLからIssue番号を抽出

**第3引数以降（必須）: baseBranch / targetBranch 指定**
- `base:<repo>:<branch>` — ベースブランチ指定
- `target:<repo>:<branch>` — ターゲットブランチ（実装ブランチ）指定
- `<repo>` は短縮名: `api`, `user`, `admin`, `lp`

| 短縮名 | ディレクトリ |
|--------|------------|
| api | cancel-billing-service-api |
| user | cancel-billing-service |
| admin | cancel-billing-service-admin |
| lp | cancel-billing-service-lp |

**パース例:**
```
testcase coverage workflow ./testcases.csv 751 base:api:main target:api:feature/751
testcase coverage workflow ./testcases.csv 733 base:api:main target:api:feature/733 base:user:main target:user:feature/733
```

## 手順

### Step 1: 入力の読み込みとコンテキスト把握

**1.1 CSVファイルの読み込み**

テストケースCSVを読み込み、全テストケースをパースする。各行のテストケースID・カテゴリ・シナリオ・期待結果を把握する。

**1.2 Issue読み込み**

```bash
gh issue view {ISSUE_NUMBER} --repo akichim21/cancel
gh issue view {ISSUE_NUMBER} --repo akichim21/cancel --comments
```

Issueの要件・受入条件を参考情報として把握する。ただし、**実装されているテストコードを正（正解）とする。**

**1.3 差分の取得**

対象リポジトリごとに以下を実行:

```bash
cd /Users/aki/cancel/{ディレクトリ名}
git fetch origin
git diff {baseBranch}...{targetBranch} > /tmp/verify-diff-{短縮名}.txt
git log --oneline {baseBranch}..{targetBranch} > /tmp/verify-log-{短縮名}.txt
```

### Step 2: 自動テスト担保状況の調査（並列実行）

以下のサブエージェントを**並列に**起動する。各エージェントにCSVの全テストケース・差分・qa-patternsの判断基準を渡す。

#### 2.1 Claude サブエージェント（メイン調査）

各テストケースについて以下を調査する:

1. **対応する自動テストファイルの特定**: テストケースの内容に対応するテストファイル・テスト関数を特定する
2. **expect検証の充足度チェック**:
   - テストケースの期待結果が、`expect` で**具体的な値まで**検証されているか
   - `toBeDefined()`, `toBeTruthy()` など弱いアサーションだけで済ませていないか
   - ビジネスロジックの数値（金額、日時、ステータス等）が網羅的に `expect` されているか
3. **担保レイヤーの判定**: API Unit / API 統合 / Frontend Unit / Playwright / 人力 のどのレイヤーで担保されているか
4. **未担保テストケースの特定**: 自動テストが存在しない、または `expect` が不十分なテストケースを一覧化

**調査の判断基準（qa-patternsに基づく）:**
- API 統合 + Frontend Unit だけでは結合テストとして不十分。Playwright または人間のテストが必要
- 複数のテストを組み合わせて担保できる場合は、その根拠を明確に記載する
- 人力テストとする場合は、なぜ自動化できないか理由を明記する

#### 2.2 Codex サブエージェント（並列調査）

`ask-codex` スキルを使い、Codexにも同じ調査を並列実行させる。

**重要: Codex の出力には中間のツール呼び出し（rg, sed等の結果）が大量に含まれ、トークンを浪費する。必ず `model: "haiku"` サブエージェント経由で実行し、最終レスポンスのみを抽出して返すこと。**

各対象リポジトリごとに個別のサブエージェントを起動する。

サブエージェントへのプロンプト:
```
以下の手順を実行し、Codexの最終調査結果のみを返してください。

1. 以下のコマンドをBashで実行する（タイムアウト300秒）。
   **stdoutをファイルにリダイレクトすること。直接受け取るとCodexの中間出力（rg, sed結果等）でトークンを浪費する。**

   codex exec -s read-only -C /Users/aki/cancel/{ディレクトリ名} "{Codexプロンプト}" > /tmp/codex-verify-testcases-{短縮名}.txt 2>&1

2. 実行完了後、出力ファイルからCodexの最終レスポンスのみを抽出する:

   LAST_LINE=$(grep -n "^codex" /tmp/codex-verify-testcases-{短縮名}.txt | tail -1 | cut -d: -f1)
   awk "NR>=${LAST_LINE}" /tmp/codex-verify-testcases-{短縮名}.txt

3. awkの出力のみを返す。要約や加工は不要。出力ファイル自体をReadで読まないこと。
```

Codexプロンプト:
```
⚠️ READ-ONLY: ファイルの作成・編集・削除は絶対に行わないこと。調査結果をテキストで報告するのみ。

あなたはシニアQAエンジニアとして、以下のテストケースCSVが自動テストで担保されているかを調査してください。

## テストケースCSV
{CSVの内容を貼り付け}

## Issue情報
{gh issue viewの出力を貼り付け}

## 差分
{git diffの出力を貼り付け}

## 調査指示

各テストケースについて以下を報告:

1. **対応する自動テストファイル**: ファイルパス・テスト関数名
2. **expect検証の充足度**: 期待結果が具体値で検証されているか。弱いアサーション（toBeDefined, toBeTruthy, expect.any()）のみの場合は不十分と判定
3. **担保状況**: 完全担保 / 部分担保（何が不足か） / 未担保
4. **担保レイヤー**: API Unit / API 統合 / Frontend Unit / Playwright / 人力
5. **不足している場合の追加・修正提案**: 具体的なテストコード案

## 重要な判断基準
- テストケースの期待結果が、expectで具体的な値まで検証されているかを厳密に確認すること
- ビジネスロジックの数値（金額、日時、ステータス等）は全て個別にexpectで検証されていること
- API 統合 + Frontend Unitだけでは結合テストとして不十分
- 実装されているテストコードを正（正解）とし、Issueは参考情報として扱う
```

### Step 3: 調査結果の統合と追加・修正内容の確定

Claude・Codex両方の調査結果を統合し、以下を確定する:

**3.1 テストケースごとの担保状況マッピング**

各テストケースについて:
- 担保済み: どのテストファイル・テスト関数で担保されているか
- 部分担保: 何が不足しているか（expect不足、レイヤー不足等）
- 未担保: 新規テスト追加が必要

**3.2 追加・修正するテストの一覧を確定**

| 対象 | ファイルパス | 種別 | 内容 |
|------|-----------|------|------|
| server/frontend/e2e | パス | 追加/修正 | 何を追加・修正するか |

**3.3 ユーザーに確認**

追加・修正内容の一覧をユーザーに提示し、実装に進んでよいか確認する。

### Step 4: テストの追加・修正の実装

Step 3で確定した内容に基づき、テストコードを追加・修正する。

**実装ルール:**
- `.claude/skills/vitest/SKILL.md` のアサーションルールに厳密に従う
- `expect` は具体的な値で検証する（`toBeDefined` や `expect.any()` は id 以外で使わない）
- ビジネスロジックの数値は内訳まで網羅的に検証する
- テストファイルは既存の構造・パターンに合わせる

**Worktree対応:**
- `.claude/worktree-manifests/{ISSUE_NUMBER}.json` が存在する場合、manifestに従ってworktreeディレクトリ内で作業する
- manifestが存在しない場合は元ディレクトリで作業する

### Step 5: テスト実行と修正ループ

追加・修正したテストを含む対象テストを実行し、全てgreenになるまで修正する。

**実行コマンド:**

| レイヤー | コマンド | ディレクトリ |
|---------|---------|------------|
| API Unit/統合 | `npm test` または対象ファイル指定 `npm test -- {path}` | cancel-billing-service-api worktree |
| Frontend Unit | `npx vitest run {path}` | cancel-billing-service / -admin / -lp worktree |
| Playwright | `npx playwright test {path}` | cancel-billing-service / -admin / -lp worktree |

**修正ループ:**
1. テスト実行
2. REDのテストがあれば原因を分析し修正
3. 再実行
4. 全てGREENになるまで繰り返す
5. どうしても通らない場合は `it.skip` + `// TODO:` コメントで理由を記録

### Step 6: 結果CSVの出力

2つのCSVファイルを出力する。

#### 6.1 自動テスト一覧CSV

ファイル名: `test-inventory-{ISSUE_NUMBER}.csv`

```csv
テストID,レイヤー,ファイルパス,テスト名,検証内容,ステータス
T001,API 統合,src/__tests__/integration/xxx.test.js,"should create cancellation",キャンセル請求作成の正常系: amount/cancellationFee/serviceFee/status/paymentMethodを検証,GREEN
T002,API Unit,src/__tests__/unit/xxx.test.js,"should validate params",パラメータバリデーション: 必須項目欠如で400を検証,GREEN
T003,Playwright E2E,e2e/tests/xxx.spec.ts,"申請フロー",Step1:ログイン→Step2:申請フォーム入力→Step3:確認→Step4:送信→Step5:完了画面表示確認,GREEN
T004,Playwright E2E,e2e/tests/yyy.spec.ts,"管理画面フロー",Step1:ログイン→Step2:一覧表示→Step3:詳細確認→Step4:編集→Step5:保存確認,GREEN
```

- `レイヤー`: API Unit / API 統合 / Playwright E2E / Frontend Unit を明記
- `検証内容`: Playwrightの場合はステップごとに何をしたかを記載
- `ステータス`: GREEN / SKIP（理由付き）

#### 6.2 テストケース担保マッピングCSV

元のテストケースCSVに以下のカラムを追加して出力する:

ファイル名: `testcase-coverage-{ISSUE_NUMBER}.csv`

```csv
{元CSVの全カラム},担保テストID,担保レイヤー,担保根拠
...,T001;T002,API 統合 + API Unit,"API 統合でキャンセル請求作成の正常系レスポンス(amount/serviceFee/status等)を具体値で検証済み。API Unitでバリデーションロジックの境界値を網羅。Playwright T003で画面遷移を含む統合テスト済みのため、結合レベルでも担保できている"
...,T003,Playwright E2E,"Playwrightフローで申請作成→一覧表示→詳細確認の画面遷移をブラウザで検証。サーバー側はT001 API 統合で担保済みのため、E2E統合として十分"
...,手動,人力,"外部決済API（Stripe Connect）との実通信が必要なため自動化不可。[手動チェック] カード登録→決済→完了の導線を確認"
```

- `担保テストID`: 6.1の自動テスト一覧CSVのテストIDを参照
- `担保レイヤー`: どのレイヤーの組み合わせで担保しているか
- `担保根拠`: **なぜこのテストで担保できたと言えるのか**を具体的に記載。qa-patternsの判断基準に基づく

**CSV記述ルール（重要）:**
- **システム変数名・メソッド名の使用は禁止**。アプリや管理画面で表示している日本語に変換して記載すること
  - NG: `cancelRestriction=sameDay`, `m_updateStylist`, `cannotCancelBooking=true`, `code: 10008`, `status: 'canceled'`
  - OK: 「当日のみキャンセル不可」設定, スタイリスト情報更新API, キャンセル不可設定ON, キャンセル不可エラー, キャンセル成功
- テスト名・検証内容・担保根拠すべてに適用する
- テストコード内の変数名やAPIエンドポイント名ではなく、ユーザーが理解できる機能名・画面名で記述する

### Step 7: 最終報告

以下をユーザーに報告する:

1. **担保状況サマリー**: 全テストケース数 / 自動テスト担保数 / 人力テスト数
2. **追加・修正したテスト一覧**: ファイルパスと変更内容
3. **全テスト実行結果**: GREEN / SKIP の一覧
4. **出力ファイルパス**: 2つのCSVの場所
5. **人力テストが必要な項目**: チェックリスト形式で明記（ある場合）
