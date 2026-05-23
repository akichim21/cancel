---
name: issue-start
description: "Issue を起点に実装を開始する時に使用する skill。"
---

## IMPORTANT
- **Planモードに入ることを禁止する。** このワークフローはPlanモードを使わず、直接実行すること。

## 引数パース

`$ARGUMENTS` を `<issue番号 or URL> [ブランチ名] [--base <ベースブランチ>]` としてスペース区切りで分割する。

**第1引数（必須）: Issue番号 or GitHub Issue URL**
- 数値の場合: そのままISSUE_NUMBERとして使用
  - 例: `729` → ISSUE_NUMBER=`729`
- GitHub Issue URLの場合: URLからIssue番号を抽出
  - 例: `https://github.com/akichim21/cancel/issues/729` → ISSUE_NUMBER=`729`
  - パターン: `https://github.com/{owner}/{repo}/issues/{N}` → ISSUE_NUMBER=`{N}`

**第2引数（必須）: ブランチ名**
- 指定された場合: そのままBRANCH_NAMEとして使用
  - 例: `feature/GTSS-999` → BRANCH_NAME=`feature/GTSS-999`
- 省略された場合: デフォルトで `feature/GTSS-{ISSUE_NUMBER}` を使用
  - 例: ISSUE_NUMBER=`729` → BRANCH_NAME=`feature/GTSS-729`

**--baseオプション（必須）: ベースブランチ名**
- `--base <branch>` の形式で指定された場合: 全リポジトリのworktree作成時にデフォルトのベースブランチの代わりに指定されたブランチを使用する（BASE_BRANCH_OVERRIDE）
  - 例: `--base feature/GTSS-700` → BASE_BRANCH_OVERRIDE=`feature/GTSS-700`
- 省略された場合: 各リポジトリのデフォルトベースブランチを使用（Step 2-2のマッピングに従う）
- **注意**: `--base` は引数のどの位置にあってもパースする（第2引数の前後どちらでも可）

** 3つの引数全てなければエラーメッセージを返す

**パース例:**
- `729` → ISSUE_NUMBER=`729`, BRANCH_NAME=`feature/GTSS-729`, BASE_BRANCH_OVERRIDE=なし
- `729 feature/GTSS-729` → ISSUE_NUMBER=`729`, BRANCH_NAME=`feature/GTSS-729`, BASE_BRANCH_OVERRIDE=なし
- `729 fix/hotfix-login` → ISSUE_NUMBER=`729`, BRANCH_NAME=`fix/hotfix-login`, BASE_BRANCH_OVERRIDE=なし
- `729 --base feature/GTSS-700` → ISSUE_NUMBER=`729`, BRANCH_NAME=`feature/GTSS-729`, BASE_BRANCH_OVERRIDE=`feature/GTSS-700`
- `729 fix/hotfix-login --base feature/GTSS-700` → ISSUE_NUMBER=`729`, BRANCH_NAME=`fix/hotfix-login`, BASE_BRANCH_OVERRIDE=`feature/GTSS-700`
- `https://github.com/akichim21/cancel/issues/729` → ISSUE_NUMBER=`729`, BRANCH_NAME=`feature/GTSS-729`, BASE_BRANCH_OVERRIDE=なし
- `https://github.com/akichim21/cancel/issues/729 fix/hotfix-login` → ISSUE_NUMBER=`729`, BRANCH_NAME=`fix/hotfix-login`, BASE_BRANCH_OVERRIDE=なし
- `https://github.com/akichim21/cancel/issues/729 --base develop` → ISSUE_NUMBER=`729`, BRANCH_NAME=`feature/GTSS-729`, BASE_BRANCH_OVERRIDE=`develop`
- `https://github.com/akichim21/cancel/issues/729 fix/hotfix-login --base develop` → ISSUE_NUMBER=`729`, BRANCH_NAME=`fix/hotfix-login`, BASE_BRANCH_OVERRIDE=`develop`

以降、`{ISSUE_NUMBER}` と `{BRANCH_NAME}` と `{BASE_BRANCH_OVERRIDE}`（指定時のみ）としてそれぞれ使い分ける。
worktreeディレクトリ名は `{BRANCH_NAME}` のスラッシュをハイフンに置換した値 `{WORKTREE_DIR}` を使う。
例: `feature/GTSS-729` → `feature-GTSS-729`

