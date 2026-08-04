---
issue: 56
date: 2026-08-01
repos:
  - repo: lp
    repoDir: cancel-billing-service-lp
    baseBranch: main
    toBranch: GTSS-884
  - repo: infra
    repoDir: infra/cancel-billing-service-infra
    baseBranch: main
    toBranch: GTSS-884
---

# レビュー結果: #56

## 概要

**Issue:** #56 LP(cancel.co.jp) SSG化とクロール制御強化: ページ別初期HTML（canonical/noindex/og:url）・存在しないURLの404化・dev robots.txt出し分け

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| lp | `main` | `GTSS-884` | 1 | 10 |
| infra | `main` | `GTSS-884` | 1 | 4 |

- lp PR: GO-TODAY-SHAiRE-SALON/cancel-billing-service-lp #14（main 向け）
- infra PR: GO-TODAY-SHAiRE-SALON/cancel-billing-service-infra #10

## 変更ファイル一覧

### lp

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `vite-plugin-seo-prerender.js` | +182 | -0 | Added |
| `src/__tests__/prerender.test.js` | +304 | -0 | Added |
| `src/__tests__/buildIntegration.test.js` | +81 | -0 | Added |
| `src/__tests__/seo.test.jsx` | +90 | -1 | Modified |
| `src/seo.js` | +49 | -4 | Modified |
| `src/__tests__/staticSeoFiles.test.js` | +25 | -6 | Modified |
| `deploy.sh` | +20 | -1 | Modified |
| `index.html` | +4 | -0 | Modified |
| `vite.config.js` | +3 | -0 | Modified |
| `public/robots.txt` | +0 | -4 | Deleted |

### infra

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `prod/static-site-lp.tf` | +170 | -0 | Added |
| `dev/main.tf` | +29 | -0 | Modified |
| `modules/static-site/variables.tf` | +27 | -0 | Modified |
| `modules/static-site/main.tf` | +16 | -6 | Modified |

## メインエージェントによる独立検証（実行済み）

保存前に以下をこちらで実行・確認した。指摘一覧はこの検証を通ったもののみ記載する。

| 検証 | 結果 |
|---|---|
| `npx vitest run`（lp / GTSS-884 worktree） | **17 files / 184 tests 全 green**（11.76s） |
| `npm run build:prod` 実ビルド → dist/ 目視 | index.html + 拡張子なし 10 + 404.html + robots.txt + sitemap.xml。head はページ別に正しく出し分け |
| GTM がプリレンダ後も残るか | **残る**（`grep -c GTM-56D47XBB` = index.html:2 / terms-of-service:2 / verify-email-sent:2）。GTM は `transformIndexHtml` で `<head>` 直後（マーカー領域の外）に入るため領域置換の影響を受けない |
| `deploy.sh` の `node -e` が手元 Node で動くか | **動く**（Node v20.20.0 でも module 構文自動検出で成功。警告は stderr のため `$(...)` を汚さない。CI は .nvmrc=22） |
| 外部から LP へ入ってくる URL が 11 ルートに収まるか | **収まる**。api が生成するのは `/verify-email?token=` / `/stripe-success?applicationId=` / `/stripe-refresh?applicationId=` / `/payment-complete` / `/payment-cancel` のみ（`application.service.ts` / `webhook.service.ts` / `invoice.service.ts` / `cancellation-send.service.ts`）。SMS の `/pay/:id` は `apiBaseUrl()`（api.cancel.co.jp）であり LP ドメインではないため 404 化の影響を受けない |
| LP 内部リンクが 11 ルートに収まるか | **収まる**（`/`・`/#anchor`・`/terms-of-service`・`/privacy-policy`・`/specified-commercial-transaction` のみ。末尾スラッシュ付きリンクなし） |
| `terraform fmt -check -recursive`（infra） | green |
| `custom_error_responses` 既定値の後方互換 | `error_caching_min_ttl` は provider が未指定時 0 を送るため、既定値 0 は user / admin の現行 state と一致（codex が state 実値でも照合済み） |

`buildPageHeadTags` ⇔ `applyPageMeta` の同値性、noindex ルートでの description / canonical / og:url 非出力、マーカーの欠落・重複検出、HTML エスケープには**不整合なし**（codex-reviewer(lp) の重点確認結果とも一致）。

## 指摘一覧

- [x] 対応する

### [Test Coverage] ルート網羅の検証が `PAGE_META` 側にしかなく、App.jsx にエイリアスパスを足すと本番 404 になる

**ファイル:** `lp/src/__tests__/prerender.test.js:247-257`, `lp/vite-plugin-seo-prerender.js:18-34`, `lp/src/App.jsx:408-419`
**重要度:** High

**該当コード:**

```javascript
// main側（変更前）— 未登録パスが増えても CloudFront が 200 でトップを返すため実害がなかった
// （prerender.test.js / PRERENDER_ROUTES 自体が存在しない）
```

```javascript
// GTSS-884側（変更後）— prerender.test.js のマニフェスト網羅ガードは pageKey 集合の比較のみ
247    it('ルートマニフェストの pageKey は resolvePageKey(route) と一致する（JS 分岐との単一性）', () => {
248      for (const { route, pageKey } of PRERENDER_ROUTES) {
249        expect(resolvePageKey(route, '')).toBe(pageKey);
250      }
251    });
252
253    it('PAGE_META の全ページ種別（unknown 以外）がマニフェストで網羅されている', () => {
254      const manifestKeys = new Set(PRERENDER_ROUTES.map((r) => r.pageKey));
255      const pageMetaKeys = Object.keys(PAGE_META).filter((k) => k !== 'unknown');
256      expect([...pageMetaKeys].sort()).toEqual([...manifestKeys].sort());
257    });
```

