# docs/

Cancel Billing Service の集約ドキュメント。

## ディレクトリ構成

```
docs/
├── product/                          # 製品仕様（全アプリ横断）
├── tech/                             # 技術ドキュメント・実装パターン
├── cancel-billing-service-api/       # APIサーバー固有ドキュメント
├── cancel-billing-service/           # サロン向けポータル固有
├── cancel-billing-service-admin/     # 管理画面固有
└── cancel-billing-service-lp/        # LP・申請フォーム固有
```

## 書き分けルール

- **`product/`**: ビジネス仕様。「何をする/しない」「なぜ」を書く。アプリ実装に依存しない
- **`tech/`**: 全アプリ横断の技術パターン（認証、デプロイ、CORS、Stripe Connect 等）
- **`cancel-billing-service-*/`**: 各サブリポジトリ固有の機能仕様・画面仕様・実装メモ
- 各サブリポジトリの `CLAUDE.md` は「よく使うコマンド」「環境変数」程度に留め、詳細はここに集約する

## 主要ドキュメント

| パス | 内容 |
|---|---|
| `product/overview.md` | サービス全体像 |
| `product/application-flow.md` | サロン申請〜利用開始フロー |
| `product/cancellation-flow.md` | キャンセル請求フロー |
| `tech/architecture.md` | システム全体アーキテクチャ |
| `tech/auth.md` | JWT 認証フロー |
| `tech/deployment.md` | デプロイ手順・AWS リソース一覧 |
| `tech/stripe-connect.md` | Stripe Connect オンボーディング |
| `tech/cors.md` | CORS 設定 |
| `cancel-billing-service-api/README.md` | API エンドポイント・DynamoDB スキーマ |
| `cancel-billing-service/README.md` | サロン向けポータル機能一覧 |
| `cancel-billing-service-admin/README.md` | 管理画面機能一覧 |
| `cancel-billing-service-lp/README.md` | LP・申請フォーム機能一覧 |
