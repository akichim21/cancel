---
issue: 30
date: 2026-06-25
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-817
    toBranch: GTSS-836
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: GTSS-817
    toBranch: GTSS-836
  - repo: lp
    repoDir: cancel-billing-service-lp
    baseBranch: feature/GTSS-13
    toBranch: GTSS-836
---

# レビュー結果: #30 代理店コードの記録（GTSS-836）

3本（api / admin / lp）を code-reviewer / lessons-reviewer / codex-reviewer の 3 サブエージェントでレビューし、
全指摘を worktree 実コードと突き合わせて再検証（cross-file 追跡）した。裏取りできた指摘のみ採録する。

## 概要

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-817` | `GTSS-836` | 1 | 10 |
| admin | `GTSS-817` | `GTSS-836` | 1 | 11 |
| lp | `feature/GTSS-13` | `GTSS-836` | 1 | 4 |

総合判定: **条件付き承認**。致命的（ブロッカー）なし。要判断 1・要対応(medium) 2・低 4。
正規化の一貫性 / `GET /cancellations` の `requireAdmin` / CSV 列順・PII不変 / 支払日 JST 日境界 / LP first-touch・
payload 非破壊 / テスト網羅は検証して妥当だった。

## 指摘一覧

- [ ] 対応する（要判断）

### [Security] 1. `agentCode` が未認証の `GET /applications` / `GET /applications/:id` 応答に出る
**ファイル:** `api/src/handlers/applications.handler.ts:23,75`、`api/src/constants/application-enums.ts:113`（`serializeApplication`）
**重要度:** Medium（要判断 / スコープ次第）

**問題:** `GET /applications`（一覧）と `GET /applications/:id`（詳細）には `requireAdmin` が無く（lambda にグローバル
認証ミドルウェアも無い）、`serializeApplication` が whitelist ではなく spread passthrough のため、本PRで追加した
`agentCode` がこれら**未認証 EP のレスポンスに乗る**ようになった。仕様「代理店コードは admin の精算用途に閉じる／
サロン・顧客向けに出さない」と契約レベルで弱く矛盾する。本PRの api テスト（`__tests__/e2e/agent-code.test.js:57,113`）が
**未認証 GET で agentCode が返ること**を期待値として固定している（指摘5参照）。

**再検証で判明した文脈（重要）:**
- これらの GET は**本PR以前から email / phone / 代表者名 / 生年月日など全 PII を未認証で返している**既存の認可ギャップで、
  `agentCode` はそこに1フィールド増えただけ（本PRが新設した穴ではない）。
- **サロン/顧客フロント（user portal・LP）はこの2つの GET を呼んでいない**（grep: user portal は `/applications` 不使用、
  LP は `POST /applications` と `/stripe-*` のみ）。**消費しているのは admin のみ。** 実画面への漏洩は現状なし＝AC（画面非表示・
  CSV元データ admin限定）は満たしている。

**修正提案（要判断。いずれか）:**
- (a) `GET /applications` + `GET /applications/:id` に `requireAdmin` を付与する。**消費者は admin のみ**のため低リスクで、
  既存の PII 未認証露出も同時に塞げる。ただし `applications.test.js` 等の「トークン無し GET で 200」を期待する既存テストを
  admin トークン付きへ更新する必要がある（本PRのスコープ拡大）。
- (b) public/salon 用の serializer で `agentCode` を除外し、admin 取得経路でのみ付与する。
- (c) 既存の未認証 PII 露出を許容する現状方針のままとし、agentCode も「画面非表示で足りる」と判断して**意図的に許容**する。
  その場合は Issue にその判断を明記し、指摘5のテストはそのまま（現状の挙動固定）でよい。

> 推奨: 既存 PII 露出の是正は規模が大きいため**別 Issue 化**し、本PRでは (c)（許容＋Issue 明記）または最小限 (b) を選ぶのが現実的。
> (a) を採るなら既存テスト更新まで含めて本PRで完結させること。

---

- [x] 対応する

### [Code Quality] 2. 代理店コード保存後に親一覧 state を更新せず、新設の一覧「代理店コード」列が古いまま残る
**ファイル:** `admin/src/components/ApplicationDetailLayout.tsx:215-223`（`handleSaveAgentCode`）
**重要度:** Medium

**該当コード（変更後 / 本PR）:**
```tsx
const handleSaveAgentCode = async () => {
  if (!application || savingAgentCode) return
  try {
    setSavingAgentCode(true)
    await ApiService.updateApplicationAgentCode(application.id, agentCodeInput)
    await loadApplication()          // 詳細のみ再取得。親一覧は更新しない
    notify('代理店コードを更新しました', 'success')
  } ...
}
```
**問題:** 同コンポーネントの `handleStatusUpdate`(176行) / `handleDelete`(205行) は保存後に
`await onApplicationsChanged?.()`（= App.tsx の一覧再取得）を呼ぶのに、`handleSaveAgentCode` は呼ばない。
本PRで `ApplicationList` に「代理店コード」列を新設したため、**詳細で代理店コードを編集→一覧へ戻ると当該列が
旧値のまま**になる（手動リフレッシュまで不整合）。
**修正提案:** `loadApplication()` に続けて `await onApplicationsChanged?.()` を呼ぶ。詳細保存→一覧で列が更新される
E2E を1本追加（指摘6と統合可）。

---

- [ ] 対応する（要判断）

### [Code Quality] 3. 手動「支払済」化は `paidAt` を設定しないため、支払日フィルタ／CSV「支払日」から外れる
**ファイル:** `admin/src/components/CancellationManagement.tsx:141-145`（`handleStatusUpdate`）
**重要度:** Medium（仕様判断を含む）

**該当コード:**
```tsx
await ApiService.updateCancellationStatus(invoiceId, newStatus)   // PUT /cancellations/:id/status
const newLabel = getStatusLabel(newStatus)
setInvoices(prev => prev.map(c => c.id === invoiceId ? { ...c, status: newStatus, statusLabel: newLabel } : c))
// loadInvoices() による再取得なし。paidAt も設定しない
```
**問題:** 本PRで `paidAt` が支払日期間フィルタ（`toJstDateKey(invoice.paidAt)`）と CSV「支払日」列の入力になった。
admin が詳細モーダルで請求を手動「支払済」に変更しても、`paidAt` はクライアントでもサーバー（`repo.updateStatus` は
status/updatedAt のみ更新。`paidAt` は Stripe webhook でのみ設定）でも入らない。結果、**手動支払済の行は支払日期間で
絞ると常に除外され、CSV の支払日セルも空**になる。
**再検証:** これは「精算は実際の決済日（Stripe 完了）が対象」と解釈すれば妥当な挙動だが、「支払済」なのに支払日が空＝
精算 CSV から漏れる点は運用上わかりにくい。`loadInvoices()` を足しても `paidAt` は埋まらない（webhook 由来のため）。
**修正提案（要判断）:** (a) 手動「支払済」遷移時にサーバーで `paidAt = now()` を設定する（手動決済を精算対象に含める意図なら）、
または (b) 仕様として「手動支払済は支払日を持たず期間精算の対象外」と明記する。最低限、手動ステータス更新後に
`await loadInvoices()` を呼び表示をサーバー状態に同期させる（status/updatedAt のズレ防止）。

---

- [x] 対応する

### [Code Quality] 4. LP のストレージ既定値評価が try の外にあり、Storage アクセス例外で申込が落ちうる
**ファイル:** `lp/src/utils/agentCode.js:11-12,25,36`、`lp/src/App.jsx`（mount effect の裸呼び出し / onSubmit）
**重要度:** Low

**該当コード:**
```js
const defaultStorage = () => (typeof window !== 'undefined' ? window.localStorage : null); // 例外吸収なし
export const getStoredAgentCode = (storage = defaultStorage()) => { try { ... } catch { return '' } }
export const captureFirstTouchAgentCode = (storage = defaultStorage(), ...) => { ... }
```
**問題:** デフォルト引数 `defaultStorage()` は関数本体の `try` の**前**に評価される。サンドボックス iframe など
`window.localStorage` プロパティ取得自体が `SecurityError` を投げる環境では、`useEffect` 内の
`captureFirstTouchAgentCode()`（App.jsx の裸呼び出し）や onSubmit 内の `getStoredAgentCode()` が catch されず throw し、
**onSubmit の catch に落ちて「ネットワークエラー」で申込が中断**する。代理店コードは任意項目であり「Storage 不可でも
申込は成功」を守るべき（狭いエッジだが本PRが新設した経路）。
**修正提案:** `defaultStorage`（必要なら `defaultSearch` も）を try/catch で包み null を返す。Storage アクセス例外でも
申込が成功する unit テストを追加。

---

- [x] 対応する

### [Test Coverage] 5. E2E T-12 の2回目保存が PUT 成功/反映を待たず弱い
**ファイル:** `admin/e2e/application.spec.ts`（T-12 後半 `fill('other')`→save→`toHaveValue('other')`）
**重要度:** Low

**問題:** 2回目（別値へ上書き）は `toHaveValue('other')` のみ検証。値は直前の `fill('other')` で既にセット済みのため、
**保存が壊れても緑になりうる**（1回目は成功トースト検証があるが2回目は無い）。指摘1の「未認証 GET で agentCode が返る」を
固定しているテスト箇所（`api/__tests__/e2e/agent-code.test.js:57,113`）も、指摘1の方針確定後に「非admin応答に agentCode が
出ない／admin応答には出る」へ見直す。
**修正提案:** 2回目保存も成功トースト or PUT 発行（`waitForRequest`）or GET 反映を待つ。指摘2の「一覧で列が更新される」検証と統合。

---

- [ ] 対応する（任意・低）

### [Security] 6. LP のデバッグ `console.log` に本PRで `agentCode`／`?agent=` が乗る
**ファイル:** `lp/src/App.jsx`（`console.log('Sending registration request:', requestData)` ほか）
**重要度:** Low

**問題:** `requestData` には既存の PII（email/phone/氏名）に加え本PRで `agentCode` が乗り、URL ログには `?agent=xxx` が出る。
本人のブラウザ console のみ（admin 限定要件自体は API/DB/画面で担保）だが、本番でのデバッグログ継続は望ましくない。
**修正提案:** 本番ではこのログを抑止（dev 限定化）、最低限 `agent`/`agentCode`/PII を redact（既存ログ全体の課題のため別途でも可）。

---

- [ ] 対応する（任意・nit）

### [Code Quality] 7. admin 代理店コード入力の `maxLength={64}` が trim 前 raw に効く
**ファイル:** `admin/src/components/ApplicationDetailLayout.tsx`（agent-code-input）
**重要度:** Low

**問題:** 前後空白付きで64文字超を貼ると、ブラウザが trim 前に64文字へ切るためサーバ正規化（trim→64）と順序がずれ、末尾実文字が
欠ける可能性。代理店コードは通常短く実害は極小。
**修正提案:** hard な `maxLength` を外しサーバ正規化に委ねる、またはクライアントでも trim 後長で揃える。

## Lessons 照合（lessons-reviewer）

- `.claude/lessons.md` および各 skill `lesson.md` と横断照合した結果、**記録済みパターンへの違反なし**。
  Vitest（具体値 assert・テスト間クリア・外部APIモック）、Playwright（CSV は実 download+内容 verify・CRUD は保存後反映 verify・
  フィルタ前後比較・key にユニーク値）、PII（admin 限定）、JST 日付、first-touch/localStorage の各 lesson に準拠。
- 参考（lesson 違反ではない）: CSV の数式インジェクション対策（先頭 `=`/`+`/`-`/`@` のサニタイズ）は現状 lesson 化されていない。
  代理店コードは admin 入力＋サーバ正規化の任意文字列で admin 限定運用のため実害は低いが、将来 lesson 化の余地あり。

## 破棄した指摘（誤検出）

- codex「api が REQ-7 の支払日 JST 期間フィルタ／精算 CSV を未実装」(high×2): **誤読。** フィルタ・CSV は admin フロント
  （`filterCancellations` / `buildCancellationCsv`）に実装済みで、API は全件＋`paidAt`/`agentCode` を返すデータ源という
  意図的なクライアントサイド設計。API 側に欠落なし。

## 総評

機能・テストは全体として堅実で、正規化・認可（更新EP/`GET /cancellations`）・CSV 後方互換・JST 境界・first-touch は妥当。
**本PR内で対応推奨**は指摘2（一覧列の stale 解消・onApplicationsChanged 追加）・指摘4（Storage 例外で申込を落とさない）・
指摘5（E2E の検証強化）。**要判断**は指摘1（未認証 GET の agentCode 露出をどのレイヤで admin 限定にするか。既存 PII 露出の
是正は別 Issue 推奨）・指摘3（手動「支払済」に支払日を持たせるか＝精算対象の定義）。指摘6・7は低優先（任意）。
