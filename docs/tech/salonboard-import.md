# サロンボード取り込み（技術）

サロンボード（ホットペッパービューティーの管理画面 `salonboard.com`）からキャンセル予約を取り込む
クローリング連携の技術仕様（GTSS-817）。pure HTTP + 軽量 HTML/JSON パースで実装し、headless ブラウザは使わない。

中核は `cancel-billing-service-api/src/services/salonboard-import.service.ts`（共有）に置き、
日次バッチ（`src/batch.ts` の `action='salonboard-import'`）と手動取り込み HTTP（`POST /cancellations/import`）の
両方から同一ロジックを呼ぶ。連携先固有名を避け `source`（`'salonboard'`）で抽象化している。

## 外部 API（2026-06-11 実証・アカウント `CD34512`）

ベース URL `https://salonboard.com`。cookie はセッション全体で維持する（`CookieJar`）。

| # | メソッド / パス | 役割 | 主なパラメータ・備考 |
|---|---|---|---|
| 1 | `GET /login/` | cookie 種付け | ログインフォーム取得 |
| 2 | `POST /CNC/login/doLogin/` | ログイン | `userId`/`password`/`idCheckFlg=`。成功時レスポンス HTML の sc_data に `userid:'…'`（非空=成功） |
| 3 | `POST /CNC/groupTop/` | 会社トップ（店舗一覧） | 空 body・`Content-Length:0`。`id="biyouStoreInfoArea"`=ヘア / `id="kireiStoreInfoArea"`=キレイ |
| 4 | `POST /CNC/groupTop/forward` | 店舗コンテキストへ遷移 | `STORE_ID=H000…&designKbn=B`（**`B`=hair 必須**。`C` は不可） |
| 5 | `POST /CLP/bt/top/` | 店舗トップ | `isViaLogin=true` |
| 6 | `GET /CLS/hair/reservations/init/` | SPA 初期化 | サーバ側 cached search を持つ。`?page=N` でページ位置を進める |
| 7 | GraphQL（検索条件 mutation → 一覧 query） | キャンセル予約一覧 | `POST /CLS/hair/api/graphql/{operationName}/` |
| 8 | `GET /CLP/bt/reserve/net/reserveDetail/?reserveId=…&rpsValue=7` | 予約詳細（HTML） | 店舗スコープ（誤店舗は `BPCL010V01`）。キャンセル料・電話・カナ氏名・規定はここでのみ取得 |

### ヘアサロン抽出（REQ-1）

groupTop HTML の `id="biyouStoreInfoArea"` テーブル（ヘア区分）のみから店舗を抽出する。
**店舗名では判別不可**（実例: 店名「GO TODAY シェアサロン 札幌Alba店」がキレイサロン区分 `kireiStoreInfoArea` に在籍）。
各行から サロンID（`H000…`）＋店舗名を取得（`parseHairSalons`）。ログイン成功（`userid` 非空）かつヘアサロン 1 件以上で連携成功。

### 店舗単位連携の単一店舗自動取得（REQ-8・#23・2026-06-13 実証）

店舗単位連携は **ログインの成否のみ**を確認し、単一店舗の店舗ID・店舗名を自動取得する（多店舗の一覧クロール・確認画面は使わない）。実アカウント2種で挙動を実証:
- **会社アカウント**（`CD34512`）: groupTop に `biyouStoreInfoArea`（14店舗）。`parseHairSalons` が **2件以上** → 会社アカウントと判定しエラー（会社単位連携を促す・未保存）。
- **単一店舗アカウント**（`CD77768`）: `POST /CNC/groupTop/` は **システムエラー画面**（`biyouStoreInfoArea` 無し、`parseHairSalons`=0）を返すが、hidden `<input name="STORE_ID" value="H…">` に唯一の店舗IDを埋め込む。続けて `POST /CLP/bt/top/`（`isViaLogin=true`・forward 不要）で店舗TOPが返り、`sc_data` の `"storeid":"H…"` ＋ パンくず（`class="path"` 内 `{店舗名}様 / {店舗ID} / …`）から店舗ID・店舗名を取得（`parseStoreTop`）。
- 判定フロー: `parseHairSalons>=2`→会社エラー / `==1`→その1店舗を採用 / `==0`→店舗TOP取得＋`parseStoreTop`（取得不可はエラー・未保存）。ログイン失敗もエラー・未保存。
- パーサ: `extractHiddenStoreId`（hidden STORE_ID）/ `parseStoreTop`（店舗TOP）。fixture: `group-top-single-store.html` / `store-top-single.html`（PII置換済み）。

