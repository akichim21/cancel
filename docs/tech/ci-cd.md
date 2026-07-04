# CI/CD（GitHub Actions → CodeBuild 自動デプロイ）

> GTSS-859 で導入。4 サブリポジトリのビルド・デプロイを手元の `deploy*.sh` 手動実行から
> **GitHub Actions（テスト/lint）→ OIDC → AWS CodeBuild（build/deploy）** の自動化へ移行した。
> 秘密情報は SSM Parameter Store（→ `secrets-management.md`）。デプロイ手順の全体像は `deployment.md`。

## 全体像

```
GitHub Actions（push develop/main）
  ├─ test/lint job（フル or 軽量。ブランチで出し分け）
  └─ trigger-codebuild job（test green のときのみ）
       └─ OIDC AssumeRole（最小権限 role：codebuild:StartBuild のみ）
            └─ aws codebuild start-build --source-version <sha>（fire-and-forget）
                 └─ CodeBuild project が buildspec.yml を実行
                      ├─ フロント: npm ci → build:<env> → s3 sync → CloudFront invalidation
                      └─ API:      npm ci → migrate → API/batch Lambda 更新 → APIGW 再デプロイ
  CodeBuild Build State Change → EventBridge → SNS → AWS Chatbot → Slack（成否通知）
```

GitHub Actions 側は **テストしてトリガーするだけ**。build/deploy の正本は CI 対応化した `deploy*.sh`
（`CI=true` で CI モード動作）で、buildspec.yml はそれを呼ぶ薄いラッパ。成否は GitHub Actions では
待たず、Slack 通知で確認する（fire-and-forget）。

## ブランチ → アカウント/環境

| push 先 | GitHub Environment | AWS アカウント | 起動する CodeBuild |
|---|---|---|---|
| `develop` | `dev` | dev（818059182115） | `cancel-<app>-dev` |
| `main` | `prod`（required reviewers 承認） | prod（145887419870） | `cancel-<app>-prod` |

`dev` / `prod` は**別 AWS アカウント**。OIDC provider・deploy role・CodeBuild・SSM・CodeConnections・
Chatbot は各アカウントに 1 式ずつある（Terraform の `dev/` `prod/` ディレクトリ）。

## GitHub Actions ワークフロー（ブランチゲート）

| リポジトリ | 非 develop/main・PR | develop/main への push |
|---|---|---|
| `cancel-billing-service-api` | typecheck + `npm test`（Docker Postgres）フル | 同左 → OIDC→CodeBuild |
| `cancel-billing-service`（user） | lint + Vitest | + Playwright E2E → OIDC→CodeBuild |
| `cancel-billing-service-admin` | lint + Vitest | + Playwright E2E → OIDC→CodeBuild |
| `cancel-billing-service-lp` | lint + Vitest | （Playwright 未導入）→ OIDC→CodeBuild |

- ワークフロー: api=`.github/workflows/deploy.yml`、フロント=`.github/workflows/ci.yml`。
- `trigger-codebuild` job は `push` かつ `github.ref_name == 'develop' || 'main'` に限定（PR の ref は `NN/merge`
  形式なので合致せず起動しない）。`permissions: id-token: write` はこの job のみ。
- 各ワークフローに `concurrency`（`cancel-in-progress: false`）を設定し多重起動・順序逆転を防ぐ。
- Node は `.nvmrc`（api=24 / フロント=22）で固定。`actions/checkout` は `persist-credentials: false`。
- Playwright は `page.route` モック方式（実バックエンド不要）。CI は `npx playwright install --with-deps` のみ。

## OIDC（最小権限）

- **trust**: `token.actions.githubusercontent.com:aud = sts.amazonaws.com` かつ `sub =
  repo:GO-TODAY-SHAiRE-SALON/<repo>:environment:<dev|prod>`（Environment claim 1 パターンに限定）。
  ブランチ制限（dev=develop / prod=main）は **GitHub Environment の deployment branch policy** で担保する
  （IAM の sub では担保しない。Environment 使用時の実 claim 形に合わせる）。
