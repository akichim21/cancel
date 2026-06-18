---
issue: 12
date: 2026-06-11
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: feature/GTSS-13
    toBranch: GTSS-817
  - repo: user
    repoDir: cancel-billing-service
    baseBranch: feature/GTSS-13
    toBranch: GTSS-817
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: feature/GTSS-13
    toBranch: GTSS-817
---

# レビュー結果: #12

## 概要

**Issue:** #12 サロンボードからのキャンセル予約自動取り込み（クローリング連携）

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `feature/GTSS-13` | `GTSS-817` | 2 | 53 |
| user | `feature/GTSS-13` | `GTSS-817` | 1 | 8 |
| admin | `feature/GTSS-13` | `GTSS-817` | 1 | 19 |

レビュー実施: code-reviewer / lessons-reviewer / codex-reviewer（api・user・admin 各1）。全指摘はメインエージェントが worktree 実コードで再検証済み（裏取りできなかった指摘は破棄。codex 出力にセッション混入なし）。

## 変更ファイル一覧

### api（主要のみ。テストfixture・lockfileは省略）

| ファイル | 追加 | 削除 | 変更種別 |
|---|---|---|---|
| `src/services/salonboard-import.service.ts` | +416 | -0 | Added |
| `src/services/salonboard-client.ts` | +292 | -0 | Added |
| `src/services/cancellation-send.service.ts` | +232 | -0 | Added |
| `src/services/salonboard-auth.service.ts` | +169 | -0 | Added |
| `src/utils/salonboard-parser.ts` | +193 | -0 | Added |
| `src/utils/cancellation-fee.ts` | +137 | -0 | Added |
| `src/utils/crypto.ts` | +119 | -0 | Added |
| `src/utils/import-window.ts` | +59 | -0 | Added |
| `src/utils/mask-imported-pii.ts` | +78 | -0 | Added |
| `src/constants/cancellation-status.ts` | +118 | -0 | Added |
| `src/db/schema.ts` | +155 | -0 | Modified |
| `src/db/migrations/0003_gtss817_salonboard_import.sql` | +64 | -0 | Added |
| `src/repositories/cancellations.repository.ts` | +91 | -9 | Modified |
| `src/repositories/external-import-logs.repository.ts` | +112 | -0 | Added |
| `src/repositories/external-integrations.repository.ts` | +86 | -0 | Added |
| `src/repositories/external-shops.repository.ts` | +116 | -0 | Added |
| `src/services/cancellation.service.ts` | +56 | -1 | Modified |
| `src/handlers/salonboard.handler.ts` | +33 | -0 | Added |
| `src/handlers/cancellations.handler.ts` | +23 | -1 | Modified |
| `src/handlers/invoices.handler.ts` | +12 | -0 | Modified |
| `src/batch.ts` | +8 | -0 | Modified |
| `src/config.ts` | +2 | -1 | Modified |
| `src/__tests__/`（e2e 6本・unit 7本・helpers・fixtures） | +約3,900 | -1 | Added |

### user

| ファイル | 追加 | 削除 | 変更種別 |
|---|---|---|---|
| `src/components/InvoiceList.tsx` | +312 | -50 | Modified |
| `src/components/__tests__/InvoiceList.test.tsx` | +259 | -28 | Modified |
| `src/services/api.ts` | +15 | -0 | Modified |
| `src/services/__tests__/api.test.ts` | +32 | -0 | Added |
| `src/types/index.ts` | +23 | -1 | Modified |
| `e2e/invoice-board.spec.ts` | +156 | -0 | Added |
| `e2e/fixtures.ts` | +26 | -0 | Modified |
| `playwright.config.ts` | +2 | -1 | Modified |

### admin

| ファイル | 追加 | 削除 | 変更種別 |
|---|---|---|---|
| `src/components/CancellationManagement.tsx` | +252 | -40 | Modified |
| `src/components/SalonboardIntegration.tsx` | +252 | -0 | Added |
| `src/components/ImportLogList.tsx` | +103 | -0 | Added |
| `src/components/ApplicationDetail.tsx` | +4 | -0 | Modified |
| `src/components/Header.tsx` | +11 | -1 | Modified |
| `src/App.tsx` | +14 | -4 | Modified |
| `src/services/ApiService.ts` | +123 | -1 | Modified |
| `src/constants/cancellationStatus.ts` | +29 | -17 | Modified |
| `src/types/Cancellation.ts` | +95 | -3 | Modified |
| `e2e/cancellation-salonboard.spec.ts` | +185 | -0 | Added |
| `e2e/salonboard-integration.spec.ts` | +132 | -0 | Added |
| `e2e/import-logs.spec.ts` | +69 | -0 | Added |
| `e2e/fixtures.ts` | +152 | -0 | Added |
| `e2e/cancellation.spec.ts` | +8 | -7 | Modified |
| テスト3本・`playwright.config.ts`・`src/test/utils.tsx` | +50 | -29 | Modified |