### 一覧 GraphQL（REQ-2/3）と persisted query の自動復旧

- `Content-Type: application/graphql+json`、body は `{"query":"<32桁hex id>","variables":{…}}`（サーバは persisted `id` を `query` フィールドで受ける。完全クエリ文字列でも可）。
- 検索条件 mutation `useUpdateReservationSearchConditionMutation`（既定 id `a9d8928117f755ac70f961d4953110d6`）に
  `startDate`/`endDate`（来店予定日範囲）・`cancelStatus:["CANCEL","UNAUTHORIZED_CANCEL"]` を投入 →
  一覧 query `ReservationPageComponentRefetchQuery`（既定 id `20ff67e5e786091d8828df135e71ea36`）の 2 発。
- **persisted query id は HPB リリースで変動する**。`salonboard-client.ts` は 3 層で自動復旧する:
  ①既定（ハードコード id）→ ②`BAD_REQUEST`/4xx 検知でバンドル JS（`_next/static/chunks/*.js`）から
  Relay artifact（`params:{id:"…",name:"…",operationKind:…}`）を正規表現抽出（`extractPersistedQueries`）して再実行
  → ③抽出結果をメモリにキャッシュ。
- **ページング**: 1 ページ 50 件。`paginationInfo` の要素数＝総ページ数。`GET …/init/?page=N` でサーバ側
  cached search のページ位置を進めた後 RefetchQuery を再発行すると condition を維持したまま当該ページが返る。
- 一覧ノードに含まれる主項目: `reservationId` / `reservationStatus`(CANCEL/UNAUTHORIZED_CANCEL) / `paymentType`(LOCAL) /
  `visitationDate` / `start` / `updatedAt`(=キャンセル処理日時) / `reservationPrice.total`(予約金額) / `staffName` / `customerName`。
  **電話・カナ氏名・予約時キャンセル規定・受信日時は一覧に無く、予約詳細でのみ取得**。

### 予約詳細 HTML（REQ-2）

`<th>ラベル</th><td>値</td>` をパース（`parseReservationDetail`）。主要ラベル: 予約番号 / ステータス
（「お客様キャンセル」「無断キャンセル」）/ 支払い種別（「現地支払い」）/ **予約時キャンセル規定** / 来店日時 /
氏名(カナ) / 氏名(漢字) / 電話番号 / 合計金額。ヘッダ領域に `受信日時：YYYY/MM/DD HH:MM`。
**「キャンセル料」欄は CANCEL でも「キャンセル料なし」/「-」が入り信頼できない**ため判定・金額算出に使わない。

詳細リクエストは N+1（1 予約 = 一覧1 + 詳細1）。Akamai 警戒のため **3〜5 並列に制限**（`pMapLimit`、`DETAIL_CONCURRENCY=4`）。

### Akamai Bot Manager

`_abck`/`bm_sz` 保護下だが、UA・Sec-Fetch 系ヘッダを揃えれば pure HTTP で全通過（実証）。JS チャレンジが
昇格した場合のフォールバックとして `sparticuz/chromium`+playwright を想定し、クライアントを interface 化
（`SalonboardClient` / `setSalonboardClientFactory`）してある（本 Issue では HTTP loader のみ実装）。

## 取り込みロジック（REQ-2/3）

1. 連携済み店舗（`external_shops.linked=true`）を会社（`applicationId`）ごとにグルーピング（1 会社 1 ログイン）。
2. 会社ごと: `external_integrations` から `loginId` + 復号した password でログイン。失敗時は当該会社の全店舗を失敗計上。
3. 店舗ごと（順次・失敗は他店舗を止めない / AC-21）: `enterStore`（forward）→ 一覧取得（全ページ）。
   - 抽出窓: 来店予定日が「実行日(JST)の3日前〜3か月後」かつ「契約日（`applications.createdAt` の JST 日付）より後（同日含まず）」（`import-window.ts`）。
   - **早期スキップ（N+1 回避）**: 作成済み（`cancellations` の `externalReservationId`）or 確定理由ログ済み
     （`external_import_logs` の terminal reason）の予約は**詳細取得前にスキップ**。
   - 現地払い以外（list の `paymentType`）は詳細を取らず確定スキップ＋ログ（`not_local_payment`）。
