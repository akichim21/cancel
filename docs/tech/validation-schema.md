# バリデーション共有スキーマ（zod）

> 対象: `cancel-billing-service-api`（Hono / AWS Lambda）。Issue #9 で入力バリデーションを
> 手書き実装（正規表現＋`errors.push`）から **zod スキーマ**へ統一し、未使用の `joi` を依存から
> 除去した。スキーマはフロント（LP / admin / user portal）と契約・型を共有できる配置とする。

## 方針

- API のリクエストバリデーションは **zod スキーマ**で定義する。手書きの正規表現＋`errors.push`
  実装は段階的に zod へ移植する。
- スキーマは `src/schemas/{feature}.schema.ts` に置き、**依存を zod のみに限定**して
  named export する（ルール・メッセージ・型）。これによりフロントが同一スキーマから
  入力検証ルール・型・パース処理を導出でき、API の入出力契約が変わった際に型不整合が
  コンパイル/パース時点で検知される（契約ドリフト防止）。
- バリデーションライブラリは **zod に一本化**する（`joi` は使用しない）。

## 配置

```
cancel-billing-service-api/src/
├── schemas/
│   └── application.schema.ts   # 申請作成入力（zod）。ルール/メッセージ/型を named export
└── services/
    └── application.service.ts  # validateApplicationData が schema を safeParse して利用
```

`application.schema.ts` のエクスポート:

| export | 用途 |
|--------|------|
| `applicationInputSchema` | zod スキーマ本体（`safeParse` で検証） |
| `VALIDATION_MESSAGES` | 日本語エラーメッセージ定数（フロントと文言共有） |
| `PHONE_REGEX` / `EMAIL_REGEX` / `BIRTHDATE_REGEX` | 入力形式の正規表現 |
| `ENTITY_TYPES` | 区分の値域（`['法人', '個人']`） |
| `ApplicationInput` | 入力の論理型（フロント共有用） |

## レスポンス互換（重要）

エラー時のレスポンス形状は**現行クライアント（LP / admin / user portal）が解釈する形を壊さない**。
zod 化はサーバー内部の実装置換であり、リクエスト/レスポンス契約は不変とする。契約を変える場合は
クライアント側の改修が必須となるため、Issue / AC で明示すること。

`validateApplicationData` の契約:

- 戻り値は **日本語エラーメッセージの配列（`string[]`）**。エラーなしは空配列。
- handler（`src/handlers/applications.handler.ts`）が 400 で次の形に整形する（不変）:

```json
{ "success": false, "error": "入力値に誤りがあります", "details": ["電話番号は必須です", ...] }
```

- メッセージ文言・**push 順序**・合否は手書き実装と完全一致させる。複数項目で検証順序が
  クライアント表示に影響するため、移植時は順序まで回帰テストで固定する。

## 実装パターン（順序・文言を保ったまま移植する）

フィールド単位の宣言的 zod 制約（`z.string().regex(...)` 等）は、英語デフォルトメッセージや
型エラーを新たに混入させ、検証順序も宣言順に固定されてしまう。現行実装との**完全互換**を
優先する移植では、フィールド型を緩く受けたうえで `superRefine` に旧 imperative ロジックを
そのまま再現する:

```ts
export const applicationInputSchema = z
  .object({ phone: z.unknown(), /* ... */ })
  .passthrough() // service が入力をそのまま保存するため未知フィールドを落とさない
  .superRefine((data, ctx) => {
    const d = data as Record<string, unknown>;
    const add = (message: string) => ctx.addIssue({ code: 'custom', message });
    if (!d.phone) add(VALIDATION_MESSAGES.phoneRequired);
    else if (!PHONE_REGEX.test(String(d.phone))) add(VALIDATION_MESSAGES.phoneFormat);
    // ... 旧実装の push 順序のまま続ける
  });
```

```ts
export const validateApplicationData = (applicationData) => {
  const result = applicationInputSchema.safeParse(applicationData ?? {});
  return result.success ? [] : result.error.issues.map((i) => i.message);
};
```

- `.passthrough()`: `createApplication` が `...applicationData` で保存するため未知フィールドを保持。
- `safeParse(applicationData ?? {})`: `null` / `undefined` 入力でも throw せず必須エラーを返す。

## テスト方針

- **同値合否**: 手書き実装の全分岐（電話/メール/区分/同意/生年月日/法人・個人必須）を Vitest unit で網羅。
- **順序互換**: 複数エラー時のメッセージ順序が手書き実装と一致することを固定（移植で退行しやすい）。
- **400 互換形状**: `POST /applications` の e2e で `status 400` ＋ `{ success, error, details }` を検証。
- **依存一本化**: `joi` が `package.json` / `package-lock.json` / `node_modules` / `src` から参照0件であること。

詳細なテスト基盤は [api-testing.md](./api-testing.md) を参照。

## 今後

- 共有スキーマのフロント配布方式（モノレポ共有パッケージ / 相対参照 / 生成物配布）と、
  スキーマ変更でフロントのモック型がコンパイルエラーになる型ドリフト検知は後続 Issue で確定する。
- 他エンドポイント（`PUT /applications/:id/status` 等）のリクエストボディ検証も段階的に zod 化する。
