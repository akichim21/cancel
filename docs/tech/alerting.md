# Slack 通知（アラート）（GTSS-817-qa）

バッチ処理の失敗を**運営へプッシュする**ための Slack 通知の規約。CloudWatch は人が見に行かないと気づけず、
Sentry は例外が起きた場合しか届かない（サロンボード取り込みのログイン失敗は例外を投げない）。その隙間を埋める。

- 関連: `docs/tech/salonboard-import.md`（取り込みの失敗理由と診断情報）/ `docs/tech/sentry.md`（Sentry 送信規約）/
  `docs/tech/ci-cd.md`・`docs/tech/secrets-management.md`（秘密の配布経路）/ `docs/tech/batch-fargate.md`（ECS 経路）
- 実装: `cancel-billing-service-api/src/observability/slack.ts`
- 実装 Issue: akichim21/cancel #61（GTSS-817-qa）

## 1. 実装方針

**依存追加なし**（`fetch` 直叩き）。`@slack/web-api` を入れると esbuild バンドル（API Lambda / batch Lambda /
batch ECS で共通）が太るため、必要な 1 エンドポイントだけを自前で叩く。`postSlackMessage()` は
**throw しない契約**で、結果を `{ sent, via, reason }` で返す。呼び出し元（バッチ）の成否には一切影響させない。

## 2. 送信経路の解決（優先順）

`resolveSlackTransport(env)`（純関数）が次の優先順で決める。

| 条件 | 経路 | 送信先 |
|---|---|---|
| `SLACK_BOT_TOKEN` **と** `SLACK_ALERT_CHANNEL` が両方ある | `bot` | Slack Web API `chat.postMessage` |
| 上記が無く `SLACK_WEBHOOK_URL` がある | `webhook` | Incoming Webhook |
| どちらも無い | `none` | **何もしない**（情報ログを 1 行残すだけ） |

- Bot Token 方式は token と channel の**両方**が要る（片方だけでは `chat.postMessage` が必ず失敗するため
  Webhook へフォールバックする）。
- チャンネルは**リネーム耐性のため ID 指定**（`C…`）。
- 未設定を理由にバッチを失敗させない。デプロイもデプロイ前ガードも通る。

## 3. 送信抑止と失敗時の扱い

- **`NODE_ENV=test` は設定値の有無にかかわらず実送信しない**（CI から実チャンネルを汚染しないため）。
  テストは `postSlackMessage(text, { env, fetchImpl })` の注入シームで分岐を検証する。
- **投稿失敗は throw しない**。ネットワーク断・HTTP エラー・`chat.postMessage` の
  `ok:false`（`channel_not_found` / `not_in_channel` / `invalid_auth` 等）はすべて `console.error` のみ残す。
  Slack Web API は**失敗も HTTP 200 + `{ok:false}` で返す**ため、HTTP ステータスだけでなく本文まで確認している。

## 4. サロンボード取り込みの通知（現時点で唯一の利用者）

`runSalonboardImport` の末尾で `notifyImportFailure` が呼ぶ。

- **通知条件**: 失敗店舗が **1 件以上**、または実行全体が致命的失敗。**成功のみの実行では投稿しない**。
- **回数**: 取り込み 1 実行につき **最大 1 通**（会社ごとに 1 ブロック）。日次取り込みが継続失敗しても 1 日 1 通。
- **本文**（`buildImportFailureSlackText`。純関数・単体テスト対象）:
  - 環境（`SENTRY_ENVIRONMENT` → `NODE_ENV`）・実行契機（手動 / 日次）・実行時刻
  - 会社名（申請 ID）・連携単位（会社単位 / 店舗単位）※失敗のあった会社のみ
  - 対象店舗数・作成 / 対象外 / 失敗の件数
  - 失敗理由の内訳（日本語ラベル + 件数。例「ログイン遮断疑い 14 件」）
  - 代表的な診断情報 1 件（着地 URL・ページタイトル・doLogin 応答の有無/ステータス・ログイン画面か・
    認証エラー文言・遮断シグナル）
  - 確認先（CloudWatch ロググループ名 / 管理画面の取り込み実行履歴）
- **秘匿情報**: 顧客 PII（氏名・カナ・電話・メール）とサロンボードのログイン ID / パスワードは**含めない**。
  診断は採取側でマスク済み。会社名は屋号（`business_name`）を優先し、無ければ取引先名（`partner_name`）へ
  フォールバックする（個人事業主は取引先名が氏名を兼ねるため、屋号がある会社では氏名を出さない順序）。
  **店舗名と会社名は運営向けの識別情報として含めてよい。**