4. 詳細取得（3〜5 並列）→ フィルタ → 作成 or スキップ:
   - 詳細取得失敗 → `detail_fetch_failed`（**一過性・翌日リトライ**＝terminal でない）。
   - 現地払い以外（詳細で再確認）→ `not_local_payment`。
   - 予約時キャンセル規定なし（`-`）→ `no_policy`。
   - 元データのメール・電話が両方無し → `no_contact`。
   - 料率解釈不能 → `rate_unparseable`。
   - それ以外 → **非 prod PII マスク**して `pre_send`（送信前）で `cancellations` を作成。
5. 結果（対象店舗数・店舗別 作成/対象外スキップ/失敗 件数）を集計して返す。あわせて実行単位の結果を
   `external_import_runs` に必ず記録する（`triggerType`・店舗別内訳・失敗 error を含む）。店舗ループ以前の
   致命的失敗（店舗一覧取得失敗等）も握り潰さず `ok:false` で記録する（記録自体の失敗は取り込みを壊さない）。

### 請求金額の算出（REQ-2 / `cancellation-fee.ts`）

`予約時キャンセル規定`（料率文字列。例「2日前〜1日前キャンセル：70% 当日キャンセル：100% 無断キャンセル：100%」）を
ブラケットへパースし、来店日時とキャンセル日（一覧 `updatedAt`）の日数差（JST 暦日）とキャンセル種別で料率を決定する:
- 無断キャンセル → 無断料率
- お客様キャンセル → 当日（0日差）/ N日前ブラケット。どのブラケットにも当てはまらない（規定の最遠より前）→ 0%
- 請求金額（税込）＝ `予約金額 × 料率`、**円未満切り捨て**、**上限は予約金額**。
- 規定文字列にブラケットが 1 つも見つからない（解釈不能）→ 作成せずスキップ＋ログ（`rate_unparseable`）。

## キャンセル status の SSOT（`constants/cancellation-status.ts`）

API DB 値を正とする単一 SSOT。`pre_send`(送信前) / `pending`(請求中) / `paid`(支払済) / `canceled`(キャンセル済) /
`failed`(失敗)。legacy `sent` は `pending` へ正規化（migration 0003 で `sent`→`pending` をバックフィル）。
admin/user フロントの型・ラベルもこの SSOT に整合させる。

## 認証情報の暗号化（REQ-1 / `utils/crypto.ts`）

サロンボードのパスワードはログイン再現に平文復号が必要なため一方向ハッシュ不可。AES-256-GCM の envelope 暗号で
`external_integrations.encrypted_secret`（JSON blob）に保管する:
- ランダムなデータ鍵で平文を AES-256-GCM 暗号化（IV + 認証タグ）。
- データ鍵を保護: **dev/prod は KMS**（`kms:Encrypt/Decrypt` を単一鍵 ARN に限定。env `CREDENTIALS_KMS_KEY_ID`）、
  **local/test は env マスター鍵**（`CREDENTIALS_MASTER_KEY`、未設定時はローカル開発用の固定鍵）で同一 IF。
- レスポンス・ログに平文/blob を出さない（連携設定取得は `hasPassword` の有無のみ返す）。
KMS クライアントは `clients.ts` で lazy require（local/test では読み込まない）。

## 非 prod PII マスク（REQ-8 / `utils/mask-imported-pii.ts`）

本番（`isProdEnv()` = `NODE_ENV==='prod'`）以外では、取り込んだ顧客 PII を保存前に差し替える:
- 氏名・カナ → 合成ダミー（seed=予約 ID で決定的。画面検証性・氏名検索を壊さない）。
- メール・電話 → 紐づく `applications.email` / `applications.phone`（サロン本人の連絡先。非 prod で「送信」しても
  実顧客ではなくサロン運営者宛に届き実配信テスト可）。両方空なら配信不能プレースホルダ（実顧客へ送らない）。
