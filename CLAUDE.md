# Cancel Billing Service - Claude Code Guide

## CRITICAL RULES (MUST ALWAYS FOLLOW)

**IMPORTANT: cancel-billing-service-api (Express/Lambda), cancel-billing-service (React), cancel-billing-service-admin (React), cancel-billing-service-lp (React) のロジックを修正する際は、必ず以下を実行すること:**
1. 該当アプリのテスト (jest / vitest 等) を追加または修正する
2. 追加/修正したテストを実行してすべてgreenになることを確認する
3. テストが「ローカル制約で未実行」は禁止。修正/追加したなら環境をセットアップしてgreenを確認すること

**YOU MUST NOT: コードを変更してテストを書かずに終了すること**

テスト構成:
- `cancel-billing-service-api`: **Vitest** (`npm test` / `test:unit` / `test:e2e`)。Hono の `app.request()` でインプロセス E2E。詳細は `docs/tech/api-testing.md`
- `cancel-billing-service` / `cancel-billing-service-admin`: **Vitest**（`npm test` = typecheck + `vitest run`）＋ **Playwright**（`npm run test:e2e`、`e2e/*.spec.ts`）
- `cancel-billing-service-lp`: **Vitest**（`npm test`。`src/__tests__/*.test.jsx`）。Playwright は未整備

## Issue 登録先

- Issue はすべて親リポジトリ `akichim21/cancel`（`~/cancel`）の GitHub Issue に集約する
- サブリポジトリ (`GO-TODAY-SHAiRE-SALON/cancel-billing-service-*`) には Issue を登録しない。横断的な機能（複数アプリにまたがるもの）も `akichim21/cancel` にまとめる
- `gh issue` / `gh search` 系コマンドは、作業ディレクトリ（worktree 含む）に関わらず `--repo akichim21/cancel` を明示すること

## Verification Before Done（完了前に必ず検証する）

- 動作を証明できるまで、タスクを完了とマークしない
- 必要に応じて自分の変更の差分を確認する
- 「スタッフエンジニアはこれを承認するか？」と自問する
- テストを実行し、ログを確認し、正しく動作することを示す
- デプロイ前は **dev 環境** (`./deploy.sh dev` 等) で動作確認すること

## Issue作業ログ

GitHub Issueベースの実装作業時は、GitHub Issueコメントとして作業ログを記録すること:
- `[Analysis]`: 実装開始前に方針・変更ファイル・懸念を投稿（必須）
- `[Decision]`/`[Discovery]`: 実装中の重要な判断・発見を投稿（任意）
- `[CodeReview]`: 実装完了後にコード解説を投稿（必須）
- `[Completion]`: 実装完了時にサマリー・テストカバレッジ・レビュー注目点を投稿（必須）
- `[Modification]`: 追加修正時に変更理由・内容・影響範囲を投稿（追加修正時は必須）

詳細フォーマット: `.claude/skills/issue-start/SKILL.md` を参照

## プロジェクト概要

サロン (美容室等) 向けキャンセル請求代行サービス。顧客がドタキャンした際の請求・回収業務をサロンの代わりに代行する。Stripe Connect で集金、サロンへ payout する。

| サブリポジトリ | 技術スタック | 用途 | URL (prod) |
|---|---|---|---|
| cancel-billing-service-api | Express + AWS Lambda (Node.js) | バックエンドAPI | https://api.cancel.co.jp |
| cancel-billing-service | React 19 + TS + Vite | サロン向けユーザーポータル | https://user.cancel.co.jp |
| cancel-billing-service-admin | React 19 + TS + Vite | 運営管理者向けダッシュボード | https://admin.cancel.co.jp |
| cancel-billing-service-lp | React 18 + JSX + Vite | LP・申請フォーム | https://cancel.co.jp |

### ドメイン用語

- 「サロン」= サービス利用者（美容室・サロン事業者）
- 「申請」= サロンが利用申し込みするフロー。LP のフォームから登録 → 審査 → Stripe Connect オンボーディング → 利用開始
- 「キャンセル請求」= 顧客のドタキャン分をサロンに代わって請求する。`cancellations` テーブルで管理
- 「申請ステータス」: DB/API は英語 enum、表示は日本語ラベル
  `pending`(GTSS審査中) → `approved`(Stripe登録待ち) → `onboarding`(オンボーディング待ち) → `active`(利用中) / `rejected`(却下済み)
  - 定数定義・正規化: `cancel-billing-service-api/src/constants/application-enums.ts`（`src/config` / `src/lambda` から再 export）
  - 事業区分も英語 enum: `corporate`(法人) / `individual`(個人)
  - API レスポンスは `status` + `statusLabel`（`entityType` + `entityTypeLabel`）を返す

