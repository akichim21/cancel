---
issue: 27
date: 2026-06-25
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-817
    toBranch: GTSS-817-27
  - repo: user
    repoDir: cancel-billing-service
    baseBranch: GTSS-817
    toBranch: GTSS-817-27
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: GTSS-817
    toBranch: GTSS-817-27
---

# レビュー結果: #27

## 概要

**Issue:** #27 store(店舗)をサロンボード連携から分離: 連携なし作成・店舗select請求・媒体別データモデル化 (GTSS-817)

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-817` | `GTSS-817-27` | 1 | 32 |
| user | `GTSS-817` | `GTSS-817-27` | 1 | 14 |
| admin | `GTSS-817` | `GTSS-817-27` | 1 | 12 |

レビュー体制: 各リポジトリに code-reviewer + codex-reviewer、横断で lessons-reviewer（計7エージェント）。
全エージェントの指摘はメインエージェントが PR ブランチ実コード（worktree `origin/GTSS-817-27`）を Read/Grep で再検証し、
裏取りできたもののみ記載。`shops.id` 不変・FK/CASCADE・PII 非露出・migration backfill 順序・認可スコープは
**問題なし**を確認済み（総評参照）。

## 対応状況（2026-06-25 追記・pr-review-respond）

全 7 指摘を `.worktrees/GTSS-817-27`（branch `GTSS-817-27`）で対応済み。**Finding A/B は方針変更**: snapshot を読む/書くではなく
**店舗を物理削除→論理削除（`shops.deleted_at`）に統一**し、`external_shop_id` が SET NULL されず行が残るため一覧 JOIN・
送信解決が削除後も発生店舗名を引ける構造にした（`applications` の既存ソフトデリート規約に整合）。snapshot（AC-6.1）は維持。

| # | 指摘 | 対応 |
|---|------|------|
| A | 取り込み請求が削除後に会社名へ退行 | shops 論理削除（migration 0013）。削除後も `external_shop_id` 保持で店舗名解決。連携リンク/認証情報のみハード削除 |
| B | 一覧が削除後に店舗名空 | 同上（live JOIN が残存行を解決）。回帰テスト追加 |
| C | InvoiceForm 失敗=0件誤認 | `shopsError` で取得失敗と0件を分離・再読み込み導線。送信ブロック維持 |
| D | StoreForm 折りたたみで保存ロック | 折りたたみ時に認証情報/検証状態をクリア（未検証 cred も送らない） |
| #5 | loginId/password 片方欠落 | 両方なし or 両方ありのみ許可、片方は 400 |
| #6 | upsertByStore 非アトミック | `onConflictDoNothing` + 孤児店舗ハード削除 + 既存リンク収束。並行テスト追加 |
| #7 | テスト不足 | 上記すべてに回帰テスト追加（admin フラット展開フォールバック含む） |

**テスト結果**: API Vitest **730 passed** / tsc clean ・ user portal Vitest **152** + Playwright **19** + build clean ・
admin Vitest **179** + Playwright **45** + build clean。総評の「本PRスコープ外（既存）」項目は未対応（フォロー Issue 候補）。

## 変更ファイル一覧

### api（cancel-billing-service-api）

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/db/migrations/0012_gtss817_shop_integrations.sql` | +45 | -0 | New |
| `src/db/migrations/rollback/0012_gtss817_shop_integrations.down.sql` | +47 | -0 | New |
| `src/db/migrations/meta/_journal.json` | +7 | -0 | Modified |
| `src/db/schema.ts` | +56 | -15 | Modified |
| `src/handlers/shops.handler.ts` | +34 | -0 | New |
| `src/handlers/index.ts` | +2 | -0 | Modified |
| `src/repositories/shop-integrations.repository.ts` | +255 | -0 | New |
| `src/repositories/shops.repository.ts` | +18 | -120 | Modified |
| `src/services/shops.service.ts` | +106 | -0 | New |
| `src/services/salonboard-auth.service.ts` | +149 | -74 | Modified |
| `src/services/invoice.service.ts` | +34 | -8 | Modified |
| `src/services/cancellation-send.service.ts` | +18 | -2 | Modified |
| `src/services/salonboard-import.service.ts` | +6 | -2 | Modified |
| テスト 18 ファイル（新規 5: `invoice-shop-select` / `send-shop-name` / `shop-admin-crud` / `shop-integrations` / `shops-salon`、他は移行追従＋`helpers/seed.js`） | +1296 | -83 | New/Modified |

