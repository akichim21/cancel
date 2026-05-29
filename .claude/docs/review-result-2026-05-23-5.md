---
issue: 14
date: 2026-05-23
repos:
  - repo: infra
    repoDir: ~/infra/cancel-billing-service-infra
    baseBranch: main
    toBranch: feature/GTSS-14
---

# レビュー結果: #14

## 概要

**Issue:** #14 [Infra] dev 環境を dev アカウントへ移設 + 現行構成の Terraform import

AWS Lambda + API Gateway(REST) + IAM 実行ロールを Terraform `import` で IaC 化し、(1) 現行 dev 資源(prod アカウント同居)の import、(2) dev アカウント(818059182115) への再構築雛形、(3) **prod 資源の import を追加**（共有 IAM ロールの所有環境として）した PR。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| infra (`cancel-billing-service-infra`) | `main` | `feature/GTSS-14` | 2 | 17 |

> **検証範囲の注記**: `terraform validate` は 3 環境すべて Success を確認済み。ただし**実 AWS refresh を伴う `terraform plan` (no-changes 担保) はこの環境では未実行**（認証/state なし）。import パリティ系の指摘（#7）は apply 前に実 AWS で `plan` 再確認が必須。

## 変更ファイル一覧

### infra

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `.gitignore` | +2 | -1 | Modified |
| `README.md` | +115 | 0 | Added |
| `modules/api-compute/main.tf` | +252 | 0 | Added |
| `modules/api-compute/variables.tf` | +139 | 0 | Added |
| `modules/api-compute/outputs.tf` | +26 | 0 | Added |
| `dev-legacy/{main,providers,variables}.tf` + lock | +186 | 0 | Added |
| `dev/{main,providers,variables}.tf` + lock | +140 | 0 | Added |
| `prod/{main,providers,variables}.tf` + lock | +229 | 0 | Added |

## 指摘一覧

- [x] 対応する

### [Code Quality] `import { for_each }` を使うのに `required_version = ">= 1.5.0"` のまま

**ファイル:** `infra/prod/providers.tf:2`（同様に `dev/providers.tf:2`, `dev-legacy/providers.tf:2`, `modules/api-compute/main.tf:2`）
**重要度:** Medium

**該当コード（変更後 / 新規ファイル）:**
```hcl
# prod/main.tf:130-140 — import ブロックで for_each を使用
import {
  for_each = toset(local.proxy_methods)   # ← config-driven import の for_each
  to       = module.api_compute.aws_api_gateway_method.proxy[each.key]
  id       = "${local.api_id}/${local.proxy_res_id}/${each.key}"
}
```
```hcl
# prod/providers.tf:2 / dev/ / dev-legacy/ / modules すべて
terraform {
  required_version = ">= 1.5.0"   # ← for_each import は 1.7+ が必要
```

**問題:** `import` ブロック自体は Terraform 1.5+ だが、`import` ブロック内の `for_each`（インポートの動的展開）は **Terraform 1.7 で追加**。`>= 1.5.0` のままだと 1.5/1.6 のオペレータが prod を import できない。手元 1.14.x では validate が通るため顕在化しないが、宣言と実機能要件が乖離。
**修正提案:** 4 ファイルの `required_version` を `>= 1.7.0`（または `>= 1.7.0, < 2.0.0`）へ。

---

### [Code Quality] 共通モジュールに dev-legacy 専用の `moved` ブロックが混入（しかもデッドコード）

**ファイル:** `infra/modules/api-compute/main.tf:234-252`
**重要度:** Medium

**該当コード（変更後 / 新規ファイル）:**
```hcl
# modules/api-compute/main.tf:234-252 — 全環境が参照する共通モジュール内
moved {
  from = aws_api_gateway_method.root_any        # ← 現行 config に存在しない旧形状
  to   = aws_api_gateway_method.root["ANY"]
}
moved {
  from = aws_api_gateway_integration.proxy      # ← 無index（旧 single resource）
  to   = aws_api_gateway_integration.proxy["ANY"]
}
# 他 2 ブロック
```

**問題:** コメント自身が「dev-legacy が既に import 済みの state を移行する」一回限り処理と認める。これが**全環境共通モジュール**にあるため prod/dev でも毎回評価される（prod は `from` が state に無く no-op で実害なし）。さらに **現 `dev-legacy/terraform.tfstate` を grep した結果 `root_any`/`proxy_any` の旧形状は存在せず**、dev-legacy でも既に no-op = 完全なデッドコード。再利用モジュールが特定コンシューマの歴史を恒久的に背負う点が保守性を損なう。
**修正提案:** 4 ブロックを削除する（state 確認済みで安全）。将来別環境の移行で必要になった場合はコンシューマ環境側(`*/main.tf`)に書く。

---

### [Code Quality] `create_deployment=true`（新規 dev）でも stage が `deployment_id` を無条件 ignore

**ファイル:** `infra/modules/api-compute/main.tf:218-227`
**重要度:** Low

**該当コード（変更後 / 新規ファイル）:**
```hcl
# modules/api-compute/main.tf:218-227
resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  stage_name    = var.stage_name
  deployment_id = var.create_deployment ? aws_api_gateway_deployment.this[0].id : var.existing_deployment_id
  lifecycle {
    ignore_changes = [deployment_id]   # ← create_deployment=true でも常に ignore
  }
}
```

**問題:** import パリティ用 `create_deployment=false` では `ignore_changes=[deployment_id]` は正しいが、新規構築する dev (`create_deployment=true`) では、method/integration 変更で deployment が triggers 経由で再作成されても stage が新 deployment を指さず、`triggers`/`create_before_destroy` の再デプロイ機構が事実上 dead になる。実害は限定的（dev は雛形で apply 後 deploy-api.sh が実デプロイ管理）。
**修正提案:** `create_deployment` で stage を分岐（managed deployment 側は `deployment_id` を ignore しない）。または雛形である旨をコメント明記。

