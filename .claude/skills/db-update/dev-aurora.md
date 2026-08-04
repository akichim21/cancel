# dev Aurora 直接更新（RDS Data API）

`cancel-billing-service-api/` をカレントにして実行する（`.env.development` がそこにある）。

## 0. 大前提

- データストアは **Aurora PostgreSQL**。`applications` / `application_users` / `users` / `cancellations` /
  `monthly_sales` / `shops` 等（`src/db/schema.ts` が正）。DynamoDB はもう使わない（移行元のみ）。
- dev/prod は Lambda 同様 **RDS Data API** で外から叩ける。local/test は docker Postgres（`psql` 直結、:5440/:5439）。
- 接続情報は env ファイルにある。**ファイルは開かず（Read/cat/grep/echo 禁止）、シェルに source して使う**。

## 1. 接続スニペット（これをそのまま使う）

```bash
cd cancel-billing-service-api
# env を「読み込むだけ」。中身は出力しない。
set -a && . ./.env.development && set +a   # prod は ./.env.production（原則使わない）

# 実行ヘルパ。--profile は dev=cancel-billing-service-dev / prod=cancel-billing-service-prod
DB() { aws rds-data execute-statement \
  --resource-arn "$AURORA_RESOURCE_ARN" \
  --secret-arn  "$AURORA_SECRET_ARN" \
  --database    "$AURORA_DATABASE" \
  --region ap-northeast-1 \
  --profile cancel-billing-service-dev \
  --sql "$1" --output json; }
```

- 動作確認したい時は `echo "$AURORA_RESOURCE_ARN"`（ARN は秘匿不要）まで。**`AURORA_SECRET_ARN` は echo しない**
  （`[ -n "$AURORA_SECRET_ARN" ] && echo set` で有無だけ確認）。
- 値はシェル変数経由で AWS CLI に渡るだけなので、ログ・コメントに秘密は残らない。

## 2. 手順：SELECT → UPDATE → 検証（必ずこの順）

```bash
# (1) 現値を確認（= 保存フォーマットの確認）。スキーマの列名は src/db/schema.ts を見る
DB "SELECT application_id, phone FROM applications WHERE application_id = 'app_xxx'"

# (2) UPDATE。必ず WHERE で絞る。依頼された列だけ。書式は (1) の現値に合わせる
DB "UPDATE applications SET phone = '090-1133-8562' WHERE application_id = 'app_xxx'"
#   → 戻り値の numberOfRecordsUpdated が想定件数か確認

# (3) 再 SELECT で結果検証
DB "SELECT application_id, phone FROM applications WHERE application_id = 'app_xxx'"
```

- SQL 文字列リテラルは単一引用符 `'...'`。値に `'` が含まれる場合は `''` でエスケープ。
- 複数行・複数テーブルにまたがる時は、各テーブルで (1)〜(3) を回す。

## 3. 保存フォーマットを壊さない

書き換え前の SELECT で現値の表記をそのまま踏襲する。アプリは保存時に正規化しないため、**既存値の書式が
正**（混在しうる）。

- **電話番号**: 入力のまま保存（`090-1133-8562` のハイフン有 / `09011338562` のハイフン無が混在しうる）。
  E.164（`+8190…`）化は送信時のみ（`src/utils/phone.ts`）。→ 既存行に合わせる。
- **ステータス / 事業区分**: DB は英語 lowercase enum（`pending`/`approved`/`onboarding`/`active`/`rejected`、
  `corporate`/`individual`）。日本語ラベルを入れない（`src/constants/application-enums.ts`）。
- **PII マスク**: 論理削除済みは `customer_name` 等が `***` 等になっている。誤って実値で上書きしない。

## 4. よく使うテーブル・列（早見）

| テーブル | キー | 代表的な列 |
|---|---|---|
| `applications` | `application_id`（`app_<ms>`） | `phone` / `email` / `partner_name` / `status` / `entity_type` / `deleted_at` |
| `cancellations` | `id`（`imp_*` 取込 / 手動） | `application_id`(FK) / `customer_phone` / `customer_name` / `customer_email` |
| `application_users` | `id`(UUID) | `application_id`(FK) / `email` / `status` |

- 列名は **snake_case**（ドメインの camelCase ではない）。不確かなら `src/db/schema.ts` を参照。
- `cancellations` は `application_id` で複数件ぶら下がる。「この申請の」修正は WHERE を `application_id` にすると一括で当たる。

## 5. 安全ルール

- **WHERE 必須**: 全件更新事故を防ぐ。WHERE 無しの UPDATE/DELETE は書かない。
- **件数を確認**: `numberOfRecordsUpdated` が想定どおりか毎回見る。想定外なら止めて報告。
- **依頼列だけ**: `updated_at` 等の付随列は明示依頼が無ければ触らない（通知抑止等の副作用回避）。
- **PII を出力しない**: SELECT 結果に顧客 PII が含まれる時は会話・ログでマスクする。
- **テスト**: コード非変更の dev データ修正はテスト追加不要（CLAUDE.md のテスト必須ルールはコード修正時の話）。

## 6. prod（原則使わない）

- prod を触るのは人手前提。Claude は原則実行しない。どうしても必要なら:
  `set -a && . ./.env.production && set +a` ＋ `--profile cancel-billing-service-prod`。
- prod は SELECT で対象を確定 → 件数まで提示して**人間の明示承認を得てから** UPDATE。バックアップ/復元手段
  （`scripts/restore-application.ts` 等）の確認も先に行う。

## 7. local/test（参考）

- local: `psql -h localhost -p 5440 -U postgres -d cancel_local`（`npm run db:local:up` 済み前提）。
- test: `:5439` / `cancel_test`（揮発、`npm test` が内包管理）。
- RDS Data API は使わない（`resolveDbDriver()` が node-postgres を選ぶ）。
