---
issue: 29
date: 2026-06-25
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-817-28
    toBranch: GTSS-817-29
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: GTSS-817
    toBranch: GTSS-817-29
---

# レビュー結果: #29

## 概要

**Issue:** #29 external_shop_id を shop_id にリネーム（店舗マスタ分離後の命名整理・external_store_id との混同解消）(GTSS-817)

`external_shop_id`/`externalShopId` → `shop_id`/`shopId` への**純粋なリネーム**（挙動不変）。#27 で店舗マスタ `shops` を媒体別連携 `shop_integrations` から分離した結果、`external_shop_id` は「外部」ではなく内部の店舗マスタ `shops.id` への FK になり、`shop_integrations.external_store_id`（外部媒体の実店舗 ID `H000…`）と紛らわしいためリネームする。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-817-28` | `GTSS-817-29` | 1 | 24 |
| admin | `GTSS-817` | `GTSS-817-29` | 1 | 4 |

> admin の base は manifest 上 `GTSS-817-27` だが remote からマージ削除済みのため、PR base / 比較基準は `GTSS-817`（manifest `prBaseNote` どおり）。引数の `base=GTSS-817-28` は api にのみ存在するブランチで admin には存在しないため api のみに適用。

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/db/schema.ts` | +25 | -25 | Modified |
| `src/db/migrations/0014_gtss817_rename_external_shop_id.sql` | +29 | -0 | Added |
| `src/db/migrations/rollback/0014_gtss817_rename_external_shop_id.down.sql` | +22 | -0 | Added |
| `src/db/migrations/meta/_journal.json` | +7 | -0 | Modified |
| `src/repositories/cancellations.repository.ts` | +8 | -8 | Modified |
| `src/repositories/external-import-logs.repository.ts` | +11 | -11 | Modified |
| `src/repositories/external-integrations.repository.ts` | +17 | -17 | Modified |
| `src/repositories/shop-integrations.repository.ts` | +2 | -2 | Modified |
| `src/repositories/shops.repository.ts` | +2 | -2 | Modified |
| `src/services/cancellation-send.service.ts` | +3 | -3 | Modified |
| `src/services/invoice.service.ts` | +1 | -1 | Modified |
| `src/services/salonboard-auth.service.ts` | +6 | -6 | Modified |
| `src/services/salonboard-import.service.ts` | +9 | -9 | Modified |
| `src/__tests__/e2e/schema.test.js` | +54 | -0 | Modified (T-1 追加) |
| `src/__tests__/e2e/salonboard-store.test.js` | +18 | -18 | Modified |
| `src/__tests__/e2e/send-shop-name.test.js` | +17 | -17 | Modified |
| `src/__tests__/e2e/salonboard-import.test.js` | +9 | -9 | Modified |
| `src/__tests__/e2e/cancellations-list-shop.test.js` | +5 | -5 | Modified |
| `src/__tests__/e2e/shop-admin-crud.test.js` | +5 | -5 | Modified |
| `src/__tests__/e2e/shop-integrations.test.js` | +5 | -5 | Modified |
| `src/__tests__/e2e/invoice-shop-select.test.js` | +3 | -3 | Modified |
| `src/__tests__/e2e/salonboard-send.test.js` | +3 | -3 | Modified |
| `src/__tests__/e2e/repository-columns.test.js` | +2 | -2 | Modified |
| `src/__tests__/helpers/seed.js` | +1 | -1 | Modified |

### admin

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `e2e/fixtures.ts` | +2 | -2 | Modified |
| `e2e/import-logs.spec.ts` | +2 | -2 | Modified |
| `src/components/ImportLogList.tsx` | +1 | -1 | Modified |
| `src/types/Cancellation.ts` | +1 | -1 | Modified |

## 指摘一覧

純粋なリネームとして全レイヤー（schema / migration / repository / service / 型 / テスト / admin）で一貫しており、**挙動不変・冪等性・FK 構成が正しく維持されている。コードの欠陥指摘はなし（承認）。** 確認事項として運用面のメモを 1 件のみ記載する。

- [ ] 対応不要（既知・Issue 本文と AC-4/H-1 で対処済み）

### [Codex] デプロイ順序：破壊的リネームと旧コード稼働の一時的不整合ウィンドウ（運用メモ・Low）

**ファイル:** `api/deploy.sh`（`[1/3] migrate → [2/3] API → [3/3] batch`）+ `api/src/db/migrations/0014_gtss817_rename_external_shop_id.sql`
**重要度:** Low（運用・既知）

**該当コード:**
```bash
# deploy.sh
log_info "[1/3] Aurora マイグレーションを適用しています (npm run migrate:$ENVIRONMENT)..."
npm run "migrate:$ENVIRONMENT"
log_info "[2/3] API Lambda をデプロイしています (deploy-api.sh $ENVIRONMENT)..."
"$SCRIPT_DIR/deploy-api.sh" "$ENVIRONMENT"
```
```sql
-- 0014_gtss817_rename_external_shop_id.sql
ALTER TABLE cancellations RENAME COLUMN external_shop_id TO shop_id;
```

**問題:** `ALTER … RENAME COLUMN` は旧列名 `external_shop_id` を原子的に即時消去する。`deploy.sh` は migrate（[1/3]）を先に完了させてから API Lambda を更新（[2/3]）するため、その間に稼働している**旧 Lambda コード（`external_shop_id` を参照）のクエリは "column does not exist" で 500 になり得る**。Issue が掲げる「ダウンタイムなし」は厳密には migrate↔code 間の短い window については成立しない。

**評価（対応不要の根拠）:** この順序は #29 固有でなく全マイグレーション共通の既存パターン。Issue 本文の「技術的な考慮事項」で既に明記済み（"旧コードは旧列名を参照するため、migrate 後に旧 API が残ると 500 … `./deploy.sh dev` は migrate→API を一括実行するため整合"）。Lambda は `update-function-code`（canary/alias なし＝原子スワップ）でバージョン併存が無く、`deploy.sh` が migrate 直後に code 更新を連続実行するため window は小さい。対象は低トラフィックの管理系 API で、AC-4 / H-1（dev で migrate→API 適用後の正常応答＋逆 migration を人力検証）が deploy 検証をカバーする。**追加のコード変更は不要。** 厳密な無停止が要件化された場合のみ expand/contract（新列追加→両書き込み→旧列削除）を将来検討。

## 総評

メインエージェントによる独立再検証（migration 履歴の逆算・cross-file 追跡）と、code-reviewer / lessons-reviewer / codex-reviewer の 3 サブエージェントすべてが一致して **承認**。

**確認済みの不変条件:**
- **リネーム漏れ・過剰リネームなし**: `git grep externalShopId|external_shop_id` を `GTSS-817-29` の `src`（migration SQL / 履歴 snapshot を除く）に実行 → 能動コード（schema.ts・repositories・services・型）に旧名の残存ゼロ。`external_store_id`/`externalStoreId`（変更禁止の外部媒体 ID）は誤変更ゼロ（diff 中の出現はコメント内のみで識別子は保持）。
- **migration 0014 の正しさ**: ALTER RENAME の対象識別子（`cancellations_external_shop_id_fk`/`_idx`/`cancellations_external_shop_reservation_unique_idx`、`external_import_logs_external_shop_id_fk`/`_idx`、`external_integrations_external_shop_id_fk`）は 0003 / 0006 で生成されて以降 drop/recreate されておらず、適用時点の実 DB 現行名と完全一致。0006 の `external_shops → shops` テーブルリネームは FK 制約名を変えないため整合。`external_import_logs_shop_reservation_unique_idx` は元から `shop_` 名のため改名対象外（コメントと一致）、`external_integrations_app_source_shop_unique_idx` は名称維持（構成列のみ自動追従）。FK 参照先（`shops.id`）・ON DELETE（SET NULL ×2 / CASCADE ×1）・UNIQUE 構成は不変。
- **逆 migration の対称性**: `rollback/0014_*.down.sql` は up と逆順（external_integrations → external_import_logs → cancellations、各テーブル内も FK/idx → column の逆順）で完全対称。
- **drizzle 規約整合**: `_journal.json` の新エントリ（idx=14, version="7", when=1782900000000 で単調増加, tag がファイル名一致）は整合。per-migration snapshot は 0006 以降の手書き migration 全てが省略している既存規約どおりで、0014 が snapshot 無しなのは defect ではない。
- **挙動不変**: `onConflictDoNothing`/`onConflictDoUpdate` の conflict target・部分ユニークの `where` 述語・`leftJoin` の列参照・`getByApplicationSourceAndShop` の `null→isNull` 分岐がすべて `shopId` に追従。冪等性維持。
- **API↔admin 契約保全**: import-logs レスポンスの `shopId` は `external-import-logs.repository.ts` の `toDomain`（`getTableColumns` 由来）が schema プロパティ名から派生するため、schema の `shopId` がそのまま契約になり、admin 側の `ImportLog.shopId` / `ImportLogList.tsx` の `log.shopId` / fixtures・spec と一致。`ImportLogList.tsx:147` のフォールバック `log.storeName || log.shopId || '-'` は旧 `log.externalShopId`（同じ内部 UUID）と同値で挙動不変。
- **コールチェーン**: メソッド名変更 `deleteByExternalShopId → deleteByShopId` の唯一の呼び出し元 `salonboard-auth.service.ts` の `deleteShop` も同 PR で追従済み。`findByExternalRef` 等の引数名変更は全て位置引数で安全。

**テストカバレッジ:** `schema.test.js` に T-1（#29/AC-1）を新規追加し、リネーム後の列名・FK 名・index 名・ON DELETE（confdeltype）・UNIQUE 構成の不変と、旧名の不在を実 Postgres で検証している。既存 E2E（salonboard-import/send/store, cancellations-list-shop, invoice-shop-select, repository-columns, send-shop-name, shop-admin-crud, shop-integrations）も新名へ網羅的に追従。Issue では api 766 tests / admin Playwright 22 passed が green と報告されている。

**マージ前の残作業:** AC-4 / H-1（dev で `./deploy.sh dev` の migrate→API を流し、正常応答と逆 migration を人力検証）のみ。コードレビュー観点では承認。
