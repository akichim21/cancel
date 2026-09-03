# サロンボード取り込み（技術）

サロンボード（ホットペッパービューティーの管理画面 `salonboard.com`）からキャンセル予約を取り込む
クローリング連携の技術仕様（GTSS-817）。

**通信トランスポートは 2 系統あり `SALONBOARD_TRANSPORT` で切り替える（#22）:**
- `http`（既定）: pure HTTP + cookie セッション + 軽量 HTML/JSON パース（headless ブラウザ不使用）。
  **Decodo プロキシにも対応**（undici `ProxyAgent` を fetch の `dispatcher` に渡す。proxy 未設定時は直結）。
  実測（2026-06-18）で **pure HTTP + JP 住宅プロキシは Akamai に遮断されず**、ログイン〜保護エンドポイントまで
  通常応答が返る（`doLogin` が CAPTCHA ではなくアプリのログイン結果ページを返す）。**Chromium 不要で Lambda が
  軽量**（memory/timeout 小・コールドスタート短）なため、HTTP + proxy が実運用の第一候補。
- `playwright`: 実ブラウザ（Chromium）で Akamai の JS を実行して `_abck` を正規取得し、**Decodo 住宅/モバイル
  スティッキープロキシ（JP 固定）経由**で通信する。Akamai が JS チャレンジへ昇格して pure HTTP で突破不能に
  なった場合の**フォールバック**として位置づける。
- **AWS Lambda の egress IP は Akamai にネットワークレベルで遮断される（実測: `salonboard.com` へ TimeoutError）
  ため、dev/prod では http/playwright いずれもプロキシ必須**（`requireSalonboardProxy` が未設定時 throw）。
  既定は `http` のまま。

どちらのトランスポートでも `SalonboardClient` interface（login / enterStore / 一覧 / 詳細）と取り込みロジック
（抽出窓・料率算出・冪等・PII マスク・理由ログ）は共通。レスポンスは生 HTML/JSON で返し、解析は
`utils/salonboard-parser`（純粋関数）へ委譲する（transport と parse の分離）。

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
| 4 | `POST /CNC/groupTop/forward` | 店舗コンテキストへ遷移 | `STORE_ID=H000…&designKbn=B`（**`B`=hair**）。**キレイは `designKbn=K` → `GET /KLP/top/`**（GTSS-817-kirei #25） |
| 5 | `POST /CLP/bt/top/` | 店舗トップ | `isViaLogin=true` |
| 6 | `GET /CLS/hair/reservations/init/` | SPA 初期化 | サーバ側 cached search を持つ。`?page=N` でページ位置を進める |
| 7 | GraphQL（検索条件 mutation → 一覧 query） | キャンセル予約一覧 | `POST /CLS/hair/api/graphql/{operationName}/` |
| 8 | `GET /CLP/bt/reserve/net/reserveDetail/?reserveId=…&rpsValue=7` | 予約詳細（HTML） | 店舗スコープ（誤店舗は `BPCL010V01`）。キャンセル料・電話・カナ氏名・規定はここでのみ取得 |

### 店舗抽出（REQ-1）

groupTop HTML の `id="biyouStoreInfoArea"` テーブル（ヘア区分）と `id="kireiStoreInfoArea"` テーブル（キレイ区分）の**両方**から店舗を抽出する。
**店舗名では判別せず区分テーブルで抽出する**（実例: 店名「GO TODAY シェアサロン 札幌Alba店」はキレイサロン区分 `kireiStoreInfoArea` に在籍するが、これも取り込み対象）。
各行から サロンID（`H000…`）＋店舗名を取得（`parseSalons`）。ヘア→キレイの順に並べ、両区分にまたがる重複店舗IDは先勝ち（ヘア優先）で 1 件に畳む。ログイン成功（`userid` 非空）かつ店舗 1 件以上で連携成功。

> **取り込み実行のキレイ対応（GTSS-817-kirei #25 で解決）**: 店舗一覧の抽出に加え、**日次/手動の取り込み実行もヘア＋キレイ両対応**。店舗種別は **`shop_integrations.salon_type`**（`'hair'`/`'kirei'`、媒体別連携リンク側で保持。#27 で `shops` から移設）で保持し、`importShop` が種別で遷移・一覧・詳細の取得経路を出し分ける（`clientOpsFor`）。請求・料率・スキップ理由分類のパイプラインはヘアと共通。ヘア既存経路は不変。

#### キレイ（KLP）経路（GTSS-817-kirei #25・2026-06-19 実機検証）

ヘアは React/Next.js + GraphQL（JSON）だが、**キレイは Struts/jQuery のサーバレンダリング HTML**で別系統。実機（店舗単位キレイアカウント）で確定した差分:

| | ヘア | キレイ |
|---|---|---|
| forward 区分値 | `designKbn=B` | **`designKbn=K`** |
| 店舗トップ | `POST /CLP/bt/top/` | **`GET /KLP/top/`** |
| 予約一覧（検索実行） | GraphQL（`/CLS/hair/api/graphql/…`、persisted query、JSON） | **`POST /KLP/reserve/reserveList/search`**（action+method。HTML テーブル） |
| 一覧絞り込み | GraphQL variables（`cancelStatus`） | フォーム POST `reserveDispStatusCdArray` ＋ Struts `org.apache.struts.taglib.html.TOKEN`（CSRF）＋ `storeIdForMultipleTabCheck`/`watchword`/`KMAGIC` |
| 期間指定 | `startDate`/`endDate` | `rsvDateFrom`/`rsvDateTo`（**`YYYYMMDD`**） |
| キャンセル状態コード | `['CANCEL','UNAUTHORIZED_CANCEL']` | **`reserveDispStatusCdArray`: `7`=お客様キャンセル / `9`=無断キャンセル**（他: 6=お断り/8=サロンキャンセル/10=自動キャンセルは対象外） |
| 予約詳細 | `GET /CLP/bt/reserve/net/reserveDetail/?reserveId=…&rpsValue=7` | **`GET /KLP/reserve/net/reserveDetail/?reserveId=…`** |

- **遷移**: 会社単位は `POST /CNC/groupTop/forward`（`STORE_ID&designKbn=K`）→ `GET /KLP/top/`（`enterKireiStore`）。店舗単位はログイン直後に `/KLP/top/` へ着地済み（`enterSingleKireiStore`）。
- **検索の実行先（重要）**: 検索ボタン `#search` は `$.shuhari.formSubmit("reserveList","search")` でフォーム action に `search` を付与し **`POST /KLP/reserve/reserveList/search`** へ送る。**base パス `/KLP/reserve/reserveList/` への POST は検索を実行せず初期フォーム（0 件）を返す**ため、必ず `/search` を付ける（本対応前は実運用で常に 0 件になっていた・実機確認済み）。
- **CSRF（Struts double-submit）**: フォーム再描画ごとに TOKEN が更新されるため、**`GET /KLP/reserve/reserveList/` でフォーム取得 → 同一セッションで `POST …/search`**。hidden は `extractKireiListFormFields` で丸ごと引き継ぎ、`buildKireiListBody` が期間＋状態(7,9)を上書き/付与する。
- **一覧の行構造（実機 HTML 準拠）**: `parseKireiReservationList` は結果テーブル（`reserveId=` リンクを含む `<table>`）を列見出し駆動でマッピング。実機の特徴に対応 —
  - 列見出しは `<br>` 由来の空白を含む（「来店 日時」「ステー タス」「お支払金額 （pt利用前）」）→ 空白除去して語マッチ。
  - **来店日時は `MM/DD`（年なし）** → 取得期間（`rsvDateFrom/To`）から年を補完（`resolveKireiVisitDate`。一覧はサーバ側で期間フィルタ済みのため一意に決まる）。
  - お客様名セルは 氏名 `<p>` ＋「(予約番号)」リンク → 予約番号は詳細リンクから取り、氏名から括弧表記を除去。
  - お支払金額は「`X 円(X)`」の二段表記 → 先頭の数値のみ採用。**キャンセル日時列は無い**（`updatedAt=null`、契約日判定は来店日でフォールバック）。
  - 一覧に支払い種別の確定ラベルは無いため `paymentType=null`（詳細が権威）。`isLocalPayment` は `現地決済` も許容。
- **詳細（実機 HTML で確認済み）**: `parseKireiReservationDetail` はヘアと同じ `<th>ラベル</th><td>値</td>`。予約番号/ステータス/支払い種別/**予約時キャンセル規定**/氏名(カナ)/氏名(漢字)/電話番号/合計金額/来店日時/受信日時 はヘアと同名ラベルで抽出成功。**HPB 経由予約はメールアドレス列が無い**（email は null、連絡は電話）。カナセルの「統合候補のお客様情報を確認する」等のリンク文言は `cleanName` で除去。
- **実機検証状況**: ログイン/着地/種別判定/店舗単位 verify、`POST …/search` の検索実行、一覧行パース（実 2 行）、詳細パース（実 1 件・規定あり）まで**実データでライブ検証済み**。ただし対象店舗に **お客様/無断キャンセル（状態 7,9）の予約が 0 件**のため、状態 7,9 で絞った実一覧行・キャンセル詳細（キャンセル処理日等）の確認のみキャンセル実績のある店舗で別途必要。
- **トランスポート**: HTTP/Playwright 両実装あり。**既定は `http`**（`SALONBOARD_TRANSPORT=playwright` で明示 opt-in。本節冒頭の記述に合わせる）。dev/prod はどちらの transport でも **Decodo プロキシ必須**（AWS の egress IP は Akamai に遮断されるため）。

### 店舗単位連携の単一店舗自動取得（REQ-8・#23・2026-06-13 実証）

店舗単位連携は **ログインの成否のみ**を確認し、単一店舗の店舗ID・店舗名を自動取得する（多店舗の一覧クロール・確認画面は使わない）。実アカウント2種で挙動を実証:
- **会社アカウント**（`CD34512`）: groupTop に `biyouStoreInfoArea`（14店舗）。`parseSalons`（ヘア＋キレイ）が **1件以上** → 会社アカウントと判定しエラー（連携単位の変更を促す・未保存）。
- **単一店舗アカウント**（`CD77768`）: `POST /CNC/groupTop/` は **システムエラー画面**（区分テーブル無し、`parseSalons`=0）を返すが、hidden `<input name="STORE_ID" value="H…">` に唯一の店舗IDを埋め込む。続けて `POST /CLP/bt/top/`（`isViaLogin=true`・forward 不要）で店舗TOPが返り、`sc_data` の `"storeid":"H…"` ＋ パンくず（`class="path"` 内 `{店舗名}様 / {店舗ID} / …`）から店舗ID・店舗名を取得（`parseStoreTop`）。

