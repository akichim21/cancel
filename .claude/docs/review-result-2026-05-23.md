---
issue: 1
date: 2026-05-23
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: main
    toBranch: feature/GTSS-1
---

# レビュー結果: #1

## 概要

**Issue:** #1 cancel-billing-service-api を Hono へ移行しテスト基盤(Vitest + app.request)を構築する

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `main` | `feature/GTSS-1` | 2 | 23 |

旧 `handleRequest`（`path.split` 手書きルータ）を Hono `app` のルート定義へ置換し、Lambda へは `hono/aws-lambda` の `handle(app)` をエクスポート。jest を完全削除し Vitest（`app.request()` インプロセス E2E）へ移行、外部依存（DynamoDB/Stripe/SES/Twilio）をモック隔離、`@hono/node-server` のローカルサーバを追加。**`npm test` = 10 files / 129 tests すべて green を確認済み。**

> **レビュー運用上の注意（記録）**: 本レビュー実行中、codex-reviewer サブエージェントが誤って別ブランチ `feature/GTSS-6`（TypeScript化 + esbuild）の worktree を検出してレビューし、共有差分ファイル `/tmp/review-diff-api.txt` を GTSS-6 の内容で上書きした。Step 6.5 の混入検知ルールに従い **codex-reviewer の出力全件と、汚染差分に基づく code-reviewer の「TS化スコープ混入」指摘は破棄**した。本レビューの指摘は `git diff main...origin/feature/GTSS-1`（再生成済み・TSマーカー0件）と `src/lambda.js` 実体に基づく。

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/lambda.js` | +211 | -168 | Modified（Hono化・挙動不変） |
| `src/dev-server.js` | +21 | 0 | Added（@hono/node-server） |
| `src/__tests__/unit/pure-logic.test.js` | +272 | 0 | Added |
| `src/__tests__/e2e/applications.test.js` | +247 | 0 | Added |
| `src/__tests__/e2e/cancellations-invoices.test.js` | +203 | 0 | Added |
| `src/__tests__/e2e/auth.test.js` | +199 | 0 | Added |
| `src/__tests__/e2e/branches.test.js` | +192 | 0 | Added |
| `src/__tests__/e2e/stripe-pay.test.js` | +166 | 0 | Added |
| `src/__tests__/e2e/filters.test.js` | +129 | 0 | Added |
| `src/__tests__/e2e/routing.test.js` | +62 | 0 | Added |
| `src/__tests__/e2e/lambda-handler.test.js` | +56 | 0 | Added |
| `src/__tests__/e2e/isolation.test.js` | +40 | 0 | Added |
| `src/__tests__/setup.js` | +48 | 0 | Added |
| `src/__tests__/helpers/auth.js` | +28 | 0 | Added |
| `src/__tests__/helpers/external-mocks.js` | +20 | 0 | Added |
| `vitest.config.js` | +17 | 0 | Added |
| `package.json` | +13 | -6 | Modified |
| `CLAUDE.md` | +21 | -5 | Modified |
| `README.md` | +19 | -5 | Modified |
| `jest.config.js` | 0 | -11 | Deleted |
| `tests/api.test.js` | 0 | -89 | Deleted |
| `tests/setup.js` | 0 | -8 | Deleted |
| `package-lock.json` | — | — | Modified（依存差し替え） |

## 指摘一覧

> 全体として非常に質の高い、挙動を忠実に保った移行。CORS フォールバック・404・500・OPTIONS・認証ガード・raw body 署名検証の整合を保てており、E2E と unit のカバレッジも実用十分（129 tests green）。検証の結果 **High/Medium の確定指摘はなし**。以下は Low の改善提案のみ。

- [x] 対応する

### [Code Quality] レスポンス Content-Type が `application/json` → `text/plain;charset=UTF-8` に変化

**ファイル:** `cancel-billing-service-api/src/lambda.js:3340`（`toResponse` / `corsFromCtx`）、`src/lambda.js:63`（`getCorsHeaders`）
**重要度:** Low

**該当コード:**
```javascript
// baseBranch側（変更前）— API Gateway プロキシ統合では
// Lambda が Content-Type を返さない場合、API Gateway が application/json を補完していた
const getAllApplications = async (corsHeaders) => {
  // ...
  return { statusCode: 200, headers: corsHeaders, body: JSON.stringify(...) };
  // corsHeaders に Content-Type は含まれない → クライアントは application/json を受信
};
```

```javascript
// toBranch側（変更後）— Hono の newResponse は文字列 body に対し
// Fetch Response 既定の text/plain;charset=UTF-8 を付与する
const toResponse = (c, legacy) =>
  c.newResponse(legacy.body == null ? '' : legacy.body, legacy.statusCode, legacy.headers || {});