```javascript
// App.jsx（変更なし）— ここへパスを足しても上の 2 テストは通る
408    const isPaymentSuccess = currentPath === '/payment-success' || ... || currentPath === '/payment-complete' || ...;
```

**問題:**
本 PR で `PRERENDER_ROUTES` は「プリレンダ対象の URL 一覧」であると同時に、**REQ-2 適用後は「200 を返す URL の許可リスト」**になった。未登録パスは CloudFront が HTTP 404 + `/404.html` を返す。

ところが 253-257 行のガードは **pageKey 集合**の比較でしかなく、`/payment-complete → payment-success` と同型の「既存 pageKey を共有するエイリアスパス」を `App.jsx:408-419` に追加しても集合は変わらないため**検知できない**。247-251 行のテストもマニフェストに載っているルートしか回さないので同様。結果、App.jsx に画面を足して `npm test` が全 green でも、そのパスは**本番で 404**になる。

`routing.test.jsx:34-95` には既知 10 パスがリテラルの `it()` として並んでいるが、`PRERENDER_ROUTES` と突き合わせる導線がない。本 PR 以前は未登録パスも CloudFront が 200 でトップを返していたため実害がなく、**この失敗モードは本 PR が新たに作り出したもの**である点が重要。

**修正提案:**
`route`（URL パス）そのものを突き合わせるテストを 1 本足す。`routing.test.jsx` のパスをリテラル配列へ切り出して共有するのが最小変更。

```javascript
// 例: src/__tests__/prerender.test.js
const APP_ROUTES = [
  '/', '/terms-of-service', '/privacy-policy', '/specified-commercial-transaction',
  '/verify-email', '/verify-email-sent', '/stripe-success', '/stripe-refresh',
  '/payment-success', '/payment-complete', '/payment-cancel',
];
it('App.jsx が描画する全パスが PRERENDER_ROUTES に登録されている（未登録＝本番 404）', () => {
  expect(PRERENDER_ROUTES.map((r) => r.route).sort()).toEqual([...APP_ROUTES].sort());
});
```

あわせて `App.jsx:407` 付近へ「パス追加時は `PRERENDER_ROUTES` にも登録すること（未登録は本番で HTTP 404）」のコメントを置く。

---

### [Code Quality] deploy.sh: 生成物の事前検証が S3 更新の「後」にあり、失敗時に配信が壊れた状態で終わる

**ファイル:** `lp/deploy.sh:151-169`
**重要度:** Medium

**該当コード:**

```bash
# main側（変更前）— 単純な sync のみ。失敗しても中間状態が生まれない
log_info "S3へのアップロードを開始します..."
aws s3 sync dist/ "s3://$S3_BUCKET" \
    --delete \
    "${PROFILE_ARGS[@]}" \
    --cache-control "max-age=3600"

# CloudFront キャッシュ削除
if [ -n "$CLOUDFRONT_DISTRIBUTION_ID" ]; then
```

```bash
# GTSS-884側（変更後）— sync --delete のあとにマニフェスト取得・存在確認が来る
151  log_info "S3へのアップロードを開始します..."
152  aws s3 sync dist/ "s3://$S3_BUCKET" \
153      --delete \
154      "${PROFILE_ARGS[@]}" \
155      --cache-control "max-age=3600"
156
157  # 拡張子なしファイルの一覧はプリレンダのルートマニフェスト（単一ソース）から得る。
158  log_info "拡張子なし HTML の Content-Type を上書きしています..."
159  EXTENSIONLESS_HTML_FILES=$(node -e "import('./vite-plugin-seo-prerender.js').then(...)")
160  for f in $EXTENSIONLESS_HTML_FILES; do
161      if [ ! -f "dist/$f" ]; then
162          log_error "プリレンダ生成物 dist/$f が見つかりません（ビルド設定を確認してください）"
163          exit 1
164      fi
165      aws s3 cp "dist/$f" "s3://$S3_BUCKET/$f" \
166          --content-type "text/html; charset=utf-8" \
167          --cache-control "max-age=3600" \
168          "${PROFILE_ARGS[@]}" > /dev/null
169  done
```

**問題:**
`node -e`（159 行目）の失敗、または `dist/$f` 欠落（161-164 行目）で `exit 1` するのは、**すでに `sync --delete` が S3 を置き換えた後**。この時点で拡張子なし 10 オブジェクトは sync が推定した Content-Type（`binary/octet-stream`）のまま公開されており、CloudFront はそれをそのまま返すのでブラウザは HTML を表示せず**ダウンロードを開始する**。対象には利用規約・プライバシーポリシー・特定商取引法表記という掲載義務のあるページが含まれる。加えて `--delete` により旧オブジェクトも消えているため、単純な再実行以外に戻す手段がない。

なお `set -e` と `$(...)` 代入の組み合わせにより `node` 失敗時にスクリプトが止まること自体は正しく効く（Node v20.20.0 で実行確認済み。module 構文自動検出により CJS 判定エラーにはならず、警告は stderr のため変数を汚さない）。問題は**止まる位置**である。次の指摘のとおり、この `node -e` 自体が古い Node で落ちうる経路でもあるため、両者は同時に効く。

**修正提案:**
マニフェスト取得と全ファイルの存在確認を、最初の AWS 操作より前（`aws s3 sync` の直前、ビルド成功確認の直後）へ移す。