#### 判定フローと評価順（GTSS-890 で「2件以上」→「1件以上」へ厳格化）

判定は `decideShopVerify({ salonCount, effectiveUnit, hasMatchingLinkedShop })`（`salonboard-auth.service.ts` の
**DB 非依存の純粋関数**。DB 参照は呼び出し側が解決して boolean / 実効単位に落として渡す）に集約し、次の順で評価する。
先に成立した分岐で確定し、以降は評価しない。

| # | 条件 | 結果 |
|---|---|---|
| 1 | 実効単位が `company` | `company-unit-guard` → 既存の店舗追加ガードと同じ文言 |
| 2 | `parseSalons` が **2件以上** | `company-account` → 会社アカウント文言（1件が既存リンクと一致していても救済しない） |
| 3 | `parseSalons` が **1件** | 救済成立なら `adopt-listed-shop`（従来どおり採用）／不成立なら `company-account` |
| 4 | `parseSalons` が **0件** | `single-store` → 店舗TOP取得＋`parseStoreTop`（取得不可はエラー・未保存） |

ログイン失敗もエラー・未保存。**店舗一覧テーブルが描画されるのは会社アカウントのみ**（配下 1 店舗でも会社アカウント）
という前提に基づく厳格化で、ヘア区分・キレイ区分の店舗は合算して数える。

**評価タイミング**: 評価順 1 は `applicationId` と DB だけで確定しログイン結果に依存しないため、
`verifySalonboardShopLogin` は冒頭（**ログインより前**）で `getIntegrationUnit` を引いて fail-fast する。
使う予定のない資格情報をサロンボードへ送らず、API GW 29s / Lambda 30s の同期経路で既定 `maxAttempts=8` の
リトライ予算を空振りに使い切らないため。**ID/PW が誤っていてもこのガード文言が優先**される（保存経路の既存ガードと
同じ順序＝資格情報の正否で文言が変わらない。入口ごとの文言差は下記のとおり残る）。
評価順 2〜4 は `parseSalons` の結果に依存するのでログイン後。

> **保存経路では別文言が返る**: 上の評価順 1 の文言は `POST /admin/salonboard/shop-verify` のもの。保存経路は
> `verifySalonboardShopLogin` に到達する前に各サービスの既存ガードが先に発火する。
> - `POST /admin/shops`（`saveSalonboardShop`）: `会社単位連携が設定されています。店舗の追加はできません`
>   （評価順 1 と同一文言。`SHOP_VERIFY_COMPANY_UNIT_GUARD` を両方から参照する）
> - `PUT /admin/shops/:id`（`updateShop`）: `会社単位連携では連携情報は変更できません。名称・住所のみ編集できます`
>   （**別文言**。編集経路では名称・住所のみの更新は会社単位でも通すため、こちらのほうが実態に合う）
>
> いずれも単位ミスマッチ文言（「会社アカウントです／単位を変更してください」）は返らないため、REQ-1(a) の意図
> （会社単位運用の会社に誤って単位変更を促さない）は満たされる。`PUT` 経路の回帰は e2e `GTSS-890 T-35`。

**グランドファザリング（救済）**: 厳格化前に「店舗 1 件の会社アカウント」で登録された店舗の再連携が弾かれないよう、
`hasMatchingLinkedShop` が真のときだけ 1 件パスを通す。呼び出し側（`verifySalonboardShopLogin` の `context`）は
`applicationId` と `shopId` の両方があるときに限り
`shopIntegrationsRepo.findLinkedByApplicationShopSource(applicationId, shopId, source)`（**`linked=true` 条件込み**。
既存の `findByApplicationSourceStore` は `linked` を条件に含まないため要件を満たさない）を引き、その外部店舗IDが
取得できた 1 件と一致するかで判定する。**新規作成経路（`shopId` を渡さない）・会社/対象店舗の指定が無い単体検証・
未連携リンク・別店舗／別会社／別 source のリンクとの一致**はすべて false に落ちて救済されない。
DB には店舗一覧テーブル由来か否かの痕跡が残らず既存レコードから対象を特定できないため、この救済で
事前のデータ調査・マイグレーションを不要にしている。

**文言の出し分け**（`src/constants/salonboard-messages.ts`。実装内の重複排除のためだけの定数で、**テストからは
import しない**＝文言が変わっても検証が無効化されないようにする）: 会社アカウント判定時は `getIntegrationUnit` の
`unitLocked` で「連携単位を会社単位へ変更するよう促す文言」と「確定済みで変更できないため店舗単位ログインの入力を
促す文言」を出し分ける。会社を指定しない検証・存在しない会社IDでは確定状態を判定できないため前者を返す。
会社アカウント判定は**店舗名・店舗種別の妥当性判定より前**に評価する（店舗名が空でも会社アカウント文言になる）。

- パーサ: `extractHiddenStoreId`（hidden STORE_ID）/ `parseStoreTop`（店舗TOP）。fixture: `group-top-single-store.html` / `store-top-single.html`（PII置換済み）。

#### 同期検証のログイン予算（`resolveSalonboardVerifyRetry`。判定へ到達するための前提）

上の判定はすべて**ログイン成功が前提**で、ログインが予算内に終わらなければ運営には
「サロンボードへの接続に失敗しました。時間をおいて再度お試しください」しか返らない（＝連携単位ミスマッチの案内も出ない）。
dev 実測（2026-08-01・Lambda ログ）ではログイン 1 回に **7〜8s**、遅い Decodo 出口 IP を掴むと per-nav timeout（8s）で
1 試行が落ちる。**旧設定（総予算 20s）ではこの「1 回目が 8〜11s で失敗」の後に残る予算でログインが完走できず、
引き直しが必ず尻切れになって 20s 待たせた末に必ず接続失敗**になっていた（6 回中 2 回。運営から見ると
「新規作成では会社アカウントのエラーが出ない」）。次の 2 点で「引き直しが意味を持つ」状態にする。

| 設定 | Lambda（dev/prod） | ローカル | 意図 |
|---|---|---|---|
| `totalBudgetMs` | **24_000**（旧 20_000） | 180_000 | 8s 級の失敗 1 回の後でも 2 回目（7〜8s）が完走できる |
| `minAttemptBudgetMs` | **9_000**（新規） | 0（無効） | 残りがこれ未満なら引き直さず即返す（尻切れ試行で待たせない。1 回目は必ず実行） |
| `syncResponseBudgetMs` | **26_000**（新規） | 0（無効） | ログイン後の住所スクレイピング（best-effort）を諦める期限。API GW 29s 超過で**成功した検証を 504 で失わない** |
| `requestTimeoutMs` | 8_000 | 8_000 | 遅い IP は早く見切って新 IP へ引き直す（この方針は据え置き） |

すべて `SALONBOARD_VERIFY_*` env で上書き可能。住所は任意項目のため、期限切れ時は `null`（運営が手入力）で成功を返す。

#### 会社単位検証での単一店舗アカウント検出（GTSS-890 / REQ-2）

会社単位の verify（`verifySalonboardLogin`）は店舗 0 件を一律「店舗を取得できませんでした」で返していたため、
**単位ミスマッチ（店舗単位ログインの入力）と一般的な取得失敗が区別できなかった**。`detectAccountUnit({ html })`
（`salonboard-parser.ts`）で 0 件時のアカウント種別を判定し、2 分岐する。

- **判定シグナル**（**追加のネットワークリクエストを発行しない**。既存パーサの合成のみ）:
  1. `parseSalons` が 1 件以上 → `'company'`
  2. hidden `STORE_ID`（`extractHiddenStoreId`。単一店舗アカウントのシステムエラー画面。会社アカウントは空文字）→ `'shop'`
  3. 会社トップ HTML を店舗トップとして解析でき店舗IDが取れる（`parseStoreTop`。Playwright は単一店舗だとログイン直後に
     店舗トップへ着地するため会社トップ HTML の中身が店舗トップになる）→ `'shop'`
  4. いずれも取れない → `null`（判定不能）
- **シグナル競合時は会社アカウント判定を優先**（店舗一覧 1 件＋hidden `STORE_ID` が同時に取れるケース）。
- **着地 URL には依存させない**（HTTP トランスポートでは着地URLが常に空のため、判定は会社トップ HTML のみに依存）。
  トランスポート差分（HTTP=システムエラー画面／Playwright=店舗トップ着地）は 2 シグナルの OR で吸収する。
- `'shop'` → 「店舗単位のログイン情報です。連携単位を「店舗単位」に変更してから…」／`null` → 従来文言のまま。
  **`null` 分岐は潰さない**（HTML 変更による取得失敗を「店舗単位に変更してください」と誤案内すると運営が誤った単位へ切り替える）。
- 会社単位パネルは lock 済み会社では描画されないため、この経路に lock 分岐は持たない（`verifySalonboardLogin` の契約は不変）。
- キレイの単一店舗アカウントも会社トップはシステムエラーになりシグナルは種別非依存。文言に種別（ヘア／キレイ）は含めない。

#### 店舗種別の自動判定（GTSS-817-kirei #25・REQ-6・2026-06-18/19 実機検証）

店舗単位アカウントは区分テーブルを持たないため、`detectSalonType` が次のシグナルを優先順で評価して種別を判定する（実2アカウントで3シグナル相互一致）:
1. **着地URL名前空間**（最強）: ヘア=`/CLP/bt/top/` / キレイ=`/KLP/top/`（Playwright は `login()` が `landingUrl` を返す）。
2. **storeBaseInfo リンクの designKbn**: `?designKbn=B`→hair / `?designKbn=K`→kirei。
3. **区分マーカー**: `header_ico_bt`（`alt="ヘアサロン"`）→hair / `header_ico_kr`（`alt="キレイサロン"`）→kirei。
4. ナビ名前空間（補助）: `/CLP/` のみ→hair / `/KLP/` のみ→kirei。
- **いずれも取れない場合は `null`＝判定不能でエラー（保存しない）**。誤種別で取り込みを壊さないフェイルセーフ（REQ-6/AC-5）。
- 0件（単一店舗）の店舗TOP取得は種別に応じて出し分ける（ヘア=`fetchStoreTopHtml`(/CLP/bt/top/) / キレイ=`fetchKireiStoreTopHtml`(/KLP/top/)）。Playwright はログイン着地HTMLが店舗TOPなのでまず着地HTMLを `parseStoreTop` し、取れなければ再取得する。
- 会社単位は groupTop の区分テーブル（`biyouStoreInfoArea`=hair / `kireiStoreInfoArea`=kirei）で種別が決まり、`parseSalons` が各店舗に `salonType` を付与する。
- 注: `/CNC/mgr/storeBaseInfo/` は `?designKbn=` 無しの直接 GET だとシステムエラーになる（店舗トップのリンクが `?designKbn=B|K` を保持）。

