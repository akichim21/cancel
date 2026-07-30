---
issue: 23
date: 2026-06-18
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-817
    toBranch: GTSS-817-store
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: GTSS-817
    toBranch: GTSS-817-store
---

# レビュー結果: #23

## 概要

**Issue:** #23 管理画面の申込詳細ページ化・店舗CRUD・サロンボード連携の会社/店舗単位選択（マルチソース対応・#12 続編）

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-817` | `GTSS-817-store` | 1 | 32 |
| admin | `GTSS-817` | `GTSS-817-store` | 1 | 33 |

レビュー実施: code-reviewer（api/admin）・lessons-reviewer（横断）・codex-reviewer（api/admin）の5エージェント並列 → 各指摘をメインエージェントが worktree 実コードで cross-file 再検証。codex の1回目出力（admin 側は問題なし、api 側は別ブランチ `GTSS-817-proxy` 文脈の混入7件）は **破棄**し、再実行の on-scope 指摘のみ採用。Pre-PR で確定済みの2大欠陥（admin `getApplication` id 正規化／`useCallback` メモ化）は両方とも正しく修正されていることを確認済み。lessons 違反は検出なし。

## 変更ファイル一覧

### api（主要のみ）

| ファイル | 変更種別 |
|---------|---------|
| `src/db/schema.ts` / `src/db/migrations/0006_gtss817_store_unit.sql` | Modified / Added |
| `src/services/salonboard-auth.service.ts`（+439） | Modified |
| `src/services/salonboard-import.service.ts`（+357/-） | Modified |
| `src/services/cancellation.service.ts` | Modified |
| `src/repositories/cancellations.repository.ts` | Modified |
| `src/repositories/external-integration-settings.repository.ts`（新規 +80） | Added |
| `src/repositories/{external-shops → shops}.repository.ts` | Renamed |
| `src/utils/salonboard-parser.ts` / `src/services/salonboard-client.ts` | Modified |
| `src/handlers/salonboard.handler.ts` / `cancellations.handler.ts` | Modified |
| `src/__tests__/e2e/salonboard-store.test.js`（+823）他テスト・fixture | Added |

### admin（主要のみ）

| ファイル | 変更種別 |
|---------|---------|
| `src/App.tsx` / `src/components/Header.tsx` | Modified |
| `src/components/ApplicationDetailLayout.tsx`（新規 +335） | Added |
| `src/components/StoreList.tsx`（+192）/ `StoreForm.tsx`（+255） | Added |
| `src/components/ApplicationList.tsx` / `CancellationManagement.tsx` / `ImportLogList.tsx` / `ImportRunList.tsx` | Modified |
| `src/services/ApiService.ts`（+175） | Modified |
| `src/types/Cancellation.ts` / `src/types/Shop.ts`（新規） | Modified / Added |
| `src/components/ApplicationDetail.tsx`（旧モーダル・**未削除**） | （死蔵） |
| e2e/unit テスト多数 | Added |

## 指摘一覧

- [x] 対応する

### [Security] 会社単位連携の保存に連携単位 lock のサーバ側ガードが無く、店舗単位確定後でも会社単位連携を保存できる

**ファイル:** `api/src/services/salonboard-auth.service.ts:75-139`（`saveSalonboardIntegration`）
**重要度:** High

**該当コード（変更後・会社単位 save。lock チェックが無い）:**
```typescript
export const saveSalonboardIntegration = async (
  applicationId: string,
  loginId: string,
  password: string,
  editedShops: { externalStoreId: string; shopName?: string }[] = [],
): Promise<SaveResult> => {
  const verified = await verifySalonboardLogin(loginId, password);
  if (!verified.ok) {
    return { ok: false, error: verified.error };
  }
  // ← ここに getEffectiveUnit / getIntegrationUnit による lock チェックが無い
  const encryptedSecret = await encryptSecret(password);
  const keepStoreIds = verified.salons!.map((s) => s.externalStoreId);
  const savedShops = await getDb().transaction(async (tx: any) => {
    await externalIntegrationsRepo.upsert({ applicationId, source: SOURCE, loginId, encryptedSecret, linked: true, ... }, tx);
    // ...各ヘアサロンを upsert(linked:true)...
    await shopsRepo.unlinkOthersByApplication(applicationId, SOURCE, keepStoreIds, tx);  // ← 店舗単位店舗を強制 unlink
    return saved;
  });
```

**比較（変更後・店舗単位 save/update/delete には lock ガードが有る）:**
```typescript
export const saveSalonboardShop = async (...) => {
  const unit = await getEffectiveUnit(applicationId, source);  // :243 — company なら拒否
  ...
export const updateShop = async (...) => {
  const unit = await getEffectiveUnit(existing.applicationId, source);  // :304
export const deleteShop = async (id) => {
  const unit = await getEffectiveUnit(existing.applicationId, existing.source);  // :372
```

**問題:** REQ-5/AC-6 は「`(application, source)` のいずれかが `linked=true` で確定したら、その連携先の連携単位はサーバ側でも変更不可」と規定する。店舗 CRUD（`saveSalonboardShop`/`updateShop`/`deleteShop`）は `getEffectiveUnit()==='company'` で拒否する対称ガードを持つが、**会社単位保存パス `saveSalonboardIntegration` には lock チェックが無い**。そのため、ある会社が店舗単位で `shops.linked=true` 済み（＝`getIntegrationUnit.unitLocked=true`）でも、`POST /admin/salonboard/integration` を直接呼べば会社単位の認証情報行（`external_shop_id IS NULL`）を保存でき、以後 `getEffectiveUnit` が `'company'` を返すようになる。さらに `unlinkOthersByApplication(keepStoreIds=クロール結果)`（:129）により**既存の店舗単位店舗が `linked=false` に強制 unlink** され、per-shop 認証情報行（`external_shop_id=shop.id`）は会社単位 save に触られず `linked=true` のまま残り状態が不整合になる。`PUT /admin/salonboard/integration-unit` だけが lock を強制し、会社単位 save が別経路で実効単位を変えてしまうため REQ-5 のサーバ側不変条件を満たさない。「店舗単位 linked 済みの会社で会社単位 save が拒否される」テストも存在しない。

**修正提案:** `saveSalonboardIntegration` の保存前に `getIntegrationUnit(applicationId, SOURCE)` を確認し、`unitLocked && unit !== 'company'` を 4xx（locked）で拒否する。未ロックで会社単位保存を許す場合も、同一 Tx で `external_integration_settings.unit='company'` を upsert して実効単位を一貫させる。e2e（shop-linked → 会社単位 save が 409/400）を追加する。

---

### [Code Quality] 「会社単位」を選択しても会社単位サロンボード連携を実行する UI 導線が存在しない（旧モーダルが死蔵化）

**ファイル:** `admin/src/components/ApplicationDetailLayout.tsx`（`SalonboardIntegration` を未描画）/ `admin/src/components/StoreList.tsx:113-119` / `admin/src/components/ApplicationDetail.tsx:194`（死蔵）
**重要度:** High

**該当コード（変更後・StoreList の会社単位分岐は読み取り専用バナーのみ）:**
```tsx
{!isShopUnit && (
  <div className="mb-6 bg-blue-50 border border-blue-200 rounded-md p-4">
    <p className="text-sm text-blue-700">
      この会社は会社単位で連携しています。店舗の追加・編集はできません（読み取り専用）。
    </p>
  </div>
)}
```

**該当コード（変更後・`SalonboardIntegration` の唯一の参照元は削除済みモーダル）:**
```tsx
// grep 結果（テスト除く・本番経路）:
//   src/components/ApplicationDetail.tsx:12   import { SalonboardIntegration } ...
//   src/components/ApplicationDetail.tsx:194  <SalonboardIntegration applicationId={application.id} />
// ApplicationDetailLayout は getSalonboardIntegration を「状態取得」用に呼ぶのみで <SalonboardIntegration> を描画しない。
// App.tsx は <ApplicationDetailLayout> のみ描画し <ApplicationDetail>（旧モーダル）の JSX 参照は 0 件。
```

**問題:** REQ-2(b)/REQ-5/UC-2 step2 は「会社単位を選ぶと会社単位のサロンボード連携設定 UI（#12 の既存 UI）が出る」と規定し、UC-4 は会社単位連携**完了済み**の店舗一覧表示を要求する。しかし `SalonboardIntegration`（会社単位ログイン→ヘアサロン一覧クロール→確認画面→保存）は新詳細ページのどこにもレンダーされず、唯一の描画元だった `ApplicationDetail.tsx`（旧モーダル）は `App.tsx`/`Dashboard.tsx` から `<ApplicationDetail>` が削除された結果、自身のテストからしか参照されない**死蔵コード**になっている。結果、**未連携の会社で「会社単位」を選んでも会社単位連携を完了する手段が無く**、「会社単位で連携完了済み」状態（UC-4 の前提）に到達できない。加えて `StoreList` は `linked` を問わず `unit==='company'` のとき常に「会社単位で連携しています」と断定し、未連携でも空の読み取り専用一覧を見せる。

**修正提案:** `unit==='company' && !unitLocked` のとき `ApplicationDetailLayout` ヘッダー（または店舗タブ）に `SalonboardIntegration`（会社単位フロー）を再配置し、読み取り専用化は `unit==='company' && unitLocked` に限定する。`StoreList` の会社単位バナー文言を「連携済み」「未連携・連携待ち」で出し分ける。併せて死蔵化した `ApplicationDetail.tsx` とそのテストを削除する（本指摘の解決とセット）。未連携→会社単位選択→連携完了→読み取り専用化の Vitest/Playwright を追加する。

---

### [Code Quality] 会社スコープのキャンセル一覧 API がグローバルと異なるレスポンス形を返し「会社名」列が表示されない（REQ-4 同一コンポーネント再利用の shape 不整合）

**ファイル:** `api/src/services/cancellation.service.ts:57-60` / `api/src/repositories/cancellations.repository.ts:54-83`
**重要度:** Medium

**該当コード（変更後・グローバル用は `companyName` を付与）:**
```typescript
findAllWithShop: async () => {
  const rows = await getDb().select({ c: cancellations, partnerName: applications.partnerName,
      businessName: applications.businessName, storeName: shops.shopName })
    .from(cancellations)
    .leftJoin(applications, eq(cancellations.applicationId, applications.applicationId))
    .leftJoin(shops, eq(cancellations.externalShopId, shops.id));
  return rows.map((r) => {
    const companyName = r.partnerName || r.businessName || '不明';
    return { ...toDomain(r.c), shopName: companyName, companyName, storeName: r.storeName || null };
  });
},
```

**該当コード（変更後・フィルター経路は `applications` JOIN 無し・`companyName` 欠落）:**
```typescript
// サロン向けポータルの自社一覧。新カラム自動返却 + 発生店舗名（external_shops）を付与（REQ-7）。
findByApplicationIdWithShop: async (applicationId, db = getDb()) => {
  const rows = await db.select({ c: cancellations, storeName: shops.shopName })
    .from(cancellations)
    .leftJoin(shops, eq(cancellations.externalShopId, shops.id))
    .where(eq(cancellations.applicationId, applicationId));
  return rows.map((r) => ({ ...toDomain(r.c), storeName: r.storeName || null }));  // ← companyName 無し
},
```

**問題:** `getCancellations(applicationId)` は会社スコープ時に `findByApplicationIdWithShop` を呼ぶ（`cancellation.service.ts:57-60`）。これは元々サロン向けポータル用の関数で `applications` を JOIN せず `companyName` を返さない。一方グローバル用 `findAllWithShop` は `companyName`（＋後方互換の `shopName=companyName`）を返す。admin の共有コンポーネント `CancellationManagement.tsx:339` は「会社名」列に `{invoice.companyName || invoice.shopName || '-'}` を描画するため、**会社詳細スコープのキャンセル一覧では会社名列が `-` 表示**になり、グローバルと食い違う（REQ-4「差分は `application_id` フィルターの有無のみ」に反する）。`storeName`（店舗名列）は両方で正常。フィルター e2e（`salonboard-store.test.js:540`）は id 集合のみ検証し `companyName` の有無を assert しないため検知できていない。

**修正提案:** `findByApplicationIdWithShop` を admin で流用せず、`findAllWithShop` 相当の projection（`applications` JOIN・`companyName` 付与）に `application_id` 条件だけを足した admin 用クエリへ寄せ、フィルター有無で shape が変わらないことをテストで固定する（サロンポータル側の既存契約に影響しないよう関数は分離する）。

---

### [Code Quality] 詳細ページの申請者情報が現行モーダルと同等でない（代表者名・生年月日・同意情報・備考・申込/更新日時が欠落・REQ-1 違反）

**ファイル:** `admin/src/components/ApplicationDetailLayout.tsx:241-256`
**重要度:** Medium

**該当コード（変更後・新ヘッダーの申請者情報）:**
```tsx
<h1 className="text-2xl font-bold text-gray-900">{application.partnerName}</h1>
<span className={...}>{statusLabel(application.status)}</span>
...
<div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-gray-500">
  <span>{entityTypeLabel(application.entityType)}</span>
  <span>{application.email}</span>
  {application.phone && <span>{application.phone}</span>}
  <span className="text-gray-400">ID: {application.id}</span>
</div>
```

**該当コード（変更前・旧モーダル `ApplicationDetail.tsx` が表示していた項目）:**
```tsx
// :118-127  代表者名 representativeName / 生年月日 birthDate
// :168-175  同意情報 application.agree（同意済み/未同意）
// :182-188  備考 application.notes
// :199-208  申込日時 createdAt / 更新日時 updatedAt
```

**問題:** REQ-1 は「詳細ページに表示する申請者情報の内容（事業者種別・名称・代表者名・生年月日・連絡先・同意情報・備考・申込日時／更新日時）は現行モーダルと同等とする」と明記。しかし新 `ApplicationDetailLayout` ヘッダーは `partnerName / status / entityType / email / phone / ID` のみで、**代表者名・生年月日・同意情報・備考・申込日時・更新日時がすべて欠落**している。運営が詳細ページで同意有無・備考・申込日時を確認できなくなる回帰。`ApplicationDetailLayout.test.tsx` もこれらの項目表示を assert していないため検知できていない。

**修正提案:** ヘッダー直下に申請者情報セクションを設け、旧モーダル同等の項目（法人時の代表者名・生年月日・同意バッジ・備考・createdAt/updatedAt）を復元する。表示を検証する Vitest を追加する。

---

### [Test Coverage] 非同期取り込み（202 started）後にボタンが即再活性化し、テスト（toBeEnabled）が AC-11/T-23 の文言（ボタン非活性）と矛盾している

**ファイル:** `admin/src/components/CancellationManagement.tsx:98-112` / `admin/e2e/import-button-context.spec.ts:3,90-91`
**重要度:** Medium（要・作者確認）

**該当コード（変更後・finally で即 importing=false）:**
```tsx
const handleImport = async () => {
  if (importing || !applicationId) return
  setError(null); setImportResult(null)
  try {
    setImporting(true)
    const result = await ApiService.importCancellations(applicationId)  // dev/prod は 202 {started:true} 即返し
    setImportResult(result)
    await loadInvoices()
  } catch (err) { setError(...) }
  finally { setImporting(false) }  // ← 202 直後にボタン再活性化（disabled={importing}）
}
```

**該当コード（変更後・e2e は名前と逆のアサーション）:**
```tsx
// 行3コメント: 「…『開始しました』を表示しボタンが押下不可になる。」
// 行90コメント: 「取り込み完了後はボタンは再び押せる（importing=false）。」
await expect(page.getByText('取り込みを開始しました')).toBeVisible();
await expect(page.getByRole('button', { name: '取り込み実行' })).toBeEnabled();  // ← AC とは逆
```

**問題:** Issue は AC-11/T-23 で一貫して「『取り込みを開始しました』表示**＋ボタン非活性**（二重実行防止）」を成功条件として明記している。実装は `finally` で `importing=false` に戻すため、非同期 `{started:true}`（202 即返し）の直後にボタンが再び押せ、admin が同一会社の取り込みを多重起動できる。さらに e2e はテスト名「ボタンが押下不可になる」と裏腹に `toBeEnabled()` を assert しており、仕様・実装・テストの三者が食い違う。バックグラウンドジョブの完了はクライアントから観測できないため、実装者が意図的に再活性化を選んだ形跡（行90コメント）がある＝バグ確定ではなく**仕様文言との不一致**。どちらを正とするか作者確認が必要。

**修正提案:** 仕様（二重実行防止）を維持するなら、`started` 用の別 state（例 `importStarted`）でボタンを disabled のまま据え置き、「更新」操作等で解除する設計にし、e2e を `toBeDisabled()` へ修正する。仕様側を緩めるなら Issue/AC-11・T-23 の文言を実態（202 後は再活性）に合わせて更新する。

---

### [Code Quality] 店舗単位 verify で店舗名が取得できなくても（空文字）検証成功になり、空名で保存される（AC-9 の店舗名取得失敗分岐が欠落）

**ファイル:** `api/src/services/salonboard-auth.service.ts:184-198`
**重要度:** Medium（厳密な AC 読み・エッジケース）

**該当コード（変更後・0件＝単一店舗パス）:**
```typescript
// 0 件 = 単一店舗アカウント。groupTop はシステムエラー画面のため店舗 TOP を取得して解析する。
let topHtml: string;
try { topHtml = await client.fetchStoreTopHtml(); }
catch (e) { return { ok: false, error: '店舗情報を取得できませんでした' }; }
const info = parseStoreTop(topHtml);
if (!info.externalStoreId) {
  return { ok: false, error: '店舗情報を取得できませんでした' };  // ← ID 欠落は弾く
}
return {
  ok: true,
  shop: { externalStoreId: info.externalStoreId, shopName: info.shopName ?? '' },  // ← 名前は空でも ok:true
};
```

**問題:** REQ-8/AC-9 は「ログイン成功でも店舗ID／**店舗名**を自動取得できなかった場合は…保存しない」と規定。`externalStoreId` 欠落は :192 で正しく弾くが、**`shopName` が空でも `ok:true`** を返し、`saveSalonboardShop` の fallback で空名のまま `shops` に保存される。`salons.length===1` 経路（:181）も `salon.shopName` をそのまま採用するため同様。AC-9 の「店舗名取得不可は未保存」分岐が実装・テストとも欠落。実害は admin が後で表示名を編集できる点で小さいが、AC を厳密に満たさない。

**修正提案:** verify 成功条件を `externalStoreId` かつ `shopName`（trim 後非空）の両方が取得できた場合に限定する（1件経路・0件経路の双方）。ID のみ取得／名前のみ取得／空名の fixture を追加する。

---

### [Code Quality] StoreForm で `source: 'salonboard'` をハードコード（REQ-10 の source 駆動方針からの逸脱）

**ファイル:** `admin/src/components/StoreForm.tsx:107`
**重要度:** Low

**該当コード（変更後）:**
```tsx
await ApiService.createShop({
  applicationId,
  ...,
  source: 'salonboard',   // ← ハードコード
})
```

**問題:** Issue の実装スコープは salonboard のみだが、REQ-10／ファイル変更表（「source を props で受け（既定 'salonboard'）」）は**コンポーネントを source 駆動**にする方針を明記している。`StoreForm` はソースを直書きしており、将来の連携先追加時にコンポーネント改修が必要になる。実害は将来のみで現スコープでは低優先。

**修正提案:** `source` を props/context で受け取り既定値だけ `'salonboard'` にする。`StoreList → StoreForm`（必要なら ApiService 呼び出しまで）一貫して伝播させる。

---

### [Test Coverage] e2e mock の連携単位（integration-unit）が「設定即ロック」になっており REQ-5 の「linked のみが lock 条件」を反映していない

**ファイル:** `admin/e2e/fixtures.ts:380`
**重要度:** Low

**該当コード（変更後）:**
```typescript
unitState = { unit: nextUnit, unitLocked: true }  // PUT 成功で即ロック
```

**問題:** REQ-5/AC-6 は「lock の唯一の判定条件は `linked=true` の有無。連携試行に失敗（`linked=false`）の段階では確定せず切り替え可能」と規定する。mock は単位 PUT 単体で即 `unitLocked:true` にしており、「連携失敗のままなら切替可能」挙動を再現できない。フロントはサーバ返却値を素直に反映するため本番バグではないが、mock が実 API 仕様と乖離していると将来の回帰を隠す。

**修正提案:** mock の lock は「店舗作成／会社単位連携保存などで linked になった時」に限定し、単位 PUT 単体ではロックしないよう実 API 仕様に寄せる。

---

### [Code Quality] 死蔵コード `ApplicationDetail.tsx` と `StoreList.unitLocked` 未使用 props

**ファイル:** `admin/src/components/ApplicationDetail.tsx`（全体）/ `admin/src/components/__tests__/ApplicationDetail.test.tsx` / `admin/src/components/StoreList.tsx:8`
**重要度:** Low

**問題:** (a) REQ-1 でモーダル→ページ化した結果、旧 `ApplicationDetail.tsx` は本番経路から到達不能になったが削除されておらず、対応テストも維持されている（「会社単位連携 UI は健在」と読み手を誤認させる。上記 High 指摘の根本）。(b) `StoreList` の props 型 `unitLocked` は `ApplicationStoreList` から渡されるが本体で未使用。

**修正提案:** (a) は上記 High（会社単位連携導線）解決時に `SalonboardIntegration` の再配置とセットで `ApplicationDetail.tsx`／テストを削除する。(b) は使わないなら props から外す。

---

## 総評

横断対応（admin 主・api/batch 従）として REQ-1〜10 を概ね実装し、テスト整備（api Vitest 543／admin Vitest 144・Playwright 40）・PII 取扱い（パスワード AES-256-GCM・`hasPassword` のみ返却・fixture PII 置換）・migration 0006 の後方互換（リネーム・`NULLS NOT DISTINCT` UNIQUE・過去行バックフィルなし）は堅実で、Pre-PR で確定済みの2大欠陥（admin id 正規化／useCallback メモ化）も正しく修正されている。lessons 違反は無し。

一方、**機能の核に関わる High が2件**残っている:
1. **会社単位連携を実行する UI 導線の欠落**（admin）— 未連携で「会社単位」を選ぶと連携を完了できず、UC-2/UC-4 が成立しない。旧モーダルの死蔵化と表裏。
2. **会社単位保存のサーバ側 lock ガード欠如**（api）— REQ-5/AC-6 のサーバ側不変条件を迂回でき、店舗単位店舗の強制 unlink という状態不整合を招く。

Medium は REQ との細部不一致（会社名列の shape 不整合・申請者情報パリティ・非同期ボタン非活性・店舗名空保存）で、いずれも対応する検証テストが無いため緑のまま通過している。**1・2 を最優先**で対応し、Medium のうち「非同期ボタン非活性（AC-11/T-23）」は実装・テスト・Issue 文言の三者不一致のため**作者の意図確認**を推奨する。