```bash
# ビルド成功確認の直後に置く
EXTENSIONLESS_HTML_FILES=$(node -e "...")
for f in $EXTENSIONLESS_HTML_FILES; do
    [ -f "dist/$f" ] || { log_error "プリレンダ生成物 dist/$f が見つかりません"; exit 1; }
done

# ここから S3 操作
aws s3 sync dist/ "s3://$S3_BUCKET" --delete ...
for f in $EXTENSIONLESS_HTML_FILES; do
    aws s3 cp "dist/$f" "s3://$S3_BUCKET/$f" --content-type "text/html; charset=utf-8" ...
done
```

---

### [Lessons] deploy.sh の `node -e` は「素の Node ESM 解決」を通る唯一の経路だが、smoke import テストがない

**ファイル:** `lp/deploy.sh:159`, `lp/package.json`
**重要度:** Medium
**該当 lesson:** `.claude/lessons.md`「import boundary の回帰は smoke import テストで防ぐ」

**該当コード:**

```bash
# main側（変更前）— Node を介する箇所が deploy.sh に存在しなかった
```

```bash
# GTSS-884側（変更後）
159  EXTENSIONLESS_HTML_FILES=$(node -e "import('./vite-plugin-seo-prerender.js').then((m) => console.log(m.PRERENDER_ROUTES.map((r) => r.file).filter((f) => f !== 'index.html').join('\n')))")
```

**問題:**
この 1 行が、`vite-plugin-seo-prerender.js`（→ `src/seo.js`）を **Vite の transform を経ずに素の Node ESM 解決で読む唯一の経路**。新規テスト（`prerender.test.js` / `buildIntegration.test.js`）はいずれも Vitest = Vite 経由の import なので、この経路の破綻を一切検出できない。見逃す回帰は 3 種類:

1. **モジュール判定**: `package.json` に `"type": "module"` がなく `.js` は ambiguous 扱い。現状動くのは Node の module 構文自動検出頼み（**Node 20.19+ / 22.7+ で既定有効**。手元 v20.20.0 で実行して成功を確認済み）。**Node 20.0-20.18 / 22.0-22.6 では `SyntaxError`** になる。CI は `buildspec.yml` の `n "$(cat .nvmrc)"`（.nvmrc=22）で最新 22.x に切り替わるため安全だが、手元 `./deploy.sh` にはバージョン検査がない。
2. **Vite 専用記述の混入**: 今後 `src/seo.js` に `import.meta.env` / 拡張子なし import / CSS・JSX import が入ると、**Vitest は green のままデプロイ時だけ落ちる**。
3. **契約破り**: `PRERENDER_ROUTES` のエクスポート名や `.file` フィールド名を変えても、deploy.sh との齟齬を誰も検出しない。

**修正提案:**
`buildIntegration.test.js` は既に `execFileSync` を持っているので、deploy.sh と**同一の one-liner**を素の `node` で実行して期待 10 ファイル名が返ることを assert するケースを 1 本足す（上記 3 種すべてを一度に塞げる）。

```javascript
it('deploy.sh と同じ node -e が素の Node ESM 解決で 10 ファイル名を返す', () => {
  const out = execFileSync('node', ['-e', /* deploy.sh:159 と同一の式 */], { cwd: ROOT, encoding: 'utf8' });
  expect(out.trim().split('\n')).toEqual(
    PRERENDER_ROUTES.map((r) => r.file).filter((f) => f !== 'index.html')
  );
});
```

恒久対策として `package.json` に `"type": "module"` を足す、プラグインを `.mjs` へ改名する、あるいはプラグインが `dist/prerender-manifest.json` も出力して deploy.sh は `node` を介さず読む、のいずれかも検討に値する。

---

### [Codex] infra: import と 404 設定変更が同一 apply になっており、Issue の T-17 手順（import 確定 → 差分ゼロ確認 → 変更のみ apply）になっていない

**ファイル:** `infra/prod/static-site-lp.tf:15-23`
**重要度:** Medium

**該当コード:**

```hcl
# main側（変更前）— ファイル自体が存在しない（新規追加）
```

```hcl
# GTSS-884側（変更後）
15  #   適用手順（T-17 / 人間が prod プロファイルで実施。main マージによる prod デプロイで
16  #   404.html が S3 に配置された後に行うこと）:
17  #     1. terraform plan -var lp_enable_404_response=false
18  #          → lp の 4 リソースが「imported（変更なし）」= import 定義が実構成と一致することを確認
19  #            （2026-08-01 に read-only plan で差分ゼロを確認済み）
20  #     2. terraform apply -target=aws_s3_bucket.lp -target=aws_s3_bucket_website_configuration.lp \
21  #          -target=aws_s3_bucket_policy.lp -target=aws_cloudfront_distribution.lp
22  #          # 既定 lp_enable_404_response=true。import 4 件 + 403/404→404 /404.html の変更のみ
23  #     3. terraform plan    # lp リソースに差分がないことを確認
```

**問題:**
Terraform の `import` ブロックは **plan ではプレビューされるだけで state には記録されない**（記録は apply 時）。したがって手順 1 は state を一切動かさず、手順 2 の apply で「4 リソースの import」と「CloudFront の 403/404 → 404 変更」が**同時に**実行される。Issue の AC-2.4 / T-17 が求めている「import 直後の plan 差分ゼロ確認 → 403/404→404 変更のみの差分で apply」という段階適用になっておらず、**基準状態を state へ確定したチェックポイントが存在しない**。import 定義が実構成とわずかにずれていた場合、そのずれと意図した変更が 1 回の apply に混ざり、切り分けもロールバックも難しくなる。

また手順 2 は `lp_enable_404_response` の既定値（true）に暗黙依存している。

**修正提案:**
ヘッダコメントの手順を以下へ差し替える（`-target` は既存 drift のため全手順で必須のまま維持）。