// getCorsHeaders は Content-Type を設定しないため、JSON ルートのレスポンスは
// Content-Type: text/plain;charset=UTF-8 になる
```

**問題:** 実機検証（インストール済み Hono v4 で `app.request` 実行）で、JSON ルートのレスポンス Content-Type が `text/plain;charset=UTF-8` になることを確認した。旧 Lambda→API Gateway（AWS_PROXY）経路では Content-Type 未設定時に `application/json` が補完されていたため、これは AC-1.1「レスポンス形状を移行前と不変」からの逸脱。実害は小さい（フロント3本は `fetch` + `.json()` で消費しており Content-Type に依存せずパース可能、axios 不使用を確認済み）が、CloudFront 等の content-sniffing/キャッシュや将来の非 fetch コンシューマには影響しうる。HTML を返す `GET /pay/:id`（`src/lambda.js:1371` で `text/html` 明示）は legacy.headers 経由で保持されるため影響なし。
**修正提案:** JSON ルートのレスポンスに `Content-Type: application/json` を補完する。例: `toResponse` で legacy.headers に Content-Type が無ければ `application/json` を既定付与する（HTML 等の明示済みケースは上書きしない）。あわせて `routing.test.js` 等にレスポンス Content-Type のアサーションを 1 件追加すると回帰を防げる（現状テストはリクエスト側 Content-Type のみ検証）。

---

### [Test Coverage] 通知送信回数を弱い不等号（`toBeGreaterThanOrEqual`）で検証している

**ファイル:** `cancel-billing-service-api/src/__tests__/e2e/branches.test.js:148`（同種 `:171`、`src/__tests__/e2e/stripe-pay.test.js:77`）
**重要度:** Low

**該当コード:**
```javascript
// 顧客メール + サロンメール（SES 2通）
expect(sesMock.commandCalls(SendEmailCommand).length).toBeGreaterThanOrEqual(2);
```

**問題:** `.claude/skills/vitest/lesson.md`「重要な数値は網羅的に expect する／弱いアサーションを使わない」に照らした軽微な指摘。`checkout.session.completed` 等の通知本数は決定論的に確定する（顧客＋サロンの 2 通）ため、`>= 2` ではなく確定値で検証すべき。
**修正提案:** `expect(sesMock.commandCalls(SendEmailCommand)).toHaveLength(2);` のように確定値アサーションへ置換。`stripe-pay.test.js:77` / `branches.test.js:171` も同様に該当ケースの正確な本数で検証する。

---

### [Code Quality] テストシーム `__setTestClients` が本番バンドルにもエクスポートされる

**ファイル:** `cancel-billing-service-api/src/lambda.js:418` 付近（`module.exports.__setTestClients`）、`:10`/`:25`（`let stripe` / `let twilioClient`）
**重要度:** Low

**該当コード:**
```javascript
// テスト専用シーム: Stripe / Twilio クライアントを差し替える。
module.exports.__setTestClients = ({ stripe: s, twilioClient: t } = {}) => {
  if (s) stripe = s;
  if (t) twilioClient = t;
};
```

**問題:** 本番経路から `__setTestClients` を呼ぶコードは存在せず（grep 確認済み）、`aws-sdk-client-mock` と同等の許容された注入シームのため lessons-reviewer も「lesson 違反ではない」と判定。実害はない。
**修正提案（任意）:** より防御的にするなら `if (process.env.NODE_ENV !== 'test') return;` ガードを冒頭に入れる、もしくはテストビルド時のみエクスポートする。現状は呼び出し元が無いため対応は任意。

---

### [Test Coverage] Stripe webhook の base64 body 経路が未検証（dev スモーク推奨）

**ファイル:** `cancel-billing-service-api/src/lambda.js:3286`（`app.post('/webhook/stripe')`）、`src/__tests__/e2e/lambda-handler.test.js`（`isBase64Encoded: false` のみ）
**重要度:** Low（情報）

**問題:** webhook ルートは `await c.req.text()` で raw body を取得し `handleStripeWebhook` の署名検証へ渡す。`hono/aws-lambda` は `isBase64Encoded: true` のとき内部でデコードして body 文字列を再構成するため、署名検証に使う raw bytes が API Gateway のエンコード設定によっては旧実装（`event.body` をそのまま `constructEvent`）と一致しない懸念がある。テストは `constructEvent` をモックしているため raw bytes の整合性自体はカバーされていない。
**修正提案:** AC-1.2 の人力スモーク（`deploy-api.sh dev` 後）で、dev に実 Stripe 署名 webhook を一度通して署名検証が成立することを確認する。可能なら `isBase64Encoded: true` の Lambda event での E2E を 1 本追加。

## 総評

旧 `handleRequest` の手書きルータを Hono の薄いアダプタ（旧 `event` 互換オブジェクト生成 → 既存関数呼び出し → Hono Response 変換）へ置換する設計は明快で、ビジネスロジック関数のシグネチャを完全に維持しており挙動不変の原則をよく守っている。実機検証で以下の挙動等価性を確認した:

- **メソッド不一致 → 404**: Hono v4 はパス一致・メソッド不一致時に 405 ではなく **404** を返すため、旧ルータの「未マッチ → 404」と等価（code-reviewer の「405 になる」指摘は実機検証で否定し破棄）。
- **ヘッダー小文字化整合**: `buildEvent` は Fetch Headers API でキーが小文字化されるが、既存関数が `authorization || Authorization`・`stripe-signature || Stripe-Signature` の両参照を持つため整合。
- **ルート specificity 順序**: `/applications/:id/approve` 等（3 セグメント）と `/applications/:id`（2 セグメント）はセグメント数が異なり競合せず、登録順問題なし。
- **404/OPTIONS/500 形状・CORS フォールバック**: `notFound`/`onError`/`app.options('/*')` で旧挙動を再現。

テストは unit（純粋ロジック境界値・等価分割 39 ケース）・E2E（操作＋結果検証）・外部依存隔離まで網羅し、129 件すべて green。確定的な High/Medium 指摘はなく、上記 Low（特に Content-Type の `application/json` 補完）への対応と、AC-1.2/AC-6.1 の dev スモーク（実 AWS デプロイ・ローカル疎通）を本マージ前に消化すれば AC-1.1「挙動不変」を厳密に主張できる。