### user（cancel-billing-service）

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/components/StoreManagement.tsx` | +327 | -0 | New |
| `src/components/InvoiceForm.tsx` | +65 | -77 | Modified |
| `src/services/api.ts` | +29 | -1 | Modified |
| `src/types/index.ts` | +13 | -2 | Modified |
| `src/App.tsx` | +9 | -0 | Modified |
| `src/components/Header.tsx` | +1 | -0 | Modified |
| テスト/E2E 8 ファイル（`StoreManagement.test` / `api.test` / `InvoiceForm.test` / `stores.spec` / `invoice-store.spec` / `fixtures` 他） | +427 | -10 | New/Modified |

### admin（cancel-billing-service-admin）

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/components/StoreForm.tsx` | +148 | -91 | Modified |
| `src/components/StoreList.tsx` | +21 | -9 | Modified |
| `src/types/Shop.ts` | +38 | -4 | Modified |
| `src/services/ApiService.ts` | +10 | -6 | Modified |
| テスト/E2E 8 ファイル（`StoreForm.test` / `StoreList.test` / `store-list-linkless.spec` / `fixtures` / `test/utils` 他） | +514 | -47 | New/Modified |

## 指摘一覧

- [x] 対応する

### [Code Quality] 取り込み請求(createImported)が店舗名スナップショットを保存せず、店舗削除後に SMS/メール本文が会社名へ退行する

**ファイル:** `api/src/services/salonboard-import.service.ts:572-601`（参照: `cancellation-send.service.ts:61-71`）
**重要度:** Medium

Issue 本文 line 83 / AC-2.2 は **「過去請求の発生店舗名は REQ-6 のスナップショット（`cancellations.shop_name`）で保持されるため、店舗削除後も一覧・送信本文の店舗名は壊れない」** と明記している。しかし取り込み請求を作る `createImported` の `record` は `externalShopId: shop.id` のみで `shopName`/`shopAddress` を保存しない（手動請求 `createInvoice` のみスナップショット保存）。連携店舗を admin が削除すると FK `ON DELETE SET NULL` で `external_shop_id` が NULL になり、`dispatchPayment` の解決順は会社名（`partnerName`）へフォールバックする。

**該当コード（変更後・createImported は snapshot 列を持たない）:**
```typescript
// salonboard-import.service.ts
    const record = {
      id: `imp_${randomUUID()}`,
      applicationId: ctx.applicationId,
      status: CANCELLATION_STATUS.PRE_SEND,
      source: SOURCE,
      externalShopId: shop.id,           // ← FK のみ。shopName/shopAddress は無い
      externalReservationId: r.reservationId,
      // ... 以降に shopName / shopAddress の保存は無い
    };
    const { created } = await cancellationsRepo.createImported(record);
```

```typescript
// 対比: invoice.service.ts:197-200（手動請求は snapshot を保存している）
      // 発生店舗 FK（shops.id）＋ 店舗名/住所のスナップショット（REQ-6）。
      externalShopId: invoiceData.shopId,
      shopName: resolvedShopName,
      shopAddress: resolvedShopAddress,
```

**問題:** REQ-7（line 121）の設計上、取り込み請求は「`external_shop_id` から動的解決」する方針なので平常時は正しく店舗名が出る（T-18/T-19 で担保）。ただし **店舗削除後**は snapshot が無いため送信本文が会社名へ退行し、line 83/AC-2.2 の保証（取り込み請求も含めた「店舗削除後も壊れない」）と矛盾する。AC-7.1 は未チェック（H-3 人力待ち）でこのエッジは自動テストにも無い。
**修正提案:** いずれか。(a) `createImported` でも `shopName: shop.shopName` / `shopAddress: shop.shopAddress` を保存する（ただし店舗改名時に旧名が残る＝REQ-7 の動的反映と競合するため、保存するなら送信解決順を snapshot 優先にしている点との整合を確認）、または (b) 仕様 line 83 を「取り込み請求は店舗削除後は会社名へフォールバックする」と明記して保証範囲を手動請求に限定する。設計意図（削除後の表示）をどちらに倒すか決めて統一する。

---

### [Code Quality] 一覧クエリがスナップショット(cancellations.shop_name)を coalesce せず、手動請求でも店舗削除後に一覧の店舗名が空になる

**ファイル:** `api/src/repositories/cancellations.repository.ts:35-45, 95-101`（本 PR では未変更ファイル）
**重要度:** Medium

