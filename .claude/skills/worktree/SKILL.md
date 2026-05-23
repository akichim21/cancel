---
name: worktree
description: Git Worktree ベースの開発ワークフロー。Issue作業時のworktree作成・配置・ポート管理・ディレクトリ解決ルールを定義。
---

# Git Worktree ベース開発ワークフロー

Issue 単位の worktree を安全に管理するガイド集。

## 関連スキル

| スキル | 内容 |
|--------|------|
| [worktree-cleanup](../worktree-cleanup/SKILL.md) | Issue 用 worktree を安全に削除する時 |

## 概要

Issue作業時、変更対象のリポジトリにgit worktreeを作成し、元ディレクトリを汚さず独立した作業環境で開発を行う。
**複数Issueの並列作業に対応**しており、Issue毎にmanifestファイルとworktreeディレクトリが独立する。

## 対象リポジトリとベースブランチ

| リポジトリ | ベースブランチ |
|-----------|-------------|
| cancel-billing-service-api | main |
| cancel-billing-service | main |
| cancel-billing-service-admin | main |
| cancel-billing-service-lp | main |

**対象外**: cancel（親リポジトリ）はworktreeを使用しない。

## Worktree配置ルール

- **パス**: `{repo}/.worktrees/{WORKTREE_DIR}/`
  - `{WORKTREE_DIR}` はブランチ名のスラッシュをハイフンに置換した値
  - 例: ブランチ `feature/GTSS-729` -> `.worktrees/feature-GTSS-729/`
- **ブランチ名**: `issue-start` の引数で指定されたブランチ名をそのまま使用
- 複数Issueが同一リポジトリにworktreeを持てる

## Manifest管理（並列Issue対応）

manifestはIssue毎に個別ファイルとして `.claude/worktree-manifests/` に格納する。

- **パス**: `.claude/worktree-manifests/GTSS-{N}.json`
- **1 Issue = 1 manifestファイル**

### manifestスキーマ

```json
{
  "issueNumber": 729,
  "branchName": "feature/GTSS-729",
  "worktreeDir": "feature-GTSS-729",
  "slot": 3,
  "ports": {
    "api": 1341,
    "admin": 3003,
    "userPortal": 5173,
    "lp": 5273
  },
  "repos": { ... }
}
```

## ディレクトリ解決ルール

**作業中のIssue番号**に対応する `.claude/worktree-manifests/GTSS-{N}.json` を参照し:

1. manifest内の該当リポジトリの `hasWorktree` が `true` -> `worktreePath` を使用
2. `hasWorktree` が `false` -> 元ディレクトリ（`/Users/aki/cancel/{repo}/`）を使用
3. manifestが存在しない -> 全て元ディレクトリを使用

**重要**: 必ず作業中のIssue番号に対応するmanifestを参照すること。別Issueのmanifestを参照してはならない。

## 作業ルール

- **全てのコード編集・テスト実行・gitコミットはworktreeディレクトリ内で行う**
- ファイルパスを参照する際は、manifestで解決したworktreeパスを使用する
- テスト実行（npm test 等）もworktreeディレクトリ内で実行する
- git操作（add, commit, status, diff等）もworktreeディレクトリ内で実行する
- **並列作業時は、各セッションが自分のIssue番号に対応するworktreeのみ操作する**

## 禁止事項

- **Claude CodeのEnterWorktreeツールを使用しない**（issue-startコマンドでworktreeを管理するため）
- worktree外の元ディレクトリで変更対象リポジトリのファイルを編集しない
- push/PR作成はClaude側では行わない（人間が手動で実施）
- **別Issueのworktreeディレクトリを操作しない**
- **node_modulesのシンボリックリンクを絶対に作成しない** — 各worktreeで独立したnode_modulesをインストールすること

## ポート管理

並列worktree間でのポート競合を防ぐため、スロットベースのポート割当方式を採用する。

### スロット割当方式

- Issue番号をCRC32（cksum）でハッシュ化し、10で割った余りでスロット番号（0-9）を決定
- 他のmanifestと衝突する場合は線形プローブ（+1ずつ）で空きスロットを探す
- 最大10個のworktreeが並行稼働可能

### ポート計算式

| 用途 | ベースポート | 計算式 | 変数名 |
|------|------------|--------|--------|
| API (cancel-billing-service-api) | 1338 | 1338 + slot | API_PORT |
| 管理画面 (cancel-billing-service-admin) | 3000 | 3000 + slot | ADMIN_PORT |
| ユーザーポータル (cancel-billing-service) | 5173 | 5173 + slot | USER_PORTAL_PORT |
| LP (cancel-billing-service-lp) | 5273 | 5273 + slot | LP_PORT |

### ポート設定ファイルの場所

| リポジトリ | 設定ファイル | 内容 |
|-----------|------------|------|
| cancel-billing-service-api | `.env` | `PORT={API_PORT}` |
| cancel-billing-service-admin | `.env.local` | `VITE_API_BASE_URL` / dev サーバーポート |
| cancel-billing-service | `.env.local` | dev サーバーポートを書き換え |
| cancel-billing-service-lp | `.env.development` | `VITE_API_URL` / dev サーバーポートを書き換え |

## node_modulesインストール手順

各worktreeで独立したnode_modulesが必要。**シンボリックリンクは禁止。**

| リポジトリ | コマンド | 備考 |
|-----------|---------|------|
| cancel-billing-service-api | `npm install` | そのまま動作する |
| cancel-billing-service-admin | `npm install` | そのまま動作する |
| cancel-billing-service | `npm install` | そのまま動作する |
| cancel-billing-service-lp | `npm install` | そのまま動作する |

## Worktreeのライフサイクル

1. **作成**: `issue-start` コマンドのStep 2.5で自動作成
2. **ポート割当**: Step 2.5-4でスロット計算・ポート設定ファイル生成
3. **使用**: 実装中は常にworktreeディレクトリで作業
4. **削除**: `worktree-cleanup {N}` コマンドで該当Issueのworktreeのみ削除