- **許可**: 対象 CodeBuild project の `codebuild:StartBuild` / `codebuild:BatchGetBuilds` のみ（Resource 限定）。

## CodeBuild service role（最小権限）

Terraform `modules/ci-codebuild` が `deploy_type` で出し分ける。

- 共通: Logs（対象ロググループ）/ CodeConnections（Get/Use）/ SSM 読取（該当 param 限定）/ KMS Decrypt
  （`kms:ViaService=ssm.<region>.amazonaws.com` 条件）
- フロント（static）: `s3:ListBucket`（バケット限定）/ `s3:Get,Put,DeleteObject`（`<bucket>/*` 限定）/
  `cloudfront:CreateInvalidation`（対象 distribution 限定）。**バケット作成・公開ポリシーは CI で行わない**
  （Terraform 作成前提。deploy スクリプトは CI モードでこれらをスキップ）。
- API（lambda）: `lambda:UpdateFunctionCode/UpdateFunctionConfiguration/GetFunction`（対象 2 関数限定）/
  `rds-data:*`（個別列挙・対象クラスタ限定）/ `secretsmanager:GetSecretValue`（Aurora secret 限定）/
  `apigateway:GET`（restapis 検索）+ `apigateway:POST`（対象 `/deployments`）/ デプロイ用 S3（限定）。
  連携暗号の `kms:Encrypt/Decrypt` は **Lambda 実行ロール**側（CodeBuild ではない）。

## セットアップ順序（初期構築）

1. **REQ-7 前提整備**: 各リポジトリに `develop` ブランチ / GitHub Environments（`dev`/`prod`）/ branch protection /
   ESLint（admin/lp）/ `.nvmrc`。
2. **Terraform apply（dev/prod 両アカウント）**: `dev/codebuild.tf` `prod/codebuild.tf`（OIDC provider・deploy role・
   CodeBuild+service role・SSM プレースホルダ・CodeConnections・通知・Lambda デプロイ用 S3 バケット）。
   - **初回 apply の注意**: `aws_iam_openid_connect_provider.github` が既にアカウントに存在する場合は
     `terraform import aws_iam_openid_connect_provider.github <arn>` してから apply する（未作成なら不要）。
     Lambda デプロイ用バケットをローカル deploy で手動作成済みのアカウントは `terraform import aws_s3_bucket.lambda_deploy <bucket>`。
3. **SSM 実値投入**: `secrets-management.md` の直 push runbook（未投入だと API が秘密欠落で起動失敗）。
4. **CodeConnections 手動認可**: AWS コンソールで PENDING の接続を 1 回認可（未認可だと source 取得失敗）。
5. **GitHub Environment variables**: `terraform output ci_github_deploy_role_arns` / `ci_codebuild_project_names` を
   各リポジトリの `dev`/`prod` Environment の `AWS_ROLE_ARN` / `CODEBUILD_PROJECT` / `AWS_REGION` へ設定。
6. **dev 先行・アプリ単位で有効化** → 最後に **prod（main）** を有効化。

## 失敗時の運用・ロールバック

- CodeBuild 失敗は Slack 通知で検知し、**修正を push して再実行**する（fire-and-forget の補完）。
- **ロールバックは「直前の正常コミットを push し直す」**を基本手順とする。
- API の migrate は `__drizzle_migrations` で冪等・追加的 DDL・前方互換のため、「migrate 成功／Lambda 更新失敗」でも
  再 push で収束する。フロントの `s3 sync --delete` の途中失敗も再実行で収束する。
- 連続 push は `concurrency`（`cancel-in-progress: false`）で直列化し、`--source-version <sha>` が常に push 時点の
  SHA を指すことで古いビルドの後勝ちを抑える。

## 参照

- 秘密情報（SSM）: `secrets-management.md`
- デプロイ手順・リソース一覧: `deployment.md`
- Terraform: `~/infra/cancel-billing-service-infra`（`modules/ci-codebuild` / `dev/codebuild.tf` / `prod/codebuild.tf`）
- 先行事例: `~/shaire/shaire-lp-nextjs`（workflow/buildspec） / `~/infra/shaire-infra`（OIDC/CodeBuild/SSM/通知）