## 指摘一覧

- [x] 対応する

### [Codex] 送信処理: status 遷移後の外部失敗を全て握り潰し、決済リンク無し通知が顧客へ届く

**ファイル:** `api/src/services/cancellation-send.service.ts:99-101,105,127,177-190`
**重要度:** High

**該当コード:**
```typescript
// toBranch側（新規ファイル）— dispatchPayment 内。Stripe 失敗は console.error のみで継続
    } catch (e) {
      console.error('send: Stripe checkout error:', e);
    }
  }

  // メール（メールがある場合）。← paymentLink === null でもガード無しで送信に進む
  if ((notificationMethod === 'email' || notificationMethod === 'both') && customerEmail) {
```

```typescript
// toBranch側 — performSend。遷移が先、通知が後。失敗しても success: true
  const transitioned = await cancellationsRepo.markSentIfPreSend(cancellation.id, { amount });
  ...
  const paymentLink = await dispatchPayment(transitioned, application);
  const finalRow = await cancellationsRepo.getById(cancellation.id);
  return json(200, corsHeaders, {
    success: true,
    data: { ...finalRow, stripePaymentUrl: paymentLink ?? finalRow?.stripePaymentUrl },
  });
```

**問題:** `markSentIfPreSend` で不可逆に `pre_send→pending` へ遷移した**後**に Stripe/SES/Twilio を実行し、エラーは全て `console.error` で握り潰して `success: true` を返す。Stripe checkout 作成失敗時も `paymentLink=null` のままメール/SMS 送信に進む（`:105`/`:127` にガード無し）ため、**決済リンクの無い請求通知が実顧客に届き**、status は pending のため再送は `alreadySent` で弾かれる。復旧手段は status の手動巻き戻し（次指摘の無検証 API）しかない。
**修正提案:** (a) Stripe リンク作成失敗時は通知をスキップし、status を `pre_send` に戻す（または `send_failed` 等の再試行可能状態）。(b) レスポンスに失敗を明示し admin/user UI で警告表示。(c) Stripe mock reject の失敗系 e2e を追加。

---

### [Security] ステータス更新 API が無検証 × admin に pre_send ボタン追加 → 支払済み請求の再送信（二重請求）経路

**ファイル:** `admin/src/components/CancellationManagement.tsx:383`（UI）+ `api/src/services/cancellation.service.ts:173-190` + `api/src/repositories/cancellations.repository.ts:193-199`
**重要度:** High

**該当コード:**
```tsx
// baseBranch側（変更前）— admin 詳細モーダルのステータス更新ボタン
{(['draft', 'pending', 'paid', 'failed', 'canceled'] as const).map(status => (
  <button key={status} onClick={() => handleStatusUpdate(selectedInvoice.id, status)} ...>
```

```tsx
// toBranch側（変更後）— pre_send が追加され、全行で任意遷移が可能
{(['pre_send', 'pending', 'paid', 'failed', 'canceled'] as const).map(status => (
  <button key={status} onClick={() => handleStatusUpdate(selectedInvoice.id, status)} ...>
```

```typescript
// api 側（既存・本PRで未強化）— whitelist も遷移ガードも無く生文字列を保存
    const { status } = updateData;
    if (!status) { return { statusCode: 400, ... }; }
    const updated = await cancellationsRepo.updateStatus(cancellationId, status);
```

**問題:** `PUT /cancellations/:id/status` は status の存在チェックのみで、値の whitelist 検証も遷移ガードも無い（新設 SSOT `cancellation-status.ts` の「想定外の値は呼び出し側のバリデーションで弾く」契約に対し、唯一の呼び出し側が弾いていない）。admin UI に `pre_send` ボタンが加わったことで、(a) `pre_send→pending` を送信モーダルを通さず実行でき**決済リンク発行・通知なしで「請求中」表示**になる、(b) **`paid → pre_send` に巻き戻すと「送信」ボタンが再出現し、支払済みの請求へ新しい Stripe 決済リンク+通知を再発行**できる。`markSentIfPreSend` の二重送信防止（AC-25）がこの経路で無効化される。なお `ApiService.updateCancellationStatus` の型には `pre_send` が無く、`as` キャストで型エラーを握り潰している（`CancellationManagement.tsx:108`）。
**修正提案:** API 側で `CANCELLATION_STATUS_VALUES` による検証＋`paid/pending → pre_send` の遷移禁止を追加。admin の汎用ステータスボタンから `pre_send` を外す（pre_send 行は送信モーダル経由のみ）。方針決定後に ApiService の型を揃えキャストを除去。

