---
name: db-update
description: dev（必要なら prod）の Aurora PostgreSQL を RDS Data API 経由で直接 SELECT/UPDATE する時に使う skill。「DB のこのレコードを直して」「電話番号/メールを書き換えて」等のアドホックなデータ修正・調査時に参照する。env ファイルの中身（特に AURORA_SECRET_ARN）は絶対に開かず、シェルに source して使う。
---

# DB 直接更新スキル（Aurora / RDS Data API）

`cancel-billing-service-api` の永続化は **Aurora PostgreSQL**（旧 DynamoDB ではない）。dev/prod は VPC 外から
**RDS Data API**（`aws rds-data execute-statement`）で叩ける。API/マイグレーションを介さないアドホックな
データ修正・調査の手順とガードを定める。

## 使用タイミング

- dev（主）の特定レコードを直接 SELECT して中身を確認したい / UPDATE で書き換えたい時
- 「この申請の電話番号/メール/ステータスを直して」のようなコード変更を伴わないデータ修正依頼
- prod は原則使わない（使う場合は厳格ガード。後述）

## 最優先ルール（env を見ない）

- **`.env.development` / `.env.production` を Read / cat / grep / echo しない。** 特に `AURORA_SECRET_ARN`
  は秘匿情報。**シェルに `source` して環境変数として使う**（値は画面・ログ・コメントに出さない）。
- 接続は常に `set -a && . ./.env.development && set +a` で読み込み、`aws rds-data execute-statement` に
  `--resource-arn "$AURORA_RESOURCE_ARN" --secret-arn "$AURORA_SECRET_ARN" --database "$AURORA_DATABASE"` を渡す。

## ガイド

| ガイド | 内容 |
|--------|------|
| [dev-aurora.md](./dev-aurora.md) | 接続スニペット・SELECT→UPDATE→検証の手順・安全ルール・テーブル早見・prod ガード |

## 鉄則（要約）

1. **env は source のみ**（中身を出力しない）。プロファイルは dev=`cancel-billing-service-dev` / prod=`cancel-billing-service-prod`。
2. **保存フォーマットを壊さない**: 書き換え前に必ず SELECT で現値を見て、その表記（電話のハイフン有無等）に合わせる。
3. **必ず WHERE で範囲を絞る**。UPDATE/DELETE の前後で SELECT して件数と結果を検証する。
4. **依頼された列だけ**変更する（`updated_at` 等は明示依頼が無ければ触らない）。
5. **PII はマスクして出力**（顧客氏名・電話・メール等を会話・ログにそのまま貼らない）。
6. コード変更を伴わない dev データ修正はテスト追加不要。**prod は人手前提・原則 Claude は実行しない**。