### 主要外部サービス

- **Stripe Connect**: サロン向け決済アカウント。`STRIPE_SECRET_KEY` 必須（`sk_test_`/`sk_live_`）
- **DynamoDB**: `cancel-billing-applications-{env}` / `cancel-billing-users-{env}` / `cancel-billing-cancellations-{env}`
- **SES** (ap-northeast-1): メール送信
- **Twilio**: SMS 通知

## AWS 環境

- AWS プロファイル: **dev=`cancel-billing-service-dev`（818059182115）/ prod=`cancel-billing-service-prod`（145887419870）**
  （GTSS-13 で dev 資源を dev アカウントへ移設。デプロイ/マイグレーションは dev プロファイルを使う。
  ただし DynamoDB→Aurora 移行の DynamoDB scan のみ、旧テーブルが prod アカウント同居のため prod プロファイル）
- リージョン: `ap-northeast-1`
- Lambda関数名: `cancel-billing-service-dev` / `cancel-billing-service-prod`

dev は GTSS-13 で **dev アカウント(818059182115)** へ移設（S3 を `*-dev-818059182115` に改名、CloudFront は
dev アカウントで新規。ID は `terraform output dev_frontend_cloudfront_ids` を deploy*.sh / 各 CLAUDE.md へ記入）。
prod は従来どおり prod アカウント。infra は `cancel-billing-service-infra/dev`（`modules/static-site`）が管理。

| サブリポジトリ | dev S3（dev アカウント） | prod S3 | dev CloudFront | prod CloudFront |
|---|---|---|---|---|
| cancel-billing-service-lp | `cancel-billing-lp-dev-818059182115` | `cancel-billing-lp-prod-app` | terraform output（dev acct） | `E3AU8H3BJJK35A` |
| cancel-billing-service (user portal) | `cancel-billing-user-web-dev-818059182115` | `cancel-billing-user-portal-prod-app` | terraform output（dev acct） | `EKU0PRCYVJUIZ` |
| cancel-billing-service-admin | `cancel-billing-admin-dev-818059182115` | `cancel-billing-admin-prod-app` | terraform output（dev acct） | `EZ2JYIS8UOYRB` |

> 移設前の prod アカウント同居資源（参考・撤去対象 REQ-3）: dev S3 `*-dev-145887419870` /
> dev CloudFront lp=`E1OUC1XEZOT7LN` user=`E71P95BIB50NW` admin=`E15K6M6VG5BSZ8`。

## デプロイ

各サブリポジトリの `deploy*.sh` を使う。**`prod` は確認プロンプトが出るため一度立ち止まる。**

```bash
# API (Lambda + batch) — 統合デプロイ。migrate → API → batch を一括実行（実行漏れ防止）
cd cancel-billing-service-api && ./deploy.sh dev       # / prod
#   個別: ./deploy-api.sh dev（API のみ）/ ./deploy-batch.sh dev（batch のみ）。単独実行時は migrate:<env> を自分で流す

# サロンポータル
cd cancel-billing-service && ./deploy.sh dev           # / prod

# 管理画面
cd cancel-billing-service-admin && ./deploy-admin.sh dev  # / prod （※スクリプト名が異なる）

# LP
cd cancel-billing-service-lp && ./deploy.sh dev        # / prod
```

`.claude/settings.json` で `./*.sh prod*` 系は `deny` にしている。本番デプロイは人間が手元で実行する想定。

## 環境変数の置き場所

| アプリ | dev | prod | ローカル |
|---|---|---|---|
| api | `.env.development` | `.env.production` | `.env` または `.env.development` |
| user portal | `.env.development` | `.env.production` | `.env.local`（gitignore） |
| admin | `.env.development` | `.env.production` | `.env.local`（gitignore） |
| lp | `.env.development` | `.env.production` | `.env.development` 流用 |

**注意**:
- `STRIPE_SECRET_KEY` には公開鍵 (`pk_`) を絶対に入れない
- `cancel-billing-service-admin` の API URL 変数は `VITE_API_BASE_URL`（`VITE_API_URL` ではない）
- `cancel-billing-service-lp` の API URL 変数は `VITE_API_URL`

## 個人情報（PII）の取り扱い

顧客・サロンスタッフの氏名/カナ/電話/メール、外部連携（サロンボード等）のログインID・パスワード・店舗ID/店舗名は個人情報・機微情報として扱う。**表示・DB保存・HTML保存の3場面で必ず以下を守ること。**