本 PR は手動請求で `cancellations.shop_name` スナップショットを**書き込む**（`invoice.service.ts:199`）が、一覧クエリは `storeName: shops.shopName` を `externalShopId → shops.id` の live join のみで解決し、**スナップショットを読まない**。店舗削除後は join が NULL になり、`cancellations.shop_name` にスナップショットが残っていても一覧の店舗名が `-` になる。書いたデータが list 経路で未使用（written-but-never-read）。

**該当コード（変更後＝base と同一・coalesce していない）:**
```typescript
// 管理者一覧 adminListSelect
    .select({
      c: cancellations,
      partnerName: applications.partnerName,
      businessName: applications.businessName,
      storeName: shops.shopName,                 // ← snapshot を見ず live join のみ
    })
    .leftJoin(shops, eq(cancellations.externalShopId, shops.id));

// サロンポータル一覧 findByApplicationIdWithShop
      .select({ c: cancellations, storeName: shops.shopName })   // ← 同上
      .leftJoin(shops, eq(cancellations.externalShopId, shops.id))
```

**問題:** Issue line 83/AC-2.2 の「店舗削除後も**一覧**の店舗名は壊れない」が手動請求でも満たされない。送信経路 `dispatchPayment` は `cancellation.shopName`（snapshot）を先頭に解決するのに、一覧経路だけ snapshot を無視しており非対称。T-16/T-17 は店舗が生存している状態のみ検証するため検出されない。
**修正提案:** `storeName` を `COALESCE(cancellations.shop_name, shops.shop_name)`（drizzle の `sql`/`coalesce`）にして、`dispatchPayment` と同じ「snapshot 優先 → live join」の解決順へ揃える。これにより削除後も手動請求の発生店舗名が一覧で保持される（取り込み請求は上の指摘の方針決定に従う）。

---

### [Code Quality] InvoiceForm: getShops の取得失敗が「店舗0件」と区別できず、誤った作成導線＋送信恒久ブロックになる

**ファイル:** `user/src/components/InvoiceForm.tsx:46-65, 258-264, 602`
**重要度:** Medium

`getShops()` が `{ success: false }`（401/500 等）を返すと `setShops` がスキップされ、ネットワーク例外は `catch` で握りつぶされる。いずれも `shops=[]` のまま `shopsLoaded=true` になるため、`shopsLoaded && !hasShops` が true となり「店舗がありません。店舗を作成してください。施設管理へ」の 0 件空状態が表示される。実際は店舗が存在しても「0 件」と断定して作成を促し（重複店舗の懸念）、かつ送信ボタンが `!hasShops` で恒久的に無効化されリロードまで請求できない。

**該当コード（変更後）:**
```tsx
  useEffect(() => {
    let active = true;
    (async () => {
      try {
        const result = await apiService.getShops();
        if (active && result.success) {
          setShops(result.data || []);
        }
      } catch {
        // 取得失敗時は空のまま（送信はブロックされる）  ← 失敗と0件が同じ表現になる
      } finally {
        if (active) setShopsLoaded(true);
      }
    })();
    // ...
  }, []);
  const hasShops = shops.length > 0;
```
```tsx
                {shopsLoaded && !hasShops ? (
                  <div className="... bg-yellow-50 ...">
                    店舗がありません。店舗を作成してください。
                    <Link to="/stores" ...>施設管理へ</Link>
                  </div>
                ) : ( /* select */ )}
/* ... */
  disabled={isLoading || !policyAgreed1 || !policyAgreed2 || !hasShops}
```

**問題:** 取得失敗（通信障害・認証切れ・サーバエラー）が「店舗未登録」と同一表示になり、誤誘導と恒久ブロックを生む。`StoreManagement.tsx` は同じ getShops 失敗を `error` 表示で区別できているため挙動が非対称。
**修正提案:** `shopsError` state を追加し、`result.success === false` と `catch` では「店舗情報の取得に失敗しました。再読み込みしてください」を表示して作成リンク/select を出さない。0 件空状態は「取得成功 かつ `data.length === 0`」のときだけに限定する。`StoreManagement` と挙動を揃える。

---

### [Code Quality] StoreForm: 連携セクションを折りたたんでも認証情報がクリアされず、保存ボタンが理由不明にロックする

**ファイル:** `admin/src/components/StoreForm.tsx:155, 237`
**重要度:** Medium

