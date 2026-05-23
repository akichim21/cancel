# 実装設計の書き方

- **ファイル変更一覧**: 変更対象ファイルのパスと変更概要を列挙する。**関連REQ列を含める**。
- cancel のリポジトリ構成に従い、対象リポジトリを明記する。

## テンプレート

```markdown
## 実装設計 (Implementation Design)

### ファイル変更一覧
| リポジトリ | ファイル | 変更概要 | 関連REQ |
|-----------|---------|---------|---------|
| cancel-billing-service-api | `src/cloud/xxx.js` | API ハンドラ/ビジネスロジックの変更 | REQ-1 |
| cancel-billing-service | `src/pages/xxx.tsx` | サロンポータル画面の変更 | REQ-2 |
| cancel-billing-service-admin | `src/pages/xxx.tsx` | 管理画面の変更 | REQ-3 |
| cancel-billing-service-lp | `src/xxx.jsx` | LP・申請フォームの変更 | REQ-4 |
```

- **データモデル変更**: DynamoDB テーブルの属性追加、新規テーブル追加など。
- **API変更**: Express ルート/ハンドラの追加・変更、パラメータ・レスポンス形式など。

## リポジトリ別ファイル構成参考

- **cancel-billing-service-api**: `src/lambda.js` (Express/Lambda エントリ・定数), `src/cloud/` (API ハンドラ), `src/services/` (ビジネスロジック)
- **cancel-billing-service**: `src/pages/` (画面), `src/components/` (共通コンポーネント) — サロン向けユーザーポータル
- **cancel-billing-service-admin**: `src/pages/` (画面), `src/components/` (共通コンポーネント) — 運営管理者ダッシュボード
- **cancel-billing-service-lp**: `src/` (LP・申請フォーム画面/コンポーネント)
