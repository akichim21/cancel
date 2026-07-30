---
issue: 28
date: 2026-06-25
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-817-27
    toBranch: GTSS-817-28
---

# レビュー結果: #28

## 概要

**Issue:** #28 店舗単位サロンボード連携で店舗住所(住所)を storeInfoPreview から GET スクレイピングし shops.shop_address を空欄補完 (GTSS-817)

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-817-27` | `GTSS-817-28` | 1 | 11 |

ベースブランチ `GTSS-817-27` は変更ブランチ `GTSS-817-28` の祖先（direction OK）。ローカルとリモートは同期済み（`7c165a6`）。

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/utils/salonboard-parser.ts` | +57 | -0 | Modified |
| `src/services/salonboard-client.ts` | +56 | -0 | Modified |
| `src/services/salonboard-auth.service.ts` | +52 | -5 | Modified |
| `src/repositories/shops.repository.ts` | +17 | -1 | Modified |
| `src/__tests__/unit/salonboard-parser.test.js` | +102 | -1 | Modified |
| `src/__tests__/unit/salonboard-shop-verify.test.js` | +147 | -3 | Modified |
| `src/__tests__/unit/salonboard-store-info-preview.test.js` | +79 | -0 | Added |
| `src/__tests__/e2e/salonboard-store.test.js` | +141 | -0 | Modified |
| `src/__tests__/helpers/salonboard.js` | +14 | -0 | Modified |
| `src/__tests__/fixtures/salonboard/store-info-preview-hair.html` | +13 | -0 | Added |
| `src/__tests__/fixtures/salonboard/store-info-preview-kirei.html` | +13 | -0 | Added |

## 指摘一覧

全体として設計は堅牢（transport/parse 分離・失敗許容の境界・媒体別 URL の定数化・数値文字参照デコード・PII 配慮）。
3つのサブエージェント（code-reviewer / lessons-reviewer / codex-reviewer）の指摘をメインエージェントが呼び出しチェーンまで
再検証し、裏取りできたもののみ以下に掲載する。REQ-1〜4 の主要ロジック（verify 失敗許容・会社単位除外・空欄補完の
非上書き・媒体別 URL）は検証の結果いずれも要件どおりで問題なし。**ブロッカーは無し。** 最重要は指摘1（BTRIM の空判定ズレ）。

- [x] 対応する

### [Code Quality] `fillAddressIfEmpty` の「空白のみ」判定が BTRIM 依存で REQ-3 とズレる（全角スペース・タブ・NBSP）+ 既存値の ASCII トリム副作用

**ファイル:** `api/src/repositories/shops.repository.ts:68-79`
**重要度:** Medium

**該当コード:**
```typescript
// 変更前: なし（fillAddressIfEmpty は本 PR で新設）
```

```typescript
// 変更後（toBranch）
fillAddressIfEmpty: async (id: string, address: string | null | undefined, db: any = getDb()) => {
  if (address == null || String(address).trim() === '') return null;   // JS trim: U+3000/タブ/NBSP も空とみなす
  const rows = await db
    .update(shops)
    .set({
      shopAddress: sql`coalesce(nullif(btrim(${shops.shopAddress}), ''), ${address})`, // SQL btrim: ASCII空白(U+0020)のみ
      updatedAt: new Date().toISOString(),
    })
    .where(eq(shops.id, id))
    .returning();
  return first(rows);
},
```

**問題:**
1. **空判定の非対称**: PostgreSQL `btrim()`（1引数）は **ASCII スペース(U+0020)のみ** 除去し、タブ・改行・NBSP(U+00A0)・**全角スペース(U+3000)** は除去しない。一方 JS の `String(address).trim()` はこれら全てを空とみなす（`node -e` で実測確認: `"　　"` / `"\t"` / NBSP はいずれも `trim()===''`）。このため既存 `shop_address` が **全角スペースのみ**（運営が住所欄に `"　"` だけ手入力した等）の場合、`nullif(btrim('　'),'')` が非 NULL を返し「空ではない」と判定され、**スクレイピング住所で補完されない**。`'   '`（ASCII）なら補完されるのに `'　　'`（全角）だと補完されない、という REQ-3「空白のみは補完対象」からの漏れ。これは node-postgres / Aurora Data API の差ではなく、両者とも同一 SQL を Postgres に投げるためサーバ側式の問題で挙動は同一。
2. **既存値の ASCII トリム副作用**: COALESCE は `btrim(既存)` を返すため、既存値が `" 東京都 "`（前後 ASCII スペース）のとき、補完がスキップされる代わりに `"東京都"`（トリム後）で **再保存** される。スクレイピング住所が取れる度（再検証の度）に既存値の前後スペースが除去される。「既存実値は上書きしない」が厳密には成立せず、軽微だが仕様コメントと不一致。