- `externalReservationId`・金額・日時・規定・メニュー・スタッフ名等の非 PII は素通し（テスト再現性）。
- `cancellations` と `external_import_logs` payload の両方に適用。

## データモデル

- `cancellations` 新カラム: `source` / `externalShopId`(FK→`external_shops`) / `externalReservationId` /
  `reservationStatus` / `cancellationType` / `paymentType` / `cancellationPolicy` / `receivedAt` / `customerNameKana` /
  `externalCanceledAt`（キャンセル日。サロンボード一覧の更新日時。`createdAt`＝取り込み実行日とは別。一覧・詳細・
  送信モーダルの「キャンセル日」表示に使う。手動作成は NULL）。
  **冪等キー**: `(external_shop_id, external_reservation_id)` の部分ユニーク（`WHERE external_reservation_id IS NOT NULL`）。
  手動作成（両 NULL）は NULLS DISTINCT で対象外。別店舗の同一予約 ID は別請求として作成される。
- `shops`（#23 で `external_shops` から**リネーム**。FK カラム名 `external_shop_id`/`external_store_id` は不変）:
  会社→店舗 1:N。`(applicationId, source, externalStoreId)` UNIQUE で upsert。会社単位の再連携時は今回取得されな
  かった既存店舗を `linked=false` にする。店舗単位では運営が店舗を個別に作成・更新・削除する（店舗CRUD API）。
- `external_integration_settings`（#23 新規）: `(application_id, source)` PK・`unit`（`company`/`shop`）。連携単位を
  `(会社, source)` 単位で保持。**行が無い場合は既定 `shop`**。lock（変更不可）はカラムを持たず、当該 `(会社, source)` の
  `external_integrations.linked=true` または `shops.linked=true` が1件でもあれば**導出**する（lock の唯一条件は `linked=true`）。
- `external_integrations`: `loginId` + `encryptedSecret`（envelope）+ `linked` + nullable `external_shop_id`（#23 追加・
  FK→`shops.id` ON DELETE CASCADE）。会社単位は `external_shop_id IS NULL` の1行、店舗単位は店舗ごとに1行。
  UNIQUE は `(application_id, source, external_shop_id)` **NULLS NOT DISTINCT**（PG15+。会社行の NULL を1行に制約）。
- `external_import_logs`: 対象外/スキップの生データ（payload JSON）+ 理由 + 対象期間。`application_id` カラムで会社
  フィルター可。`(externalShopId, externalReservationId)` UNIQUE で upsert（重複排除）。顧客 PII を含むため退会時マスク対象。
  作成成功（リトライ成功）時は当該予約のログ行を削除し、キャンセル一覧との矛盾を解消する。
- `external_import_runs`: **取り込みの実行単位ログ**。#23 で **会社（＋source）ごとに1行**へ変更（nullable `application_id`
  ＋index 追加。過去行は NULL のままバックフィルせず、`?applicationId=` フィルター時は除外・無指定では全社表示）。
  `triggerType`（`scheduled`/`manual`）/ `ok` / `totalShops` / `created` / `skipped` / `failed` / `byReason`(JSON) /
  `shops`(JSON・店舗別の内訳＋失敗 error) / `error` / `startedAt` / `finishedAt`。集計値のみで PII を含まない。
  管理画面「取り込み実行履歴」/ `GET /import-runs?applicationId=`。
- **マルチソース**: 上記すべてが `source` を含むため、同一会社で `salonboard`/`rakuten_beauty`/`own_site` 等の
  レコードが衝突せず並列に保持できる（連携単位設定も source ごとに独立）。

## 退会（申請削除）時のマスク

`applications` 削除トランザクション（GTSS-20）に、`cancellations` の `customerNameKana` マスクと
`external_import_logs.payload` の `***` マスクを追加（既存方針に揃える / REQ-6,8）。

## バッチ / スケジュール

`src/batch.ts` の `action='salonboard-import'`。EventBridge Scheduler `cron(10 0 * * ? *)` + `Asia/Tokyo`
（JST 0:10。infra `modules/batch-compute` の `salonboard_import` スケジュール）。取り込みは通知を出さないため
`initClients()` 不要だが、外部 HTTP egress と認証情報復号の KMS 権限が必要。詳細は `docs/tech/batch-jobs.md`。

