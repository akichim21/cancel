---
issue: 7
date: 2026-05-23
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: feature/GTSS-6
    toBranch: feature/GTSS-7
---

# レビュー結果: #7

## 概要

**Issue:** #7 cancel-billing-service-api を handler/service/repository に構造化リファクタする

`src/lambda.ts`（約3,500行）に混在していたルーティング・認証・ビジネスロジック・DynamoDB アクセス・外部サービス呼び出し（Stripe/SES/Twilio）を **handler / service / repository / middleware / utils** の各層へ分離した **挙動不変（behavior-invariant）リファクタ**。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `feature/GTSS-6` | `feature/GTSS-7` | 1 | 30 |

**テスト結果:** 既存 E2E 含む全 **138 テスト / 12 ファイル green**（worktree 実機で実行確認、AC-3.1 達成）。

## 変更ファイル一覧

### api

| ファイル | 行数 | 変更種別 |
|---------|------|---------|
| `src/lambda.ts` | 3552 行削減（→ app 構築＋handler 登録に縮小） | Modified |
| `src/config.ts` | +36 | Added |
| `src/clients.ts` | +70 | Added |
| `src/middleware/auth.ts` | +133 | Added |
| `src/handlers/index.ts` | +38 | Added |
| `src/handlers/adapter.ts` | +29 | Added |
| `src/handlers/applications.handler.ts` | +65 | Added |
| `src/handlers/auth.handler.ts` | +44 | Added |
| `src/handlers/cancellations.handler.ts` | +31 | Added |
| `src/handlers/invoices.handler.ts` | +20 | Added |
| `src/handlers/stripe.handler.ts` | +9 | Added |
| `src/handlers/webhook.handler.ts` | +12 | Added |
| `src/services/application.service.ts` | +1202 | Added |
| `src/services/auth.service.ts` | +535 | Added |
| `src/services/invoice.service.ts` | +406 | Added |
| `src/services/webhook.service.ts` | +388 | Added |
| `src/services/notification.service.ts` | +229 | Added |
| `src/services/cancellation.service.ts` | +187 | Added |
| `src/services/stripe.service.ts` | +41 | Added |
| `src/repositories/applications.repository.ts` | +24 | Added |
| `src/repositories/cancellations.repository.ts` | +24 | Added |
| `src/repositories/users.repository.ts` | +23 | Added |
| `src/repositories/table-setup.ts` | 0（`dynamodb-setup.js` から 100% リネーム） | Renamed |
| `src/utils/cors.ts` | +17 | Added |
| `src/utils/crypto.ts` | +29 | Added |
| `src/utils/phone.ts` | +22 | Added |
| `src/__tests__/unit/application-service.test.js` | +72 | Added |
| `src/__tests__/unit/notification-service.test.js` | +72 | Added |
| `vitest.config.js` | +3/-1 | Modified |

## 検証済み・問題なし（挙動同一を確認）

メインエージェント＋3レビューア（code-reviewer / lessons-reviewer / codex-reviewer）が、削除側（旧 `lambda.ts`）と追加側（新 service/handler）の両ブロックを対比して以下を確認した。**重大な挙動差異（High）はなし。**

- **認証ガードの適用範囲**: `middleware/auth.ts` の `requireAuth`/`requireAdmin` が旧 `lambda.ts` と同一テーブル・同一 Key・同一条件（`status !== ACTIVE` で 401、DB 例外で 500）。`/applications` 系の認証有無（`send-stripe-link` のみ `requireAdmin`）も一致。認可ロジックの新規追加・削除なし。
- **テーブル名解決**: `config.ts:23-36` の getter が呼び出し時に `process.env` を評価し、旧の `DYNAMODB_TABLE_NAME` / `NODE_ENV === 'prod'` 分岐と同値。`src/services/` 配下に `docClient`・直書きテーブル名は皆無（AC-2.1 達成）。
- **SES/Twilio 通知**: 請求通知・支払い完了 Webhook・Stripe requirements 通知・申請受付メール・認証情報メール・パスワード再設定メールの全パスで、送信先・件名・本文・SMTP/SES 分岐（`NODE_ENV==='prod' && smtpTransporter`）・Twilio の `messagingServiceSid` 分岐・`/pay/{id}` 短縮 URL を旧と 1:1 で確認（AC-2.2 達成）。
- **Stripe Webhook 署名検証**: `webhook.handler.ts` が `c.req.text()` で raw body を取得 → `event.rawBody` 経由で `constructEvent` に投入。署名検証に必須の raw body 経路が保持。dev スキップ分岐も同一。
- **500 エラー形状**: 各 service の catch 節 body 形状（`success/error/message`）、`notFound`=`{error:'Not Found'}` 404、`onError`=`{error:'Internal Server Error', message}` 500 が旧と一致。
- **モジュールロード副作用**: `clients.ts` の Stripe/Twilio/SES クライアント生成・Twilio 設定 `console.log`・prod 限定 SMTP transporter 構築が旧 `lambda.ts` 冒頭と同一タイミング・同一内容。
- **lessons 照合**: 重点 lesson「通知フロー仕様は実装コードと照合」を全通知パスで検証し違反なし。他 lesson（ステータスフィルタの取りこぼし／外部 API モック検証）も問題なし。

## 指摘一覧

- [x] 対応する

### [Code Quality] `table-setup.ts` が `config`/`clients` の集約を経由していない