## 5. 環境変数

| 変数 | 秘密 | 用途 | 未設定時 |
|---|---|---|---|
| `SLACK_BOT_TOKEN` | ○ | Slack App の Bot Token（`xoxb-…` / 要 `chat:write`） | Webhook へフォールバック |
| `SLACK_ALERT_CHANNEL` | × | 通知先チャンネル **ID** | Webhook へフォールバック |
| `SLACK_WEBHOOK_URL` | ○ | Incoming Webhook URL | 通知 no-op |

### 実行経路ごとの配布

| 経路 | スクリプト | 配布方法 |
|---|---|---|
| API Lambda | `deploy-api.sh` | 3 変数とも Lambda の全置換 `environment` へ |
| batch Lambda | `deploy-batch.sh` | 3 変数とも Lambda の全置換 `environment` へ |
| batch ECS(Fargate) | `deploy-batch-ecs.sh` | **`SLACK_ALERT_CHANNEL` のみ** task definition の `environment` へ |

> **ECS だけ扱いが異なる理由**: `deploy-batch-ecs.sh` は GTSS-860 のレビュー指摘［Security］で
> 「実秘密を task definition の `environment`（平文）に入れない」方針を採っており、`ecs:DescribeTaskDefinition`
> 権限だけで平文が読めてしまうのを避けている。`SLACK_BOT_TOKEN` / `SLACK_WEBHOOK_URL` は
> `STRIPE_SECRET_KEY` / `DECODO_PASSWORD` と同じく **ECS `secrets`（`valueFrom`=SSM Parameter Store）**
> 経由で注入する。register 前の自己検証がこの 2 変数の `environment` 混入を実際に弾く。

> **⚠️ Lambda の env 全置換**: `deploy-api.sh` / `deploy-batch.sh` は
> `update-function-configuration --environment` で環境変数セットを**全置換**する。生成 JSON に含めないと
> 毎デプロイで消える（`SENTRY_DSN` と同じ罠）。コンソールでの手動設定は次回デプロイで消えるため禁止。

### 未対応（インフラリポジトリ側の別作業）

CI/CD（CodeBuild）経由でデプロイする場合、以下が必要。**未実施の間は Slack 通知が no-op になるだけで
デプロイもバッチも通常どおり完走する**（`buildspec.yml` / `buildspec-batch.yml` にコメントで明記済み）。

1. `SLACK_BOT_TOKEN`（または `SLACK_WEBHOOK_URL`）を SSM パラメータへ登録する。
2. Terraform の CodeBuild プロジェクト定義（`dev/codebuild.tf` / `prod/codebuild.tf` の `ci_api`）へ
   `type=PARAMETER_STORE` の環境変数として追加する。`SLACK_ALERT_CHANNEL` は非秘密なので平文で可。
3. ECS 経路を使う場合は `modules/batch-fargate` の `container_secrets` へ `SLACK_BOT_TOKEN` /
   `SLACK_WEBHOOK_URL` を追加する。

## 6. Slack 側の準備手順

どちらか一方でよい（両方設定した場合は Bot Token が優先される）。

### A. Bot Token 方式（推奨）

1. Slack App を用意する（既存 shaire ワークスペースの App を流用するか、cancel 専用 App を作る）。
2. OAuth スコープに **`chat:write`** を付与し、ワークスペースへインストールして Bot Token（`xoxb-…`）を取得する。
3. 通知先チャンネルへ **bot を招待する**（`/invite @<app名>`）。招待しないと `not_in_channel` で失敗する。
4. チャンネル ID を取得して `SLACK_ALERT_CHANNEL` に設定する（チャンネル名ではなく ID）。

### B. Incoming Webhook 方式

1. Slack App の Incoming Webhooks を有効化し、通知先チャンネルを選んで Webhook URL を発行する。
2. `SLACK_WEBHOOK_URL` に設定する（URL 自体が秘密なので SSM / env で扱い、コミットしない）。

## 7. 動作確認（dev）

1. 上記いずれかを設定して dev へデプロイする。
2. admin から手動取り込みを 1 回実行する（失敗が出る会社を対象にする）。
3. 通知先チャンネルへ 1 通届くこと、本文に会社名・連携単位・失敗理由の内訳・診断が載ることを確認する。
4. 環境変数を**未設定のまま**デプロイしても、デプロイが成功し取り込みが完走することを確認する
   （情報ログ `[slack] 通知先が未設定のため送信をスキップしました` が 1 行出るだけ）。