連携セクションのトグルは `setShowIntegration((v) => !v)` のみで `loginId`/`password`/`verified` をリセットしない。`canSave = !saving && shopName.trim() !== '' && (!hasCredentials || verified)`、`hasCredentials = loginId.trim() !== '' || password.trim() !== ''`。

再現: ①店舗名入力 → ②「サロンボード連携（任意）」を開いてログイン/PW を入力（`hasCredentials=true`・`verified=false` → `canSave=false`）→ ③もう一度トグルで**閉じる**（入力欄は隠れるが state は残る）。この状態で画面上は「店舗名だけの未連携店舗」に見えるのに、`canSave` が false のまま保存ボタン（`disabled={!canSave}`）が原因不明にグレーアウトする（入力欄が隠れているのでユーザーに理由が見えない）。

**該当コード（変更後）:**
```tsx
  const canSave = !saving && shopName.trim() !== '' && (!hasCredentials || verified)
  // ...
            <button
              type="button"
              onClick={() => setShowIntegration((v) => !v)}   // ← 開閉のみ。creds/verified を残す
              aria-expanded={showIntegration}
            >
```

**問題:** 「連携を入力 → やめて折りたたむ」操作で保存が不能化し、原因が画面から判別できない UX トラップ。
**修正提案:** セクションを閉じる際に `setLoginId('')` / `setPassword('')` / `setVerified(false)` をクリアする（「閉じる＝連携やめる」と意味が一致）か、`canSave` の `hasCredentials` 判定を `showIntegration && hasCredentials` に限定して折りたたみ時は連携なし扱いにする。前者推奨。回帰テスト追加も。

---

### [Code Quality] saveSalonboardShop / updateShop: loginId・password の片方欠落が黙って「連携なし」扱いになる

**ファイル:** `api/src/services/salonboard-auth.service.ts:356-359, 439-440`
**重要度:** Low

`wantsLink = !!(input?.loginId && input?.password)` のため、loginId か password の片方だけ送ると `wantsLink=false` となり、POST は連携なし店舗作成、PUT は名前/住所更新に黙って落ちる。運営は連携したつもりで未連携店舗を保存しうる。

**該当コード（変更後）:**
```typescript
  const wantsLink = !!(input?.loginId && input?.password);
  if (!wantsLink) {
    // 連携なし作成 / 名前住所更新へ分岐（片方だけ入力でもここに来る）
```

**問題:** admin 限定経路なのでセキュリティ事故ではないが、入力ミス（片方だけ）が無言で連携なし保存に化けるデータ整合の罠。
**修正提案:** loginId/password は「両方なし or 両方あり」のみ許可し、片方だけなら 400（バリデーションエラー）を返す。e2e に片側欠落ケースを追加。

---

### [Code Quality] shop-integrations.repository.upsertByStore が非アトミックな SELECT→INSERT に退行（並行時 unique violation→500）

**ファイル:** `api/src/repositories/shop-integrations.repository.ts:192-232`（対比: base `shops.repository.ts` の `onConflictDoUpdate`）
**重要度:** Low

旧 `shopsRepo.upsertByStore` は `insert().onConflictDoUpdate()` でアトミックだった。新実装は `findByApplicationSourceStore`（SELECT）→ 無ければ `shops.create` + `shopIntegrations.create`（INSERT）の順で、衝突ハンドリングが無い。同一 `(applicationId, source, externalStoreId)` の並行保存で双方が SELECT 空振り → 双方 INSERT すると `shop_integrations_app_source_store_unique_idx` 違反で 500、かつ Tx 外なら孤児 shop 行が残りうる。

**該当コード（変更後＝非アトミック）:**
```typescript
    const existing = await shopIntegrationsRepo.findByApplicationSourceStore(
      domain.applicationId, domain.source, domain.externalStoreId, db,
    );
    if (existing) { /* update */ return { shop, integration }; }
    const shop = await shopsRepo.create({ ... }, db);            // ← SELECT 空振り後に
    const integration = await shopIntegrationsRepo.create({ ... }, db); // ← ここで UNIQUE 違反しうる
```

**問題:** 取り込み経路は会社単位の claim ロックでほぼ直列化され実害は小さい（concurrency テストあり）が、admin `POST /admin/shops`・再連携はロック外で並行時 500 になりうる。T-3 は逐次冪等のみで並行未テスト。
**修正提案:** integration の insert を `onConflictDoUpdate`/`onConflictDoNothing + 再読込` に寄せるか、unique violation を捕捉して既存リンクを再取得する。並行テストを追加。

---

