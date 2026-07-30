---
name: cross-repo-reference
description: git commit メッセージ・PR 本文/タイトル・GitHub コメント（PR/Issue）を書く時に必ず参照する。親リポジトリ akichim21/cancel の Issue を外部からメンション／リンクしないための規則。
---

# クロスリポジトリ参照の禁止

git commit メッセージ・PR・GitHub コメントを作成する際は、親リポジトリ
`akichim21/cancel` を外部から参照しないこと。

## 背景

- Issue はすべて親リポジトリ `akichim21/cancel` に集約している（CLAUDE.md「Issue 登録先」）。
- 一方、コードの commit / PR はサブリポジトリ（`GO-TODAY-SHAiRE-SALON/cancel-billing-service-*`）側で行う。
- サブリポジトリの commit / PR / コメントに `akichim21/cancel#N` のような **クロスリポジトリ参照** を書くと、private な親リポへの逆リンク（メンション通知・バックリンク）が発生してしまう。
- これを避けるため、git / GitHub の成果物には親リポを書かない。

## 禁止事項（MUST NOT）

| 場面 | 禁止すること |
|------|------|
| git commit メッセージ | `akichim21/cancel` を追加しない（URL・`akichim21/cancel#N` 形式・リポジトリ名いずれも） |
| PR 本文・タイトル | `akichim21/cancel` の Issue をメンション／リンクしない |
| PR コメント / Issue コメント | `akichim21/cancel` の Issue をメンション／リンクしない |

具体的に書かないもの:

- `owner/repo#N` 形式の参照（例: `akichim21/cancel#22`）
- `akichim21/cancel` の Issue / PR への URL（`https://github.com/akichim21/cancel/issues/...` 等）
- `Closes` / `Fixes` / `Refs` などで親リポ Issue を閉じる・参照する記述

## 正しい書き方

- チケットキーのプレフィックスのみで参照する（例: `GTSS-817`）。
- 同一サブリポジトリ内の番号参照（`#N`）は、その番号が **そのサブリポジトリの** Issue/PR を指す場合のみ使う。親リポの番号を `#N` として書かない。
- どうしても文脈を残したい場合は、リンクにならない素のチケットキー（`GTSS-817`）に留める。

```
# OK（サブリポジトリの commit）
feat: 顧客一覧にステータスフィルタを追加（GTSS-817）

# NG
feat: 顧客一覧にステータスフィルタを追加（akichim21/cancel#22）
feat: 顧客一覧にステータスフィルタを追加

Refs: https://github.com/akichim21/cancel/issues/22
```

## 関連

- PR 本文のクロスリポジトリ参照禁止は [pr-create/rules.md](../pr-create/rules.md) にも記載。
- Issue 集約先のルールは CLAUDE.md「Issue 登録先」を参照。
