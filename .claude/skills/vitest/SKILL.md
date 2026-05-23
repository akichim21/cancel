---
name: vitest
description: cancel-billing-service-api / フロントエンドのテスト作成・修正時に従うポリシー。テスト構成、ファクトリ、アサーションルール、外部API依存の扱いを定義。
globs: "cancel-billing-service-api/src/**/*.test.js, cancel-billing-service-api/jest.config.js"
---

# cancel テストポリシー

## 使用タイミング

- cancel-billing-service-api のテストを新規作成・修正する時
- フロントエンド (cancel-billing-service / -admin / -lp) のテストを新規作成・修正する時
- issue-start 時（テスト方針の確認）

## 過去の教訓

- **MUST**: 実装前に [lesson.md](./lesson.md) を読み、過去の指摘パターンを確認すること

## テスト基盤

- **cancel-billing-service-api**: Jest（`npm test`）。Express ハンドラの統合テストが e2e 相当
- **cancel-billing-service / -admin / -lp**: フロントエンドは Vitest（未整備。追加時に導入）
- API は AWS Lambda 上で動く Express アプリ。外部依存（Stripe / DynamoDB / SES / Twilio）はモックする
- DynamoDB アクセスは `aws-sdk-client-mock` 等でモックするか、ローカル DynamoDB を使う

## ディレクトリ構成（API）

```
cancel-billing-service-api/src/
├── __tests__/        # テストコード
│   ├── helpers/      # 共通ヘルパー (ファクトリ・モック初期化)
│   ├── unit/         # ユニットテスト (高速、外部依存なし)
│   └── integration/  # ハンドラ統合テスト (Express ルートを実際に呼ぶ = e2e 相当)
└── lambda.js         # Lambda エントリポイント
```

## テストの書き方

### ハンドラ統合テストの基本構造（e2e 相当）

```javascript
const request = require('supertest');
const { app } = require('../../lambda');

describe('機能名', () => {
  beforeEach(() => {
    // 外部依存 (Stripe / DynamoDB / SES) のモックをリセット
  });

  it('should ...', async () => {
    const res = await request(app)
      .post('/api/endpoint')
      .send(params);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ ... });
  });
});
```

### 認可が必要なエンドポイントのテスト

運営管理者向けエンドポイントは管理者トークン、サロン向けエンドポイントはサロンユーザーのトークンを発行してテストする。ファクトリで前提となるユーザー・申請・キャンセル請求レコードを作成する。

### 各テストでカバーすべき項目

1. **正常系** (happy path): 期待通りの入力で正しい結果が返る
2. **権限チェック**: 不正なロール/トークンで呼んだ場合 -> 403 等
3. **パラメータバリデーション**: 必須パラメータ欠如 -> 400 等
4. **未認証**: トークンなしで呼んだ場合 -> 401 等

## アサーションルール

### 重要カラムの数値は網羅的にexpectする（最重要）

ビジネスロジックに関わる数値・日時・フラグは**すべて個別にexpect**する。総額だけでなく内訳まで検証すること。

```javascript
// NG: 総額だけ、または存在確認だけ
expect(result.totalAmount).toBeDefined();
expect(result.totalAmount).toBe(8800);

// OK: 内訳・日時・手数料・ステータスまで網羅的に検証
expect(result).toMatchObject({
  totalAmount: 8800,
  cancellationFee: 7000,
  serviceFee: 1800,
  discountAmount: 0,
  paymentMethod: 'CARD',
  status: 'PAYMENT_SUCCESS',
});
// 日時も検証
expect(result.chargedAt).toBe('2026-03-03T10:00:00.000Z');
```

**検証すべきカラムの目安**:

| エンティティ | 必ず検証するカラム |
|------------|-----------------|
| Cancellation（キャンセル請求） | `amount`, `cancellationFee`, `serviceFee`, `status`, `paymentMethod`, `chargedAt`, サロンID, 顧客情報 |
| Application（申請） | `status`, `salonName`, `stripeAccountId`, 申請日時, 審査ステータス遷移 |
| Payout（サロンへの送金） | `amount`, `stripeTransferId`, `status`, `arrivalDate` |

### 使うべきパターン

```javascript
// 具体的なオブジェクト構造を検証
expect(result).toMatchObject({ id: expect.any(String), status: 'ACTIVE' });

// 配列の長さと中身を検証
expect(result.items).toHaveLength(3);
expect(result.items[0]).toMatchObject({ name: '請求A', amount: 7000 });

// HTTP エラーステータスの検証
expect(res.status).toBe(403);
expect(res.body.error).toBe('PERMISSION_DENIED');

// nullかもしれない値
expect(result ?? null).toBeNull();

// 数値の具体値がわかる場合
expect(result.count).toBe(0);
```

### 避けるべきパターン

```javascript
// NG: 弱いアサーション — 存在確認だけでは値のバグを見逃す
expect(result).toBeDefined();
expect(result).toBeTruthy();

// NG: 型だけチェック — 中身が壊れていても通る
expect(result).toEqual(expect.any(Object));
expect(result.list).toEqual(expect.any(Array));
// → toMatchObject({ key: 具体値 }) でネスト内部まで検証すること

// NG: 冗長な型チェック
expect(Array.isArray(result)).toBe(true);
expect(typeof result).toBe('object');

// NG: 総額だけ検証して内訳を検証しない
expect(result.totalAmount).toBe(8800); // ← 内訳も検証すること
```

**`expect.any()` の唯一の許可ケース**: サーバーがランダム生成する `id` のみ `expect.any(String)` を使ってよい。それ以外の値はすべて具体値で検証する。

## 外部API依存のテスト

以下は外部サービスに依存するため、**バリデーション/認可チェックのみテストし、正常系は実 API 呼び出しをモックする**:

| モジュール | 外部依存 | 対処 |
|-----------|---------|------|
| Stripe Connect (決済・送金) | Stripe API | `stripe` クライアントをモック。署名検証等のローカルロジックはテスト可 |
| DynamoDB (申請/ユーザー/キャンセル請求) | AWS DynamoDB | `aws-sdk-client-mock` でモック、またはローカル DynamoDB |
| SES (メール送信) | AWS SES | 送信クライアントをモックし、呼び出し引数を検証 |
| Twilio (SMS 通知) | Twilio API | クライアントをモックし、送信先・本文を検証 |

## 重要な注意事項

- **外部 API はすべてモック**し、本物の Stripe/AWS/Twilio を呼ばないこと
- 申請ステータス遷移（`GTSS審査中` → `Stripe登録待ち` → `オンボーディング待ち` → `利用中` / `却下済み`）は全パスをテストする
- DynamoDB を使うテストは各テスト前にテーブル状態をクリアし、テスト間のデータ汚染を防ぐ
- テストがどうしても通らない場合は `it.skip` + `// TODO:` コメントで理由を記録し、先に進む
- テスト実行終了時に process やログファイルが残らないようにする