#### 店舗住所の取得（storeInfoPreview スクレイピング・GTSS-817 #28・2026-06-25 実機検証）

店舗単位連携の verify が店舗（`{externalStoreId, shopName, salonType}`）の解決に成功した後、**同一セッションが生存している間（`client.close()` 前）**に掲載管理プレビュー（`storeInfoPreview`）から店舗住所を取得し、`ShopVerifyResult.shop.shopAddress` に入れる（`fetchShopAddressSafely`）。会社単位連携は対象外（`verifySalonboardLogin` 経路には差し込まない。店舗ごと forward のタイムアウト懸念）。

- **取得は素の `GET`（Struts TOKEN 不要）**。`プレビューを見る` ボタンは `org.apache.struts.taglib.html.TOKEN`/`STORE_ID`/`modified` 付き POST だが、ログイン済み店舗セッションでは素の GET でも同一の住所ページが返る（POST から TOKEN を抜いても 200・住所あり。店舗はセッション cookie から解決され POST した `STORE_ID` に依存しない）。`reflectTop` への遷移・クリックは不要。
- **媒体別 URL（末尾スラッシュ差）**: ヘア=`GET /CNB/preview/storeInfoPreview/`（末尾スラッシュ**あり**）/ キレイ=`GET /CNK/preview/storeInfoPreview`（**なし**）。`プレビューを見る` の `onclick`（`sendToStoreInfo(...,'/CNB/preview/storeInfoPreview/',…)` / `'/CNK/preview/storeInfoPreview'`）と一致させる。**逆のスラッシュだと住所無しの空（~3.8KB）ページが返る**。定数 `STORE_INFO_PREVIEW_PATH`（`salonboard-client.ts`）で媒体別に明示。
- **生 HTML は数値文字参照でエンコードされる**（住所セルが `&#21271;&#28023;&#36947;…`）。`fetch().text()` の生本文をパースするため**必ずデコードが要る**（ブラウザ描画＝Playwright `page.content()` では復号済みだが取得は生 HTTP）。`parseStoreAddress`（`salonboard-parser.ts`）が `住所` ラベルの `<th>`→`<td>` を抽出し、`decodeHtmlEntities`（10進 `&#NNNN;`・16進 `&#xNN;`・`&nbsp;`・`&amp;` 等）でデコード → タグ除去 → 制御文字/全角空白の正規化 → 連続空白の単一化 → 前後トリム → 最大長（200）トリムで 1 行に正規化。住所セル不在・デコード後空文字は `null`。
- **店舗コンテキストの確立**（HTTP トランスポート）: プレビュー GET は店舗コンテキスト確立後でないと空/エラーになる。0件パス（単一店舗）は `fetchStoreTopHtml`(/CLP/bt/top/) / `fetchKireiStoreTopHtml`(/KLP/top/) または Playwright のログイン着地で確立済み。**1件パスは forward を踏まず即 return するため、住所取得の前に解決済み `externalStoreId` で `enterStore`(designKbn=B) / `enterKireiStore`(designKbn=K) を呼んでコンテキストを確立**してから GET する。なお GTSS-890 以降、**1件パスは「店舗編集からの再検証で対象店舗自身の連携済みリンクと一致した」救済ケース専用**になった（新規作成経路では到達しない）ため、この住所取得順序の担保も救済成立ケースの e2e（`salonboard-store.test.js`）に置いている。
- **失敗許容（クリティカルパスにしない）**: 取得メソッドの失敗契約は「HTML を返す / CAPTCHA は型付き throw（`SalonboardCaptchaError`）/ 4xx は throw」。verify 側ラッパ（`fetchShopAddressSafely`）が try/catch で握りつぶし `shopAddress=null` とし、verify の `ok` は `false` にしない（住所はオプショナル。店舗ID・店舗名の解決には影響させない）。
- **空欄補完（空のときだけ）**: 保存（新規連携 `saveSalonboardShop` / 再検証 `updateShop`）の **同一トランザクション内**で `shopsRepo.fillAddressIfEmpty(shopId, shopAddress)` を呼ぶ。`shop_address = COALESCE(NULLIF(BTRIM(shops.shop_address), ''), :新規)` で **空（NULL/空文字/空白のみ）のときだけ**スクレイピング住所をセットし、**既存の実値（運営・サロンの手動編集を含む）は上書きしない**。スクレイピング住所が `null`/空白のときは no-op（変更なし）。保存/一覧レスポンス（`toShopResponse` / `GET /admin/shops`）に `shopAddress` を含む（機微情報は従来どおり返さない）。
- **取り込み（recurring import）には差し込まない**: 住所取得は連携の verify/保存時のみ。日次バッチ（`salonboard-import.service`）には追加しない（住所はほぼ不変で、毎回取得するとバッチ時間・失敗面が増える。空のときだけ補完なので再検証で随時埋まる）。
- パーサ/取得: `parseStoreAddress` / `decodeHtmlEntities`（`salonboard-parser.ts`）、`fetchStoreInfoPreviewHtml(salonType, externalStoreId)`（HTTP/Playwright 両実装。`salonboard-client.ts`）。fixture: `store-info-preview-hair.html` / `store-info-preview-kirei.html`（PII置換済み・数値文字参照エンコード）。
- 注: 店舗住所は**店舗の業務上の所在地であり顧客 PII ではない**ため、非本番の取り込み PII マスク（`mask-imported-pii.ts`）の対象外。ただし fixture 化時は CLAUDE.md の置換規約に従いダミーへ置換する。

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

> ⚠️ **来店時刻（`cancellations.start_time`）は取り込み経路によって `H:MM` / `HH:MM` が混在する
> （ゼロ埋め非保証）**。ヘア（GraphQL）経路は取得値をそのまま保存するため `9:00` が入り得る一方、
> キレイ（KLP）経路はゼロ埋めした値になる。この列を読む側は **`HH:MM` の固定長を前提にした切り出しを
> してはならない**（`H:MM` も受理する。顧客宛メール／SMS 本文の予約日時整形
> `cancel-billing-service-api/src/utils/appointment-datetime.ts` がこの前提で実装されている）。

詳細リクエストは N+1（1 予約 = 一覧1 + 詳細1）。**bot スコア抑制のため詳細取得は直列（同時 inflight=1）**
で 1 件ずつ順次処理し、各取得の間にランダム遅延（ジッタ）を挟む（#22 / REQ-3。旧 `pMapLimit` /
`DETAIL_CONCURRENCY=4` の並列は廃止）。ジッタ範囲は `SALONBOARD_IMPORT_JITTER_MS_*`（既定 800〜2500ms）。

### Akamai Bot Manager / Decodo プロキシ（#22）

`salonboard.com` は **Akamai Bot Manager**（`_abck`/`bm_sz`）で保護され、IP レピュテーション + bot スコアで
判定する。実測で確定した前提:
- **AWS の IP レンジはネットワークレベルで遮断**（dev batch Lambda の egress `35.72.34.85` から
  `salonboard.com` は TimeoutError、`example.com` は到達可）。→ AWS 直 egress では不可。
- 住宅/モバイル回線（JP）からは到達可。**pure HTTP は `_abck` を JS 実行で生成できない**が、実測（2026-06-18・
  JP 住宅プロキシ）では `GET /login/` → `POST doLogin` → 保護 SPA（`/CLS/hair/reservations/init/`）まで **200 で
  通常応答が返り Akamai のチャレンジに昇格しなかった**（doLogin は CAPTCHA ではなくアプリのログイン結果ページ）。
  → 現状は **HTTP + proxy が軽量で有効**。ただし IP レピュテーション/velocity 次第で CAPTCHA（ドラッグ&ドロップ型）へ
  昇格しうるため、突破不能化に備え `playwright` をフォールバックとして残す。

**`playwright` トランスポートの対策（`SalonboardPlaywrightClient`）:**
- **Decodo スティッキープロキシ（JP 固定）**: 単一ポート（既定 `gate.decodo.com:7000`）+ username パラメータ方式
  `user-<user>-country-jp-session-<runId>-sessionduration-<min>`。**1 ラン=1 セッション=1 IP**、ラン間で session
  （=runId）を更新して別 IP にする。`resolveSalonboardProxy({runId})` が構築（未設定時 fail-safe: local 直結 /
  dev・prod は throw）。ポート方式 30001-30010 は国がランダムで JP 固定できないため不採用。
- **実ブラウザで JS 実行**して `_abck` を正規取得（PDCA: 実アカウントでログイン成功・`userid` 取得を確認済み）。
- **一貫したフィンガープリント**: `locale=ja-JP` / `timezoneId=Asia/Tokyo` / 固定 UA + `sec-ch-ua` / viewport。
- **stealth**: `navigator.webdriver` を除去（自動化検知回避）。
- **アセット＋サードパーティホスト遮断**（`shouldAbortRequest`）: 画像/フォント/メディア（resourceType）に加え、
  **`*.salonboard.com` 以外のホスト（GTM/karte/GA/広告/Sentry 等）も `route.abort()`**。Akamai の JS と `_next`
  バンドルはファーストパーティ（`*.salonboard.com`。バンドルは `imgbp.salonboard.com`）なので残す。これで Decodo の
  実測転送量の**約 7 割（GTM 単体 10.8MB 等）を削減**。JS/CSS のファーストパーティは Akamai の JS 実行に必要なので通す。
- **セッション内アセットキャッシュ**（`SessionAssetCache`）: 後述「Decodo 転送量の内訳と削減」。route 傍受で
  効かなくなる HTTP キャッシュの代替を自前で持ち、同一 URL の再取得をなくす。
- **service worker を止める**（`serviceWorkers: 'block'`）: SW 発の通信は route 傍受の対象外で、登録されると
  遮断が素通しになる。取り込みに SW は不要。
- **ブラウザ自身のバックグラウンド通信を止める**（`NO_BACKGROUND_NETWORK_ARGS`）: component update /
  safebrowsing / autofill / 接続確認は**ページ発ではないため route では止められず**、proxy を流れていた
  （実測 google.com 3.9MB・content-autofill.googleapis.com 1.3MB・connectivitycheck.gstatic.com）。
- **人間的ペーシング**: 直列 + リクエスト間ジッタ。
- **CAPTCHA 検知**: login / 各ページ応答から検知したら `SalonboardCaptchaError` を投げ、当該ランを失敗として
  理由記録し中断（無限ループ・無駄な velocity を回避）。将来の自動解決はフック差し替えで対応。