```
1. terraform apply -var='lp_enable_404_response=false' \
     -target=aws_s3_bucket.lp -target=aws_s3_bucket_website_configuration.lp \
     -target=aws_s3_bucket_policy.lp -target=aws_cloudfront_distribution.lp
     # import のみを state へ確定する（変更ゼロであることを apply 前の plan で確認）
2. terraform plan -var='lp_enable_404_response=false' -target=...   # 差分ゼロを確認
3. terraform plan -var='lp_enable_404_response=true'  -target=aws_cloudfront_distribution.lp -out=lp404.tfplan
     # 「1 in-place change / destroy なし」を確認してから apply lp404.tfplan
4. terraform plan -var='lp_enable_404_response=true' -target=...   # 適用後の差分ゼロを確認
（ロールバック: 手順 3 を lp_enable_404_response=false で実行）
```

---

### [Codex] infra: prod LP の識別子が新規 local と既存 variable で二重管理されている

**ファイル:** `infra/prod/static-site-lp.tf:39-40`, `infra/prod/codebuild.tf:41-47, 351-352`
**重要度:** Medium

**該当コード:**

```hcl
# main側（変更前）— prod/codebuild.tf。CodeBuild のデプロイ先はこの variable が単一ソースだった
41  variable "lp_bucket_name" {
43    default = "cancel-billing-lp-prod-app"
45  variable "lp_cloudfront_distribution_id" {
47    default = "E3AU8H3BJJK35A"
...
351   bucket_name                = var.lp_bucket_name
352   cloudfront_distribution_id = var.lp_cloudfront_distribution_id
```

```hcl
# GTSS-884側（変更後）— prod/static-site-lp.tf。同じ値をハードコードした local が並立する
39    lp_bucket_name     = "cancel-billing-lp-prod-app"
40    lp_distribution_id = "E3AU8H3BJJK35A" # deploy.sh prod の invalidation 対象と同一
...
144 output "lp_cloudfront_distribution_id" {
145   description = "prod LP の CloudFront ディストリビューション ID（deploy.sh prod / invalidation 用）"
146   value       = aws_cloudfront_distribution.lp.id
147 }
```

**問題:**
Terraform が管理する S3 / CloudFront は新規の `local`（ハードコード）を、CodeBuild のデプロイ先・invalidation 先は既存の `var.lp_bucket_name` / `var.lp_cloudfront_distribution_id` を参照する。現時点では既定値が一致しているだけで、`-var` / tfvars / 将来のリソース移行で片方だけ変更すると、**Terraform が管理する配信先と CodeBuild のデプロイ先が別物になる**（デプロイしたのに反映されない・invalidation が別ディストリビューションに飛ぶ）。

さらに `output "lp_cloudfront_distribution_id"`（144 行目）は既存の `variable "lp_cloudfront_distribution_id"` と同名で、両者が異なる値を持ちうる。人・AI いずれにとっても誤読しやすい。

**修正提案:**
最低限、local を既存 variable から導出して単一ソース化する。

```hcl
locals {
  lp_bucket_name     = var.lp_bucket_name
  lp_distribution_id = var.lp_cloudfront_distribution_id
}
```

より安全にするなら `module.ci_lp` へ `aws_s3_bucket.lp.bucket` / `aws_cloudfront_distribution.lp.id` を直接渡し、variable 側を廃止する。output は `managed_lp_cloudfront_distribution_id` 等へ改名して variable との同名衝突を解消する。

---

### [Code Quality] infra: `lp_enable_404_response` と import ブロックを T-17 完了後も残すと恒久的な事故要因になる

**ファイル:** `infra/prod/static-site-lp.tf:32-36, 42-50, 149-170`
**重要度:** Medium

**該当コード:**

```hcl
# main側（変更前）— ファイル自体が存在しない（新規追加）
```

```hcl
# GTSS-884側（変更後）
32  variable "lp_enable_404_response" {
33    description = "lp CloudFront の 403/404 を 404 /404.html へ切り替える（false=現行の 200 /index.html。import 差分ゼロ確認用）"
34    type        = bool
35    default     = true
36  }
...
42    lp_error_responses = var.lp_enable_404_response ? [
43      { error_code = 403, response_code = 404, response_page_path = "/404.html" },
44      { error_code = 404, response_code = 404, response_page_path = "/404.html" },
45      ] : [
46      { error_code = 403, response_code = 200, response_page_path = "/index.html" },
47      { error_code = 404, response_code = 200, response_page_path = "/index.html" },
48    ]
```

**問題:**
`lp_enable_404_response` は「import 直後の差分ゼロ確認」という**一度きりの用途**のために入っている。T-17 完了後もこれが残ると、`-var lp_enable_404_response=false` を一度渡すだけで **prod が無言で soft-404（403/404 → 200 `/index.html`）へ戻る**。本 Issue が解消した SEO 上の問題がそのまま復活し、しかも terraform 上は「正当な設定値」なのでレビューでも気づきにくい。

`import` ブロック（149-170 行）も同様で、HashiCorp は import 完了後の削除を推奨している。残置すると、state から誤ってリソースが消えた場合に次回 apply が黙って再 import してしまい、差分の意味が読み取りにくくなる。

**修正提案:**
本 PR で削除する必要はない（T-17 の実施に必要なため）。ただし **T-17 完了後に `variable "lp_enable_404_response"` / `locals.lp_error_responses` の分岐 / `import` ブロック 4 件を除去する**フォローアップを Issue #56 のチェックリストへ明記すること。除去後は `custom_error_response` を 403/404 → 404 `/404.html` の固定記述にする。

---