**修正提案:** SQL 側の空判定を Unicode 空白込みに揃える。例: 既存値の正規化を `regexp_replace(shop_address, '^\s+|\s+$', '', 'g')`（`\s` は U+3000/NBSP/タブを含む）で行い、その結果が空なら新住所、非空ならトリムせず原値を保持する `CASE` 式へ。全角スペースのみ・タブのみ・NBSP のみの既存値ケースを `it.each` に追加（現状は ASCII `'   '` のみ）。

---

### [Security/PII] PII 不在 grep テストの `forbidden` 配列に実 PII / 実店舗ID / 実トークン断片を平文コミット

**ファイル:** `api/src/__tests__/unit/salonboard-parser.test.js:472-487`
**重要度:** Low（本 PR では新規漏えいなし・既存パターン踏襲。repo 横断で要検討）

**該当コード:**
```javascript
// 変更後（toBranch）— 本 PR が追加した forbidden 配列
const forbidden = [
  '伊藤', // 実管理者名
  'CE30902', // 実管理者ID
  '札幌Alba', // 実店舗名
  'H000764880', // 実キレイ店舗ID（fixture では合成 H000999777）
  'H000660558', // 実ヘア店舗ID（原文でマスクされた実値・fixture では合成 H000999001）
  '914024fbc666', // 実 KMAGIC 先頭
  'b81a3194', // 実 Struts TOKEN 先頭
];
```

**問題:** fixture からの実 PII 漏えいを防ぐためのテスト自体が、実管理者名（`伊藤`）・実管理者ID（`CE30902`）・実店舗名（`札幌Alba`）・実店舗ID・実 KMAGIC/Struts TOKEN 断片を平文でリポジトリに保持している。ルート `CLAUDE.md` の PII 規約（実 ID・店舗 ID・トークンをコミット/ログに残さない）の趣旨に反する。Issue 本文が `H000660558→H000XXXXXX` とマスクしている実値が、テストファイルには生で入っている点も非対称。
**ただし重要な前提:** これらの断片は本 PR 以前から同ファイルの別配列（`:41-56`, `:335-347`）に既にコミット済みで、本 PR は確立済みの（疑問のある）パターンを踏襲して新たな配列を追加しただけ。**本 PR が repo に新規の秘密を持ち込むわけではない。**
**修正提案:** 本 PR 単体のブロッカーにはしない。別途 repo 横断のクリーンアップとして、`forbidden` を実値の salted hash/HMAC 照合へ置換するか、合成ダミー（`H000999xxx` 等）の許可リスト方式（「fixture は合成値以外の `/H000\d{6}/` を含まない」）に切り替えることを推奨。少なくとも実名・実管理者ID・トークン断片の生コミットは解消したい。

---

### [Code Quality] 住所取得失敗の `catch` が無ログ（コメント「理由ログのみ」と不一致）

**ファイル:** `api/src/services/salonboard-auth.service.ts:235-238`
**重要度:** Low

**該当コード:**
```typescript
// 変更後（toBranch）
    const html = await client.fetchStoreInfoPreviewHtml(salonType, externalStoreId);
    return parseStoreAddress(html);
  } catch {
    // 住所取得の失敗は verify 全体へ伝播させない（理由ログのみ）。
    return null;
  }
```

**問題:** 失敗握りつぶし方針（REQ-2）自体は正しいが、`catch` 節が空でコメントの「理由ログのみ」に反してログ出力が無い。CAPTCHA・4xx・DOM 変化・HTTP コンテキスト不備がすべて区別なく `shopAddress=null` に潰れ、運用時（特に H-1 dev 実機や本番）の原因切り分けができない。
**修正提案:** password / HTML 本文 / token を含めず、`salonType`・`externalStoreId`・`error.name`/`message` 程度を `console.warn` か既存ロガー/メトリクスで出力する。verify/save の成功維持（`ok=true`）は変えない。または「ログしない」が意図ならコメントを実態に合わせる。