実行結果は `external_import_runs` テーブルへ記録するのに加え、CloudWatch Logs Insights で `shops[].failed` /
`error` を抽出・アラート化できるよう構造化ログ（JSON 1 行）も出力する（非同期 invoke では戻り値が破棄されるため
二重で可視化する）。スケジュール起動は `trigger='scheduled'`、API からの手動委譲は `trigger='manual'`。

### 手動取り込み（REQ-4/9・#23 で申請単位化）

`POST /cancellations/import`（運営のみ）。#23 で **`applicationId` 必須**の会社スコープ実行に変更（無指定は 4xx。
全社一括の手動実行は廃止し、会社詳細のキャンセル請求管理タブから**その会社のみ**起動する）。**dev/prod**は batch Lambda
（`action='salonboard-import'`, `trigger='manual'`）へ当該 `applicationId` をスコープに**非同期 Invoke**（`InvocationType='Event'`）
で委譲し、`202 { success, started:true }` を即返す。件数は同期返却できないため、admin は「取り込み実行履歴」
（`external_import_runs`）と一覧で結果を確認する。**local/test**は batch Lambda が無いため同期実行し件数を返す。
non-infra TODO: API Lambda ロールに batch 関数への `lambda:InvokeFunction` 権限が必要。

### 連携単位・店舗CRUD API（#23・すべて `requireAdmin`）

- `GET /admin/shops?applicationId=` — 当該会社の店舗一覧。
- `POST /admin/shops` `{applicationId, source?, loginId, password, shopName?}` — 店舗単位の作成（店舗単位verify→1Txで店舗＋
  店舗単位認証情報を保存・`linked=true`）。連携単位が `company` の `(会社,source)` は 4xx 拒否。
- `PUT /admin/shops/:id` `{shopName?, loginId?, password?}` — 表示名更新／再連携（同一店舗ID upsert）。
- `DELETE /admin/shops/:id` — 店舗削除（FK CASCADE で店舗単位認証情報も削除。`cancellations`/`external_import_logs` は
  `external_shop_id` が SET NULL で残る）。`company` は 4xx 拒否。
- `POST /admin/salonboard/shop-verify` `{applicationId?, loginId, password}` — 店舗単位ログイン検証のみ（単一店舗自動取得・
  店舗一覧は返さない・会社アカウント/取得不可はエラー）。
- `PUT /admin/applications/:applicationId/integration-unit?source=salonboard` `{unit}` — 連携単位の設定。lock 済みは 4xx
  （同一単位の再送は冪等成功）。
- `GET /admin/salonboard/integration/:applicationId` — レスポンスに `unit`/`unitLocked` を追加。
- 一覧3系統 `GET /cancellations|/import-logs|/import-runs` に任意 `?applicationId=` フィルター（無指定は全件＝後方互換）。

## テスト

- unit: `cancellation-status` / `crypto-secret`（envelope ラウンドトリップ）/ `salonboard-parser`（fixture。#23 で
  `extractHiddenStoreId`/`parseStoreTop` の店舗単位パースを追加）/ `cancellation-fee`（料率算出・境界）/
  `import-window`（抽出窓・契約日境界）/ `mask-imported-pii`。
- e2e（`app.request()` + fake client 注入 + fixture）: 連携検証/保存（`salonboard-integration`）/
  取り込みフィルタ・冪等・スキップ/ログ・PIIマスク・並列上限（`salonboard-import`）/ 送信・手動取り込み・
  バッチ dispatch・取り込みログ API（`salonboard-send`）/ 一覧店舗名分離（`cancellations-list-shop`）。
  **#23 追加**: 店舗単位 verify/save・店舗CRUD・連携単位/lock・一覧の `applicationId` フィルター・実行記録の会社単位化・
  マルチソース独立・リネーム回帰（`external_shops`→`shops`）。
- fixture（`src/__tests__/fixtures/salonboard/`）は実 HTTP 採取レスポンスを**PII マスクして**作成（生 PII は非コミット）。
  #23 で `group-top-single-store.html`（単一店舗の groupTop システムエラー）/ `store-top-single.html`（店舗TOP）を追加。