### [Test Coverage] GTM 注入がプリレンダ後も残ることの回帰テストがない（壊れても全テスト green のまま prod へ出る）

**ファイル:** `lp/src/__tests__/buildIntegration.test.js:27-51`
**重要度:** Medium

**該当コード:**

```javascript
// main側（変更前）— ファイル自体が存在しない（新規追加）
```

```javascript
// GTSS-884側（変更後）
27  function expectPrerenderedFiles() {
28    for (const { file } of PRERENDER_ROUTES) {
29      expect(existsSync(join(DIST, file)), file).toBe(true);
30    }
31    expect(existsSync(join(DIST, '404.html'))).toBe(true);
32    expect(existsSync(join(DIST, 'robots.txt'))).toBe(true);
33    expect(existsSync(join(DIST, 'sitemap.xml'))).toBe(true);
34
35    // 公開ページ: ページ別 canonical（prod ドメイン固定）+ アプリ起動スクリプトあり
36    const terms = readFileSync(join(DIST, 'terms-of-service'), 'utf8');
37    expect(terms).toContain('<link rel="canonical" href="https://cancel.co.jp/terms-of-service" />');
38    expect(terms).toContain('<title>利用規約｜キャンセル請求便</title>');
39    expect(terms).toContain('/assets/');
```

**問題:**
本 PR で `dist/index.html` は「Vite の出力」から「プリレンダプラグインが `closeBundle` で書き戻したもの」へ変わり、他 10 ルートもそこから複製されるようになった。GTM が全ページに残るのは、`gtmPlugin` が `transformIndexHtml` で `<head>` 直後（= `<!-- seo:prerender:start -->` 領域の**外**）にスニペットを入れているという**暗黙の位置関係**に依存している。

実ビルドで現状は正しいことを確認済み（`grep -c 'GTM-56D47XBB'` が index.html / terms-of-service / verify-email-sent いずれも 2）。しかし、マーカー領域を `<head>` 直後へ動かす・プラグイン順序を変える・GTM をマーカー内へ移すといった将来の変更で **prod 全ページから GTM が消えても、既存 184 テストは全 green のまま**通過する。LP は申込コンバージョン計測を GTM に依存しているため、静かに壊れると発見が遅れる。

**修正提案:**
`expectPrerenderedFiles()` は `build:dev` / `build:prod` 双方から呼ばれるため、GTM は prod 専用としてモード別に 1 行足す。

```javascript
// build:prod のテスト内に追加
expect(readFileSync(join(DIST, 'index.html'), 'utf8')).toContain(GTM_CONTAINER_ID);
expect(readFileSync(join(DIST, 'terms-of-service'), 'utf8')).toContain(GTM_CONTAINER_ID);
// build:dev 側は逆に含まれないことを確認
expect(readFileSync(join(DIST, 'index.html'), 'utf8')).not.toContain(GTM_CONTAINER_ID);
```

`GTM_CONTAINER_ID` は `vite-plugin-gtm.js` が既に export しているのでそのまま import できる。

---

### [Codex] buildIntegration.test.js: `execFileSync` に timeout 未指定で、Vitest 側のタイムアウトが実質機能しない

**ファイル:** `lp/src/__tests__/buildIntegration.test.js:16-25, 65, 79`
**重要度:** Medium

**該当コード:**

```javascript
// main側（変更前）— ファイル自体が存在しない（新規追加）
```

```javascript
// GTSS-884側（変更後）
16  const BUILD_TIMEOUT_MS = 180_000;
17
18  function runBuild(script) {
19    execFileSync('npm', ['run', script], {
20      cwd: ROOT,
21      stdio: 'pipe',
22      // SENTRY_AUTH_TOKEN が手元環境にあっても sourcemap upload を発火させない。
23      env: { ...process.env, SENTRY_AUTH_TOKEN: '' },
24    });
25  }
...
64      },
65      BUILD_TIMEOUT_MS   // ← it() の第3引数。Vitest 側のタイムアウト（build:prod 側は 79 行目）
66    );
```

**問題:**
`execFileSync` は worker のイベントループを同期的にブロックするため、`it()` の第 3 引数で与えた 180 秒（141 行目）では**ハングした子プロセスを中断できない**。`vite build` が何らかの理由で固まると（依存の解決待ち・ディスク I/O 待ち等）、Vitest はタイムアウトを発火できず CI（GitHub Actions の `npm test` ジョブ）がジョブ上限まで停止する。`BUILD_TIMEOUT_MS` は宣言されているのに実効しない点で、意図と実装が乖離している。

**修正提案:**
`execFileSync` のオプション側にタイムアウトを渡す（子プロセスを確実に落とす）。

```javascript
function runBuild(script) {
  execFileSync('npm', ['run', script], {
    cwd: ROOT,
    stdio: 'pipe',
    env: { ...process.env, SENTRY_AUTH_TOKEN: '' },
    timeout: BUILD_TIMEOUT_MS,
    killSignal: 'SIGKILL',
  });
}
```

---

### [Code Quality] lp の `CLAUDE.md` が SSG 化前の記述のまま（削除済みの `public/robots.txt` を参照している）

**ファイル:** `lp/CLAUDE.md:62`
**重要度:** Medium

**該当コード:**

```markdown
<!-- main側（変更前）— 当時は正しい記述 -->
SEO 設定（ページ別 title / description / canonical / noindex / OGP）は `src/seo.js`
（`resolvePageKey` / `applyPageMeta`）が JS レンダリング時に head へ設定し、
`public/sitemap.xml` / `public/robots.txt` は静的配信する。
```