---

### [Codex] `CREDENTIALS_KMS_KEY_ID` がどのデプロイ経路にも存在せず、dev/prod で連携保存が必ず失敗する

**ファイル:** `api/src/utils/crypto.ts:65-75` + `api/deploy-api.sh` / `api/deploy-batch.sh` / `api/.env.example`（いずれも未収載）
**重要度:** High

**該当コード:**
```typescript
// toBranch側（新規ファイル）— dev/prod は KMS Encrypt に CREDENTIALS_KMS_KEY_ID が必須
const useKms = (): boolean =>
  process.env.NODE_ENV === 'prod' || process.env.NODE_ENV === 'dev';

const kmsKeyId = (): string => process.env.CREDENTIALS_KMS_KEY_ID as string;  // 未設定でも素通り

const kmsEncryptDataKey = async (dataKey: Buffer): Promise<string> => {
  const { KMSClient, EncryptCommand } = require('@aws-sdk/client-kms');
  const res = await client.send(new EncryptCommand({ KeyId: kmsKeyId(), Plaintext: dataKey }));
```

**問題:** dev/prod では `encryptSecret` が KMS Encrypt（`KeyId=CREDENTIALS_KMS_KEY_ID`）を要求するが、この変数は `deploy-api.sh` / `deploy-batch.sh` / `.env.example` のどこにも存在しない（grep で確認）。**dev/prod デプロイ後、連携設定の保存 API は実行時に必ず失敗する**。さらに deploy-api.sh は Lambda 環境変数を固定 JSON で全置換するため、手動設定しても次回デプロイで消える。KMS 鍵の作成・Lambda ロールへの `kms:Encrypt/Decrypt` 権限付与も infra 側に未反映。
**修正提案:** deploy-api.sh / deploy-batch.sh の Variables に `CREDENTIALS_KMS_KEY_ID` を追加し、`.env.example` にも追記。`kmsKeyId()` は未設定時に即 throw（fail-fast）。KMS 鍵作成と IAM 権限は infra リポジトリの TODO として明示。dev デプロイでの動作確認（CLAUDE.md の Verification Before Done）を完了条件にする。

---

### [Code Quality] サロンボード一覧取得: フォールバック後も非2xx を検証せず「予約0件の正常取り込み」としてサイレント成功する

**ファイル:** `api/src/services/salonboard-client.ts:258-265` + `api/src/utils/salonboard-parser.ts:84,101`
**重要度:** High

**該当コード:**
```typescript
// toBranch側（新規ファイル）— 再試行後の status を検証せず json() を返す
    let listRes = await fetchPage();
    if (listRes.status >= 400) {
      await this.refreshQueriesFromBundle();
      if (opts.page === 1) await setCondition();
      listRes = await fetchPage();
    }
    return listRes.json();   // ← 2回目も 4xx ならエラー JSON がそのまま返る
```

```typescript
// parser 側 — エラー JSON は edges 欠落 → 空配列・totalPages=1 に正規化される
  const edges: any[] = search?.edges ?? [];
  ...
  const totalPages = Math.max(1, pageInfo.length || 1);
```

**問題:** 動的フォールバック再試行後も `listRes.status >= 400` のまま `json()` を返すため、persisted query がフォールバックでも復旧しない事態（HPB 大規模リリース等）が **「予約0件の正常取り込み」として恒久的にサイレント成功**する。`importShop` の try/catch は throw しか拾わないので `failed` にも計上されず、運用上検知不能（REQ-3「特定店舗が継続的に失敗する場合に運営が気づける」に反する）。`enterStore` も応答ステータスを検証していない。
**修正提案:** 再試行後も非 2xx なら throw して店舗レベル失敗（`failed`+`error`）に計上する。「フォールバック後も失敗」ケースの unit テストを追加（現状の `salonboard-client-fallback.test.js` は「2回目成功」のみ）。

---

### [Codex] user PC テーブルが `overflow-hidden` のまま 6→13 列化し、中幅画面で操作列（送信ボタン）に到達できない

**ファイル:** `user/src/components/InvoiceList.tsx:446`
**重要度:** High

**該当コード:**
```tsx
// baseBranch側（変更前）— 6列のテーブル。overflow-hidden でも実害なし
<div className="hidden md:block card overflow-hidden">
  <table className="min-w-full divide-y divide-gray-200">
```

```tsx
// toBranch側（変更後）— ラッパーは不変のまま列が13に倍増（全セル whitespace-nowrap）
{/* PC: テーブル表示 */}
<div className="hidden md:block card overflow-hidden">
  <table className="min-w-full divide-y divide-gray-200">
```