**`http` トランスポートの proxy（`SalonboardHttpClient`）:** global fetch は env プロキシ（`HTTP_PROXY` 等）を
参照しないため、**undici `ProxyAgent` を fetch の `dispatcher`** に渡して Decodo 経由で egress する
（`Proxy-Authorization: Basic <base64(user:pass)>`＝`proxyAuthToken`、1 クライアント=1 スティッキー IP、
proxy 未設定時は直結）。全リクエストに `AbortSignal.timeout`（既定 `HTTP_REQUEST_TIMEOUT`=30s）を付与し、
超過/プロキシ失敗は `classifyHttpError` で `SalonboardTimeoutError`/`SalonboardProxyError` へ正規化する
（理由分類＋下記リトライ可能化）。undici は `package.json` 依存（v6・Node20 互換）で、必要時のみ動的 import
（直結時・proxy 未設定の local/test では読み込まない）。proxy 解決・fail-safe は playwright と共通
（`resolveSalonboardProxy`/`requireSalonboardProxy`）。

クライアントは `SALONBOARD_TRANSPORT` で選択（`createSalonboardClient({ runId })`）。テスト注入シーム
`setSalonboardClientFactory` は維持。取り込み実行ごとに選択トランスポート構成を 1 行ログ出力する
（`[salonboard-import] transport=… chromium=… proxy=…`＝`describeTransport`。proxy は host:port のみで認証情報は出さない）。
実プロキシでの実ログイン・実行頻度/CAPTCHA 頻度は人手確認（T-2/T-4/T-10/T-11）。

### ログイン失敗の診断情報（GTSS-817-qa / REQ-1）

`login()` は**失敗したときだけ** `SalonboardLoginResult.diagnostics` に診断情報を載せる（成功時は採取しない＝
正常系のオーバーヘッドと情報量を増やさない）。これが無かった頃は「認証情報が違う」「Akamai に遮断された」
「HTML 構造が変わった」「doLogin 応答が返ってこなかった」のどれかを**ログから一切判別できなかった**
（2026-08-06 dev: 会社単位 14 店舗が全件 `login_failed`。所要 72s が `NAV_TIMEOUT` 60s と整合するが、
doLogin 応答待ちの空振りか `networkidle` 不達かは不明だった）。

| 項目 | 内容 | playwright | http |
|---|---|---|---|
| `doLoginObserved` / `doLoginStatus` / `doLoginBodyLength` | doLogin 応答を観測できたか・HTTP ステータス・本文長 | `waitForResponse` の成否 | 常に観測（`true`） |
| `landingUrl` | ログイン後の着地 URL（**クエリ除去**） | `page.url()` | `null`（明示 POST のため着地なし） |
| `pageTitle` | `<title>`（`extractPageTitle`。`page.title()` は使わず両経路同一実装） | ○ | ○ |
| `finalHtmlLength` | 遷移後 HTML の長さ | ○ | ○（groupTop 応答） |
| `isLoginPage` | 応答がサロンボードのログイン画面か（**REQ-5 の主判定**） | ○ | ○ |
| `authErrorText` | 認証エラー文言（最大 100 文字。**実測では出ないため補助情報**） | ○ | ○ |
| `blockSignals` | WAF/bot 対策マーカー名の一覧（`Access Denied` / `Reference #` / `Incapsula` 等） | ○ | ○ |
| `timings` | `loginPageMs` / `clickMs` / `doLoginWaitMs` / `navigationMs` | 4 項目とも | `clickMs` は `null` |
| `bodySnippet` | タグ除去後の先頭 300 文字（PII マスク済み） | ○ | ○ |
| `loginIdMasked` | ログイン ID の先頭 2 文字のみ（`CD***`） | ○ | ○ |

**秘匿情報（必須）**: パスワードは**採取項目に存在しない**。ログイン ID はマスクし、本文抜粋は
`redactPiiText`（Sentry の PII スクラブと同一規約）でメール/電話を潰したうえで、本文へ echo された
ログイン ID 原文もマスク値へ置換する。純関数（`isLoginPageHtml` / `extractPageTitle` / `extractAuthErrorText` /
`detectBlockSignals` / `maskLoginId` / `stripUrlQuery` / `htmlSnippet` / `buildLoginDiagnostics`）は
`salonboard-client.ts` に置き、unit テストで固定する。

**ログイン画面判定（`isLoginPageHtml`）**: サロンボードは**認証失敗時にエラー文言を一切出さずログイン画面を
再表示する**（実採取 fixture `login-failure.html` に `エラー`/`正しく`/`一致` 等の文字列が 1 つも無い）。
したがって文言ではなく「ログインフォーム（`input[name="userId"]` + `input[name="password"]`）が返ってきたか」で
判定する。成功時の応答（`login-success.html`）は groupTop への auto-submit フォームのみでログインフォームを
持たないため、fixture 2 本で判定を確定できる。`sc_data.pagegroup1` は成功応答にも `'ログイン'` が入るので
判定には使わない。

### ログイン失敗のリトライ（residential 出口 IP のばらつき + 遮断疑い）

residential プロキシは**出口 IP の品質にばらつき**があり、遅い/タールピットされる IP を掴むと login の
`page.goto`（playwright）/ fetch（http）が**タイムアウト**する（実測: 同一コードで login が 9.6s 成功／
65.6s 激遅と IP 依存）。`loginWithRetry`（`salonboard-login.ts`）が新しいスティッキーセッション
（=新 runId=新 IP）で引き直す。同じ IP で粘らず**IP を変えて引き直す**のが要点。各試行間にジッタを挟む
（velocity 抑制）。会社単位・店舗単位の両ログイン経路に適用。

| 観測 | 判定 | 挙動 | 記録される理由 |
|---|---|---|---|
| `timeout` / `proxy_error` を throw | 一過性 | 新 IP で最大 3 回（`MAX_LOGIN_ATTEMPTS`）引き直す | `timeout` / `proxy_error` |
| `login.ok=false` かつ **doLogin 応答あり かつ ログイン画面が返った** | 認証拒否 | **引き直さず即失敗**（アカウントロック回避） | `login_failed` |
| `login.ok=false` かつ **doLogin 応答なし／非ログイン画面／遮断シグナル検出** | 遮断疑い | **新 IP で 1 回だけ**引き直す（`MAX_BLOCK_RETRIES=1`） | 復旧すれば成功。再失敗で `login_blocked` |
| `login.ok=false` かつ **診断が取れない**（旧クライアント / テスト fake） | 認証拒否扱い（フェイルセーフ） | 引き直さず即失敗 | `login_failed` |
| `CAPTCHA` を throw | — | 引き直さない（velocity を上げ bot スコアを悪化させるため） | `captcha_detected` |
| クライアント構築失敗（proxy 未設定等） | 恒久エラー | `loginWithRetry` の外へ伝播 | `proxy_error` 等 |

判定は `isBlockSuspected(diagnostics)` に閉じている。**診断が `undefined` のときは `false`（= 引き直さない）**
へ倒す: 逆にすると認証情報が誤っているアカウントを毎回 2 回叩くことになり、リトライを絞っている当初の目的
（アカウントロック回避）を損なうため。

検証経路（admin の「連携／検証」）は API Gateway 29s 配下なので `totalBudgetMs` / `minAttemptBudgetMs` が
設定されており、**残予算が 1 回のログインを完走できる量に満たなければ引き直さない**（`budgetExceeded`）。
取り込み（batch）は予算指定が無く、常に 1 回の引き直しが可能。`login_blocked` は**一過性理由**として扱い
`TERMINAL_IMPORT_LOG_REASONS` に含めない（翌日の日次取り込みで再試行）。

**Chromium 実行環境（REQ-5・採用: Lambda + `@sparticuz/chromium`）**: `selectChromiumSource(env)` が優先順
`CHROMIUM_EXECUTABLE_PATH` > `CHROMIUM_CHANNEL`（ローカルの system Chrome） > `AWS_LAMBDA_FUNCTION_NAME` あり
（= `@sparticuz/chromium` が brotli 圧縮 Chromium を `/tmp` へ展開し executablePath を返す） > playwright 同梱
で決める。`build.mjs` は `playwright-core` / `@sparticuz/chromium` を **external 化**（バンドル不可）、
`deploy-batch.sh` が両者を `node_modules` 同梱し、batch Lambda を memory 2048MB / timeout 600s /
ephemeral `/tmp` 1024MB へ引き上げ、`SALONBOARD_TRANSPORT` / `DECODO_*` を投入する。
**HTTP + proxy 運用（`SALONBOARD_TRANSPORT=http`）の場合は Chromium 不要**（`@sparticuz/chromium` を展開せず
メモリ/タイムアウトの引き上げも不要）で、`DECODO_*`（`DECODO_PROXY_HOST`/`DECODO_PROXY_PORT` + 認証）だけで動く。
dev/prod は `.env.development`/`.env.production` に `DECODO_PROXY_HOST`/`DECODO_PROXY_PORT` を記載しないと
`requireSalonboardProxy` が `proxy_error` で停止する。

### 店舗遷移・一覧取得の失敗リトライ（GTSS-817-qa / REQ-8）

ログインが成功した後も、**店舗コンテキストへの遷移（`enterStore` の `page.goto(/CLS/hair/reservations/init/)`）と
一覧取得**は同じ理由（遅い出口 IP・Akamai の一時的な引き延ばし）で `NAV_TIMEOUT`(60s) を超えて落ちる。
2026-08-08 dev の実測では **14 店舗中 13 店舗が成功する同一ラン**で 1 店舗だけこの遷移が timeout した。
`importShop` はここで即失敗していたため、その店舗は**予約一覧すら取得しておらず丸ごと未取り込み**（取り込みログ
`external_import_logs` にも 1 行も残らず、`external_import_runs.shops[].error` にだけ残る）になっていた。
取得窓は「実行日の 3 日前〜3 か月後」なので、**翌日の日次実行では窓の左端の予約が窓外へ落ちて取りこぼす**
（＝失敗した日の分は永久に取り込まれない）。

そこでログインと同じ思想で、**同じ IP で粘らず新しいスティッキーセッション（=新 runId=新 IP）で引き直して
1 回だけ再試行**する（`MAX_SHOP_FETCH_ATTEMPTS = 2`）。引き直しの前にはジッタを挟む（velocity 抑制）。

| 観測（`classifyFailure` の分類） | 挙動 | 記録される理由 |
|---|---|---|
| `timeout` / `proxy_error` | 新セッション（=新 IP）で**1 回だけ**再試行。成功すれば通常どおり取り込む | 復旧すれば失敗計上なし。再失敗で `timeout` / `proxy_error` |
| `captcha_detected` | 引き直さない（velocity を上げ bot スコアを悪化させるため。ログインと同じ） | `captcha_detected` |
| 理由分類できない失敗（誤店舗 forward の 4xx・HTML 構造変化・パース失敗） | 引き直さない（同じ結果にしかならない） | 分類なし（`shops[].error` のみ） |