```markdown
<!-- GTSS-884側（変更後）— CLAUDE.md は未変更のため同じ文言が残っている -->
SEO 設定（ページ別 title / description / canonical / noindex / OGP）は `src/seo.js`
（`resolvePageKey` / `applyPageMeta`）が JS レンダリング時に head へ設定し、
`public/sitemap.xml` / `public/robots.txt` は静的配信する。
```

**問題:**
本 PR で `public/robots.txt` は**削除**され（プラグイン生成へ移行）、SEO メタは「JS レンダリング時のみ」から「ビルド時プリレンダ + JS の二重適用」へ変わった。にもかかわらず lp リポジトリの `CLAUDE.md` は無変更で、**存在しないファイルを指し、廃止された方式を現行として説明している**。Issue の変更ファイル一覧は親リポジトリの `docs/` 3 本のみを挙げており（そちらは作業ツリーに未コミットの更新あり）、lp 自身の `CLAUDE.md` が漏れている。この文書は毎セッション読まれるため、誤誘導のコストが大きい。

**修正提案:**
lp の `CLAUDE.md` の該当段落と「ページ構成」節を更新する。

- SEO 値の単一ソースは `src/seo.js` の `PAGE_META`、URL 一覧の単一ソースは `vite-plugin-seo-prerender.js` の `PRERENDER_ROUTES`
- 適用は「ビルド時プリレンダ（`buildPageHeadTags`）+ JS（`applyPageMeta`）の二重適用」
- `robots.txt` はモード別にビルド時生成（dev=`Disallow: /` / prod=`Allow: /` + Sitemap）。`public/robots.txt` は廃止
- `sitemap.xml` は `public/` の静的配信のまま
- 存在しない URL は CloudFront が HTTP 404 + `/404.html`（アプリ非起動の独立ページ）を返す
- `deploy.sh` は「sync --delete → 拡張子なし 10 ファイルを個別 cp」の 2 段構え

---

### [Codex] infra: `modules/static-site` の `error_document` コメントが lp の新挙動と矛盾する

**ファイル:** `infra/modules/static-site/main.tf:25`
**重要度:** Low

**該当コード:**

```hcl
# main側（変更前）— 当時は 3 サイトすべてで正しい記述
21    index_document {
22      suffix = "index.html"
23    }
24
25    # SPA: 直リンク時の 404 は CloudFront 側で 200 /index.html に変換する。
26    error_document {
27      key = "index.html"
28    }
```

```hcl
# GTSS-884側（変更後）— ファイル冒頭は更新されたが、この行は据え置き
21    index_document {
22      suffix = "index.html"
23    }
24
25    # SPA: 直リンク時の 404 は CloudFront 側で 200 /index.html に変換する。
26    error_document {
27      key = "index.html"
28    }
```

**問題:**
同ファイル冒頭（7-8 行目）は「エラー応答は `var.custom_error_responses` で選択。lp は 404 → 404 /404.html」へ正しく更新されている一方、25 行目は「CloudFront 側で 200 /index.html に変換する」と断定したまま。lp では 404 → 404 `/404.html` になるため矛盾する。この矛盾は、将来「404.html を返したいのだから `error_document` も変えるべき」という誤った修正（S3 website 側を触る）を誘発しやすい。

**修正提案:**

```hcl
  # S3 website 側は既存互換で index.html のまま維持する。
  # viewer への最終応答（ステータス / ボディ）は CloudFront の var.custom_error_responses が決める。
  error_document {
    key = "index.html"
  }
```

---

### [Test Coverage] deploy.sh の新デプロイ経路（個別 cp / メタデータ / CI 分岐）が自動検証されていない

**ファイル:** `lp/deploy.sh:151-169`, `lp/src/__tests__/buildIntegration.test.js`
**重要度:** Low

**問題:**
T-16（`buildIntegration.test.js`）が担保しているのは**ビルド成果物の内容**までで、本 PR のもう一方の中核である deploy.sh の変更 —「10 件の個別 `cp`」「`Content-Type: text/html; charset=utf-8` / `Cache-Control: max-age=3600` の付与」「CI モードでの `--profile` 除外」「生成物欠落時の停止位置」— は一切検証されていない。CloudFront の実挙動は人力（T-11 / T-14）でしか確認できないが、**AWS CLI コマンドの組み立て自体はモックで自動検証できる**。上の Medium 指摘（事前検証の位置）も、テストがあれば実装時点で検出できた性質のもの。

**修正提案:**
必須ではない（本 PR のブロッカーにはしない）が、フォローアップとして `PATH` 先頭に引数を記録するだけのダミー `aws` / `node` を置くシェルテストを 1 本用意すると、以下が回帰検出可能になる。

- `sync --delete` → `cp` の実行順と cp 回数（= `PRERENDER_ROUTES` から index.html を除いた件数）
- 各 cp の `--content-type` / `--cache-control`
- `CI=true` のとき `--profile` が付かない / 非 CI では付く
- `dist/` に生成物が無いとき、**AWS コマンドが 1 度も呼ばれずに** 非ゼロ終了する

---

### [Security] infra: prod LP の S3 / CloudFront に `prevent_destroy` がない

**ファイル:** `infra/prod/static-site-lp.tf:52, 71, 87`（`aws_s3_bucket.lp` / `aws_s3_bucket_policy.lp` / `aws_cloudfront_distribution.lp`）
**重要度:** Low

**該当コード:**

```hcl
# main側（変更前）— これらは terraform 管理外だったため、terraform からは壊しようがなかった
```

```hcl
# GTSS-884側（変更後）— 本番配信の実体が state 配下に入るが destroy ガードはなし
52  resource "aws_s3_bucket" "lp" {
53    bucket = local.lp_bucket_name
54  }
...
87  resource "aws_cloudfront_distribution" "lp" {
88    enabled             = true
```