**問題:** 列数が 6→13 に倍増（`<th>` カウントで確認）し全セル `whitespace-nowrap` だが、外側が `overflow-hidden` のままなので、md〜ノートPC幅では右端の列が**スクロール不能のままクリップ**される。最右の操作列に到達できず、**pre_send の送信操作自体が不可能**になる。Playwright はデフォルト 1280px で通るため検知されない。
**修正提案:** ラッパーを `overflow-x-auto` に変更（必要なら table に `min-w-max`）。admin 側も同様の確認を推奨。

---

### [Code Quality][Lessons] admin の楽観更新が `statusLabel` を据え置き、ステータス変更後も旧ラベルが表示され続ける

**ファイル:** `admin/src/components/CancellationManagement.tsx:109-112`（楽観更新）、`:312`（一覧バッジ）、`:359`（詳細）
**重要度:** Medium

**該当コード:**
```tsx
// toBranch側 — status のみパッチし statusLabel は古いまま
await ApiService.updateCancellationStatus(invoiceId, newStatus as 'draft' | 'pending' | 'paid' | 'failed' | 'canceled')
setInvoices(prev => prev.map(c => c.id === invoiceId ? { ...c, status: newStatus } : c))
if (selectedInvoice?.id === invoiceId) {
  setSelectedInvoice(prev => prev ? { ...prev, status: newStatus } : null)
}
```

```tsx
// 表示側 — statusLabel を優先するため旧ラベルが残る
<span className={...}>{invoice.statusLabel || getStatusLabel(invoice.status)}</span>
```

**問題:** 実 API は `serializeCancellation` で全行に `statusLabel` を必ず付与するため、本番ではステータス変更後もバッジ・詳細がリロードまで旧ラベル表示のままになる（サマリーカードは status から再計算するため表示が矛盾する）。unit/e2e のフィクスチャが `statusLabel` を省略しているため検知できていない — lessons の「テストデータ形状では通るが実環境データで壊れる」パターン。
**修正提案:** 楽観更新で `statusLabel: getStatusLabel(newStatus)` を併せて設定。`statusLabel` 付きフィクスチャで「変更→ラベル変化」を検証するテストを追加。

---

### [Codex] user Dashboard が pre_send 未対応（「不明」表示・「今月の請求額」に未送信分を合算）

**ファイル:** `user/src/components/Dashboard.tsx:130-146`（getStatusText）、`:52-74`（calculateStats）
**重要度:** Medium

**該当コード:**
```tsx
// 変更前後とも同一（本PRで未修正）— pre_send ケースが無く default '不明'
const getStatusText = (status: Invoice['status']) => {
  switch (status) {
    case 'paid': return '支払い完了';
    case 'sent':
    case 'pending': return '支払い待ち';
    ...
    default: return '不明';
  }
};
```

**問題:** Dashboard は InvoiceList と同じ `apiService.getInvoices()` を使うため、取り込み済み `pre_send` 行が「最近の請求書」に流入するが、Dashboard 独自の `getStatusText` に `pre_send` が無く**「不明」と表示**される（`statusLabel` フォールバックも無し）。さらに `calculateStats` の「今月の請求額」は status を問わず当月作成分を合算するため、**未送信の pre_send 金額が請求額として計上される**。
**修正提案:** ステータスラベル定義を共通モジュール化して Dashboard にも適用（`statusLabel` 優先 + `pre_send`=送信前）。「今月の請求額」「支払い待ち」への pre_send の含め方を意図的に決めて反映する。

---

### [Code Quality] 取り込みログ一覧の「店舗」列が本番では内部 UUID 表示になる

**ファイル:** `admin/src/components/ImportLogList.tsx:88` + `api/src/repositories/external-import-logs.repository.ts:91-96`
**重要度:** Medium

**該当コード:**
```typescript
// api 側（新規）— コメントの通り JOIN 無しで storeName を返さない
  // 管理画面の取り込みログ一覧（全件・店舗 JOIN 無し。理由・店舗ID・予約ID・対象期間を返す）。
  findAll: async (db: any = getDb()) => {
    const rows = await db.select().from(externalImportLogs);
    return rows.map(toDomain);
  },
```

```tsx
// admin 側（新規）— storeName が無いと externalShopId（UUID FK）を表示
<td className="...">{log.storeName || log.externalShopId || '-'}</td>
```