- **引き直し上限は 1 実行（会社ラン）あたり 2 回**（`MAX_SESSION_RENEWALS_PER_RUN`）。全店舗が失敗するような
  事象は遮断・障害の可能性が高く、粘っても bot スコアを悪化させるだけなので、上限到達後は再試行しない
  （`session_renew_skipped` を出力し、`shops[].error` は「店舗取得失敗（セッション引き直し不可）: …」になる）。
  手動取り込みが動く batch Lambda の実行時間（600s）を食い潰さないための歯止めでもある。
- **会社単位**は引き直したセッションを**以降の店舗へ引き継ぐ**（1 ラン 1 セッションの原則を維持）。引き直しの
  再ログイン自体が失敗した場合は、セッションが無い状態で進むと店舗ごとに無意味なエラーが並ぶため、
  **残りの店舗を同じ理由（`login_failed` 等）で失敗計上して打ち切る**（`session_renew_failed` を出力）。
- **店舗単位**は当該店舗の認証情報で張り直す（他店舗には影響しない）。
- 試行回数は `shops[].attempts` に残る（1 回で済んだ店舗には付かない）。`shops[].error` は再試行した場合
  「店舗取得失敗（2回試行）: …」になる。
- 予約詳細取得の一過性失敗も**同じ引き直しで 1 回だけ再試行**する（後述「予約詳細取得の失敗リトライ」）。
  引き直し上限（`MAX_SESSION_RENEWALS_PER_RUN`）は店舗レベルと**共有**する。

### Decodo 転送量の内訳と削減（2026-09-03 実測）

Decodo は転送量課金で、ダッシュボードはホスト別合計しか出さない（実績: imgbp.salonboard.com 469MB /
salonboard.com 415MB / google.com 3.9MB / content-autofill.googleapis.com 1.3MB / sentry 104KB /
connectivitycheck.gstatic.com 1.8KB）。内訳を割るために `scripts/salonboard-traffic-probe.ts` を用意した
（CDP の `Network.loadingFinished.encodedDataLength` を URL / ホスト / 種別で集計する。実アカウントで
実サイトへ出るため、取り込み本体と同時に走らせないこと）。

**判明したこと**: 画像・フォント・メディア・サードパーティは既に遮断できていた。残っていた大半は
**同一 URL の再取得**で、ログイン + 1 店舗 + 詳細 3 件の最小フローで 2.38MB のうち **1.38MB（58%）**が
重複だった（`CLP/js/bt/common.js`・`jquery`・`CLP/css/bt/common.css` を毎ナビゲーション、Akamai のセンサ JS
`salonboard.com/<ランダム>/…`（`max-age=21600`・約 80KB）を 12〜14 回）。

原因は **Playwright の `route()` を有効にすると Chromium の HTTP キャッシュが無効化される**こと
（ローカル検証: 同一の `max-age` 付き JS を 4 ナビゲーションで、傍受ありは 4 回 782KB / 傍受なしは
1 回 196KB + キャッシュヒット 3。`launchPersistentContext` にしても傍受が有効なら効かない。CDP の
`Network.setBlockedURLs` はキャッシュを無効化しない）。

対策は**傍受を残したままキャッシュを自前で持つ**こと（`SessionAssetCache`）。傍受をやめると
サードパーティ遮断（GTM 等）が失われ、そちらの方が高くつく。

| 項目 | 方針 |
|---|---|
| キャッシュ対象 | `GET` / `200` / resourceType が `script` `stylesheet` / `Cache-Control` に `max-age>0`（`no-store`・`no-cache` は対象外） |
| 対象外 | HTML（予約詳細は `no-store`）・GraphQL 等のデータ取得・遮断済みの画像/フォント/メディア |
| キー | クエリ込みの URL。2 回目以降は `route.fulfill` で返す（`x-sb-asset-cache: hit` を付与＝実転送でない印） |
| 上限 | 1 エントリ 4MB / セッション合計 48MB（超過は挿入順に破棄）。`close()` で解放 |
| 期限 | サーバの `max-age` を尊重（期限切れは再取得） |

実ブラウザは `max-age` を尊重して再取得しないため、キャッシュする方が挙動としても自然（毎回引き直す方が
むしろ不自然）。**実測: 同一フローで 2.38MB → 0.68MB（-71%）**、所要時間も 30s → 18s に短縮した。

### 予約詳細取得の失敗リトライ

予約詳細（`page.goto(/CLP/bt/reserve/net/reserveDetail/?reserveId=…)`）も同じ理由で `NAV_TIMEOUT`(60s) を
超えて落ちる。2026-09-03 dev の実測では、**同一ランで 21 予約を処理できている店舗**の中で 1 予約だけ詳細
取得が timeout し、その予約は取り込みログに `timeout` で残ったうえ、**店舗サマリが failed=1 になって運営へ
「一部失敗」通知**が飛んだ。同じ予約はその 5 分後、同じランの別セッション（別出口 IP）では取得できており、
恒久障害ではなく**出口 IP 起因の一過性失敗**だった（直近 14 日で 11 件・うち 7 件が同一店舗）。

そこで店舗レベルと同じく、**新しいスティッキーセッション（=新 IP）へ引き直して 1 回だけ再試行**する
（`MAX_DETAIL_FETCH_ATTEMPTS = 2`）。引き直しの前にはジッタを挟む。

| 観測（`classifyFailure` の分類） | 挙動 | 記録される理由 |
|---|---|---|
| `timeout` / `proxy_error` | 新セッション（=新 IP）で**1 回だけ**再試行 | 復旧すれば失敗計上なし。再失敗で `timeout` / `proxy_error` |
| `captcha_detected` | 引き直さない（velocity を上げないため。ログイン・店舗遷移と同じ） | `captcha_detected` |
| 理由分類できない失敗（パース失敗・HTML 構造変化・誤店舗 4xx） | 引き直さない | `detail_fetch_failed` |

- **引き直したセッションは店舗コンテキストに入っていない**（ログイン直後の状態）。詳細ページは店舗
  コンテキスト前提なので、再試行の前に `enter` からやり直す。入り直しに失敗した場合はその状態を持ち越し、
  **次の予約の詳細取得前に入り直す**（コンテキストが外れたまま別店舗のデータ・4xx を掴まないための不変条件）。
- 引き直し上限（`MAX_SESSION_RENEWALS_PER_RUN` = 2 回/実行）は**店舗レベルと共有**する。上限到達後は
  再試行せず、従来どおりその予約を失敗として確定する（`session_renew_skipped`）。1 実行で増える追加
  ナビゲーションは最大 2 回分に収まり、手動取り込みが動く batch Lambda の 600s も食い潰さない。
- 失敗が確定した予約は従来どおり `external_import_logs` に理由付きで残り、**翌日の日次実行で再評価される**
  （非 terminal reason）。取り込み済みになった時点で当該ログ行は削除される。

**ログイン成功判定（単一店舗アカウント対応）**: `userid` は doLogin 応答に載る。会社単位は遷移先 groupTop にも
残るが、**単一店舗アカウントは login 後 `/CLP/bt/top/`（店舗トップ）へ遷移し最終 HTML に userid を持たない**。
そのため Playwright 実装は `page.on('response')` で doLogin 応答本文を捕捉して userid を判定する（遷移先 HTML へ
フォールバック）。実機 T-11 でこの false-negative を検出・修正。

**T-11 実機確認（end-to-end）**: 単一店舗アカウントで Decodo JP プロキシ + 実 Chromium 経由に login →
enterSingleStore → 一覧（本番窓で実キャンセル取得）→ 予約詳細パース（支払い種別/規定/氏名/連絡先すべて取得）まで
成功を確認済み。AWS 直 egress は Akamai 遮断のため不可（実測）で、プロキシ経由前提の設計どおり到達できる。

## 取り込みロジック（REQ-2/3）

1. **連携済みの店舗を列挙する**。対象は `shops` ではなく **`shop_integrations.linked=true`**（媒体別連携リンク）で、
   `findAllLinkedWithShop()` がリンクと店舗マスタを JOIN して返す（id は `shops.id`＝当サービスの店舗ID。認証情報解決・
   `enterStore` 等はこの id をキーに従来どおり）。連携なし店舗（`shop_integrations` 行を持たない店舗）は対象外。
   これを会社（`applicationId`）ごとにグルーピング（1 会社 1 ログイン）。
2. 会社ごと: `external_integrations` から `loginId` + 復号した password でログイン。失敗時は当該会社の全店舗を失敗計上。
3. 店舗ごと（順次・失敗は他店舗を止めない / AC-21）: `enterStore`（forward）→ 一覧取得（全ページ）。
   - 抽出窓: 来店予定日が「実行日(JST)の3日前〜3か月後」かつ「契約日（`applications.createdAt` の JST 日付）より後（同日含まず）」（`import-window.ts`）。
   - **早期スキップ（N+1 回避）**: 作成済み（`cancellations` の `externalReservationId`）or 確定理由ログ済み
     （`external_import_logs` の terminal reason）の予約は**詳細取得前にスキップ**。
   - 現地払い以外（list の `paymentType`）は詳細を取らず確定スキップ＋ログ（`not_local_payment`）。
4. 詳細取得（**直列・各取得の間にジッタ**。#22 / REQ-3）→ フィルタ → 作成 or スキップ:
   - 詳細取得失敗 → `detail_fetch_failed`（**一過性・翌日リトライ**＝terminal でない）。
   - 現地払い以外（詳細で再確認）→ `not_local_payment`。
   - 予約時キャンセル規定なし（`-`）→ `no_policy`。
   - 元データのメール・電話が両方無し → `no_contact`。
   - 料率解釈不能 → `rate_unparseable`。
   - それ以外 → **非 prod PII マスク**して `pre_send`（送信前）で `cancellations` を作成。
   - ブラウザ/プロキシ起因の失敗（#22 / REQ-7）は理由分類して記録（いずれも一過性=非 terminal・翌日リトライ）:
     `captcha_detected`（CAPTCHA 昇格）/ `proxy_error`（プロキシ接続失敗）/ `timeout`（通信タイムアウト）/
     `login_failed`（`userid` 取得できず＝認証拒否）/ `login_blocked`（**ログイン遮断疑い**。GTSS-817-qa。
     doLogin 応答なし・非ログイン画面・遮断シグナルのいずれかで、新 IP の引き直しでも復旧しなかった）。
     login・店舗遷移（enterStore/一覧取得）・詳細取得のいずれの経路でも `classifyFailure` で分類し、
     会社別実行結果の `shops[].reasonCode` / `byReason` と取り込みログ `reason` に残す。`login_blocked` は
     admin の実行履歴で「ログイン遮断疑い」ラベルとして表示される（未知コードはコードのままフォールバック）。