GitHub Issue #{ISSUE_NUMBER} の内容を確認し、実装を開始してください。

## 実装フロー

### Step 1: Issue読み込み

> **Issue 登録先**: Issue はすべて親リポジトリ `akichim21/cancel` に集約されている。サブリポジトリ（`GO-TODAY-SHAiRE-SALON/cancel-billing-service-*`）には登録しない。`gh issue` 系コマンドは作業ディレクトリに関わらず `--repo akichim21/cancel` を明示すること。

```bash
gh issue view {ISSUE_NUMBER} --repo akichim21/cancel
gh issue view {ISSUE_NUMBER} --repo akichim21/cancel --comments
```

- Issueの要件・受入条件を正確に把握する
- 既存コメント（過去のAnalysis等）があれば文脈を理解する

### Step 2: ワークツリーセットアップ

`.claude/rules/worktree-workflow.md` のルールに従い、変更対象リポジトリにworktreeを作成する。

#### 2-1: 変更対象リポジトリの特定

Step 2の探索結果から、変更が必要なリポジトリを特定する。

#### 2-2: 各リポジトリでworktree作成

デフォルトベースブランチマッピング:
- cancel-billing-service-api → `main`
- cancel-billing-service → `main`
- cancel-billing-service-admin → `main`
- cancel-billing-service-lp → `main`

**ベースブランチの決定**: `{BASE_BRANCH_OVERRIDE}` が指定されている場合はそれを使用し、指定されていない場合は上記のデフォルトマッピングを使用する。以降 `{base_branch}` は決定されたベースブランチを指す。

各変更対象リポジトリで以下を実行:

```bash
cd /Users/aki/cancel/{repo}
git fetch origin
mkdir -p .worktrees

# 1. リモートにブランチが存在するか確認:
git ls-remote --heads origin {BRANCH_NAME}

# 2a. リモートにブランチが存在する場合 → リモートブランチを追跡してworktree作成:
git worktree add .worktrees/{WORKTREE_DIR} -b {BRANCH_NAME} origin/{BRANCH_NAME}

# 2b. リモートにブランチが存在しない場合 → ベースブランチから新規作成:
# {BASE_BRANCH_OVERRIDE}が指定されている場合: ローカルの{BASE_BRANCH_OVERRIDE}
# 指定されていない場合: origin/{デフォルトベースブランチ}
# BASE_BRANCH_OVERRIDEあり → ローカルブランチを起点にする（派生ブランチからの分岐を想定）
git worktree add .worktrees/{WORKTREE_DIR} -b {BRANCH_NAME} {base_branch}
# BASE_BRANCH_OVERRIDEなし → リモートの最新を起点にする
git worktree add .worktrees/{WORKTREE_DIR} -b {BRANCH_NAME} origin/{base_branch}

# 依存パッケージのインストール（リポジトリごとに手順が異なる）
cd .worktrees/{WORKTREE_DIR}
```

**⚠️ 重要: node_modulesのシンボリックリンク禁止**
`ln -s ../../node_modules node_modules` のようなシンボリックリンクは**絶対に作成しない**。worktree間で依存が共有され、ブランチごとに異なる依存バージョンを扱えなくなるため、必ず各worktreeで独立したnode_modulesをインストールすること。

**リポジトリ別インストール手順:**

全リポジトリとも `npm install` でそのまま動作する:

```bash
# cancel-billing-service-api / cancel-billing-service /
# cancel-billing-service-admin / cancel-billing-service-lp:
npm install
```

#### 2-3: manifest の作成（Issue別ファイル）

`.claude/worktree-manifests/GTSS-{ISSUE_NUMBER}.json` にworktree情報を記録する（並列Issue対応のため、Issue毎に個別ファイル）:

```bash
mkdir -p .claude/worktree-manifests
```

```json
{
  "issueNumber": {ISSUE_NUMBER},
  "branchName": "{BRANCH_NAME}",
  "baseBranchOverride": "{BASE_BRANCH_OVERRIDE or null}",
  "worktreeDir": "{WORKTREE_DIR}",
  "slot": {SLOT},
  "ports": {
    "api": {API_PORT},
    "admin": {ADMIN_PORT},
    "userPortal": {USER_PORTAL_PORT},
    "lp": {LP_PORT}
  },
  "repos": {
    "cancel-billing-service-api": {
      "hasWorktree": true,
      "worktreePath": "/Users/aki/cancel/cancel-billing-service-api/.worktrees/{WORKTREE_DIR}",
      "branch": "{BRANCH_NAME}",
      "baseBranch": "{base_branch}"
    },
    "cancel-billing-service": {
      "hasWorktree": false
    },
    "cancel-billing-service-admin": {
      "hasWorktree": false
    },
    "cancel-billing-service-lp": {
      "hasWorktree": false
    }
  }
}
```