**問題:** API の `findAll` は external_shops を JOIN せず `storeName` を返さない（`listImportLogs` も付与しない）ため、**本番では店舗列に内部 UUID が表示される**。admin の e2e は実 API が返さない `storeName` 入りのモック（`e2e/fixtures.ts:186` は `{ success, importLogs }` 形状。実 API は素の配列）で表示をテストしており、本番で再現しない画面を検証している。
**修正提案:** API 側 `findAll` で external_shops を JOIN して `storeName` を返す。e2e モックのレスポンス形状・フィールドを実 API に合わせる。

---

### [Performance][Codex] 手動取り込みが API Gateway リクエスト内で全社・全店舗クローリングを同期実行（29秒制限で 504）

**ファイル:** `api/src/services/cancellation.service.ts:40-60`（`POST /cancellations/import`）
**重要度:** Medium

**該当コード:**
```typescript
// toBranch側（新規）— HTTP リクエスト内で全量同期実行
export const importCancellations = async (event, corsHeaders) => {
  const authCheck = requireAdmin(event, corsHeaders);
  if (authCheck.error) { return authCheck.response; }
  try {
    const summary = await runSalonboardImport({ now: new Date() });
    return { statusCode: 200, headers: corsHeaders,
      body: JSON.stringify({ success: true, ...summary }) };
```

**問題:** 手動取り込みは連携済み全会社・全店舗のクローリング（会社ごとログイン → 店舗ごと一覧全ページ + 予約詳細最大4並列）を同期実行する。実データ規模では API Gateway のハードリミット 29 秒を超える可能性が高く、admin は 504 を受けるが Lambda 側は処理継続するため「エラー表示なのに取り込みは進む」不整合になる（AC-15 の完了後件数確認が成立しない）。冪等キーで二重作成は防がれる。
**修正提案:** batch Lambda の非同期 Invoke（`action: 'salonboard-import'`）＋結果は取り込みログ/一覧で確認する方式へ変更。当面の暫定なら 504 時の運用手順を明記。

---

### [Security] crypto: マスター鍵未設定時にソース記載の公知文字列由来の固定鍵へ無警告フォールバック（fail-open）

**ファイル:** `api/src/utils/crypto.ts:47-59`
**重要度:** Medium

**該当コード:**
```typescript
// toBranch側（新規）— 未設定なら公知文字列から導出した固定鍵を使用
const resolveMasterKey = (): Buffer => {
  const b64 = process.env.CREDENTIALS_MASTER_KEY;
  if (b64 && b64.trim()) { ... }
  // ローカル開発・テスト専用の決定的フォールバック鍵（dev/prod では使わない）。
  return crypto.createHash('sha256').update('cancel-billing-local-dev-master-key').digest();
};
```

**問題:** `useKms()` は `NODE_ENV === 'prod' | 'dev'` の厳密一致で、それ以外は全て公知固定鍵へフォールバックする。deploy スクリプトが NODE_ENV を強制注入するため本番経路での発現可能性は低いが、NODE_ENV の設定ミスや将来の実行経路追加で**本物のサロンボードパスワードが公知鍵で暗号化保存**され得る fail-open 構造。
**修正提案:** フォールバック鍵は `NODE_ENV === 'test'`（および明示の local）に限定し、それ以外で鍵未設定なら throw（fail-closed）。

---

### [Codex] 日次バッチの実行結果（店舗別失敗含む）がどこにも記録されない

**ファイル:** `api/src/batch.ts:33-40` + `api/src/services/salonboard-import.service.ts`（markShopsFailed）
**重要度:** Medium

**該当コード:**
```typescript
// toBranch側（追加）— summary は return のみ（EventBridge 非同期呼び出しでは破棄される）
    case 'salonboard-import': {
      // 日次取り込み（GTSS-817 / REQ-3）。EventBridge Scheduler `cron(10 0 * * ? *)` Asia/Tokyo から発火。
      const result = await runSalonboardImport({ now: new Date() });
      return { ok: true, action, ...result };
    }
```

**問題:** REQ-3 は「実行結果（店舗別の作成/対象外/失敗件数）を記録し後から確認できる」「特定店舗の継続失敗に運営が気づける」ことを要求するが、batch は summary を return するだけで `[batch] received action` 以外のログが無い。EventBridge からの非同期呼び出しでは戻り値は破棄され、ログイン失敗・店舗取得失敗は `external_import_logs` にも残らず**日次実行では完全に不可視**。前述のサイレント成功（salonboard-client）と組み合わさると障害に気づく手段が無い。
**修正提案:** 最低限 `console.log(JSON.stringify(summary))` の構造化ログを出す。望ましくは実行単位の記録（テーブル or CloudWatch メトリクス＋アラーム）。
-> テーブルに記録して

---

### [Codex] 連携保存が非トランザクション＋再連携時に消滅店舗を unlink しない