**問題:**
本 PR で `cancel.co.jp` の配信実体（CloudFront `E3AU8H3BJJK35A` + S3 `cancel-billing-lp-prod-app`）が初めて terraform state に入る。同 state には本 Issue と無関係の drift があることがファイル冒頭に明記されており（25-27 行目）、`-target` 無し apply 禁止という**人手の規律**だけで守られている状態になる。`static-site-lp.tf` の削除や誤った `terraform destroy` は本番 LP を停止させる。バケットは `force_destroy` 未指定（= false）で中身があれば削除が失敗するが、**CloudFront ディストリビューションには何のガードもない**。

なお `prevent_destroy` は現時点で本リポジトリのどこでも使われておらず、本指摘は新規の規約導入にあたる。採用可否は判断に委ねる。

**修正提案:**

```hcl
resource "aws_cloudfront_distribution" "lp" {
  # ...
  lifecycle {
    prevent_destroy = true
  }
}
```

同じブロックを `aws_s3_bucket.lp` にも付ける。設定変更（403/404→404）は in-place update のため `prevent_destroy` の影響を受けない。

---

### [Test Coverage] buildIntegration.test.js が `stdio: 'pipe'` でビルド失敗時のログを握り潰す

**ファイル:** `lp/src/__tests__/buildIntegration.test.js:18-25`
**重要度:** Low

**問題:**
`execFileSync` に `stdio: 'pipe'` を渡しているため、`vite build` が失敗したときに throw される Error の `message` は `Command failed: npm run build:dev` のみで、**Vite / terser の実エラー本文は `err.stdout` / `err.stderr` に入ったまま表示されない**。`.github/workflows/ci.yml` の `npm test` が落ちたとき、CI ログだけでは原因が追えない。

**修正提案:**
上の timeout 追加とあわせて対応する。

```javascript
function runBuild(script) {
  try {
    execFileSync('npm', ['run', script], {
      cwd: ROOT, stdio: 'pipe', env: { ...process.env, SENTRY_AUTH_TOKEN: '' },
      timeout: BUILD_TIMEOUT_MS, killSignal: 'SIGKILL',
    });
  } catch (err) {
    throw new Error(`npm run ${script} failed:\n${err.stdout}\n${err.stderr}`);
  }
}
```

---

### [Code Quality] infra: `custom_error_responses` に validation がなく、空リストで user / admin の SPA フォールバックが無言で消える

**ファイル:** `infra/modules/static-site/variables.tf:22-40`
**重要度:** Low

**問題:**
`custom_error_responses = []` を渡すと `dynamic "custom_error_response"` が 0 件展開になり、CloudFront から custom error response が消える。すると S3 website 側の `error_document`（index.html）が **HTTP 404 のまま**返り、user / admin の SPA ディープリンクが壊れる。既定値は正しいが、空リストという踏みやすい誤用に対するガードがない。

**修正提案:**

```hcl
variable "custom_error_responses" {
  # ...
  validation {
    condition     = length(var.custom_error_responses) > 0
    error_message = "custom_error_responses は最低 1 件必要（空にすると SPA フォールバックが消え SPA ディープリンクが壊れる）"
  }
}
```

---

### [Code Quality] `buildPageHeadTags` は「canonicalPath あり = description あり」を暗黙前提にしており、崩れると `applyPageMeta` と乖離する

**ファイル:** `lp/src/seo.js:201-205`
**重要度:** Low

**該当コード:**

```javascript
// GTSS-884側（変更後）
201    if (canonicalUrl) {
202      tags.push(`<link rel="canonical" href="${escapeHtml(canonicalUrl)}" />`);
203      tags.push(`<meta property="og:title" content="${escapeHtml(meta.title)}" />`);
204      tags.push(`<meta property="og:description" content="${escapeHtml(meta.description)}" />`);
205      tags.push(`<meta property="og:url" content="${escapeHtml(canonicalUrl)}" />`);
```

**問題:**
description を持たない公開ページ（`canonicalPath` あり / `description` なし）を `PAGE_META` へ足すと、204 行目は `escapeHtml(undefined)` → `String(undefined)` により **`content="undefined"`** を出力する。一方 `applyPageMeta` 側は `upsertHeadTag` の `if (value == null)` 分岐で **og:description タグを削除**するため、両者が乖離する（本 PR の中核である「プリレンダ = JS 確定後」の同値性が崩れる）。

現状 `PAGE_META` の公開 4 ページはすべて description を持つため実害はなく、かつ `seo.test.jsx` の全 pageKey 同値性テストがこの乖離を検知できる（＝入れた瞬間に落ちる）。したがって severity は Low だが、コード上の暗黙前提としてガードしておく価値はある。

**修正提案:**
`if (canonicalUrl)` ブロック内でも `meta.description` の有無で分岐するか、`PAGE_META` に「canonicalPath があるなら description 必須」を明示するコメント / テストを置く。

---

### [Code Quality] `/index.html` 直アクセスのみ初期 HTML と JS 確定後の head が一致しない

**ファイル:** `lp/src/seo.js:5-9`, `lp/src/seo.js`（`resolvePageKey`）
**重要度:** Low

**問題:**
`dist/index.html` はプリレンダによりトップ用 head（canonical `https://cancel.co.jp/` / description / og:url あり）を持つ。しかし `/index.html` へ直アクセスすると `resolvePageKey('/index.html')` は `'unknown'` を返すため、JS が canonical / description / og:url を**削除して `noindex` を付与**する。初期 HTML と JS 確定後が食い違う唯一のケース。