- `baseBranchOverride`: `--base` で指定された値を記録する。指定されていない場合は `null`
- 各repoの `baseBranch`: 実際に使用されたベースブランチ（overrideがあればその値、なければデフォルト値）

変更対象リポジトリのみ `hasWorktree: true` + パス情報を設定し、それ以外は `hasWorktree: false` とする。

#### 2-4: スロットベースポート割当

Issue毎にユニークなポートを割り当て、並列worktree間のポート競合を防ぐ。

**スロット計算:**

```bash
# 1. Issue番号をCRC32ハッシュでスロット番号（0-9）に変換
ISSUE_NUM={ISSUE_NUMBER}
SLOT=$(echo -n "$ISSUE_NUM" | cksum | awk '{print $1 % 10}')

# 2. 既存manifestとの衝突チェック（線形プローブ）
EXISTING_SLOTS=$(for f in .claude/worktree-manifests/GTSS-*.json; do
  [ -f "$f" ] && jq -r '.slot' "$f" 2>/dev/null
done)

ATTEMPTS=0
while echo "$EXISTING_SLOTS" | grep -qx "$SLOT" && [ $ATTEMPTS -lt 10 ]; do
  SLOT=$(( (SLOT + 1) % 10 ))
  ATTEMPTS=$((ATTEMPTS + 1))
done

if [ $ATTEMPTS -ge 10 ]; then
  echo "ERROR: 全スロット(0-9)が使用中です。worktree-cleanupで不要なworktreeを削除してください。"
  exit 1
fi
```

**ポート計算:**

| 用途 | ベースポート | 計算式 | 変数名 |
|------|------------|--------|--------|
| API (cancel-billing-service-api) | 1338 | 1338 + SLOT | API_PORT |
| 管理画面 (cancel-billing-service-admin) | 3000 | 3000 + SLOT | ADMIN_PORT |
| ユーザーポータル (cancel-billing-service) | 5173 | 5173 + SLOT | USER_PORTAL_PORT |
| LP (cancel-billing-service-lp) | 5273 | 5273 + SLOT | LP_PORT |

```bash
API_PORT=$((1338 + SLOT))
ADMIN_PORT=$((3000 + SLOT))
USER_PORTAL_PORT=$((5173 + SLOT))
LP_PORT=$((5273 + SLOT))
```

**ポート設定ファイルの生成:**

各worktreeに対応するポート設定ファイルを生成する（worktreeが存在するリポジトリのみ）。

**cancel-billing-service-api** — `.env` に書き込み:
```bash
cd /Users/aki/cancel/cancel-billing-service-api/.worktrees/{WORKTREE_DIR}
echo "PORT=${API_PORT}" >> .env
```

**cancel-billing-service-admin** — `.env.local` に書き込み（dev サーバーポート + API URL）:
```bash
cd /Users/aki/cancel/cancel-billing-service-admin/.worktrees/{WORKTREE_DIR}
cat >> .env.local <<ENVLOCAL
VITE_API_BASE_URL=http://localhost:${API_PORT}
ENVLOCAL
# Vite dev サーバーは起動時に --port ${ADMIN_PORT} を指定する
```

**cancel-billing-service** — `.env.local` に書き込み（API URL）:
```bash
cd /Users/aki/cancel/cancel-billing-service/.worktrees/{WORKTREE_DIR}
cat >> .env.local <<ENVLOCAL
VITE_API_BASE_URL=http://localhost:${API_PORT}
ENVLOCAL
# Vite dev サーバーは起動時に --port ${USER_PORTAL_PORT} を指定する
```

**cancel-billing-service-lp** — `.env.development` に書き込み（API URL）:
```bash
cd /Users/aki/cancel/cancel-billing-service-lp/.worktrees/{WORKTREE_DIR}
cat >> .env.development <<ENVDEV
VITE_API_URL=http://localhost:${API_PORT}
ENVDEV
# Vite dev サーバーは起動時に --port ${LP_PORT} を指定する
```