**ファイル:** `api/src/services/salonboard-auth.service.ts:73-97`
**重要度:** Medium

**該当コード:**
```typescript
// toBranch側（新規）— Tx 無しで逐次 upsert。今回取得されなかった旧店舗はそのまま
  const encryptedSecret = await encryptSecret(password);
  await externalIntegrationsRepo.upsert({ applicationId, source: SOURCE, loginId, encryptedSecret, linked: true, ... });

  const savedShops = [];
  for (const salon of verified.salons!) {
    const shop = await externalShopsRepo.upsertByStore({ ... linked: true });
    savedShops.push(shop);
  }
```

**問題:** 認証情報と店舗一覧の保存が単一トランザクションでなく、途中失敗で部分保存になる。また再連携時に今回取得されなかった既存店舗を `linked=false` にしないため、サロンボード側で閉店・除外された店舗が日次取り込み対象に残り続け、毎日 `enterStore` 失敗を出し続ける（前指摘により失敗は不可視のまま）。
**修正提案:** 保存を単一 Tx 化し、取得結果に含まれない既存店舗を unlink する。

---

### [Code Quality] キャンセル料の整数チェックが3層とも欠如（＋user は予約金額欠落時に上限チェック自体をスキップ）

**ファイル:** `api/src/services/cancellation-send.service.ts:161-174` / `user/src/components/InvoiceList.tsx:162-175` / `admin/src/components/CancellationManagement.tsx:133-141`
**重要度:** Medium

**該当コード:**
```typescript
// api（新規）— Number.isFinite のみ。100.5 等の小数が通過
  if (!Number.isFinite(amount) || amount <= 0) {
    return json(400, corsHeaders, { success: false, error: 'キャンセル料は0より大きい必要があります' });
  }
  if (appointmentAmount != null && amount > appointmentAmount) { ... }
```

```tsx
// user（新規）— appointmentAmount が null/undefined だと上限チェックをスキップ
    if (target.appointmentAmount != null && amount > target.appointmentAmount) {
      return { error: `キャンセル料は予約金額（...）以下で入力してください。` };
    }
    return { amount };
```

**問題:** 小数（例 `100.5`）が全層のバリデーションを通過する。`cancellations.amount` は integer 列のため `markSentIfPreSend` の UPDATE が DB エラーになるか、通過しても Stripe の JPY `unit_amount`（整数必須）が失敗し、前述の「リンク無し通知」経路に合流する。また user 側は `appointmentAmount` 欠落行で AC-20 の上限なしに任意の正値を送信できる（API 側も同条件でスキップするため最終防衛線が無い）。
**修正提案:** API に `Number.isInteger(amount)` を 400 バリデーションとして追加し、user/admin の入力に `step="1"`＋整数チェックを追加。`appointmentAmount` 未取得時の送信可否を仕様として決める（推奨: 送信不可＋案内）。整数外・予約金額欠落のテストを追加。

---

### [Codex] REQ-2 の「キャンセル日」が永続化されず、「キャンセル処理日」に取り込み実行日（createdAt）を表示

**ファイル:** `api/src/services/salonboard-import.service.ts:257` + `api/src/db/schema.ts`（該当カラム無し） + `admin/src/components/CancellationManagement.tsx:321,365`
**重要度:** Medium

**該当コード:**
```typescript
// api（新規）— cancelDate は料金計算にのみ使用し、保存していない
      cancelDate: (r.updatedAt as string) || (r.visitationDate as string),
```

```tsx
// admin（新規）— 「キャンセル処理日」列に createdAt（取り込み実行日時）を表示
<td className="...">{fmtDate(invoice.createdAt)}</td>
```

**問題:** REQ-2 の保存項目一覧に「キャンセル日」が明記されているが、schema に対応カラムが無くサロンボード上のキャンセル日（一覧の `updatedAt`）は永続化されない。取り込みは3日前まで遡るため、admin/user の「キャンセル処理日」（createdAt）は実際のキャンセル日と最大数日ずれる。詳細モーダルでは同じ createdAt を「キャンセル処理日」と「作成日」の2ラベルで重複表示している。
**修正提案:** `canceledAt`（または `externalCanceledAt`）カラムを追加して取り込み時に保存し、一覧・詳細・送信モーダルの「キャンセル日」表示をそちらへ切り替える。

---

### [Codex] user モバイルカード: pre_send（未送信）行に「支払期限」を表示

**ファイル:** `user/src/components/InvoiceList.tsx:405-415`
**重要度:** Medium

**該当コード:**
```tsx
// toBranch側 — pre_send でも createdAt+30日 の支払期限を無条件表示
<p>支払期限: {invoice.dueDate ? formatDate(invoice.dueDate) : (() => {
  const d = new Date(invoice.createdAt);
  d.setDate(d.getDate() + 30);
  return formatDate(d.toISOString());
})()}</p>
```