SEO 上は安全側（トップの複製 URL が noindex になる）に倒れるため実害はない。ただし `src/seo.js:5-9` のヘッダコメントにある「JS 側は SSG 済みの head へ同値を冪等に再適用するだけになる」は**既知 11 ルートに限った話**であり、この例外がコメントから読み取れない。

**修正提案:**
`src/seo.js` のヘッダコメントに「`/index.html` 直アクセスは `unknown` 扱いとなり初期 HTML から noindex へ書き換わる（安全側・意図どおり）」を 1 行追記する。

---

### [Code Quality] 404.html に GTM が入らないため、prod の 404 到達が一切計測されない

**ファイル:** `lp/vite-plugin-seo-prerender.js`（`render404Html`）
**重要度:** Low

**問題:**
`render404Html()` は独立テンプレートで `vite-plugin-gtm.js` の `transformIndexHtml` を通らないため、生成物に GTM スニペットが入らない（実ビルドで確認: `grep -c 'GTM-56D47XBB' dist/404.html` = 0、他ページは 2）。REQ-2 で 404 化する URL が増える（トレイリングスラッシュ・大文字小文字違い・未知パス + `?_page=`）にもかかわらず、**どれだけ 404 に到達しているかを GTM / GA で観測できない**。

「アプリの起動スクリプトを含めない」という Issue の要件は React バンドルを指すもので、GTM の同期スニペットは 404 表示を上書きしないため要件とは両立する。

**修正提案:**
意図的に入れない判断であれば `render404Html()` にその旨をコメントで残す。計測したい場合は prod ビルドのみ `injectGtm(html, isProd)` を 404.html にも通す（`vite-plugin-gtm.js` の `injectGtm` は純関数として export 済みでそのまま再利用できる）。あるいは CloudFront のアクセスログ / CloudWatch メトリクスで 404 レートを見る運用に寄せる。

## 総評

**品質は総じて高い。** 設計の勘所（SEO 値の単一ソース = `PAGE_META` / URL 一覧の単一ソース = `PRERENDER_ROUTES`、純関数 + 薄いプラグインラッパ、マーカー欠落・重複での throw、404.html をアプリ非起動の独立テンプレートにする判断、`--exclude` を使わず `--delete` の削除判定を効かせる判断）はいずれも妥当で、コメントに理由まで残されている。既存 `vite-plugin-gtm.js` / `gtm.test.js` のパターン踏襲も一貫している。

**テストカバレッジ**は 184 tests green を独立に確認済み。プリレンダ head の含有/非含有を双方向で検証している点、`buildPageHeadTags` ⇔ `applyPageMeta` の同値性を全 pageKey で回している点、期待値を `PAGE_META` から導出せずリテラル固定してトートロジーを避けている点は良い。実ビルド統合（T-16）まで入れて純関数テストとの乖離を潰す設計も適切。

**セキュリティ**面の新規リスクはない。HTML 埋め込みは `escapeHtml` を通しており、属性はすべてダブルクォートで囲まれているためシングルクォート未エスケープも問題にならない。PII・機密値の混入なし。infra 側も公開範囲の拡大・`force_destroy` 追加・OAI/OAC の意図しない変更はなく、`custom_error_responses` の既定値は user / admin の現行 state と一致しており SPA フォールバックを壊さない。

**残るリスクは「生成ロジックの正しさ」ではなく、(a) 新設された暗黙の契約、(b) 適用手順、(c) デプロイ経路の堅牢性に集中している。**

最も重いのは **High 1 件**: `PRERENDER_ROUTES` が「200 を返す URL の許可リスト」へ昇格したのに、App.jsx 側との突き合わせがなく、エイリアスパスを足すと `npm test` 全 green のまま本番 404 になる。**この失敗モードは本 PR が新たに作り出したもの**（従来は未登録パスも CloudFront が 200 でトップを返していた）で、テスト 1 本で塞げるため同 PR 内での対応を強く推奨する。

Medium 8 件のうち**リリース前に必須**なのは、deploy.sh の検証タイミング（配信が壊れた状態で終わりうる）と prod terraform の適用手順（import と設定変更が 1 回の apply に同居）の 2 件。`node -e` の smoke import テストと GTM 回帰テストは、いずれも「Vitest green なのにデプロイ時／本番だけ壊れる」経路を塞ぐもので、同 PR 内での対応が費用対効果に優れる。lp の `CLAUDE.md` 更新も同 PR 内が自然（同一リポジトリのため）。

Low 7 件は記録・フォローアップ扱いで差し支えない。ただし `lp_enable_404_response` と import ブロックの除去は **T-17 完了後の宿題として Issue に明記**しておかないと確実に忘れる性質のもの。

**サブエージェント実行状況:** codex-reviewer（lp / infra）・code-reviewer・lessons-reviewer の 4 本すべてが完了。全指摘をメインエージェントが実ファイル・実ビルド・実テストで再検証したうえで採否を判断した。

破棄・修正した指摘:
- code-reviewer の「`deploy.sh:159` の `node -e` は Node 20.x で確実に落ちる」→ **不正確**。module 構文自動検出は Node 20.19+ にも入っており、手元の v20.20.0 で実行して成功を確認済み。実際に落ちるのは Node 20.0-20.18 / 22.0-22.6。指摘自体は smoke import テスト欠如（Medium）として範囲を修正のうえ採用した。
- code-reviewer の「sync → cp 間に 404 になる」懸念 → **ならない**（sync 時点でオブジェクトは存在する）。窓の間は Content-Type が `binary/octet-stream` になるだけで、CloudFront キャッシュと後続の invalidation により自己回復する。Medium 指摘の本文へ正しい影響範囲として反映した。
