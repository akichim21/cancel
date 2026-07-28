---
name: review-pr
description: "Pull Request レビューを codex-reviewer ベースで実施する skill。"
---

## 引数パース

`$ARGUMENTS` を `<issue番号> <ブランチ名...>` としてスペース区切りで分割する。

**第1引数（必須）: Issue番号**
- 数値の場合: そのまま使用（例: `751`）
- GitHub Issue URLの場合: URLからIssue番号を抽出

**第2引数以降（必須）: ブランチ名**
- 全リポジトリで共通の場合: 1つだけ指定（例: `GTSS-751`）
- リポジトリ毎に異なる場合: `repo:branch` 形式で複数指定（例: `server:GTSS-751 admin:GTSS-751-admin`）

| 短縮名 | ディレクトリ |
|--------|------------|
| api | cancel-billing-service-api |
| user | cancel-billing-service |
| admin | cancel-billing-service-admin |
| lp | cancel-billing-service-lp |

**パース例:**
- `751 GTSS-751` → Issue #751、全リポジトリでブランチ `GTSS-751`
- `733 customer:GTSS733 stylist:GTSS733` → Issue #733、customer/stylistそれぞれ `GTSS733`

## 手順

### Step 1: Issue/仕様情報の取得

以下の優先順位でIssue/仕様情報を解決する:

1. **引数にIssue URLがある場合**: 第1引数がGitHub Issue URL（例: `https://github.com/owner/repo/issues/123`）であれば、`gh issue view {URL}` で取得する
2. **引数にIssue番号がある場合**: 第1引数が数値であれば、`gh issue view {ISSUE_NUMBER} --repo akichim21/cancel` で取得する
3. **PR本文にIssueリンクがある場合**: 対象リポジトリのPR（またはBitbucket PR）本文から Issue URL や `#123` 形式のリンクを検出し、`gh issue view` で取得する
4. **PR本文に仕様の記載がある場合**: PR本文自体に要件・仕様の記述があれば、それをIssue情報の代わりに使用する
5. **上記いずれもない場合**: ユーザーに「関連するIssueはありますか？ Issue URLを入力してください」と質問する

```bash
# Issue URLまたは番号が判明した場合
gh issue view {ISSUE_NUMBER} --repo akichim21/cancel
gh issue view {ISSUE_NUMBER} --repo akichim21/cancel --comments
```

codex-reviewer への渡し方:
- **Issue URLが特定できた場合**: 取得コマンド（`gh issue view <URL> --json title,body -q '.title + "\n" + .body'`）を渡す
- **Issue URLがなく、PR本文等に仕様テキストがある場合**: そのテキストをそのまま渡す
- **Issueが存在しない場合**: 「Issue情報なし」と伝え、仕様・意図確認レビュー（観点1）をスキップさせる

Issueの要件・受入条件を把握し、レビューの文脈に活用する。

### Step 2: Manifest読み込みとベースブランチ解決

`.claude/worktree-manifests/GTSS-{ISSUE_NUMBER}.json` を読み込む。

**ベースブランチの解決順序:**
1. 引数にbaseBranchの指定があればそれを使う
2. manifest内の各repoの `baseBranch` フィールドがあればそれを使用
3. manifest内の `baseBranchOverride` フィールドがあればそれを使用
4. いずれもなければデフォルト `main` を使用
5. manifestファイル自体が存在しない場合 → デフォルト `main` を使用

**レビュー対象リポジトリの特定:**
- 引数でブランチ名が1つだけ指定された場合 → manifestの `hasWorktree: true` の全リポジトリが対象。manifestがなければ全リポジトリを検索
- 引数で `repo:branch` 形式で指定された場合 → 指定されたリポジトリのみ対象

### Step 3: リポジトリに入りブランチを最新化

対象リポジトリごとに以下を実行する。作業ディレクトリはリポジトリの**元ディレクトリ**（worktreeではなく `/Users/aki/cancel/{ディレクトリ名}`）を使用する。

```bash
cd /Users/aki/cancel/{ディレクトリ名}
git fetch origin

# 両ブランチをローカルに取得・最新化
git checkout {baseBranch} && git pull origin {baseBranch}
git checkout {toBranch} && git pull origin {toBranch}

# ベースブランチに戻す
git checkout {baseBranch}
```

### Step 4: 差分取得とブランチ方向の検証

```bash
git diff {baseBranch}...{toBranch}
git log --oneline {baseBranch}..{toBranch}
```

**ブランチ方向の検証:**
- `git log --oneline {baseBranch}..{toBranch}` でtoBranchがbaseBranchより先にコミットを持つことを確認する
- コミットが0件の場合 → 差分がないか、方向が逆の可能性。**ユーザーに質問して確認する**
- baseBranchが明らかにおかしい場合（例: developベースなのにmasterと比較している等）→ **ユーザーに質問して確認する**

### Step 5: 差分情報の準備

対象リポジトリごとに差分テキストを取得・保存する。

**cancel（親リポジトリ）の場合:**
- 集約用のため `git diff` で差分を取得する

**cancel-billing-service-api / cancel-billing-service / cancel-billing-service-admin / cancel-billing-service-lp の場合:**
- GitHub ホストのため Pull Request が存在する可能性がある
- まず `git log --oneline {baseBranch}..{toBranch}` でコミット一覧を取得
- `git diff {baseBranch}...{toBranch}` で差分を取得

各リポジトリの差分を一時ファイルに保存し、後続のレビューステップで参照する:

```bash
# 各リポジトリで
git diff {baseBranch}...{toBranch} > /tmp/review-diff-{短縮名}.txt
git log --oneline {baseBranch}..{toBranch} > /tmp/review-log-{短縮名}.txt
```

### Step 6: サブエージェントによるレビュー