**問題:** `pre_send` は決済リンク未発行・顧客未通知の状態だが、モバイルカードでは従来通り「支払期限」が表示され誤解を招く。またモバイルカードへの REQ-7 項目追加は `storeName` のみ（予約ID・支払い種別・来店日時等は詳細モーダル経由でのみ確認可能）。
**修正提案:** pre_send 行では支払期限を非表示にし、来店日時等へ差し替える。REQ-7 の一覧必須項目をモバイルカードへどこまで出すかは仕様判断として作者確認。

---

### [Test Coverage][Lessons] 送信テストが宛先・金額・本文を未検証／冪等キー競合・フォールバック失敗系のテスト欠如／弱いアサーション

**ファイル:** `api/src/__tests__/e2e/salonboard-send.test.js:70-100`（T-18/T-30）、`api/src/__tests__/e2e/salonboard-import.test.js:160,206`、`api/src/repositories/cancellations.repository.ts:121-133`（createImported）、`admin/e2e/salonboard-integration.spec.ts:127-130`
**重要度:** Medium

**該当コード:**
```javascript
// T-18 — タイトルは「送信先=顧客連絡先」だが、検証は呼び出し回数と status のみ
expect(stripe.checkout.sessions.create).toHaveBeenCalledTimes(1);
expect(twilio.messages.create).toHaveBeenCalledTimes(1);
const updated = await cancellationsRepo.getById('imp_send_1');
expect(updated.status).toBe('pending');
```

```typescript
// admin e2e — 入力欄は常に描画されるのに条件付きアサーション（無ければ黙って PASS）
const pwInput = page.getByLabel('パスワード');
if (await pwInput.count()) {
  await expect(pwInput).toHaveValue('');
}
```

**問題:** (a) T-18 は Twilio の `to`・SES の `Destination`・Stripe の `unit_amount`（編集後キャンセル料）を検証せず、誤宛先・誤金額バグが green で通る。T-30 は「SES なし」を謳いながら SES 不送信アサーションが無く、`await import('@aws-sdk/client-ses')` は未使用デッドコード。vitest lesson「呼び出し引数（送金額・送信先・本文）を expect で検証する」に反する。(b) 冪等性の最後の砦 `createImported` の `onConflictDoNothing`（部分ユニーク arbiter）を実際に競合させるテストが無い。(c) T-20/T-33 の `toBeGreaterThanOrEqual(1)` は期待値が確定計算できるのに弱い不等号。(d) admin e2e の条件付きアサーションは要素が消えると検証ごと消える。
**修正提案:** T-18 に `mock.calls` の宛先・`unit_amount`・本文アサーションを追加。T-30 は `aws-sdk-client-mock` で SendEmailCommand 0 件を検証。同一冪等キーで `createImported` 2回呼び→2回目 `{created:false}` の e2e 追加。`toBe(1)` へ厳密化。条件分岐を外し無条件アサーションに。

---

### [Code Quality] GET /cancellations/:id だけ serializeCancellation 未適用（statusLabel 無し・legacy 値未正規化）

**ファイル:** `api/src/services/cancellation.service.ts:157-160`
**重要度:** Low

**該当コード:**
```typescript
// 変更前後とも — 一覧は serialize 済みだが単件は生 item を返す
    return {
      statusCode: 200,
      headers: corsHeaders,
      body: JSON.stringify(item)
    };
```

**問題:** 一覧（管理者/サロン）は `serializeCancellation` で `statusLabel` 付与・legacy `sent` 正規化するが、単件取得だけ生で返り API 契約が不整合。
**修正提案:** `JSON.stringify(serializeCancellation(item))` に揃える。

---

### [Code Quality] detail_fetch_failed の取り込みログが、リトライ成功後も「失敗」のまま残る

**ファイル:** `api/src/services/salonboard-import.service.ts`（作成成功時のログ削除なし）+ `api/src/repositories/external-import-logs.repository.ts`
**重要度:** Low

**問題:** `detail_fetch_failed` でログ記録された予約が翌日リトライで取り込み成功しても、ログ行の削除・更新が無い（grep で delete/resolved 系の処理が無いことを確認）。admin の取り込みログ上は「詳細取得失敗」に見え続け、キャンセル一覧と矛盾する。
**修正提案:** `createImported` 成功時に該当予約の import log を削除（または resolved 相当へ更新）。

---

### [Code Quality] SalonboardIntegration: placeholder 文言「変更する場合のみ入力」と実挙動（再保存に常にパスワード必須）が矛盾

