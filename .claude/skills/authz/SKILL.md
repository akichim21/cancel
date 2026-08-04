---
name: authz
description: API の認可（permission/認証ガード）を実装・レビューする時に参照する。ルートへの requireAdmin/requireAuth 付与、状態遷移ロックの多層防御、レスポンスの機微フィールド露出、マスアサインメントを確認する。エンドポイント追加・改修、serializer 変更、ステータス遷移ロック実装、PRレビュー時に使う。
---

# 認可（Authorization）チェックリスト

API の「誰がこの操作・このデータにアクセスできるか」を、実装時とレビュー時の両方で機械的に確認するためのスキル。

UI で隠す・画面に出さないだけでは API 契約レベルの漏洩/越権は塞げない。**サーバ側の認可ガードと露出制御**を、同一リソースの全ルート・全経路で揃っているか確認する。

## ガイド

| ガイド | 内容 |
|--------|------|
| [checklist.md](./checklist.md) | 実装時・レビュー時のチェック手順（4観点: ルート認可カバレッジ / 状態遷移ロックの多層防御 / レスポンス露出 / マスアサインメント） |
| [lesson.md](./lesson.md) | 過去にこのスキルで防げたはずの実例（GTSS-842 `/approve` バイパス、GTSS-836 serializer 漏洩） |

## 4観点（要約）

1. **ルート認可カバレッジ** — 変更したリソースの破壊的/状態変更/PII 露出ルートに `requireAdmin`/`requireAuth` を明示。同一リソースの sibling ルート（`:id/approve` 等）の付け忘れを必ず確認する。**ただし「欠落 = 即バグ」ではない**：公開が設計意図のエンドポイント（LP/本人が無認可で呼ぶ）もあるので、`requireAdmin` を足す前に呼び出し元を cross-file で追い、バイパス懸念が別ガードで既に塞がれていないか確認する（[checklist.md](./checklist.md) 観点1 の ⚠️）。
2. **状態遷移ロックの多層防御** — 状態を変えうる**全経路**にサーバ側ガードを置く。`/status` にだけガードを入れても `/approve` 等の専用ルートが素通りなら「API直叩きロック」は未達。
3. **レスポンス露出** — spread passthrough な serializer（`{...item}` / `getTableColumns`）に列を足すときは、それを返す全エンドポイントの認可と露出を確認。公開向けは別 serializer / pick で機微列を除外。
4. **マスアサインメント** — `.passthrough()` 入力＋`{...input}` 保存は allow-list（pick）にする。制御列（`applicationId`/`status`/`deletedAt`/`stripe*`/トークン）を body から採用しない。

## このスキルが参照される箇所

- 実装時: `coding-standards`（セキュリティ）/ エンドポイント・serializer・状態遷移を変更する Issue 着手時
- レビュー時: `review-pr` のサブエージェントプロンプト末尾 / `review-verification`（認可の指摘の裏取り手順）
