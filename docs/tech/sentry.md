# Sentry 導入・運用（GTSS-858）

全4リポジトリのエラー監視を Sentry に統一する。本書は**プロジェクト構成・初期化方式・PII スクラブ・source map・環境変数**の運用規約をまとめる。

- 関連: `docs/tech/ci-cd.md`（秘密の配布経路）/ `docs/tech/secrets-management.md` / `docs/tech/batch-fargate.md`（batch の ECS 経路）
- 実装 Issue: akichim21/cancel #39（GTSS-858）

## 1. プロジェクト構成

Sentry org は `shaire`。**プロジェクトはリポジトリ単位で分離**する（独立ビルド・独立 source map・独立デプロイのため、release / issue ストリーム / アラートを混ぜない）。

| Sentry プロジェクト（= リポジトリ名） | 対象 | SDK |
|---|---|---|
| `cancel-billing-service-api` | Server Lambda + batch Lambda + batch ECS(Fargate) | `@sentry/aws-serverless` |
| `cancel-billing-service` | サロン向けユーザーポータル（React 19） | `@sentry/react` |
| `cancel-billing-service-admin` | 運営管理ダッシュボード（React 19） | `@sentry/react` |
| `cancel-billing-service-lp` | LP・申請フォーム（React 18 / JSX） | `@sentry/react` |

**dev / prod はプロジェクトを分けず `environment` タグで区別する**（`dev` / `prod`）。

## 2. 初期化方式: in-code `Sentry.init()` に統一（Layer 不使用）

API は当初 Sentry Node Serverless **Layer + `NODE_OPTIONS` 自動計装（ゼロコード）**を検討したが、以下の理由で **in-code init に統一**した。**Layer も `NODE_OPTIONS` も使わない。**

1. **Hono が例外を握りつぶす**: `src/handlers/index.ts` の `app.onError` が route の例外を捕捉して 500 応答を返すため、例外は Lambda handler の外へ伝播しない。handler を抜けた例外のみ捕捉する Layer 自動計装ではアプリ例外がほぼ届かない → `app.onError` 内で明示 `captureException` が必要。
2. **PII スクラブ（`beforeSend` / `beforeBreadcrumb`）は環境変数で渡せない** → in-code init が必須。
3. **batch の ECS(Fargate) 経路は Lambda ではない** → Layer / `NODE_OPTIONS` が効かない。

> トレードオフ: esbuild バンドル環境では OTel 自動計装が薄れる（分散トレースは限定的）。**エラー監視は問題なく成立**する。初期方針はエラー監視優先のため許容する。

### API の 3 実行経路（すべて計装済み）

| 経路 | エントリ | 初期化 | 送出方法 |
|---|---|---|---|
| Server API | `src/lambda.ts`（Lambda） | `initSentry()`（モジュール先頭） | `Sentry.wrapHandler` + `app.onError` の `captureException`（捕捉範囲は排他） |
| batch Lambda | `src/batch.ts`（Lambda） | `initSentry()` | `Sentry.wrapHandler`（`dispatchBatchAction` が throw する） |
| batch ECS | `src/batch-entry.ts` → `src/batch-cli.ts`（Fargate コンテナ） | `initSentry()` | `runCli` の catch で `captureException` + `flush(2000)` |

- 共通モジュール: `src/observability/sentry.ts`。`initSentry()` は **冪等**（`started` ガード）で、`SENTRY_DSN` 未設定なら**完全 no-op**（local / test は送信しない）。
- batch は `batch_execution`（Terraform）で Lambda / ECS のどちらが稼働してもエラーが届く。

## 3. PII スクラブ（必須）

CLAUDE.md「個人情報（PII）の取り扱い」に準拠。**`sendDefaultPii: false`** を全アプリで維持し、IP / ヘッダ / Cookie / リクエストボディ / ユーザ情報を自動添付しない。

API は `src/observability/sentry.ts` の純関数で二重に防御する（`beforeSend` / `beforeBreadcrumb`）。unit テスト: `src/__tests__/unit/sentry-scrub.test.ts`。

1. **キー名スクラブ**（`scrubEventPii` / `scrubBreadcrumbPii`）: `name` / `kana` / `mail` / `phone` / `address` / `pass*` / `token` / `secret` / `credential` / `loginId` / `userId` 等に一致するキーの値を `[Filtered]` へ。camelCase / snake_case も部分一致で拾う（**取りこぼしより過剰マスクを優先**）。`applicationId` 等の内部 ID は温存。
2. **本文テキストスクラブ**（`redactPiiText`）: キー名で拾えない**フリーテキスト**（`Error.message` = `exception.values[].value`、`breadcrumb.message`、`event.message`）内の**メール → `[email]` / 電話 → `[phone]`** を正規表現でマスク。
3. `user` は `id` 以外（email / username / ip_address）を落とす。

> **注意**: 本文スクラブはメール/電話パターンに限定される。**氏名など任意テキストは検出できない**ため、「例外メッセージ・console ログに顧客 PII を載せない」のはコード側の責務（レビュー観点）。