**ファイル:** `admin/src/components/SalonboardIntegration.tsx:235`（placeholder）、`:54-57`（handleVerify）
**重要度:** Low

**該当コード:**
```tsx
// toBranch側（新規）
placeholder={integration?.hasPassword ? '設定済み（変更する場合のみ入力）' : ''}
...
if (!loginId.trim() || !password.trim()) {
  setError('ログインIDとパスワードを入力してください')
  return
}
```

**問題:** 保存は必ず検証（パスワード必須）経由のため、パスワード再入力なしでは店舗名の再編集・再保存ができない。文言が「変更する場合のみ入力」だと省略可能に読める。
**修正提案:** placeholder を「再連携にはパスワードの再入力が必要」へ修正するか、保存済み認証情報での店舗名のみ更新 API を用意。

---

### [Security] admin getCancellations の `console.log` がレスポンス全体（顧客 PII）をブラウザコンソールへ出力

**ファイル:** `admin/src/services/ApiService.ts:195`
**重要度:** Low

**該当コード:**
```typescript
// 既存コード（本PRの追加ではない）— ただし本PRで PII フィールドが大幅増
const data = await response.json()
console.log('Cancellations Response:', data)
```

**問題:** ログ自体は既存だが、本 PR で電話番号・カナ氏名・予約時キャンセル規定など顧客 PII がレスポンスに増えたため露出リスクが拡大した。
**修正提案:** レスポンス全体のログを削除（または件数のみに縮小）。

---

### [Code Quality] admin CSV: ヘッダー「店子名」のまま値が店舗名/会社名混在＋新規カラム未追加、日付フォーマットの TZ 未固定

**ファイル:** `admin/src/constants/cancellationStatus.ts:86,102` + `admin/src/components/CancellationManagement.tsx:21` / `admin/src/components/ImportLogList.tsx:6`
**重要度:** Low

**該当コード:**
```typescript
// toBranch側 — ヘッダーは旧「店子名」のまま、値は storeName を先頭にフォールバック
  '店子名',
  ...
    invoice.storeName || invoice.companyName || invoice.shopName || '',
```

**問題:** 一覧では店舗名/会社名を別カラムに分けた方針と CSV が不整合（1列に混在）。予約 ID 等の新カラムも CSV 未反映。また `toLocaleDateString('ja-JP')` が端末 TZ 依存（JST 以外の端末で前日表示になり得る）。
**修正提案:** CSV のヘッダー/カラムを一覧の新構成に合わせる。共通フォーマッタに `timeZone: 'Asia/Tokyo'` を明示。

---

## 総評

冪等化（`(externalShopId, externalReservationId)` 部分ユニーク＋`markSentIfPreSend` の条件付き原子更新）、認可チェーン（連携設定3エンドポイント=requireAdmin、送信=admin/salon 2系統＋所有者チェック）、パスワードの秘匿（平文/blob をレスポンス・ログに出さない、`hasPassword` のみ返却）、PII マスク、料率パース・端数切り捨て・上限クランプの unit テスト網羅は高品質で、全レビュアーが一致して評価した。

一方で対応必須なのは High 5件:
1. **送信失敗の握り潰し**（顧客にリンク無し通知が届き復旧経路が無い）
2. **status 無検証×pre_send 巻き戻し**による支払済み請求の再送信経路（二重請求事故）
3. **`CREDENTIALS_KMS_KEY_ID` 未配備**（dev/prod で連携保存が動かない。dev デプロイ検証で即発覚する類）
4. **一覧取得のサイレント成功**（persisted query 恒久拒否が「0件成功」に化け、12の「バッチ結果未記録」と合わせ完全に不可視）
5. **user テーブルの overflow-hidden**（中幅画面で送信操作不能）

また **要確認事項**として、GraphQL persisted query の送り方について Issue 本文（「サーバは persisted `id` を受け付けず完全なクエリ文字列を要求」）と `docs/tech/salonboard-import.md:33`（「`query` フィールドに 32桁 hex id を入れれば受理される。2026-06-11 実HTTP実証」）の記載が異なる。実装・doc は整合しており doc は実証ベースだが、フォールバックパーサも id しか抽出しないため、サーバが完全クエリ文字列必須に変わった場合は自動復旧できない。実 HTTP 疎通の確認結果を Issue コメントに明示することを推奨する。

テストは量・構成（unit/e2e 分離、実 fixture HTML、テスト注入シーム）とも良好だが、「呼び出し引数の検証」（宛先・金額・本文）と失敗系（Stripe reject・フォールバック後失敗・冪等キー競合）が薄く、green でも誤送信バグを検知できない箇所がある。High 対応とあわせて補強を推奨する。