### [Test Coverage] 失敗パス・折りたたみパス・フラット展開フォールバックが未テスト

**ファイル:** `user/src/components/__tests__/InvoiceForm.test.tsx` / `admin/src/components/__tests__/StoreForm.test.tsx` / `admin/src/components/__tests__/StoreList.test.tsx`
**重要度:** Low

上記の Medium 指摘に対応するテストが無い:
- InvoiceForm: `getShops` が `{ success:false }`/reject のケース（取得失敗時に作成リンクを出さない／取得失敗文言を出す）が未カバー。`StoreManagement.test.tsx` には取得失敗テストがあるのに InvoiceForm には無い。
- StoreForm: 「連携を入力 → 折りたたむ → 保存可否」の検証が無い（既存テストは開いたまま操作）。
- StoreList: `salonboardIntegration()` の**フラット展開フォールバック分岐**（`integrations` キーを持たない旧 API レスポンス）が一度も実行されない。`makeShop` が常に `integrations[]` を合成し、literal も `integrations` を明示するため、後方互換という本 PR の注目点の回帰検出力が欠落。

**修正提案:** 各 Medium 修正に対応する回帰テストを追加。StoreList は `integrations` を持たずフラット項目のみの shop を渡し、連携済み表示・外部店舗ID・種別が出ることを検証（または `salonboardIntegration` の直接 unit テスト）。

---

## 総評

設計・実装は全体に健全で、**マージブロッカーは無い**。データモデル分離の肝である以下は再検証して問題なしを確認した:

- **migration 0012**: `shop_integrations` 作成 → 既存 shops から 1:1 backfill → `shop_address` 追加 → 旧列/旧 UNIQUE 削除の順で、backfill が列削除より前。`shops.id` を作り直さないため `cancellations`/`external_import_logs`/`external_integrations` の `external_shop_id → shops.id` FK 参照を保全。旧 UNIQUE は `shop_integrations` へ移設。`_journal.json`（idx:12）追記・逆 migration 同梱も整合。
- **FK/CASCADE**: `shop_integrations`/店舗単位 `external_integrations` は CASCADE、`cancellations`/`external_import_logs` は SET NULL。`schema.test.js` / `shop-admin-crud.test.js`(T-5) で実検証。
- **認可・PII**: サロン向け `/shops` は全 CRUD で `requireAuth` + 自社スコープ（他社 id → 403）、連携済み削除 → 400。`toSalonShopResponse`/`toShopResponse` は認証情報・暗号 blob・外部店舗ID・source を返さず `linked`/`hasPassword` のみ。取り込み経路の `maskImportedPii` は本 PR で未変更。lessons（破壊的 migration・PII・テスト未整備・Playwright allowlist・サイレント0件）への違反は無し。

注目すべき指摘は **Medium 4 件（取り込み snapshot 欠落 / 一覧の snapshot 未 coalesce / InvoiceForm 失敗=0件誤認 / StoreForm 折りたたみ保存ロック）と Low 3 件**。Medium の上位2件は「Issue が明文で保証した『店舗削除後も一覧・送信本文の店舗名は壊れない』が、書いた snapshot を list 経路が読まない／取り込みは snapshot 自体が無い、ため満たされない」という同根の不整合で、対応方針（snapshot を読む側に揃えるか、保証範囲を明記し直すか）を決めて一括で直すのが望ましい。

**本 PR スコープ外（フォロー Issue 候補・既存問題）:**
- `POST /cancellations`（`cancellation.service.ts`、本 PR 非変更）は `applicationId: decoded.application_id` の後に `...cancellationData` を spread しており、クライアントが `applicationId`/`externalShopId` を上書きできる構造。base `GTSS-817` でも同一で本 PR の退行ではないが、`createInvoice` 側は明示代入＋自社解決で安全化された一方こちらは非対称。別 Issue で要修正。
- `shop_integrations.application_id` と `shops.application_id` の一致を保証する DB 制約が無い（現行コード経路では常に同値で実害なし。hardening）。
- migration の `gen_random_uuid()` はコードベース初使用だが Postgres 17（test）/ Aurora 13+ のコア関数で動作上問題なし。

**テスト実行（実装者申告）:** API Vitest 726 passed / admin Vitest 177 + PW 45 / user Vitest 149 + PW 19。**人力残（実装者明記）:** H-1 逆 migration の dev 検証、H-2 実サロンボード認証での後付け連携、H-3 実 SMS/メール店舗名の目視（AC-7.1 は未チェック）。