- **表示（admin / user portal / API レスポンス）**
  - 外部連携のパスワードは**平文・暗号 blob を絶対に画面・レスポンスへ出さない**。有無のみ（`hasPassword: boolean`）を返す（実装例: `salonboard-auth.service.ts` の `getSalonboardIntegration`）。
  - 顧客 PII は権限のある運営（`requireAdmin`）にのみ表示する。サロン本人向けレスポンスは連携有無・件数など最小限に絞る。
  - **非本番環境（local/dev/test）では取り込み経路で顧客 PII（氏名・カナ・メール・電話）をマスク／ダミー置換**する（`docs/product/application-flow.md` のマスク方針。会社単位・店舗単位どちらの取り込みでも同じマスクを効かせる）。
- **DB保存（Aurora）**
  - 外部連携の認証情報（パスワード）は **AES-256-GCM envelope で暗号化**して保存する（`utils/crypto.ts` の `encryptSecret`）。平文では保存しない。
  - 申込の論理削除時は顧客 PII をマスクする（#GTSS-19 / `application-flow.md`）。
- **HTML保存（テスト fixture）**
  - サロンボード等の**実 HTML を fixture 化する際は、コミット前に個人情報を必ず別値へ置換**する。対象: 顧客 氏名/カナ/電話/メール、**サロンスタッフ名**、ログイン/管理者ID（`CDxxxxx`）、店舗ID（`Hxxxxxx`）、店舗名、KMAGIC / login-key 等のトークン、第三者キー（Sentry DSN 等）。置換後に元値が残っていないことを grep で検証する。
  - 実ログイン情報は **gitignore 済みの `.login.json`（会社単位）/ `.login-store.json`（店舗単位）** にのみ置く（`userId` / `password` の JSON）。コミット・ログ出力・コメント投稿に実値を含めない。
  - fixture 置換例: ログインID `CD00000`、店舗ID `H000999001`、店舗名 `テストサロン …`、スタッフ名 `テスト担当`。

## ドキュメント参照ルール

- `docs/product/`: 製品仕様（全アプリ横断）
- `docs/tech/`: 技術パターン・実装規約
- `docs/cancel-billing-service-*/`: 各サブリポジトリ固有のドキュメント
- 複雑な機能の場合は、必ず `docs/` 配下の該当ドキュメントを読むこと
- 各サブリポジトリの `CLAUDE.md` には「よく使うコマンド」「環境固有のメモ」のみを書く（詳細は `docs/` に集約）

## テスト、受け入れ条件について

- 基本全て自動テストを実施する。ただし、実装が難しいと判断したら、理由とともに人間がテストするで問題ない
- エッジケースなどのパターンが多いものは可能な限り unit テスト
- API は `Vitest` を使用（Hono `app.request()` インプロセス E2E）。フロントエンドも Vitest（user portal / admin / lp）＋ Playwright（user portal / admin）が導入済み
- テスト実行終了時には process やログファイルが可能な限り残らないようにする

## CORS

| 環境 | 許可ドメイン |
|---|---|
| dev | `https://dev.cancel.co.jp`, `https://dev.user.cancel.co.jp`, `https://dev.admin.cancel.co.jp`, `http://localhost:5173` |
| prod | `https://cancel.co.jp`, `https://user.cancel.co.jp`, `https://admin.cancel.co.jp` |

設定: `cancel-billing-service-api/src/lambda.js` の `getCorsHeaders` / 環境変数 `CORS_ORIGIN`

## トラブルシューティング

**Lambda が API Gateway から呼び出せない (500)**
```bash
aws lambda add-permission \
  --function-name cancel-billing-service-dev \
  --statement-id apigateway-invoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --profile cancel-billing-service-dev   # dev は dev アカウント。prod は cancel-billing-service-prod
```

**デプロイで「API Gateway が見つかりません」**
```bash
aws sts get-caller-identity --profile cancel-billing-service-prod
```

## リファレンス

- 各サブリポジトリの `CLAUDE.md`: コマンド・環境メモ
- `docs/product/`: 製品仕様
- `docs/tech/`: 技術ドキュメント
- `docs/cancel-billing-service-*/`: 各アプリ固有ドキュメント
- `.claude/skills/`: スキル（issue / vitest / qa-patterns 等）
- `AGENTS.md`: 他AI（Gemini / Codex 等）向けリファレンス（shaire の同名ファイルへのシンボリックリンク。cancel 固有内容を追記する場合は別ファイルへ）