5. 結果（対象店舗数・店舗別 作成/対象外スキップ/失敗 件数）を集計して返す。あわせて実行単位の結果を
   `external_import_runs` に必ず記録する（`triggerType`・店舗別内訳・失敗 error を含む）。店舗ループ以前の
   致命的失敗（店舗一覧取得失敗等）も握り潰さず `ok:false` で記録する（記録自体の失敗は取り込みを壊さない）。

## ログイン失敗の可観測性（GTSS-817-qa / REQ-2,3,4）

`login_failed` は例外を投げないため、以前は **CloudWatch を人が見に行かない限り誰も気づけない**状態だった
（Sentry にも Slack にも何も届かない）。さらに**会社単位連携では 1 回のログイン失敗が全店舗へ複製される**ため、
14 店舗分の同一メッセージが並ぶだけで原因が読み取れなかった。現在は次の 3 経路へ出す。

### 1. 構造化ログ（CloudWatch Logs Insights）

`markCompanyShopsFailed`（`salonboard-import.service.ts`）が **接頭辞を付けない純 JSON 1 引数**で
`console.error` する（Logs Insights が自動パースできるようにするため。`[salonboard-import] {...}` のように
前置きを付けると JSON として解釈されない）。

- **会社単位連携**: 店舗ごとではなく**会社ごとに 1 行**（`shopId` / `externalStoreId` は `null`、
  `affectedShops` に影響店舗数）。
- **店舗単位連携**: 従来どおり**失敗した店舗ごとに 1 行**（`shopId` / `externalStoreId` を含む）。
- **店舗遷移・一覧取得**（`importShop`）も同じ純 JSON 形式で出す（REQ-8）。`event` は
  `shop_fetch_retry`（一過性失敗を検知し引き直す）/ `shop_fetch_recovered`（再試行で成功。`console.log` 側）/
  `shop_fetch_failed`（失敗確定）で、`attempt` / `maxAttempts` と店舗 ID を含む。引き直しの可否は
  `session_renew_skipped`（1 実行あたりの上限に到達）/ `session_renew_failed`（再ログイン失敗）で追える。
- **予約詳細取得**の引き直しも同じ形式で出す。`event` は `detail_fetch_retry` / `detail_fetch_recovered`
  （`console.log` 側）で、店舗 ID に加えて `externalReservationId` と `maxAttempts`（=2）を含む。
  失敗確定時の行（`[salonboard-import] detail fetch failed store=… reservation=… reason=…`）は
  **既存のログ形式のまま**変えない（予約単位で取り込みログにも残るため）。
- 連携設定未完了（`reasonCode` なし）は既知状態なので出力しない（admin の `shops[].error` には出る）。

```json
{"logger":"salonboard-import","event":"login_failure","source":"salonboard","unit":"company",
 "applicationId":"app_1780047468842","trigger":"manual","route":"lambda","reason":"login_blocked",
 "reasonLabel":"ログイン遮断疑い","affectedShops":14,"shopId":null,"externalStoreId":null,
 "message":"サロンボードへのログインが遮断された可能性があります","diagnostics":{ ... }}
```

`event` は理由に依存しない中立名（`login_failure`）で、実理由は `reason` に入る。`event` を軸に絞ったとき
`login_blocked` を認証拒否と誤読しないため。`route` は `lambda` / `ecs` / `local`
（`resolveExecutionRoute`。手動取り込みは batch Lambda、日次は batch ECS）。

### 2. Sentry

`captureLoginFailureToSentry` が `Sentry.captureMessage` で送る。タグ・fingerprint の規約は
`docs/tech/sentry.md` の「取り込み失敗の captureMessage」を参照。送信失敗は握り潰し、取り込みを止めない。

### 3. Slack

`runSalonboardImport` の末尾で、**失敗のあった会社ごとに 1 通**投稿する（#64。1 実行あたり個別 10 通 +
超過分の集約 1 通が上限）。全件成功した会社と、連携設定が未完了なだけの会社は投稿しない。会社ループを
最後まで回せなかったときは「バッチが実行できませんでした」の 1 通のみで、会社ごとの通知とは**排他**。
本文の組み立ては `src/services/salonboard-import-notify.ts` の純関数に閉じ込めてある。
書式・エラー種別の写像・対応の目安のマトリクス・送信経路・環境変数は `docs/tech/alerting.md` を参照。

> **`IMPORT_LOG_REASON` に新しい失敗理由を追加するときは、通知のエラー種別写像テーブル
> （`IMPORT_ERROR_KIND_BY_REASON` / `IMPORT_ERROR_DETAIL_TEXTS` / `IMPORT_FAILURE_REASONS`）への追記が必須**。
> 未追記だと「その他（要調査）」として鳴り続ける（誤って一時的エラーとして黙殺されるより安全側に倒した設計）。

> **通知の写像入力は失敗系コードに限る**。会社別集計の `byReason` は 14 コード全部を 0 で初期化して加算する
> ため、正常な実行でもスキップ系理由（現地払い以外・規定なし・対象期間外など）に件数が入る。これを写像へ
> 流し込むと未知コードとして「その他」へ倒れ、一時的エラーだけで落ちた会社が毎回「要調査」で鳴る。

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

GTSS-817 #27 で **店舗マスタ（`shops`）と媒体別連携（`shop_integrations`）を分離**した。`shops` は純粋な店舗台帳
（連携の有無に依らず存在でき、1 店舗 × N 媒体を表現可能）、`shop_integrations` が媒体ごとの連携リンクを持つ。

### FK 命名規約（重要）

- `shop_id` = **当サービスの店舗（`shops.id`）への FK**。`cancellations` / `external_import_logs` /
  `external_integrations` で使う。
- `shop_integrations.external_store_id` = **外部媒体側の店舗ID**（サロンボードの `H…`）。
- 媒体は専用カラム名ではなく **`source` + `external_store_id` の組**で表現する（source 駆動を維持）。

### テーブル

- `cancellations`:
  - 発生店舗 `shopId`(FK→`shops.id`)。**表示**（一覧・詳細の店舗名/住所）は `shopId` から解決した店舗マスタを使う
    （`storeName`/`storeAddress` = `shops` JOIN）。店舗は**論理削除のみ**（`deletedAt`）で物理削除しないため `shopId` は
    保持され、削除後も JOIN で解決できる（FK の `ON DELETE SET NULL` は安全弁で通常フローでは発火しない・#27）。
  - 作成時点の `shopName` / `shopAddress` **スナップショット**は**送信本文（SMS/メール/Stripe 明細）の凍結用**で、
    **手動・取り込みの両経路**で保存する。表示には使わない（`storeName`/`storeAddress` と二重表示しない）。
  - 取り込み列: `source` / `externalReservationId` / `reservationStatus` / `cancellationType` / `paymentType` /
    `cancellationPolicy` / `receivedAt` / `customerNameKana` / `externalCanceledAt`（キャンセル日。サロンボード一覧の
    更新日時。`createdAt`＝取り込み実行日とは別。一覧・詳細・送信モーダルの「キャンセル日」表示に使う。手動作成は NULL）。
  - **冪等キー**: `(shop_id, external_reservation_id)` の部分ユニーク（`WHERE external_reservation_id IS NOT NULL`）。
    手動作成（`external_reservation_id` NULL）は NULLS DISTINCT で対象外。別店舗の同一予約 ID は別請求として作成される。
- `shops`（店舗マスタ）: **`id` / `application_id` / `shop_name` / `shop_address` / `created_at` / `updated_at`** のみ。
  会社→店舗 1:N。`source` / `external_store_id` / `salon_type` / `linked` は**持たない**（#27 で `shop_integrations` へ移設）。
  **連携が 0 件の店舗（連携なし店舗）も存在できる**。運営（店舗単位）・サロン本人ともに作成・更新・削除する（店舗 CRUD API）。
- `shop_integrations`（#27 新規・媒体別連携リンク）: `id` / `shop_id`(FK→`shops.id` **ON DELETE CASCADE**) /
  `application_id`(FK→`applications`) / `source` / `external_store_id`（外部媒体側の店舗ID）/ `salon_type`（`hair`/`kirei`）/
  `linked` / timestamps。
  - **`UNIQUE(shop_id, source)`**: 1 店舗 × source ごとに最大 1 リンク。
  - **`UNIQUE(application_id, source, external_store_id)`**: 再連携の冪等キー（旧 `shops`／`external_shops` から移設。
    会社内で同一外部店舗IDの二重連携を防ぐ）。
  - 会社単位の再連携時は今回取得されなかった既存リンクを `linked=false` にする。1 会社 × N 媒体・1 店舗 × N 媒体を表現。
- `external_integration_settings`（連携単位）: `(application_id, source)` PK・`unit`（`company`/`shop`）。**行が無い場合は
  既定 `shop`**。lock（変更不可）はカラムを持たず**導出**する: 当該 `(会社, source)` の
  `external_integrations.linked=true`（会社単位の連携済み認証情報）**または** `shop_integrations.linked=true`（連携済み店舗）
  が 1 件でもあれば lock（`unitLocked = external_integrations.existsLinked OR shop_integrations.anyLinked`）。
  `getEffectiveUnit` は従来どおり（settings=`company` または会社単位の linked 認証情報あり → `company`、それ以外 `shop`）。
- `external_integrations`（認証情報・**#27 で構造は不変**）: `loginId` + `encryptedSecret`（envelope）+ `linked` +
  nullable `shop_id`（FK→`shops.id` ON DELETE CASCADE）。`shop_id`（=`shops.id`、NULL=会社単位行）で
  キーされる。会社単位は `shop_id IS NULL` の 1 行、店舗単位は店舗ごとに 1 行。
  UNIQUE は `(application_id, source, shop_id)` **NULLS NOT DISTINCT**（PG15+。会社行の NULL を 1 行に制約）。
  パスワードは AES-256-GCM 暗号化のまま・レスポンスには出さない（`hasPassword` のみ）。
- `external_import_logs`: 対象外/スキップの生データ（payload JSON）+ 理由 + 対象期間。`application_id` カラムで会社
  フィルター可。`shop_id`(FK→`shops.id` **ON DELETE SET NULL**)。`(shopId, externalReservationId)`
  UNIQUE で upsert（重複排除）。顧客 PII を含むため退会時マスク対象。
  作成成功（リトライ成功）時は当該予約のログ行を削除し、キャンセル一覧との矛盾を解消する。