---

### [Code Quality] `updateShop` で住所を明示的に空指定 + 再連携を同時送信するとスクレイピングで再補完される

**ファイル:** `api/src/services/salonboard-auth.service.ts:528-534`
**重要度:** Low

**該当コード:**
```typescript
// 変更後（toBranch）— 連携付与/再連携パス（wantsLink=true）
  const result = await getDb().transaction(async (tx: any) => {
    const shopPatch: { shopName?: string | null; shopAddress?: string | null } = { shopName };
    if (input?.shopAddress !== undefined) shopPatch.shopAddress = input.shopAddress; // 空文字 '' も含む
    const updated = await shopsRepo.update(id, shopPatch, tx);
    // スクレイピング住所を空欄補完（REQ-3。既存値・運営手入力は上書きしない。同一 tx で原子的に）。
    const filled = await shopsRepo.fillAddressIfEmpty(id, verified.shop!.shopAddress, tx);
    const shop = filled || updated;
```

**問題:** 運営が「住所を空にする（`shopAddress: ''`）」操作と「再連携（loginId/password）」を同時に送信した場合、`update` で空にした直後に `fillAddressIfEmpty` がスクレイピング住所で補完するため、**空指定が無効化**される。手入力 vs スクレイピングの優先順位の境界が未定義・未テスト（連携なしパス `:484-493` は `fillAddressIfEmpty` を踏まないため、ログインなしの住所クリアは正常）。なお `shopAddress=''` も「空」なので REQ-3「空のときだけ補完」とは一応整合する解釈も可能。
**修正提案:** 自動補完を `input?.shopAddress === undefined` のときだけに限定するか、「空指定でも自動補完を許可する」を仕様として明文化し E2E（loginId + 空 shopAddress 同時送信）を追加して挙動を固定する。

---

### [Code Quality] `fetchStoreInfoPreviewHtml` が `externalStoreId` を照合せずセッションコンテキストに完全依存（防御提案）

**ファイル:** `api/src/services/salonboard-client.ts`（HTTP 実装 / Playwright 実装）, 呼び出し元 `salonboard-auth.service.ts:233`
**重要度:** Low（確定バグではなく防御的ハードニング）

**該当コード:**
```typescript
// 変更後（toBranch）— HTTP 実装。プレビュー URL に店舗 ID は含まれず _externalStoreId は意図的に未使用。
  async fetchStoreInfoPreviewHtml(salonType: SalonType, _externalStoreId: string): Promise<string> {
    const path = STORE_INFO_PREVIEW_PATH[salonType] || STORE_INFO_PREVIEW_PATH.hair;
    const referer = salonType === 'kirei' ? `${BASE}/KLP/top/` : `${BASE}/CLP/bt/top/`;
    const res = await this.req(path, { method: 'GET', headers: { /* Accept, Referer */ } });
    ...
  }
```

**問題:** プレビュー URL に店舗 ID が含まれず、取得結果はセッションの店舗コンテキストに完全依存する。happy path（1件パスは `enterStore`/`enterKireiStore` の forward で cookie 確立 → 同一セッション GET、0件パスは店舗 TOP 取得で確立済み）は機能するが、HTTP トランスポート（既定）のコンテキスト確立は **実機未確証（H-1 人力待ち）** の領域で、万一コンテキストがずれると別店舗の住所を取得し得る（静かなデータ破損）。なお店舗 ID 自体は同一セッションの parseSalons/parseStoreTop から解決されるため店舗 ID と住所は相互整合する（ID と住所が食い違う取り違えは起きにくい）。プレビュー HTML の店舗名セルには `（H000999001）` 形式で店舗 ID が含まれるため照合は実装可能。
**修正提案:** 必須ではないが、プレビュー HTML から店舗 ID を抽出し期待 `externalStoreId` と不一致なら `null` + sanitized warning にすると HTTP 経路の防御になる。最低限、H-1 dev 実機（ヘア/キレイ各1）で取得店舗の正しさを確認すること。

---

### [Test Coverage] テストギャップ（全角スペース既存値・手入力住所優先・空指定+再連携）

**ファイル:** `api/src/__tests__/e2e/salonboard-store.test.js:46-64`
**重要度:** Low