**ファイル:** `api/src/repositories/table-setup.ts:11-12, 75-76, 141-142, 197-199`
**重要度:** Low

**該当コード（変更後）:**
```typescript
const createTableIfNotExists = async () => {
  const client = new DynamoDBClient({ region: process.env.AWS_REGION || 'ap-northeast-1' });
  const tableName = process.env.DYNAMODB_TABLE_NAME || 'cancel-billing-applications-dev';
  // ... NODE_ENV 分岐も各関数内で独自に持つ（cancellations/users）
  // 末尾の初期 admin ユーザー投入も独自 docClient を生成（L197-199）
```

**問題:** 本ファイルは `dynamodb-setup.js` からの **similarity 100% リネーム**であり挙動は完全に不変だが、本 Issue の方針「テーブル名解決の集約」「クライアント生成の集約」からは外れて、独自の `process.env.DYNAMODB_TABLE_NAME` / `NODE_ENV` 分岐・独自 `DynamoDBClient` を保持したまま。`config.tableNames` / `clients.ts` を経由していない。
**修正提案:** 挙動には影響しないため本 PR では対応不要。後続 Issue（C/D）で `config.tableNames` 参照・`clients` 共有へ寄せると一貫性が出る。

---

### [Code Quality] `getUserInvoices` のログからテーブル名が消えた

**ファイル:** `api/src/services/invoice.service.ts:30`
**重要度:** Low

**該当コード:**
```typescript
// 変更前（旧 lambda.ts）
console.log('Using cancellations table:', cancellationsTableName);
```
```typescript
// 変更後（invoice.service.ts:30）
console.log('Executing scan on cancellations table');
```

**問題:** ログ出力からテーブル名が消えている。レスポンス契約には影響しない（ログのみ）。
**修正提案:** 意図的なら問題なし。デバッグ時にテーブル名が必要なら `config.tableNames.cancellations` を出力する形で復元してもよい。本 PR では対応不要。

---

### [Security] SMTP 認証情報のハードコードフォールバック（既存問題・本 PR 起因ではない）

**ファイル:** `api/src/clients.ts:56-57`
**重要度:** Low（本 PR では対応不要）

**該当コード:**
```typescript
auth: {
  user: process.env.SMTP_USERNAME || '<ハードコード値>',
  pass: process.env.SMTP_PASSWORD || '<ハードコード値>',
}
```

**問題:** SMTP の `user`/`pass` のフォールバック値がソースに平文で残存。ただし旧 `lambda.ts` から**完全同一で移送**されたもので、本 PR が新規に持ち込んだ問題ではない（挙動不変として正しい移送）。
**修正提案:** 挙動不変方針上この PR では変えるべきではない。**別 Issue を立てて**環境変数必須化（フォールバック削除）＋本番 SMTP 資格情報のローテーションを推奨。

---

### [Test Coverage] 複雑な Stripe Webhook 分岐の unit テストが未整備

**ファイル:** `api/src/services/webhook.service.ts` / `application.service.ts`
**重要度:** Low

**問題:** 新規 unit テスト（`application-service.test.js` / `notification-service.test.js`）は AC-2.1/AC-2.2 をモック注入で適切に検証できている。一方、最も複雑な `processStripeAccountUpdated`（`ConditionalCheckFailedException` の冪等スキップ・失敗時フォールバック更新）と `handleStripeWebhook`（`account.updated` の charges_enabled / requirements 24h 重複防止分岐）の unit テストはない。
**修正提案:** 挙動不変は既存 E2E（138 件 green）で担保されるため本 PR では必須ではない。後続のクエリ改善（C）・バリデーション改善（D）での回帰検出のため、これらの分岐の追加カバレッジを推奨。

---

### [Code Quality] 外部クライアントの lazy 化は未達（後続対応で可）

**ファイル:** `api/src/clients.ts`
**重要度:** Low

**問題:** Issue の技術考慮事項にあった「Stripe/Twilio/SES クライアントのトップレベル生成を初期化に寄せる（lazy 化）」は本 PR では未達。クライアントはモジュールロード時生成のまま。ただし生成タイミング・副作用は旧 `lambda.ts` と同一であり「挙動不変」要件は満たしている。テスト時のモック差し込みは `__setTestClients`（ESM live binding 再代入）で機能しており、E2E green と整合。
**修正提案:** 挙動不変方針上、lazy 化は本 PR スコープ外で問題なし。必要なら後続 Issue で対応。

## 総評

**マージ可。** 挙動不変リファクタとして極めて忠実な実装。旧 `lambda.ts`（約3,500行）の全関数を、ロジック・条件分岐・early return・エラーハンドリング・レスポンス形状を 1:1 で handler/service/repository/middleware/utils へ移送できている。ルーティング（URL/メソッド/登録順/認証ガード適用範囲）、テーブル名解決、SES/Twilio の送信先・トリガー条件、Stripe Webhook の raw body 経路、モジュールロード時副作用のいずれも旧実装と一致を確認。既存 E2E を一切変更せず全 138 テスト green を維持しており、AC-1.1/2.1/2.2/3.1 すべて達成している。

検出された指摘はすべて Low（一貫性・ログ・テストカバレッジ・既存セキュリティ問題の指摘）で、本 PR のマージを妨げるものはない。SMTP 認証情報のハードコードと Stripe Webhook 分岐の追加テストは、別 Issue / 後続 Issue（C/D）での対応を推奨する。