フロント3つは **Replay を `maskAllText: true` / `blockAllMedia: true`** でマスクする（admin は顧客 PII 表示が多いため特に重要）。

## 4. environment の出し分け（MODE 非依存・重要）

フロントは dev / prod とも `vite build`（`MODE=production`）になり得るため、**`import.meta.env.MODE` を environment に使わない**。専用変数 `VITE_SENTRY_ENVIRONMENT` を使う。

- API: `SENTRY_ENVIRONMENT` を `deploy-*.sh` がデプロイ環境名（`dev` / `prod`）で**強制注入**する。
- フロント: `.env.development` = `dev` / `.env.production` = `prod`（user portal は deploy.sh が `.env.local` へ焼き込む）。

## 5. 環境変数

| 変数 | 対象 | 説明 |
|---|---|---|
| `SENTRY_DSN` | api | in-code init が読む。**全置換 environment に必ず含める**（後述） |
| `SENTRY_ENVIRONMENT` | api | `dev` / `prod`。deploy スクリプトが強制注入 |
| `SENTRY_TRACES_SAMPLE_RATE` | api | 任意。未設定 = `0`（トレース無効。初期はエラー監視優先） |
| `VITE_SENTRY_DSN` | front | 未設定なら計装 no-op |
| `VITE_SENTRY_ENVIRONMENT` | front | `dev` / `prod`（MODE 非依存） |
| `VITE_SENTRY_TRACES_SAMPLE_RATE` | front | 任意。未設定 = `0` |
| `SENTRY_AUTH_TOKEN` / `SENTRY_ORG` / `SENTRY_PROJECT` | 全（ビルド時） | source map upload 用。**CI Secret のみ。コミット禁止** |

### ⚠️ env 全置換（API の最重要注意点）

`deploy-api.sh` / `deploy-batch.sh` は `update-function-configuration --environment` で **Lambda の環境変数セットを全置換**する。**`SENTRY_DSN` / `SENTRY_ENVIRONMENT` を生成 JSON に含めないと、毎デプロイで消えてエラー監視が黙って止まる**。3 スクリプト（`deploy-api.sh` / `deploy-batch.sh` / `deploy-batch-ecs.sh`）とも投入済み。コンソールでの手動設定は次回デプロイで消えるため禁止。

### DSN の注入経路

**実 DSN はコミットしない**（env / CI Secret 経由）。DSN 自体はフロントのバンドルに埋まる公開値だが、本リポジトリの env 管理方針に合わせる。

| アプリ | 注入方法 |
|---|---|
| api | `.env.development` / `.env.production` → `deploy-*.sh` が全置換 environment へ |
| user portal | `deploy.sh` が `$VITE_SENTRY_DSN` を `.env.local` へ焼き込む（CI: CodeBuild env / SSM） |
| admin / lp | **ビルド時のシェル環境変数 `VITE_SENTRY_DSN`**（Vite は `VITE_` 接頭辞のシェル変数を最優先で埋め込む） |

> フォールバックの手元 deploy（`deploy-admin.sh` / lp `deploy.sh`）を素で実行すると `VITE_SENTRY_DSN` 未設定 = Sentry 無効で黙って通る。**DSN の供給源は原則 CI**。手元から Sentry 有効でデプロイする場合は `export VITE_SENTRY_DSN=...` してから実行する。

## 6. source map

`SENTRY_AUTH_TOKEN` が**あるときだけ** upload する（無ければ map を出力しないため、ローカル/トークン未設定 CI のビルド挙動は従来どおり）。

- api: `build.mjs` が esbuild `sourcemap: 'external'` + `@sentry/esbuild-plugin`。upload 後に `.map` を削除し Lambda zip / ECS イメージへ同梱しない。
- フロント: `vite.config.*` が `build.sourcemap: 'hidden'` + `@sentry/vite-plugin`（公開バンドルに map 参照コメントを残さない）。upload 後に `.map` を削除し **S3 へ公開 map を撒かない**。

## 7. 動作確認（dev）

1. Sentry org `shaire` に 4 プロジェクトを作成し DSN を取得する。
2. DSN を各 env / CI Secret へ設定（上記「DSN の注入経路」）。
3. dev デプロイ後、意図的な例外を発火して各プロジェクトへ `environment=dev` で届くことを確認する。
   - Server: 一時的な debug ルートで `throw new Error('This should show up in Sentry!')`（Hono の onError 経由で捕捉される）
   - batch: 未知 `action` で invoke / RunTask（`dispatchBatchAction` が throw）
   - フロント: 一時的な throw → user/admin は `reactErrorHandler`、lp は `ErrorBoundary` の fallback 表示
4. 再デプロイ後に `aws lambda get-function-configuration` で `SENTRY_DSN` / `SENTRY_ENVIRONMENT` が残存することを確認する（全置換対策の回帰チェック）。
5. Replay のテキストがマスクされていること・スタックが元 TS 位置へ解決されることを確認する。
