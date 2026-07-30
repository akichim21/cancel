---
issue: 25
date: 2026-06-19
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-817
    toBranch: GTSS-817-kirei
---

# レビュー結果: #25

## 概要

**Issue:** #25 feat(GTSS-817): キレイサロンのサロンボード取り込み対応（KLP 名前空間の別系統スクレイパー）

会社単位／店舗単位のサロンボード連携で、これまでヘア区分（CLP / GraphQL）専用だった日次・手動の「取り込み実行」を、キレイ区分（KLP / Struts HTML レンダリング）にも対応させる。`shops.salon_type` 追加、種別判定 `detectSalonType`、キレイ用クライアント（CSRF POST）、キレイ用パーサ、取り込みサービスの hair/kirei 出し分けを追加。対象は API のみ。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-817` | `GTSS-817-kirei` | 2 | 16 |

コミット:
- `906f6ee` feat(GTSS-817): キレイ(KLP)サロンボード取り込み対応（店舗種別判別・別系統スクレイパー）
- `d31ee3e` fix(GTSS-817): キレイ取り込みを実データで検証・補正（検索は /search、一覧構造を実機準拠に）

## 変更ファイル一覧

### api

| ファイル | 変更行 | 変更種別 |
|---------|------|---------|
| `src/utils/salonboard-parser.ts` | +272 | Modified |
| `src/services/salonboard-client.ts` | +252 | Modified |
| `src/services/salonboard-import.service.ts` | +80/-? | Modified |
| `src/services/salonboard-auth.service.ts` | +67/-? | Modified |
| `src/repositories/shops.repository.ts` | +7 | Modified |
| `src/db/schema.ts` | +3 | Modified |
| `src/db/migrations/0007_gtss817_kirei_salon_type.sql` | +4 | Added |
| `src/db/migrations/meta/_journal.json` | +7 | Modified |
| `src/__tests__/unit/salonboard-parser.test.js` | +178 | Modified |
| `src/__tests__/unit/salonboard-shop-verify.test.js` | +62 | Modified |
| `src/__tests__/unit/salonboard-playwright-client.test.js` | +6 | Modified |
| `src/__tests__/e2e/salonboard-import-kirei.test.js` | +193 | Added |
| `src/__tests__/helpers/salonboard.js` | +125 | Modified |
| `src/__tests__/fixtures/salonboard/kirei-reserve-list.html` | +100 | Added |
| `src/__tests__/fixtures/salonboard/store-top-kirei.html` | +54 | Added |
| `src/__tests__/fixtures/salonboard/kirei-reserve-detail.html` | +35 | Added |

合計: 16 files / +1395 -50

## 指摘一覧

- [x] 対応する

### [Code Quality] キャンセル日 null により契約日前後フィルタ（before_contract）も来店予定日基準にすり替わる

**ファイル:** `api/src/services/salonboard-import.service.ts:392`
**重要度:** Medium

**該当コード:**
```typescript
// 契約日比較はキャンセル日（一覧の更新日時）基準。欠落時は来店予定日で代替する。
const cancelDate = (r.updatedAt as string) || (r.visitationDate as string);
if (!isCancelOnOrAfterContractDate(cancelDate, ctx.contractCreatedAt)) {
  await logSkip(r, IMPORT_LOG_REASON.BEFORE_CONTRACT);
  ...
}
```

**問題:** 上の High 指摘と同根。キレイは `updatedAt=null` のため契約日フィルタが**来店予定日**基準に化ける。結果として、
- 契約後に実キャンセルされたが**来店予定日が契約前**の予約 → 誤って `before_contract` で除外（取りこぼし）
- 契約前にキャンセルされたが**来店予定日が契約後**の予約 → 誤って取り込み

**修正提案:** High 指摘の「キャンセル日を詳細から取得」で同時に解消する。取得不能なら、キレイの契約日フィルタ挙動を仕様として明記する。

---

### [Test Coverage] HTTP（本番既定トランスポート）でのキレイ単一店舗の種別判定が未検証

**ファイル:** `api/src/services/salonboard-auth.service.ts`（0件分岐 `const salonType = detected; if (!salonType) return error`）/ `api/src/utils/salonboard-parser.ts`（`detectSalonType`）/ `api/src/__tests__/unit/salonboard-shop-verify.test.js`
**重要度:** Medium

**問題:** 既定 transport は `http`（`config.ts`）。HTTP の `login()` は `landingUrl: null` を返すため、店舗単位 verify の種別判定は `detectSalonType({ url: null, html: groupTopHtml })` の **HTML マーカー頼み**になる。`detectSalonType` のルール順:

```typescript
// ① 着地URL名前空間（HTTP は url 空 → 効かない）
// ② storeBaseInfo の designKbn（システムエラー画面には無い想定）
// ③ 区分マーカー header_ico_*（同上）
// ④ ナビ名前空間: /CLP/ のみ→hair / /KLP/ のみ→kirei  ← HTTP 単一店舗はここに依存
```

ヘア HTTP 単一店舗は fixture `group-top-single-store.html`（システムエラー画面）にヘッダリンク `/CLP/bt/top/` があるため**偶発的に** ④ で `hair` に倒れ、既存経路は壊れない（codex-reviewer の「null→ハードエラー」主張は不成立。再検証で確認）。

ただし:
- 種別判定がエラーページのヘッダリンク名前空間という**偶発マーカー依存**で脆い。SalonBoard が chrome を変更すると ④ が null → 保存拒否化しうる。
- **キレイの HTTP 単一店舗**は fixture/テストが皆無。キレイのシステムエラー画面が `/KLP/` を含む保証が無く、`/CLP/` を含むなら**キレイを hair と誤判定**して経路を取り違える可能性（未検証ギャップ）。
- shop-verify unit テストはキレイを `landingUrl: '/KLP/top/'`（**Playwright 専用値**）で通しており、HTTP 経路（`landingUrl: null`）を検証していない。

**修正提案:** キレイの HTTP 単一店舗 groupTop（システムエラー画面 or 店舗 TOP）の実 HTML を PII 置換して fixture 化し、`landingUrl: null` でも `detectSalonType` が `kirei` を返すこと（または判定不能=保存拒否で安全側に倒れること）を unit テストで固定する。あわせて 0件分岐を「種別不能でも hair で店舗TOP取得を試し、失敗時に KLP を試す」フォールバックにする案も検討。

---

### [Test Coverage] キャンセル請求額 `amount` を弱検証（`toBeGreaterThan(0)`）にしている

**ファイル:** `api/src/__tests__/e2e/salonboard-import-kirei.test.js:124`
**重要度:** Medium

**該当コード:**
```javascript
expect(c.amount).toBeGreaterThan(0);
```

**問題:** `.claude/skills/vitest/lesson.md`「重要カラムの数値は網羅的に具体値で検証する」に反する。`amount` はキャンセル請求の中核値で、fixture を完全に制御しているため決定的に計算可能。`>0` では料率ブラケット選択ミスを検出できず、上の High 指摘（常に 100%）を素通りさせている。

**修正提案:** 期待料率で具体値ピン留めする。現行構造（`updatedAt=null` → 当日料率）では `expect(c.amount).toBe(11000)` になり、これにより 100% バグが可視化される。High 指摘の修正後は正しい料率値（例 1 日前 70% → 7700）へ更新する。`cancellationType` 等の主要フィールドも `toMatchObject` で固定推奨。

---

### [Code Quality] `parseKireiTotalPages` が任意の `?...page...=N` クエリにマッチし totalPages を過大算出しうる

**ファイル:** `api/src/utils/salonboard-parser.ts`（`parseKireiTotalPages`）
**重要度:** Medium

**該当コード:**
```typescript
const parseKireiTotalPages = (html: string): number => {
  const nums = Array.from(html.matchAll(/[?&]page(?:Index|No|Num)?=(\d+)/gi)).map((m) => Number(m[1]));
  return nums.length ? Math.max(1, ...nums) : 1;
};
```

**問題:** ページャ要素にスコープせず HTML 全体を走査し、`?page=` だけでなく検索フォーム hidden（`pageNo` 等）やナビ/アセットの `?...page...=` も拾う。`Math.max` のため大きな値が 1 つでも混入すると `totalPages` が過大化し、**存在しない 2 ページ目以降を取得**→ペーシング待ち＋無駄リクエスト（velocity 上昇・bot スコア悪化）。実機 0 件のため総ページ数の実挙動は未検証（T-11）。

**修正提案:** ページャ DOM ブロック（例 `class="pager"`）にスコープを絞ってから抽出、または「次へ」リンク有無で `+1` する方式へ。T-11 で実ページャ構造を確認する。

---

### [Code Quality] `resolveKireiVisitDate` の年跨ぎ補完（MM/DD のみ）にテストが無い

**ファイル:** `api/src/utils/salonboard-parser.ts`（`resolveKireiVisitDate`）
**重要度:** Low

**問題:** 一覧の来店日時は `MM/DD`（年なし）で、取得 window から年を補完する。年跨ぎ（12月→1月）の境界補完ロジックがあるが、unit テストは `2025/12/31` のフル日付ケースのみで、**MM/DD のみ＋年跨ぎ window**（例 `windowStart=2025-12-29, windowEnd=2026-03-29` で `01/02`→`2026-01-02`）が未検証。

**修正提案:** 年跨ぎ window で MM/DD のみを正しく翌年補完するテストを 1 ケース追加。

---

### [Code Quality] `isLocalPayment` への `'現地決済'` 追加が実機未確認の推測

**ファイル:** `api/src/services/salonboard-import.service.ts:172`
**重要度:** Low

**該当コード:**
```typescript
return s === 'LOCAL' || s === '現地支払い' || s === '現地払い' || s === '現地決済';
```

**問題:** キレイ詳細の支払い種別ラベル揺れに「備える」推測値。誤って非現地払いを local 扱いすると誤請求方向（対象を広げる方向）。

**修正提案:** T-11 でキレイ詳細「支払い種別」の実ラベルを確認し、確証後に追加する（現状はコメントに `[未確認]` 明示を推奨）。

---

## 確認済み・良好な点（指摘なし）

- **ヘア経路の不変性:** `clientOpsFor` の hair 分岐は `enterStore`/`fetchReservationListJson`/`parseReservationList`/`fetchReservationDetailHtml`/`parseReservationDetail` を完全保持。`importShop` の `client` 直参照を `ctx.fetchList`/`ctx.fetchDetail` 委譲化した変更も挙動同値（リグレッションなし）。
- **CSRF / Struts double-submit:** キレイ一覧は GET でフォーム取得 → `extractKireiListFormFields` で `org.apache.struts.taglib.html.TOKEN` 等を抽出 → **同一セッション**で `/KLP/reserve/reserveList/search` へ POST。HTTP（CookieJar）/ Playwright（pageFetch）両トランスポートで submit 先・トークン引き継ぎが一致。`d31ee3e` の「/search 修正」も両経路に反映済み（lesson「サイレント0件＝submit先URLを疑う」準拠）。
- **種別の条件付き上書き:** `shops.repository.ts` の upsert は `salonType` 明示時のみ上書きし、未指定再連携が既存 `kirei` を `hair` に巻き戻さない。
- **migration:** `0007` は `NOT NULL DEFAULT 'hair'` の追加カラムで既存行に安全。`_journal.json` の `when` も単調増加。既存 linked キレイ店舗は再連携まで `hair` 経路になる点は運用注意（backfill 手順を Issue に残すこと）。
- **detectSalonType フェイルセーフ:** 判定不能=null → `verifySalonboardShopLogin` がエラー返却・保存しない（`auth.service.ts:93,107`）。Playwright 着地 URL を最優先 → HTML マーカー → ナビ名前空間の順で評価。
- **PII マスク:** キレイ経路も共有 `maskImportedPii` を通り、非本番で氏名マスク・メール差し替え。fixture 実 PII 不在 grep（T-10）も追加。fixture 値は `CD00000`/`H000999xxx`/`テストサロン`/`テスト担当` 等の規定プレースホルダで実 PII 残存なし。
- **per-shop 失敗分離:** キレイ取得失敗（`failKireiListFor`）が当該店舗のみ failed 計上・他店舗継続を e2e（T-9）で検証。

## 総評

実装は「ヘア経路の不変性」「CSRF の正しい取り回し」「種別判定フェイルセーフ」「PII マスク／fixture grep」など堅実で、AC の多くを満たす。一方で **最優先の懸念は「キレイにキャンセル日が存在しないことが料率計算へ直結し、お客様キャンセルが常に当日料率（通常 100%）で過大請求になりうる」点**（メインエージェントが料率チェーンを全追跡して確定）。REQ-4 の「キャンセル処理日」抽出が未実装で、`externalCanceledAt` もキレイは常に null になる。e2e が `amount>0` 弱検証のため見逃しており、リリース前に「詳細からキャンセル日を取得して料率に反映する」か「当日料率固定を製品合意する」かの判断が必須。

次点は **HTTP 本番既定でのキレイ単一店舗種別判定の未検証**（fixture 追加 or フォールバック化）と **`parseKireiTotalPages` の過剰マッチ**。いずれもパーサ全体が「実機 0 件のため構造推定」である以上、T-11（実データ・実キャンセル予約での一覧/詳細パース、ページング、支払いラベル）の完了までは本番取り込み（特に請求作成）を慎重に扱うべき。