- `external_import_runs`: **取り込みの実行単位ログ**。#23 で **会社（＋source）ごとに1行**（nullable `application_id`
  ＋index。過去行は NULL のままバックフィルせず、`?applicationId=` フィルター時は除外・無指定では全社表示）。
  `triggerType`（`scheduled`=日次自動 / `manual_admin`=運営の手動 / `manual_salon`=サロン本人の手動 /
  `manual`=旧値。#64 で細分化。カラムは自由文字列で CHECK 制約が無いためマイグレーション不要・既存行は不変）/
  `ok` / `totalShops` / `created` / `skipped` / `failed` / `byReason`(JSON) /
  `shops`(JSON・店舗別の内訳＋失敗 error) / `error` / `startedAt` / `finishedAt`。集計値のみで PII を含まない。
  管理画面「取り込み実行履歴」/ `GET /import-runs?applicationId=`。
- **マルチソース**: 上記すべてが `source` を含むため、同一会社で `salonboard`/`rakuten_beauty`/`own_site` 等の
  レコードが衝突せず並列に保持できる（連携単位設定も source ごとに独立。1 店舗が複数 source の連携を持てる）。

### Migration 0012（`src/db/migrations/0012_gtss817_shop_integrations.sql`）

参照保全のため **`shops.id` は作り直さない**。手順:
1. `shop_integrations` を作成（上記 UNIQUE 制約付き）。
2. 既存 `shops` から **1:1 backfill**（`source` / `external_store_id` / `salon_type` / `linked` を値保全して移送）。
3. `shops.shop_address` を追加。
4. `shops` の旧列（`source` / `external_store_id` / `salon_type` / `linked`）と旧 UNIQUE を削除。

逆 migration は `src/db/migrations/rollback/0012_*.down.sql`。

### 店舗削除の連鎖（論理削除）

店舗削除（`deleteShop`）は **`shops` 行を物理削除せず論理削除**（`deletedAt` をセット）する。これにより:
- `cancellations` / `external_import_logs` の `shop_id` は **保持される**（`shops` 行が残るため FK SET NULL は発火しない）。
  一覧・詳細・送信本文の店舗名/住所は `shop_id` JOIN で解決し続ける（`getById`・一覧 JOIN は `deletedAt` を弾かない）。
- `shop_integrations`・店舗単位 `external_integrations`（暗号化認証情報）のみ **物理削除**（削除済み店舗に機微情報を残さない）。

> FK 上は `cancellations`/`external_import_logs`.`shop_id` を `ON DELETE SET NULL`、`shop_integrations`/
> `external_integrations`.`shop_id` を `ON DELETE CASCADE` で定義しているが、通常フローは論理削除のため
> `cancellations` 側の SET NULL は発火しない（DB レベルの安全弁）。

## 退会（申請削除）時のマスク

`applications` 削除トランザクション（GTSS-20）に、`cancellations` の `customerNameKana` マスクと
`external_import_logs.payload` の `***` マスクを追加（既存方針に揃える / REQ-6,8）。

## バッチ / スケジュール

`src/batch.ts` の `action='salonboard-import'`。EventBridge Scheduler `cron(10 0 * * ? *)` + `Asia/Tokyo`
（JST 0:10。infra `modules/batch-compute` の `salonboard_import` スケジュール）。取り込みは**顧客向けの**通知
（SES / Twilio）を出さないため `initClients()` 不要だが、外部 HTTP egress と認証情報復号の KMS 権限が必要
（運営向けの Slack 通知は `fetch` 直叩きで `initClients()` に依存しない）。詳細は `docs/tech/batch-jobs.md`。

実行結果は `external_import_runs` テーブルへ記録するのに加え、CloudWatch Logs Insights で `shops[].failed` /
`error` を抽出・アラート化できるよう構造化ログ（JSON 1 行）も出力する（非同期 invoke では戻り値が破棄されるため
二重で可視化する）。スケジュール起動は `trigger='scheduled'`、API からの手動委譲は呼び出し元に応じて
`trigger='manual_admin'`（運営）/ `'manual_salon'`（サロン本人）（#64。`resolveManualImportTrigger`）。
旧値 `'manual'` は後方互換で読むだけ（通知・画面とも「手動実行」「手動」と表示する）。

### 手動取り込み（REQ-4/9・#23 で申請単位化）

`POST /cancellations/import`（運営のみ）。#23 で **`applicationId` 必須**の会社スコープ実行に変更（無指定は 4xx。
全社一括の手動実行は廃止し、会社詳細のキャンセル請求管理タブから**その会社のみ**起動する）。**dev/prod**は batch Lambda
（`action='salonboard-import'`, `trigger='manual_admin'`）へ当該 `applicationId` をスコープに**非同期 Invoke**（`InvocationType='Event'`）
で委譲し、`202 { success, started:true }` を即返す。件数は同期返却できないため、admin は「取り込み実行履歴」
（`external_import_runs`）と一覧で結果を確認する。**local/test**は batch Lambda が無いため同期実行し件数を返す。
non-infra TODO: API Lambda ロールに batch 関数への `lambda:InvokeFunction` 権限が必要。
**この非同期 Invoke 自体が失敗した場合**（権限不足・スロットリング・関数不在）は実行履歴を failed で解放し、
Slack へ「バッチが実行できませんでした」を投稿する（#64 / REQ-7）。取り込みが 1 秒も動いていないため、
従来は運営に API のエラー応答しか見えなかった。サロン本人の手動取り込み（`POST /salonboard/import`・
`trigger='manual_salon'`）も同じ扱い。

### 運営・連携単位・店舗CRUD API（`requireAdmin`）

店舗マスタと連携が分離（#27）したため、店舗 CRUD は**連携なし店舗の作成**と**後付け連携**を扱う。

- `GET /admin/shops?applicationId=` — 当該会社の店舗一覧（店舗マスタ＋連携リンクの有無）。
- `POST /admin/shops` `{applicationId, shopName, shopAddress?, source?, loginId?, password?}` — 店舗作成。
  - `loginId`/`password` **省略可**＝**連携なし店舗**（店舗名必須・住所任意で店舗マスタのみ作成）。
  - `loginId`/`password` あり＝店舗単位 verify → 1Tx で店舗マスタ＋`shop_integrations`（`linked=true`）＋店舗単位
    認証情報を保存。**初回連携**は自動取得した外部店舗IDをそのまま採用（一致チェックなし）。
  - 連携を付与するケースで連携単位が `company` の `(会社,source)` は 4xx 拒否。
- `PUT /admin/shops/:id` `{shopName?, shopAddress?, loginId?, password?}` — 名前/住所更新（連携なし・連携済みとも可）／
  後付け連携・再連携。**再連携**は自動取得した外部店舗IDが**既存リンクの外部店舗IDと一致**することを要求し、別店舗なら拒否。
  会社内の**別店舗が同一外部店舗IDを既に連携済み**なら拒否（`UNIQUE(application_id, source, external_store_id)`）。
- `DELETE /admin/shops/:id` — 店舗削除（**論理削除**＝`deletedAt`。`shop_integrations`・店舗単位認証情報のみ物理削除。
  `cancellations`/`external_import_logs` の `shop_id` は保持され店舗名/住所は JOIN で解決し続ける）。連携単位 `company`
  は 4xx 拒否（クロール由来）。
- `POST /admin/salonboard/shop-verify` `{applicationId?, shopId?, loginId, password}` — 店舗単位ログイン検証のみ（単一店舗自動取得・
  店舗一覧は返さない・会社アカウント/取得不可はエラー）。GTSS-890 で `applicationId` を**実際に使用**するようになり
  （連携単位の確定状態による文言の出し分け・救済判定）、任意の**対象店舗 ID `shopId`** を追加した（店舗編集からの
  再検証でのみ管理画面が送る。作成では送らない＝救済対象外）。レスポンス形式は不変。
  **保存経路（`POST /admin/shops` / `PUT /admin/shops/:id`）の内部再検証では body の識別子を使わず、サーバ側で解決した
  会社 ID（引数 / `shops.applicationId`）とパスの店舗 ID を渡す**（マスアサインメント防止）。ステータス・形式は不変（400）。
- `PUT /admin/applications/:applicationId/integration-unit?source=salonboard` `{unit}` — 連携単位の設定。lock 済みは 4xx
  （同一単位の再送は冪等成功）。lock は `external_integrations.linked` または `shop_integrations.linked` から導出。
- `GET /admin/salonboard/integration/:applicationId` — レスポンスに `unit`/`unitLocked` を追加。
- 一覧3系統 `GET /cancellations|/import-logs|/import-runs` に任意 `?applicationId=` フィルター（無指定は全件＝後方互換）。

### サロンポータル 施設（店舗）管理 API（#27・`requireAuth`・自社スコープ）

サロン本人が自社の**連携なし店舗**を管理する。連携の認証情報・外部媒体側の店舗ID・連携操作は扱わない。

- `GET /shops` — 自社店舗一覧。
- `POST /shops` `{shopName, shopAddress?}` — 連携なし店舗の作成。**連携単位を問わず作成可**（会社単位会社でも可）だが、
  サロン作成の連携なし店舗は**取り込み対象外の独立店舗**。
- `PUT /shops/:id` `{shopName?, shopAddress?}` — 名前/住所編集（連携済み店舗も名前/住所のみ編集可）。
- `DELETE /shops/:id` — 連携なし店舗の削除。**連携済み店舗は削除不可**（サロンボード連携操作も不可）。
- レスポンスは **`{id, shopName, shopAddress, linked, …}` のみ**＝連携情報・外部店舗ID・認証情報は返さない。

### 手動キャンセル請求作成の店舗解決（#27）

`createInvoice`（`invoice.service.ts`）は請求書作成画面から **`shopId`** を受け取り、自社店舗として解決して
`cancellations.shop_id` に紐づけ、作成時点の **店舗名/住所スナップショット**（`shop_name`/`shop_address`）を保存する。
請求書作成画面は店舗名/住所のフリーテキスト入力を**廃止**し登録済み店舗の **select** に変更（店舗 0 件なら作成不可・
施設管理画面への導線を表示）。旧形式（`shopName` のみ）は **400 で即時撤去**。

### 送信時の店舗名/住所解決（#27）

SMS/メール本文・Stripe 明細に出す店舗名/住所は次の順で解決する:
`cancellation.shop_name`（作成時点スナップショット。**手動・取り込み両経路で保存**）→ `shop_id` から解決した店舗
（スナップショットが空の旧データのフォールバック）→ 会社名（`partnerName`/`businessName`。**住所は会社名フォールバックなし**）。
これで手動・取り込みの双方で会社名ではなく **発生店舗名**が本文に出る（取り込み請求も従来の会社名表記から発生店舗名に
変わる＝意図的な変更）。なお**画面表示**（一覧・詳細）は別系統で、常に `shop_id` 解決の `storeName`/`storeAddress` を使い
スナップショットとは二重表示しない。