**問題:** 以下が未カバー。(a) 指摘1の `'　　'`(U+3000) / タブ / NBSP のみの既存住所（現状は ASCII `'   '` のみ）。(b) 手入力 `input.shopAddress` とスクレイピング住所の優先順位（upsert→fill の順で手入力が勝つ正しい実装だがテスト未固定 = 将来の順序入替リグレッションを検知できない）。(c) 指摘4の loginId + 空 shopAddress 同時送信。
**修正提案:** 「POST/PUT で `shopAddress` 明示指定 + プレビューに別住所 → レスポンス/DB は手入力住所」を1本、「既存 `'　　'`（全角）→ 補完される（指摘1修正後）」を `it.each` に追加。

---

### [Performance] verify 同期パスへの追加ラウンドトリップ（1件パスの forward + preview GET）

**ファイル:** `api/src/services/salonboard-auth.service.ts:295-300, 333-334`
**重要度:** Low

**問題:** 1件パスでは `enterStore`/`enterKireiStore`（forward）+ `fetchStoreInfoPreviewHtml` の追加2ラウンドトリップが verify の同期パス（API Gateway/Lambda のタイムアウト予算配下）に直列で入る。`fetchShopAddressSafely` 自体にタイムアウト指定はなく `req` の `requestTimeout` に依存。REQ-4 が会社単位を除外した理由（タイムアウト懸念）が店舗単位1件パスにも一部当てはまる。失敗時は `null` フォールバックで verify は成功するため機能破綻はしない。
**修正提案:** dev 実機（特に遅い Decodo 出口 IP 時）で verify 総レイテンシがタイムアウト予算内に収まるか1度実測確認する。

---

### [Code Quality] `slice(0, 200)` が UTF-16 コードユニット単位でサロゲートペアを分断し得る（理論上）

**ファイル:** `api/src/utils/salonboard-parser.ts`（`parseStoreAddress` の最大長トリム）
**重要度:** Low（堅牢性向上のみ）

**問題:** 最大長トリムが `.slice(0, STORE_ADDRESS_MAX_LEN)`（UTF-16 単位）のため、200 文字境界に補助平面文字（絵文字等）が来ると lone surrogate を生成し得る。日本語住所は基本 BMP で現実性は極めて低い。
**修正提案:** 必要なら `Array.from(normalized).slice(0, STORE_ADDRESS_MAX_LEN).join('')` でコードポイント単位に。優先度低。

---

## 総評

REQ-1〜4 の主要ロジックは要件どおり実装され、品質・テストカバレッジともに高水準。メインエージェントが呼び出しチェーンを
追跡して確認した「問題なし」点:

- **失敗許容の境界（REQ-2）**: `fetchShopAddressSafely` の try/catch、`filled || shop` / `filled || updated` フォールバック、
  `fillAddressIfEmpty` の null ガードを追跡し、住所取得失敗が verify/保存の `ok` を false にしないことを確認（T-4 で担保）。
  `enterStore`/`enterKireiStore`/`pageFetch`/`assertNoCaptcha` は両クライアントに実在。
- **会社単位の除外（REQ-4）**: `saveSalonboardIntegration` / `verifySalonboardLogin` に住所取得呼び出しが無いことを
  Grep で確認、E2E（`storeInfoPreviewFetches==0`）で担保。
- **媒体別 URL の末尾スラッシュ差（REQ-1）**: 定数 `STORE_INFO_PREVIEW_PATH` を両 transport が共有し、unit テストで完全一致検証。
- **非上書き補完（REQ-3）**: `COALESCE(NULLIF(BTRIM(...)))` で既存実値を保持（ただし指摘1の全角スペース/ASCII トリムの境界に注意）。
- **transport/parse 分離・数値文字参照デコード（10進/16進）・制御文字サニタイズ・PII fixture のデコード後 grep** は適切。

最重要対応は **指摘1（BTRIM の空判定が REQ-3 とズレる・全角スペース等）**。次いで指摘3（無ログ）・指摘5は運用/PII 観点で推奨。
その他は Low の改善提案で、本 PR にブロッカーは無い。

なお lessons-reviewer の確認どおり、CLAUDE.md の必須ルール（テストを書いて green を確認してから完了）に基づき、
Completion コメントは `npx vitest run` で 65 files / 761 tests passed と報告しているが、本レビューは差分照合であり
`npm test` の独立再実行は行っていない。AC-5.1 / H-1（dev 実機でのヘア/キレイ住所補完）は人力テスト未完（取得方式は
2026-06-25 実機検証済み）。
