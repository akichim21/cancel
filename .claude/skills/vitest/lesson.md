# テスト Lesson - レビュー指摘パターン集

> このファイルはテスト関連のレビュー指摘や実装中に学んだパターンを記録します。
> テスト実装時に自動で読み込まれ、同じミスの再発を防ぎます。

## パターン一覧

### 重要カラムの数値は網羅的にexpectする（必須）
- **問題**: `expect(result).toBeDefined()` や総額だけの検証では、内訳の計算ミスやフィールド欠落を見逃す
- **正しい対応**: ビジネスロジックに関わる数値・日時・フラグはすべて個別にexpectする。「このカラムは重要か？」と迷ったら検証する
- **対象例**:
  - **キャンセル請求(Cancellation)**: `amount`, `cancellationFee`, `serviceFee`, `discountAmount`, `paymentMethod`, `status`, `chargedAt`, サロンID, 顧客情報
  - **申請(Application)**: `status`, `salonName`, `stripeAccountId`, 申請日時, 審査ステータス遷移
  - **送金(Payout)**: `amount`, `stripeTransferId`, `status`, `arrivalDate`
- **例**:
  ```javascript
  // NG: 弱いアサーション
  expect(result.totalAmount).toBeDefined();

  // OK: 具体値で網羅的に検証
  expect(result).toMatchObject({
    totalAmount: 8800,
    cancellationFee: 7000,
    serviceFee: 1800,
    discountAmount: 0,
    paymentMethod: 'CARD',
    status: 'PAYMENT_SUCCESS',
  });
  // 内訳も個別検証
  expect(result.items[0]).toMatchObject({
    name: '当日キャンセル',
    amount: 7000,
  });
  ```
- **原則**: 「totalだけOK」は不十分。内訳・日時・どの割引/手数料を使ったかまで検証する

### expect.any(Object)/expect.any(Array)/expect.any(Number)は使わない（必須）
- **問題**: `expect.any(Object)`, `expect.any(Array)`, `expect.any(Number)` は型だけチェックし中身を検証しない。ネストされたオブジェクトや配列の中身のバグを見逃す
- **唯一の例外**: `id` 等サーバーがランダム生成するIDのみ `expect.any(String)` を許可
- **正しい対応**:
  - `expect.any(Object)` → `toMatchObject({ key: value, ... })` でネスト内部まで具体値検証
  - `expect.any(Array)` → `toHaveLength(N)` + 各要素を `toMatchObject` で具体値検証
  - `expect.any(Number)` → `.toBe(具体値)` で検証。テストデータから計算可能なはず
  - `toBeDefined()` → 具体値で検証。値がわかるなら `.toBe()` / `.toMatchObject()`
- **例**:
  ```javascript
  // NG: 型だけチェック — 中身が壊れていても通る
  expect(result).toEqual(expect.any(Object));
  expect(result.list).toEqual(expect.any(Array));

  // OK: 具体値で検証
  expect(result).toMatchObject({
    id: expect.any(String),  // ← ランダムIDのみ許可
    status: 'PAYMENT_SUCCESS',
  });
  expect(result.list).toHaveLength(3);
  expect(result.list[0]).toMatchObject({ name: '当日キャンセル', amount: 7000 });
  ```
- **原則**: テストデータを自分で作っているのだから、返り値の具体的な数値・文字列は全て予測可能。`expect.any()` に逃げない

### 外部 API はモックし、正常系で実通信しない
- **問題**: Stripe / DynamoDB / SES / Twilio を実際に呼ぶテストは、ネットワーク依存でフレーキーになり、本番リソースを汚染するリスクがある
- **正しい対応**: 外部クライアントをモックし、呼び出し引数（送金額・送信先・メール本文等）を `expect` で検証する。署名検証など外部依存しないローカルロジックのみ実コードでテストする
- **例**: Stripe Webhook ハンドラのテストでは、`stripe.webhooks.constructEvent` をモックしてイベントペイロードを注入し、その後の DynamoDB 更新内容を検証する

### 申請ステータス遷移は全パスを検証する
- **問題**: 正常系（`GTSS審査中` → `利用中`）だけ通っても、却下や差し戻しのパスでバグが残る
- **正しい対応**: `GTSS審査中` → `Stripe登録待ち` → `オンボーディング待ち` → `利用中`、および各段階からの `却下済み` 遷移をすべてテストする
- **補足**: 定数定義は `cancel-billing-service-api/src/lambda.js` の `APPLICATION_STATUS`

### DynamoDB を使うテストはテスト間でデータをクリアする
- **問題**: 前のテストが書き込んだレコードが残り、後続テストの件数アサーションが不安定になる
- **正しい対応**: `beforeEach` でモック状態または対象テーブルをリセットする。テスト間のデータ汚染を防ぐ

### メール/SMS 通知の本文は定数キーではなく実際のテキストを検証する
- **問題**: 通知レコードやモック呼び出しの本文を定数キー名で比較すると、テンプレート展開後の実テキストと一致せず失敗する
- **正しい対応**: 変数埋め込み済みの実際の表示テキスト（例: `'キャンセル請求のお知らせ'`）で比較する