#### 2-5: 作業ディレクトリルールの適用

**以降のStep 3〜5では、全てのファイルパス参照・編集・テスト実行・git操作をworktreeディレクトリで行うこと。**

- `.claude/worktree-manifests/GTSS-{ISSUE_NUMBER}.json` の `worktreePath` をファイルパスのベースとして使用する
- 例: `cancel-billing-service-api/src/cloud/...` → `/Users/aki/cancel/cancel-billing-service-api/.worktrees/{WORKTREE_DIR}/src/cloud/...`
- worktreeが無いリポジトリは従来通り元ディレクトリを使用する

### Step 3: 実装

以下の手順で直接実装を進める。

1. **参照すべきファイル:**
   - `.claude/skills/{vitest,playwright}/**` のスキルファイル

2. **実装タスク:**
   - コード実装 + テスト実装
   - IMPORTANT: playwrightの場合、一つのユースケースでまとめて複数のことを確認することでテスト数を増やしすぎないようにする。受け入れ条件の項目が複数に別れていても1つのユースケースであればまとめて1つのテストケースとしてよい。
     - playwrightですでに一覧を閲覧するテストがあって、一覧にデフォルトで表示Aを追加した検証をする場合、既存の一覧の閲覧テストに表示Aがあること確認するテスト追加でも良い。
     - vitestも例えばxxのデータを作成するテストがあり、そこに項目Aも追加となった場合は、既存テストに項目Aを追加する形でもよい。
     - 判断がつかない場合は新しいテストケース作成で良い

3. **ACの確認レベル分類（重要）:**

   各ACを以下の確認レベルに分類すること。**上のレベルで確認できない場合のみ下に落とす。**

   | レベル | 対象アプリ | 確認方法 | ACをパスにできる条件 | 例 |
   |--------|-----------|---------|-------------------|-----|
   | **Playwright** | サロンポータル / admin / lp | Playwright e2e テスト実行 | テストが green | Web UI表示、画面遷移、フォーム操作 |
   | **API Jest（unit + ハンドラ統合）** | api | jest テスト実行 | テストが green | ロジック、バリデーション、APIレスポンス構造 |
   | **手動確認** | 全て | 人間が実機/ブラウザで確認 | 人間が確認後にチェック | 外部API連携（Stripe/SES/Twilio）、複雑な決済フロー、目視レイアウト確認 |

   **重要なルール:**
   - **UIに表示される/されないことがACの場合**: API の Jest だけではパスにできない。Playwright または手動確認が必須
   - **サロンポータル / admin / lp のUI確認** → Playwrightで書く
   - **Playwrightで書けるケース（画面遷移、要素の表示/非表示、フォーム操作）は積極的に書く**
   - **Stripe Connect / SES / Twilio など外部API連携を含む複雑なフロー**のみ手動確認とする
   - API の Jest は「ロジックが正しいこと」の確認であり、「UIに正しく反映されること」の確認ではない
   - **Playwright も port が空いていれば、必ず実行して green かどうか確認すること。2回10秒くらいを開けてretryしても開かない場合は人間に開けるように聞くこと**

   **Playwrightは「表示確認」だけでなく「操作完了まで確認」すること（重要）:**
   - ACが「〇〇を追加できる」「〇〇を保存できる」の場合、表示確認だけでは不十分。**実際に入力→保存→結果確認まで**をフローに含めること
   - API の Jest は「APIが正しく動くこと」の確認であり、「ユーザーがUIを通して正しく操作できること」の確認ではない

   **Playwrightテストの書き方（サロンポータル / admin / lp）:**
   Playwrightテストは各 Web リポジトリ側に配置する。詳細は `.claude/skills/playwright/SKILL.md` を参照。

4. **受け入れ条件テストパターンの検証（機能単位の実装中または実装終了後に都度実施）:**
   - 機能単位の実装中または実装終了後に、Issueの受け入れ条件に「テスト」セクション（テストパターン表）が存在する場合、`.claude/skills/qa-patterns/` のベストプラクティスと照合して過不足を検証する
   - `.claude/skills/qa-patterns/bestpractice.md` と `techniques.md` を読み、テストピラミッド・同値分割法・境界値分析・優先度マトリクスの基準を確認する
   - 差分がある場合のみ [Discovery] コメントを投稿する:
   ```
   gh issue comment {ISSUE_NUMBER} --repo akichim21/cancel --body "$(cat <<'COMMENT_EOF'
   ### [Discovery] 受け入れ条件テストパターン更新

   **検証基準:** `.claude/skills/qa-patterns/` のテストピラミッド・同値分割法・境界値分析・優先度マトリクス

   **追加:** (なければ省略)
   - [Layer] #N: [シナリオ] (Priority: PX) — 追加理由

   **変更:** (なければ省略)
   - [Layer] #N: [変更内容] — 変更理由

   **削除:** (なければ省略)
   - [Layer] #N: [シナリオ] — 削除理由
   COMMENT_EOF
   )"
   ```

