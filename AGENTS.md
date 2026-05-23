# AGENTS.md - cancel

このファイルは Gemini / Codex 等の AI エージェントがリポジトリを理解するためのリファレンスです。

## リポジトリ概要

サロン（美容室等）向けキャンセル請求代行サービス。親リポジトリ `~/cancel` 配下に 4 つのサブリポジトリを含む。

| サブリポジトリ | 技術スタック | 用途 | URL (prod) |
|---|---|---|---|
| cancel-billing-service-api | Express + AWS Lambda (Node.js) | バックエンドAPI | https://api.cancel.co.jp |
| cancel-billing-service | React 19 + TS + Vite | サロン向けユーザーポータル | https://user.cancel.co.jp |
| cancel-billing-service-admin | React 19 + TS + Vite | 運営管理者向けダッシュボード | https://admin.cancel.co.jp |
| cancel-billing-service-lp | React 18 + JSX + Vite | LP・申請フォーム | https://cancel.co.jp |

| テスト | フレームワーク |
|---|---|
| API ユニットテスト | jest |
| フロントエンド | 未整備（追加時は vitest 推奨） |
| E2E | 未整備（必要時は Playwright を導入） |

## ディレクトリ構成

```
cancel/
├── cancel-billing-service-api/      # バックエンドAPI
│   ├── src/
│   │   ├── lambda.js                # API ハンドラ（モノリス的に全エンドポイントを含む）
│   │   ├── index.js                 # ローカル開発用エントリーポイント
│   │   ├── simple-lambda.js
│   │   └── dynamodb-setup.js        # テーブル作成スクリプト
│   ├── tests/                       # jest ユニットテスト
│   ├── aws-policies/                # IAM ポリシー定義
│   └── deploy-api.sh                # Lambda デプロイ
├── cancel-billing-service/          # サロン向けユーザーポータル
│   ├── src/
│   │   ├── App.tsx
│   │   ├── components/              # 画面コンポーネント
│   │   ├── contexts/                # AuthContext 等
│   │   ├── services/                # api.ts（API 通信集約）
│   │   └── types/
│   └── deploy.sh                    # S3 + CloudFront デプロイ
├── cancel-billing-service-admin/    # 運営者管理画面
│   ├── src/
│   │   ├── App.tsx
│   │   ├── components/              # 画面コンポーネント
│   │   └── services/                # ApiService.ts
│   └── deploy-admin.sh              # ※スクリプト名が他と異なる
├── cancel-billing-service-lp/       # LP・申請フォーム
│   ├── src/
│   │   ├── App.jsx                  # メイン LP + 申請フォーム
│   │   ├── components/              # Stripe/Payment 関連
│   │   └── pages/                   # 規約・特商法等の静的ページ
│   └── deploy.sh
├── docs/                            # 集約ドキュメント
│   ├── product/                     # 製品仕様（全アプリ横断）
│   ├── tech/                        # 技術ドキュメント
│   ├── cancel-billing-service-api/  # APIサーバー固有
│   ├── cancel-billing-service/      # サロンポータル固有
│   ├── cancel-billing-service-admin/# 管理画面固有
│   └── cancel-billing-service-lp/   # LP固有
└── .claude/                         # Claude Code 設定（skills, agents, hooks 等）
```

## ドメイン用語

- 「サロン」: サービス利用者（美容室・サロン事業者）
- 「申請」: サロンがサービス利用申し込みするフロー（LP → 審査 → Stripe オンボーディング → 利用開始）
- 「キャンセル請求」: 顧客のドタキャン分をサロンに代わって請求する処理
- 「申請ステータス」: `GTSS審査中` → `Stripe登録待ち` → `オンボーディング待ち` → `利用中` / `却下済み`（`cancel-billing-service-api/src/lambda.js` の `APPLICATION_STATUS`）

## 主要外部サービス

| サービス | 用途 | 環境変数 |
|---|---|---|
| Stripe Connect | サロン決済アカウント・キャンセル料の集金/payout | `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` |
| DynamoDB | データストア（ap-northeast-1） | `DYNAMODB_TABLE_NAME` 等 |
| SES | メール送信（ap-northeast-1） | `SMTP_USERNAME`, `SMTP_PASSWORD`（prod） |
| Twilio | SMS 通知 | `TWILIO_*` 系 |

## タスク別リファレンス

### Issue 作成・レビュー

| 参照先 | 用途 |
|---|---|
| `docs/product/` | 製品仕様（申請フロー・キャンセル請求フロー等） |
| `docs/tech/` | 技術パターン（認証・デプロイ・CORS・Stripe Connect） |
| `docs/cancel-billing-service-*/` | 各サブリポジトリ固有のドキュメント |
| `.claude/skills/issue/` | Issue 作成・運用ガイド |
| `.claude/skills/qa-patterns/` | テストケース設計パターン |

### コード分析

| 参照先 | 用途 |
|---|---|
| `cancel-billing-service-api/src/lambda.js` | API ロジックの正本（モノリス） |
| `cancel-billing-service-api/src/dynamodb-setup.js` | DynamoDB スキーマ |
| `cancel-billing-service*/src/components/` | 各アプリの画面 |
| `cancel-billing-service*/src/services/` | API 通信レイヤ |
| `docs/tech/` | 技術パターン・実装規約 |

### コードレビュー

| 参照先 | 用途 |
|---|---|
| `CLAUDE.md` | プロジェクト規約（テスト必須等のクリティカルルール含む） |
| `.claude/skills/coding-standards/` | コーディング規約 |
| `cancel-billing-service-api/tests/` | API テストの網羅性確認 |

### Docs 更新

| 参照先 | 用途 |
|---|---|
| `docs/README.md` | docs 全体の索引・書き分けルール |
| `docs/product/` | 製品仕様 |
| `docs/tech/` | 技術ドキュメント |
| `docs/cancel-billing-service-*/` | 各アプリ固有ドキュメント |
| `.claude/skills/docs/SKILL.md` | ドキュメント記述ガイド |

## AWS 環境

- AWS プロファイル: `cancel-billing-service-prod`（dev/prod 共通アカウント）
- リージョン: `ap-northeast-1`
- dev/prod の分離は **リソース名サフィックス** (`-dev` / `-prod`) で実現している

詳細: `docs/tech/architecture.md` / `docs/tech/deployment.md`

## 重要な規約

- **ロジック変更時は必ずテストを追加する**（`CLAUDE.md` のクリティカルルール参照）
- API テストは `jest`、フロントは `vitest`（未整備、追加歓迎）
- `STRIPE_SECRET_KEY` には公開鍵 (`pk_`) を絶対に入れない
- 環境変数名のブレに注意:
  - 管理画面 API URL: `VITE_API_BASE_URL`
  - LP API URL: `VITE_API_URL`
- 本番デプロイ（`./*.sh prod`）は `.claude/settings.json` で deny。人間が手元で実行する想定
- Issue は各サブリポジトリの GitHub Issue へ登録する（親リポジトリ `cancel` は集約用）