---

### [Security] 新規 dev ロールに `AmazonSESFullAccess` / `AmazonDynamoDBFullAccess`（過剰権限・新規導入）

**ファイル:** `infra/modules/api-compute/variables.tf:58-66`（+ `dev/main.tf` は `manage_role` 既定 true）
**重要度:** Low

**該当コード（変更後 / 新規ファイル）:**
```hcl
# modules/api-compute/variables.tf:58-66
variable "managed_policy_arns" {
  default = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    "arn:aws:iam::aws:policy/AmazonSESFullAccess",        # ← FullAccess
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess",   # ← dynamodb:* / 全リソース
  ]
}
```

**問題:** prod/dev-legacy は既存ロールの import パリティ（既存付与の踏襲）なので新規バグではない。一方 `dev/`（`manage_role=true`）は dev アカウントに**新規ロールを作成**し、この FullAccess をそのまま付与 = 新規導入の過剰権限。加えて #13 で DynamoDB → Aurora 移行後は `AmazonDynamoDBFullAccess` が完全に不要になる。
**修正提案:** 新規 dev は最小権限の customer managed/inline policy に絞る。暫定踏襲なら `dev/main.tf` に「移設初期のみ・follow-up で縮小」コメントと、README「未対応」セクションへ権限縮小項目を追加。

---

### [Code Quality] 新規 dev Lambda が module default `nodejs18.x` で作られる（README は dev=nodejs24.x）

**ファイル:** `infra/dev/main.tf:18-37`（`runtime` 未指定）/ `modules/api-compute/variables.tf:34-38`（default `nodejs18.x`）
**重要度:** Low

**該当コード（変更後 / 新規ファイル）:**
```hcl
# dev/main.tf — runtime を渡していない → module default nodejs18.x が適用
module "api_compute" {
  source            = "../modules/api-compute"
  function_name     = "cancel-billing-service-dev"
  create_deployment = true
  # runtime 指定なし
}
```
```
README.md:45 → | ランタイム | nodejs24.x (dev) | nodejs18.x (prod) |
```

**問題:** dev は `runtime` を明示しないため module default の `nodejs18.x`（deprecated）でブートストラップされ README(dev=24.x)と矛盾。`runtime` は `ignore_changes` 対象なので Terraform 起点では以後是正されない（deploy-api.sh 任せ）。
**修正提案:** `dev/main.tf` の module 呼び出しに `runtime = "nodejs24.x"` を明示。

---

### [Code Quality] `docs/tech/deployment.md` が存在しないパスを参照 + prod 環境が未記載

**ファイル:** `cancel/docs/tech/deployment.md:72-73, 82`
**重要度:** Low

**該当コード:**
```
# deployment.md:72-73, 82
environments/dev-legacy/  現行 dev 資源を import する環境
environments/dev/         dev アカウントへの再構築 雛形
...
cd ~/infra/cancel-billing-service-infra/environments/dev-legacy   # ← 存在しないパス
```

**問題:** 実体はトップレベル `dev-legacy/` / `dev/` / `prod/`（`environments/` プレフィックスなし）。ドキュメント通りに `cd` すると失敗する。さらに今回追加された `prod/` 環境がドキュメントに未記載。README はトップレベル構成で正しく整合しているため、deployment.md のみ乖離。
**修正提案:** `environments/` プレフィックスを除去し、`prod/`（現行 prod の import 環境）を追記。

---

### [Consistency] apply 前に実 AWS との一致を要確認（import パリティ）

**ファイル:** `infra/dev-legacy/main.tf`（`restrict_permission_source_arn` 既定 true）/ `prod/main.tf:46`（`api_description = null`）
**重要度:** Low（確認事項）

**問題:** dev-legacy は `restrict_permission_source_arn` 未指定でデフォルト `true`（`source_arn = execution_arn/*/*`）。import で no-changes になるには現行 AWS の dev Lambda permission が実際に `*/*` の source_arn を持つことが前提。prod の `api_description=null` も現行 prod の description が本当に空であることが前提。いずれも live AWS 未確認のため断定不可。permission の source_arn や description は import 差分が出やすい箇所。
**修正提案:** apply 前に各環境で `terraform plan` を実行し no-changes を重点確認（特に dev-legacy permission / prod description）。

## 総評

全体として**高品質**。共有 IAM ロールの所有を prod のみに限定し dev-legacy を `data` 参照にする設計（`manage_role` フラグ）、`allowed_account_ids` による誤アカウント apply 防止、`ignore_changes` での deploy-api.sh との責務分界、tfstate/tfvars の gitignore（**state ファイルは未トラッキングを確認・シークレット混入0件**）など、import IaC 化の勘所を押さえている。`prod/` 追加は Issue #14 のスコープ外だが、共有 IAM ロールの所有環境として正当な判断。

最優先は **#1（version constraint と for_each import の乖離）** と **#2（共通モジュールのデッドな `moved` 削除）**。次点で **#4（新規 dev ロールへ伝播する FullAccess）**。残りは plan で検出可能な確認事項または軽微なドキュメント整合。実 AWS での `terraform plan` no-changes 担保（AC-1.1）はレビュア/オペレータの追検証が必須。

- lessons-reviewer: 該当 lesson 違反なし・シークレット混入なし
- code-reviewer / codex-reviewer: 上記指摘に集約（`moved` no-op の妥当性・IAM 所有分離・アカウント分離は再検証のうえ指摘なしと確定）