差分を以下のサブエージェントに渡してレビューを実施する:

- code-reviewer
- lessons-reviewer
- codex-reviewer

各サブエージェントには、注目すべきフィードバックのみを返すよう指示する。

**サブエージェントのタイムアウトは 1200 秒（20分）とする。**

**サブエージェントへの検証ルール追記（必須）:**

各サブエージェント（code-quality-reviewer / security-code-reviewer / test-coverage-reviewer / codex-reviewer / lessons-reviewer 等）へのプロンプト末尾に **必ず** 以下を含めること:

```
---
**検証ルール**: `.claude/skills/review-verification/SKILL.md` の cross-file 検証チェックリストに従うこと。
特に UI 挙動・認可・バリデーション・コールバック・委譲に関する指摘は、呼び出しチェーン全体を
grep/Read で追跡してから返すこと。未検証の指摘には `[未検証]` プレフィックスを付けること。
---
```

**codex-reviewer への渡し方（必須）:**

codex-reviewer は `git diff {base}...HEAD` を使うと HEAD のチェックアウト状態に依存して
間違ったブランチの差分を取得する。以下の情報を全てプロンプトに含めること:

| パラメータ | 値 | 説明 |
|---|---|---|
| `baseBranch` | Step 2 で解決したベースブランチ名 | 例: `main`, `feature/GTSS-44-foundation` |
| `toBranch` | 引数で指定された変更ブランチ名 | 例: `feature/GTSS-44-v1` |
| `repoDir` | 対象リポジトリの元ディレクトリパス | 例: `/Users/aki/cancel/cancel-billing-service-lp` |
| `diffFile` | Step 5 で保存した差分ファイル | `/tmp/review-diff-{短縮名}.txt` |
| `logFile` | Step 5 で保存したコミットログファイル | `/tmp/review-log-{短縮名}.txt` |
| Issue情報 | Step 1 で取得したIssue本文テキスト or 取得コマンド | |

### Step 6.5: サブエージェント出力の精査（保存前に必須）

全サブエージェントの出力が揃ったら、**結果保存前に** メインエージェントが以下を実施する:

- UI 挙動・cross-file 整合性の指摘は、メインエージェントが自分で描画階層 / 呼び出しチェーンを読んで再検証する
- 「A と B で挙動が違う」類は **両ファイルを同時に Read して対比** する
- 再検証で裏取りできない指摘はレビュー結果に含めず破棄する
- `[未検証]` プレフィックス付き指摘は必ず再検証してから判断する（裏取りできたらプレフィックスを外して含める、できなければ破棄）
- codex-reviewer の出力が PR diff に存在しないファイル・無関係なブランチ名・別 Issue 文脈を含む場合は、**別セッション混入** と見なして破棄する。必要なら fresh session で codex-reviewer だけ再実行する
- codex-reviewer が「実行中のまま戻った」「結果なしで終了した」場合、codex 自体は成功していることが多い（サブエージェントはバックグラウンド完了通知で再起動されないため、待機ミスで結果が孤児化する）。**codex を再実行する前に** `/tmp/codex-review-output-{短縮名}.txt` を確認し、`grep -n "^codex" FILE | tail -1` の行以降を最終レスポンスとして回収して精査に進む

### Step 7: レビュー結果の保存

全サブエージェントの完了後、レビュー結果を `.claude/docs/review-result-YYYY-MM-DD.md` に保存する（同日に複数回実行する場合は連番を付与: `-1`, `-2`, ...）。

**ファイルフォーマット:**

````markdown
---
issue: {ISSUE_NUMBER}
date: YYYY-MM-DD
repos:
  - repo: {短縮名}
    repoDir: {ディレクトリ名}
    baseBranch: {baseBranch}
    toBranch: {toBranch}
---

# レビュー結果: #{ISSUE_NUMBER}

## 概要

**Issue:** #{ISSUE_NUMBER} {Issueタイトル}

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| {短縮名} | `{baseBranch}` | `{toBranch}` | {N} | {N} |

## 変更ファイル一覧

### {短縮名}

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `path/to/file.ts` | +{N} | -{N} | Modified |

## 指摘一覧

- [x] 対応する

### [カテゴリ] 指摘タイトル

**ファイル:** `{短縮名}/path/to/file.ts:line`
**重要度:** High / Medium / Low

**該当コード:**
```typescript
// baseBranch側（変更前）— 該当箇所の前後5行を含む
function example() {
  const old = doSomething();  // ← この行が変更対象
  return old;
}
```

```typescript
// toBranch側（変更後）— 該当箇所の前後5行を含む
function example() {
  const updated = doSomethingNew();  // ← 変更後
  return updated;
}
```

**問題:** 何が問題か
**修正提案:** どう直すべきか

---

（次の指摘...）

## 総評

全体的な品質・テストカバレッジ・セキュリティについてのサマリーコメント。
````

## 出力ルール

- サブエージェントの出力をレビューした上で、自分も注目すべきと判断した指摘のみ記載する
- すべての指摘の先頭に `- [x] 対応する` チェックボックスを含める（デフォルトチェック済み）
- 各指摘は**ファイルパス・行番号・該当コードの前後5行**を明記し、差分を見なくても指摘内容が完全に理解できるようにする
- 変更前（baseBranch側）と変更後（toBranch側）の両方のコードを掲載する
- カテゴリ: `[Code Quality]`, `[Performance]`, `[Test Coverage]`, `[Security]`, `[Lessons]`, `[Codex]`
- 重要度: `High`（バグ・セキュリティ問題）, `Medium`（改善推奨）, `Low`（スタイル・好み）
- 注目すべき指摘がない場合は、簡潔な承認メッセージのみ記載する
- 保存したファイルパスをユーザーに報告する

---