5. **受け入れ条件チェックボックスの更新（テストgreen後に必ず即座に実施）:**

   **テストがgreenなのにチェックボックス未更新のまま次のステップに進むことを禁止する。**

   自動テスト（Jest / Vitest / Playwright）を実装してgreenになったら、**必ず即座に**以下の手順でIssueのチェックボックスを更新する:

   ```bash
   # 1. 現在のIssue bodyを取得
   gh issue view {ISSUE_NUMBER} --repo akichim21/cancel --json body -q .body > /tmp/issue_body.md

   # 2. /tmp/issue_body.md を編集:
   #    - greenになったテスト項目の `- [ ]` を `- [x]` に変更
   #    - テストファイル名・テスト名を追記（例: `- [x] T-1 Vitest e2e: シナリオ ✅ src/__tests__/e2e/xxx.test.ts`）
   #    - AC配下の全テスト項目（自動+人力）がチェック済みなら、AC自体の `- [ ]` も `- [x]` に変更
   #    - 「自動テスト一覧」セクションの該当T-Nも同様に `- [x]` に変更

   # 3. 更新をIssueに反映
   gh issue edit {ISSUE_NUMBER} --repo akichim21/cancel --body-file /tmp/issue_body.md
   ```

   - 人力テスト項目はチェックを入れない（人間が確認後にチェックする）
   - 複数テストをまとめて実行した場合も、green確認後にまとめてチェック更新してよい

6. **テスト実行ハードゲート:**
   - すべての実装完了後、テストを実行してgreenであることを確認する
   - テストがredの場合は修正→再実行ループ
   - どうしても失敗を修正できないと判断した場合は失敗状態を報告して終了する
   - **テスト未実行では[Completion]コメントの投稿を禁止する**

7. **Issueコメント投稿:**
   - [Decision] コメント（任意 - Issueの方針から逸脱/トレードオフ選択時）:
     ```markdown
     ### [Decision] タイトル

     **背景:** なぜこの判断が必要になったか
     **選択:** 何を選んだか
     **理由:** なぜそれを選んだか
     ```
   - [Discovery] コメント（任意 - Issueに記載のない問題・制約を発見時）:
     ```markdown
     ### [Discovery] タイトル

     **発見:** 何を見つけたか
     **影響:** 実装にどう影響するか
     **対応:** どう対処したか
     ```
   - [CodeReview] コメント（必須 - テストgreen確認後）:
     ```markdown
     ### [CodeReview] コード解説

     **変更ファイル別の解説:**

     #### `path/to/file1`
     - **変更概要:** このファイルで何を変更したか
     - **ポイント:**
       - 重要なロジックや判断の説明
       - なぜこの実装にしたかの理由（複数のアプローチがあった場合）
       - 既存コードとの関連性

     #### `path/to/file2`
     - **変更概要:** ...
     - **ポイント:**
       - ...

     **テストの解説:**
     - `test/path/to/test_file` - 何をテストしているか、どのケースをカバーしているか
     - `e2e/path/to/test_file` - E2Eで検証しているフロー
     ```
   - [Completion] コメント（必須 - テストgreen確認後）:
     ```markdown
     ### [Completion] 実装完了

     **REQカバレッジ:**
     | REQ | AC | テスト | 状態 |
     |-----|---|----|------|
     | REQ-1 | AC-1.1, AC-1.2 | jest/playwright/... | OK |
     | REQ-2 | AC-2.1 | jest/... | OK |

     **受け入れ条件チェック状況:**
     | AC | 自動テスト | 人力テスト | AC状態 |
     |----|-----------|-----------|--------|
     | AC-1.1 | 3/3 完了 | なし | ✅ 完了 |
     | AC-2.1 | 2/2 完了 | 1件 未確認 | ⏳ 人力テスト待ち |

     **変更サマリー:**
     - `path/to/file` - 変更内容

     **テスト:**
     - Jest unit/ハンドラ統合で担保: カバーしているケース
     - Vitest unitで担保: カバーしているケース
     - Playwrightで担保: カバーしているケース
     - 手動確認推奨: テストでカバーしていないケース

     **テスト実行結果:** （実際の実行結果を貼付）
     - [コマンド]: [結果サマリー]

     **Docs更新:** （Issueに「Docs Updates (Proposed)」セクションがある場合）
     - [適用した更新内容] or [見送った理由]

     **レビュー時の注目ポイント:**
     - 箇所とその理由

     **未対応・今後の課題:** （あれば）
     ```