## テスト

- unit: `cancellation-status` / `crypto-secret`（envelope ラウンドトリップ）/ `salonboard-parser`（fixture。#23 で
  `extractHiddenStoreId`/`parseStoreTop` の店舗単位パースを追加）/ `cancellation-fee`（料率算出・境界）/
  `import-window`（抽出窓・契約日境界）/ `mask-imported-pii`。**#22 追加**: `salonboard-playwright-client`
  （login/CAPTCHA 検知/コンテキスト属性/**アセット＋サードパーティホスト遮断 `shouldAbortRequest`/`isSalonboardHost`**/
  **`describeTransport`（トランスポート要約ログ）**/ **`proxyAuthToken`（HTTP proxy 認証ヘッダ）**）・
  `salonboard-proxy-config`（Decodo username/fail-safe）。
- e2e（`app.request()` + fake client 注入 + fixture）: 連携検証/保存（`salonboard-integration`）/
  取り込みフィルタ・冪等・スキップ/ログ・PIIマスク・**直列化（inflight=1）/ジッタ/失敗理由分類/ログイン一過性失敗
  リトライ（timeout は新IPで引き直し成功・連続timeoutは上限3回・CAPTCHA/認証拒否は即失敗）**（`salonboard-import`）/
  送信・手動取り込み・バッチ dispatch・取り込みログ API（`salonboard-send`）/ 一覧店舗名分離（`cancellations-list-shop`）。
  **#23 追加**: 店舗単位 verify/save・店舗CRUD・連携単位/lock・一覧の `applicationId` フィルター・実行記録の会社単位化・
  マルチソース独立・リネーム回帰（`external_shops`→`shops`）。
  **#27 追加**: 店舗マスタと連携の分離（`shop_integrations`）— 連携なし店舗の作成/編集/削除、後付け連携と
  再連携の外部店舗ID一致・二重連携拒否、連携列挙の `shop_integrations.linked` 化（`findAllLinkedWithShop`）、
  lock の `external_integrations.existsLinked OR shop_integrations.anyLinked` 導出、サロンポータル `/shops` CRUD
  （自社スコープ・連携情報を返さない）、手動作成の `shopId` 解決＋店舗名/住所スナップショット・旧 `shopName` 形式の 400、
  送信時の店舗名/住所解決順、店舗削除の連鎖（CASCADE / SET NULL）、Migration 0012 の backfill 値保全。
  **GTSS-890 追加/更新**（連携単位 × ログイン種別のミスマッチ）:
  - unit `salonboard-parser`: `detectAccountUnit`（会社 fixture=company / 単一店舗 fixture=shop / 店舗トップ着地
    HTML=shop / 空・想定外 HTML=null / 店舗一覧1件＋hidden STORE_ID の競合は company 優先）。
  **GTSS-817-qa 追加**（ログイン失敗の原因特定）:
  - unit `salonboard-login-diagnostics`: 実 fixture でのログイン画面判定（失敗=true / 成功=false）、タイトル・
    遮断シグナル・エラー文言抽出、ログイン ID / メール / 電話のマスク（診断 JSON に原文が残らないこと）、
    両トランスポートの失敗時診断（HTTP は `landingUrl` / `clickMs` が null）、成功時は `diagnostics` 未設定。
  - unit `salonboard-login`: 認証拒否は 1 試行のみ、遮断疑いは新 runId で 1 回だけ引き直し（ジッタあり）、
    引き直し成功で継続、再失敗で `loginBlocked`、総予算切れ・最低試行予算不足では引き直さない。
  - unit `slack-notifier`: 送信経路の解決（BotToken / Webhook / no-op）、投稿失敗（reject / HTTP エラー /
    `ok:false`）でも throw しない、`NODE_ENV=test` で実送信しない、連続投稿の 1 秒間隔と HTTP 429 の
    `Retry-After` 尊重で 1 回だけ再送すること（429 以外は再送しない）。
  - unit `salonboard-import-notify`: 通知本文の全パターン（実行経路 3 × 連携単位 2 × 種別 2 の 12 通り +
    バッチ起動失敗 + 集約通知）。理由コード → 種別の写像（全 14 コード + 理由なし + 未知）、スキップ系理由の
    混入除外、代表種別の優先順、結果行の出し分けと境界値（10/11 店舗）、投稿上限の境界値（10/11 社）、
    生エラー・診断・ロググループを本文へ載せないこと、mrkdwn エスケープ、本番以外でメンションしないこと。
  - unit `batch-import-failure-notify`: 取り込みアクションの例外で ⑬ が 1 通だけ投稿されること
    （ECS(CLI) は終了コード 1・batch Lambda handler は再送出）、投稿 reject / Sentry flush reject でも
    終了コード 1 が崩れないこと、取り込み以外のアクションの失敗では ⑬ を投稿しないこと。
  - unit `deploy-slack-notify-env`: 3 デプロイスクリプトの env 配布（`SLACK_ENGINEER_MENTION_ID` と
    環境名から導出する `ADMIN_URL`、ECS の実秘密混入ガード、`BATCH_LOG_GROUP` を注入しないこと）。
  - e2e `salonboard-import-retry`: 店舗遷移/一覧取得の一過性失敗（timeout / proxy_error）を新セッションで
    1 回だけ引き直して復旧すること、再失敗は当該店舗のみ失敗計上（`attempts=2`・他店舗は継続）、CAPTCHA と
    理由分類できない失敗は引き直さないこと、引き直し上限（2 回/実行）到達後は再試行しないこと、
    引き直しの再ログイン失敗で残り店舗を同理由で打ち切ること、店舗単位連携でも引き直すこと。
  - e2e `salonboard-import-observability`: 会社単位=会社ごと 1 行 / 店舗単位=店舗ごと 1 行の構造化 JSON、
    Sentry のタグ・fingerprint・診断コンテキスト、Sentry 送信失敗でも取り込み継続、`login_blocked` の計上と
    確定理由に含めないこと。Slack は **3 社失敗で 3 通・各本文が自社名だけを含むこと**、全件成功と
    連携設定未完了のみでは投稿しないこと、2 社目の投稿失敗でも 3 社目が投稿されサマリが不変であること、
    会社ランの例外で会社名・連携単位が保たれること、⑬ の 2 経路（連携会社一覧の取得失敗 / 会社ループ途中の
    claim 失敗）で ⑬ の 1 通だけが飛ぶこと。
  - e2e `salonboard-import-invoke-failure`: 手動取り込みの非同期 invoke 失敗で実行履歴が failed で解放され、
    ⑬ が「当該会社の取り込みが未実行です」の影響範囲で投稿されること。会社名が引けなくても申請 ID で
    投稿すること、Slack 投稿が失敗しても throw しないこと（呼び出し元の API 応答が変わらない）。
  - unit `salonboard-shop-verify`: `decideShopVerify` の「件数（0/1/2以上）× 実効単位 × 一致リンク有無」網羅、
    店舗1件が会社アカウント扱いになること（会社/対象店舗の指定が無い検証では救済しない）。
    **1件パスの住所スクレイピングテストは救済成立ケースの e2e へ移設**（DB シードが要るため）。
  - unit `salonboard-verify-retry`: retry の成功ケースを店舗1件 → 単一店舗アカウントの着地 HTML へ変更。
  - e2e `salonboard-store`: 会社アカウント文言（未確定／lock 済みの出し分け）、店舗1件での新規作成拒否と
    DB 無変更、救済成立（ヘア=`enterStore` / キレイ=`enterKireiStore` → 住所取得）、不一致・未連携リンク・
    別店舗/別会社/別 source・2件以上での非救済、評価順（店舗名が空でも会社アカウント文言）。
    実マークアップ fixture での配下1店舗の会社アカウント（`T-31`）。加えて保存経路・境界の回帰:
    `PUT` × リンク無し店舗の初回連携付与（`T-32` 未 lock / `T-33` lock 済み。いずれも 400・DB 無変更）、
    `applicationId` 無し + `shopId` のみの検証（`T-34`・救済しない）、会社単位設定下の `PUT`（`T-35`・
    既存ガードの別文言・**ログインを試行しない**）、および評価順 1 が ID/PW 誤りより優先されること。
  - e2e `salonboard-integration`: 会社単位 verify の 0 件分岐（単一店舗検出→単位変更を促す文言 / 判定不能→従来文言）、
    会社単位 save での拒否と連携単位設定の非更新、店舗1件の会社アカウントは会社単位で成功。
  - 管理画面（別リポジトリ）: unit `StoreForm`（サーバ文言表示・保存非活性・入力保持・編集時のみ `shopId` 送信・
    **再検証の失敗で前回の取得結果を破棄**＝`T-36` 作成モードで詳細欄が消える / `T-37` 編集モードは既存連携値へ戻る）/
    `SalonboardIntegration`（サーバ文言表示・確認テーブル非描画・0件ガードの中立文言）、Playwright
    `salonboard-integration`（店舗フォームのエラー→閉じる→会社単位へ切替）/ `company-detail-context`
    （会社単位パネルのエラー→店舗単位へ切替）。**文言アサートは `role="alert"` にスコープを絞る**。
  - **エラー文言はテスト側の独立したリテラルで検証する**（実装定数を import すると、誤った文言に変わっても
    実装とテストが同時に変わり AC が実質何も検証しなくなる）。
- fixture（`src/__tests__/fixtures/salonboard/`）は実 HTTP 採取レスポンスを**PII マスクして**作成（生 PII は非コミット）。
  #23 で `group-top-single-store.html`（単一店舗の groupTop システムエラー）/ `store-top-single.html`（店舗TOP）を追加。
  GTSS-890 は既存 fixture の再利用＋テスト内で組み立てた HTML（店舗1件の会社アカウント等）を基本とし、
  **店舗一覧テーブルが 1 行の会社トップ**のパース回帰用に `group-top-one-store-company.html` を追加した
  （店舗ID `H000999002` / 店舗名 `テストサロン キレイ1号店` へ置換済み）。これは**多店舗の**実会社アカウントの
  会社トップからヘア区分テーブルを除去し、実機で 1 店舗しか持たないキレイ区分テーブルだけ残したもので、
  合成 HTML では再現できない `<thead>` ヘッダ行・`<td class="storeName">` 構造を含む。
  **REQ-1(a) の前提（配下 1 店舗の会社アカウントでも店舗一覧テーブルが描画される）の検証ではない**
  ―「会社全体で配下 1 店舗」のアカウントの実 HTML は未入手で、人力 T-31 は未実施のまま（前提が崩れた場合の
  ロールバック条件も Issue に残っている）。
