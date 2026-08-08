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

### dev の配線状況（適用済み）

**dev は shaire ワークスペースの Bot Token を流用**して配線済み（インフラリポジトリ
`~/infra/cancel-billing-service-infra` の `GTSS-817-qa`）。

| 項目 | 値 |
|---|---|
| SSM パラメータ | `/cancel/api/slack_bot_token`（SecureString・実値は CLI 直 push で state 非搭載） |
| 通知先チャンネル | `C08NVDWCS5T`（`var.slack_alert_channel`。shaire の二重データ検知アラート ch を暫定流用） |
| Slack workspace | `GO TODAY SHAiRE SALON`（`TGCRC9VDY`。`var.slack_team_id` と同一） |
| bot | `shaire`（`U08R3QQ1M2M`。shaire-server の `SlackNotifier` と同じトークン） |

配線の内訳:
- `dev/codebuild.tf` の `ci_api_secret_keys` へ `slack_bot_token` を追加 → `ci_api` の `ssm_env_vars` に
  `SLACK_BOT_TOKEN` が自動で入り、`deploy-api.sh` / `deploy-batch.sh` が Lambda の全置換 environment へ投入する
- `var.slack_alert_channel` を `ci_api` / `ci_batch_image` の `plain_env_vars` へ `SLACK_ALERT_CHANNEL` として供給
- `batch_fargate.container_secrets` へ `SLACK_BOT_TOKEN` を追加（タスク実行ロールの `ssm:GetParameters` 許可）
- `ci_batch_image.plain_env_vars` へ `BATCH_CONTAINER_SECRETS` を追加 → `deploy-batch-ecs.sh` が
  task definition の `secrets` へ載せる（後述）

#### ECS task definition の `secrets` は deploy スクリプトが所有する

`aws_ecs_task_definition` は `lifecycle { ignore_changes = [container_definitions] }` を持つ。これは
「TF apply のたびに task definition が `:bootstrap` イメージ + 最小 env へ巻き戻るのを防ぐ」ための
所有分割（TF = 骨組み / deploy スクリプト = イメージタグと環境変数）だが、**`ignore_changes` は更新時のみ
効き、新規作成時は効かない**。そのため `container_secrets` へ後から追加しても、**既に存在する family の
リビジョンには永久に反映されない**。

実例（dev 実測）: GTSS-886 で追加した `TWILIO_AUTH_TOKEN` は新規 family の `reminders` にだけ入り、
既存の `import` / `payouts` には入っていなかった。`SLACK_BOT_TOKEN` も同じ理由で落ちる。

そこで `deploy-batch-ecs.sh` が `environment` と同様に `secrets` も所有する（GTSS-817-qa）。

- 供給源は CI が注入する `BATCH_CONTAINER_SECRETS`（`NAME=SSM の ARN` のカンマ区切り）
- Terraform 側で `container_secrets`（= IAM 許可）と**同じ `local` から生成**するため、スクリプトの
  一覧と実行ロールの許可がズレない（ズレると `ResourceInitializationError` で起動失敗する）
- 既存（`describe`）との**和集合**にし、同名はスクリプト定義を優先する。TF や手動で足された参照を
  落として起動時 env が欠ける事故を避ける
- **未設定なら既存 `secrets` を温存**（従来挙動。prod / 手元実行の後方互換）
- `valueFrom` が ARN でなければ parse 時と register 前ガードの二重で拒否する（実値を渡した場合に
  task definition へ平文で焼き込まないため）

> **秘匿性**: `secrets[].valueFrom` に入るのは **SSM の ARN（参照）であって値ではない**。実値は起動時に
> ECS agent が SSM から取得し、task definition にも CodeBuild ログにも載らない。「実秘密を
> `environment`（平文）へ入れない」という GTSS-860 の不変条件は維持される。

> **通知先が shaire の業務チャンネル**である点に注意。cancel の取り込み失敗が混ざるため、運用感を見て
> 専用チャンネルへ分ける可能性がある。変える場合は `var.slack_alert_channel` を差し替えて再 apply し、
> **新チャンネルへ bot を招待する**（未招待だと `chat.postMessage` が `not_in_channel` で失敗する）。
> この bot は `chat:write` のみで `channels:read` を持たないため、参加確認は Slack API から取れない。

### 未対応（インフラリポジトリ側の別作業）

- **Webhook 方式は未使用**。`SLACK_WEBHOOK_URL` を使う場合も SSM + `ssm_env_vars` へ同様に追加する。

未実施の間は Slack 通知が no-op になるだけでデプロイもバッチも通常どおり完走する
（`buildspec.yml` / `buildspec-batch.yml` にコメントで明記済み）。

### prod の配線状況（コードは投入済み・**apply は未実施**）

`prod/codebuild.tf` / `prod/main.tf` を dev と同一構成にしてある（インフラリポジトリ `GTSS-817-qa`）。
**apply と SSM 実値投入は本番のため人手**で行う。

plan（`-target` なしの完全 plan でも同一。無関係 drift 無し）:

```
Plan: 1 to add, 4 to change, 0 to destroy
  aws_ssm_parameter.api_secret["slack_bot_token"]                create
  module.batch_fargate.aws_iam_role_policy.task_exec_secrets[0]  update in-place
  module.ci_api.aws_codebuild_project.this                       update in-place
  module.ci_api.aws_iam_role_policy.codebuild                    update in-place
  module.ci_batch_image.aws_codebuild_project.this               update in-place
```

task definition の再 register も destroy も発生しない。

**実施順序（重要）**

1. `cd prod && terraform apply` — SSM プレースホルダ作成 + CodeBuild env 更新
2. `aws ssm put-parameter --overwrite --name /cancel/api/slack_bot_token --type SecureString --value <Bot Token>`
   （**apply より先に put すると `aws_ssm_parameter` の作成が `ParameterAlreadyExists` で落ちる**）
3. 次の prod デプロイで反映される。ECS 側は `deploy-batch-ecs.sh` が `secrets` を載せるので
   **task definition の `-replace` は不要**

> プレースホルダのまま先にデプロイしても ECS / Lambda は起動する（SSM パラメータは存在するため
> `GetParameters` は成功する）。値が `PLACEHOLDER_...` なので `chat.postMessage` が `invalid_auth` で
> 失敗し、**通知だけが届かない**（バッチ本体は正常に完走する）。

**apply 前に決めること**: 通知先 default は dev と同じ `C08NVDWCS5T`（shaire の業務チャンネル）。
prod の取り込み失敗をそこへ混ぜてよいか判断し、分けるなら `var.slack_alert_channel` を差し替えて
**そのチャンネルへ bot を招待**する。

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