### Step 4: Pre-PRレビュー

実装完了後、**PR作成前に** 以下のレビューを**サブエージェントを起動して**実施し、致命的な漏れを早期検出する。

#### req-completeness-checker チェック
- `.claude/agents/req-completeness-checker.md` を読み、その定義に従うサブエージェントを起動する
- **入力**: Issue 本文（`gh issue view {ISSUE_NUMBER} --repo akichim21/cancel`）+ `git diff`（実装差分）をサブエージェントのプロンプトに含める
- **チェック**: 全 REQ/AC が実装・テストされているか網羅チェック + Jest/Playwright 追加/修正時の green 確認

**レビュー結果の処理:**
- **指摘がある場合**: 修正して対応する（Step 6 と同じパターン）。修正後、[PreReview] コメントをIssueに投稿する:
  ```markdown
  ### [PreReview] Pre-PR レビュー結果

  **検出された問題と対応:**
  - [問題の概要] → [対応内容]

  **修正内容:**
  - [修正箇所の箇条書き]
  ```
- **指摘がない場合**: [PreReview] コメントはスキップし、Step 4.5 へ進む

### Step 4.5: Docs 反映

`.claude/skills/docs/SKILL.md` とリンク先サブファイルを読み、以下のコンテキストで機能別ドキュメントを更新する:

- **Issue内容**: Issue #{ISSUE_NUMBER} の要件・仕様
- **実装サマリー**: [Completion]内容・変更ファイル一覧
- **変更ファイル**: 変更したファイル一覧

判断基準・手順・テンプレートはすべて `.claude/skills/docs/sync-methodology.md` に従う。
Docs変更は実装コミットに含める。

### Step 5: PR作成

Step 4 のレビューをパスし、Step 4.5 の Docs 反映が完了したら、PR を作成する。

### Step 6: 追加修正時

ユーザーから追加修正の指示を受けた場合:

1. `git diff` で現在の変更内容を把握し、修正指示を整理する
2. 以下を実施して直接修正する:
   - `git diff` の内容（現在の実装状態の把握用）
   - ユーザーの修正指示
   - `.claude/skills/` の参照パス（CLAUDE.md / rules は自動読み込み）
   - 修正実装 + テスト修正/追加
   - テスト実行ハードゲート（Step 3と同様）
   - [Modification] コメント投稿:
     ```markdown
     ### [Modification] 変更内容のタイトル

     **変更理由:** ユーザーの指示の要約
     **変更内容:**
     - 変更箇所の箇条書き
     **影響範囲:** 既存の実装やテストへの影響
     ```
   - 変更サマリー + テスト結果を報告

3. 修正内容がレビュー指摘パターンに該当するか判断し、該当する場合は以下を提案する:
   - `.claude/skills/vitest/lesson.md` への追加（Jest/Vitest関連の指摘）
   - `.claude/skills/playwright/lesson.md` への追加（Playwright関連の指摘）
   - `.claude/skills/issue/lesson.md` への追加（Issue仕様記述の指摘）
   - ユーザーの承認が得られたらlesson.mdを更新してコミットに含める

## コメント投稿ルール

- 各コメントは **ターミナル出力** と **`gh issue comment` 投稿** の両方を行う
- 1実装あたり合計 **3-5コメント** が目安（Analysis 1 + Decision/Discovery 0-2 + CodeReview 1 + Completion 1）
- 冗長にならないよう簡潔に書く。箇条書きを活用する
- コメント本文は `gh issue comment {ISSUE_NUMBER} --repo akichim21/cancel --body "$(cat <<'COMMENT_EOF'` ... `COMMENT_EOF` `)"`の形式でヒアドキュメントを使う
