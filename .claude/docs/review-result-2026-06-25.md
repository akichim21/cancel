---
issue: なし（PR本文を仕様として使用）
date: 2026-06-25
repos:
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: GTSS-817
    toBranch: GTSS-817-jst-date-display
    pr: 8
  - repo: user
    repoDir: cancel-billing-service
    baseBranch: GTSS-817
    toBranch: GTSS-817-jst-date-display
    pr: 6
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-817
    toBranch: GTSS-817-temporal-types
    pr: 22
---

# レビュー結果: GTSS-817（日付/日時の型付け + 一律 JST 表示）

## 概要

**Issue:** なし。各 PR 本文を仕様として使用。

- **admin / user**（PR #8 / #6）= 表示層を端末 TZ 非依存で一律 JST 表示にする（新規 `utils/datetime.ts`）。
- **api**（PR #22）= DynamoDB 由来でない日時/日付カラムを `text` → `timestamptz`/`date` へ型付け、生表示値を `*_str` へ改名、取り込み実行ステータスを `status`(running/success/failed) に一本化。

3 リポジトリは「API は UTC ISO8601(`…Z`) で返し、各フロントが JST 固定で整形する」という責務分担で整合している。型付け・改名・ステータス一本化のいずれも呼び出しチェーンを実ファイルで追跡した結果、**重大な不整合（マッピング崩れ・migration のデータ欠落）は無し**。サブエージェント（code-reviewer / lessons-reviewer / codex-reviewer ×3）の指摘をメインで再検証し、裏取りできたもののみ採録した。

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| admin | `GTSS-817` | `GTSS-817-jst-date-display` | 2 | 22 |
| user  | `GTSS-817` | `GTSS-817-jst-date-display` | 1 | 9 |
| api   | `GTSS-817` | `GTSS-817-temporal-types` | 1 | 22 |

## 変更ファイル一覧（主なもの）

### admin
`src/utils/datetime.ts`(新規) / `src/utils/__tests__/datetime.test.ts`(新規) / `src/components/{CancellationManagement,Dashboard,ApplicationList,ApplicationDetailLayout,ImportLogList,ImportRunList,Header}.tsx` / `src/components/__tests__/{CancellationManagement,Header,ImportRunList}.test.tsx` / `src/constants/cancellationStatus.ts` / `src/services/ApiService.ts` / `src/types/Cancellation.ts` / `src/App.tsx` / `e2e/*.spec.ts`

### user
`src/utils/datetime.ts`(新規) / `src/utils/__tests__/datetime.test.ts`(新規) / `src/components/{InvoiceList,Dashboard,Header}.tsx` / `src/components/__tests__/InvoiceList.test.tsx` / `src/services/api.ts` / `e2e/*.spec.ts`

### api
`src/db/schema.ts` / `src/db/timestamps.ts`(新規) / `src/db/migrations/{0009,0010,0011}_*.sql` / `src/repositories/*.repository.ts`(8 ファイル) / `src/services/{salonboard-import,cancellation}.service.ts` / `src/batch.ts` / `src/__tests__/e2e/{typed-temporal-columns,salonboard-import-concurrency}.test.js`(新規)

---

## 指摘一覧

### [Code Quality] 非ゼロ埋め/秒なしの生 JST 値が `Invalid Date` → `-` に化ける表示回帰（最重要）

- [x] 対応する

**ファイル:** `admin/src/utils/datetime.ts:15-26`（`user/src/utils/datetime.ts:14-24` も同一実装）
**重要度:** High

**該当コード（変更後・toBranch）:**
```typescript
const toJstInstant = (value?: string | null): Date | null => {
  if (!value) return null;
  // 'YYYY/MM/DD HH:MM'（スラッシュ・空白区切り）も ISO 風へ寄せる。
  let s = String(value).trim().replace(/\//g, '-').replace(' ', 'T');
  const hasTz = /[zZ]$|[+-]\d{2}:?\d{2}$/.test(s);
  if (!hasTz) {
    if (!s.includes('T')) s += 'T00:00:00'; // 日付のみ
    s += '+09:00'; // 生値は JST 壁時計とみなす
  }
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
};
```

**該当コード（変更前・baseBranch、admin `CancellationManagement` の受信日時）:**
```tsx
<p ... data-testid="detail-received-at">
  {selectedInvoice.receivedAt ? new Date(selectedInvoice.receivedAt).toLocaleString('ja-JP') : '-'}
</p>
// → 変更後: {formatJstDateTime(selectedInvoice.receivedAt)}
```

**問題:**
`受信日時`(receivedAt) はサロンボード由来の生 JST 文字列で、API 側の抽出正規表現が **非ゼロ埋めを許容**している:
`cancel-billing-service-api/src/utils/salonboard-parser.ts:286` →
`/受信日時[：:]\s*([0-9]{4}\/[0-9]{1,2}\/[0-9]{1,2}\s+[0-9]{1,2}:[0-9]{2})/`（月/日/時が `{1,2}`）。
よって `2026/6/1 9:05` のような値が実データとして admin に届きうる。`toJstInstant` はこれを
`2026-6-1T9:05+09:00` に組み立てて `new Date()` に渡すが、これは ISO8601 非準拠のため **V8（Node/Chrome）でも `Invalid Date`** になり、`-`（fallback）が表示される。Node 実測:

```
formatJstDateTime('2026/6/1 9:05')   → '-'         （旧 new Date('2026/6/1 9:05') は '2026/6/1 9:05:00' を表示できていた）
formatJstDateTime('2026/06/01 15:05')→ '2026/6/1 15:05:00'  （ゼロ埋めは OK）
```

加えて、ゼロ埋めでも **秒なし＋オフセット**（`2026-06-01T15:05+09:00`）は ECMAScript の必須サポート外で、Safari 14.0 以前は `Invalid Date` を返す。テスト（`datetime.test.ts`）はゼロ埋め値しか使っておらず Node では green のため、この回帰を検出できない。「端末非依存」を目的にした PR が、実データ次第で受信日時欄を黙って空にしてしまう。

**修正提案:**
生 JST naive 値を `new Date(文字列)` のパーサ任せにしない。正規表現で年月日時分（秒）を構造化抽出し、各要素を `padStart(2,'0')` でゼロ埋めしてから `+09:00`（秒も補完）を付けた厳密な ISO 文字列を組む。`datetime.test.ts` に `2026/6/1 9:05`（非ゼロ埋め）と秒なしケースを追加して green を確認すること。なお、懸念された「日付のみ `2026-06-05` の末尾 `-05` を tz と誤判定するか」は実測で誤判定なし（`-05` は 2 桁で `[+-]\d{2}:?\d{2}$` に一致しない）＝この点は問題なし。

---

### [Code Quality] `ImportRun.status` 未定義/未知値が「成功」バッジにフォールスルーする

- [x] 対応する

**ファイル:** `admin/src/components/ImportRunList.tsx:111-123`（型: `admin/src/types/Cancellation.ts:181-182`、取得: `admin/src/services/ApiService.ts:456`）
**重要度:** Medium

**該当コード（変更後）:**
```tsx
// 型: status?: 'running' | 'success' | 'failed' | string   ← optional
{run.status === 'running' ? (
  <span ...>実行中</span>
) : run.status === 'failed' ? (
  <span ...>失敗</span>
) : (
  <span ...bg-green-100 text-green-800>成功</span>   // ← status が undefined/未知/旧 ok:false-only でもここ
)}
```

**問題:**
`status` は optional 型のまま、`running`/`failed` 以外を全て「成功」に倒す。`ApiService.getImportRuns`（再検証済み）は API レスポンスを正規化せず生 JSON を返すため、`status` が `undefined`（フロント先行デプロイで API が旧形式を返す移行期や、`status` を持たない旧 run レコード）の場合に **失敗実行が緑「成功」で表示**される。バッジの真上のコメントは「DB は notNull default 'success'」を前提にしているが、型は `status?`（optional）で矛盾している。`ImportRunList.test.tsx` は常に `status` を明示しており未定義ケースは未テスト。

実害の有無は「バックエンドの `ok→status` 移行が完了し legacy レコードが残らないか」に依存する（admin 差分のスコープ外）。少なくとも「未知/欠落は中立（不明）表示」にするか、API 境界で `status` を正規化（`ok===false → 'failed'`）して実質必須化するのが安全側。

**修正提案:** API 境界で `status` を正規化（欠落・未知値は成功以外で表示）し、missing/unknown のテストを追加。

---

### [Code Quality] scheduled/daily 取り込みの `started_at` と `finished_at` が常に同一（所要時間が 0 になる）

- [x] 対応する

**ファイル:** `api/src/services/salonboard-import.service.ts:819-836`（`finalizeRun`）、`:943-957`（`runSalonboardImport` の `now`）、`:902-931`（`executeImport` の claim/finalize）
**重要度:** Medium

**該当コード（変更後）:**
```typescript
// runSalonboardImport 入口で now を一度だけ確定
now = new Date(),              // :945
...
const startedAt = now.toISOString();   // :951
runs = await executeImport(now, applicationId, runId ? null : { trigger, startedAt }); // :957（数分かかりうるクロール本体）

// executeImport 内：会社ごとに claim → 取り込み → finalize（同じ now）
runId = await externalImportRunsRepo.claim({ ..., startedAt: claimCtx.startedAt, now, ... }); // :906-913
if (runId) await finalizeRun(runId, run, now);  // :930

// finalizeRun は finishedAt のみ now で上書き（startedAt は触らない）
finishedAt: now.toISOString(),   // :831
```

**問題:**
日次/scheduled 経路（`runId` 無し＝claim モード）では、`startedAt`（claim 時の `claimCtx.startedAt`）と `finishedAt`（`finalizeRun`）が **どちらも入口で確定した同一 `now`** から作られる。実際のクロールは claim と finalize の間で実行されるのに `now` は固定のため、`external_import_runs.started_at == finished_at` となり、**所要時間が常に 0** に記録される。遅い取り込みの特定・タイムアウト切り分けで `finished_at` が無意味になる。
※ 手動経路（HTTP ハンドラで pre-claim 済みの `runId` 指定）は `startedAt` が claim 時刻、`finishedAt` がバッチ時刻で異なるため正しい。本指摘は claim モード（日次/scheduled、および `:972-987` の致命的失敗 claim 経路）に限定。`salonboard-import-concurrency.test.js:160` は `finishedAt` の truthy のみ検証し差分を見ていないため回帰検出できない。

**修正提案:** `finalizeRun` 内で完了時刻を採取する（`finishedAt: new Date().toISOString()`）。テストに `finishedAt >= startedAt`（claim モードで `!==`）の assertion を追加。

---

### [Code Quality] `importCancellations` のコメントは「409限定」だが実装は全 non-2xx に `body.error` を適用

- [x] 対応する

**ファイル:** `user/src/services/api.ts:185-188`
**重要度:** Low

**該当コード（変更後）:**
```typescript
const body = await response.json().catch(() => ({}));
if (!response.ok) {
  // GTSS-817-store: 409（既に実行中）はサーバーの error をそのまま返す。
  return { success: false, error: body?.error || `取り込みに失敗しました（${response.status}）` };
}
```

**問題:**
コメントは「409 はサーバーの error をそのまま返す」だが、`if (!response.ok)` は **全ての非 2xx**（500/403 等）で `body.error` をそのまま UI に流す。現状はバックエンドが 500 時に汎用文言（`取り込みの実行に失敗しました`）を `error` に入れ、内部詳細は別キー `message` に入れて UI は `message` を読まないため実害なし。ただし「コメントの意図（409限定）」と「実装（全非2xx）」が乖離しており、将来 `error` に機微情報が入った瞬間に静かに露出する潜在結合リスク。

**修正提案:** 409 のみ `body.error` を採用し、それ以外は汎用文言にする（コメントどおりの挙動に揃える）。

---

### [Code Quality] timestamptz の naive 値を `new Date()` で解釈する正しさが「Lambda TZ=UTC」前提に暗黙依存

- [x] 対応する

**ファイル:** `api/src/db/timestamps.ts:30`（`normalizeTimestamps`）、`api/src/repositories/application-deletion-backups.repository.ts:51`
**重要度:** Low

**問題:**
RDS Data API（dev/prod）は timestamptz を `'2026-05-01 00:00:00'`（オフセットなし naive）で返す。これを `new Date(v)` でパースすると Node は**実行環境の TZ**でローカル解釈するため、非 UTC 環境では UTC instant がずれ、API 契約（`…Z`）が崩れる。AWS Lambda は既定 `TZ=UTC` でありコードもその前提をコメント明記しているため**現状はバグではない**が、正しさがコード内ガードのない暗黙の前提（誰も Lambda の `TZ` を変えない／このパスを非 UTC のバッチから呼ばない）に依存している。`deleteExpired` 経路は比較を SQL 側に委ねるため TZ 非依存で安全。

**修正提案:** naive 文字列に明示的に `Z`/UTC を付与してからパースしてハードニングするか、`TZ=UTC` 前提を維持する判断をコメント以上に明示（テストや lint で固定）する。

---

### [Code Quality] timestamptz 化後も「ISO8601 文字列は辞書順 = 時系列順」コメントが残存（陳腐化）

- [x] 対応する

**ファイル:** `api/src/repositories/application-deletion-backups.repository.ts:50`、`api/src/repositories/external-import-runs.repository.ts`（`findRecent` のコメント）
**重要度:** Low

**該当コード（変更後）:**
```typescript
// expiresAt は ISO8601 UTC `Z` で辞書順比較が時系列順と一致する。JS 側で expiresAt > now を判定。
const live = (rows || []).find((r: any) => new Date(String(r.expiresAt)).getTime() > new Date(now).getTime());
```

**問題:**
`expires_at` / `created_at` は本 PR で `text → timestamptz` 化され、Postgres 側比較（`lte`/`desc`）は**辞書順ではなく型付き instant 比較**に変わった。動作はむしろ堅牢化されたが、コメントは旧前提（文字列の辞書順）のまま残っており、将来「文字列フォーマット依存」と誤読されるリスク。機能影響はなくドキュメント整合のみ。

**修正提案:** コメントを「timestamptz の型付き比較」に更新。

---

### [Code Quality] admin の `formatJstDateTime` が分精度の生値に偽の秒「:00」を付与（user と非対称）

- [x] 対応する

**ファイル:** `admin/src/utils/datetime.ts:35-37`
**重要度:** Low

**問題:**
admin は `toLocaleString` に書式指定を渡さない（ロケール既定＝秒を含む）ため、`receivedAt = '2026/06/01 15:05'`（秒情報なし）が `2026/6/1 15:05:00` と表示される（`datetime.test.ts` の期待値どおり）。user は `hour/minute:'2-digit'` 明示で秒なし。データに存在しない秒精度を admin だけ見せる挙動は、書式統一観点で将来の不整合リスク。admin 既定書式の維持が仕様なら許容。

**修正提案:** admin も明示書式に揃えるか、秒を持たない値であることを許容する旨を明記。

---

### [Test Coverage] user の e2e 期待値が端末 TZ 依存のまま（unit と非対称）

- [x] 対応する

**ファイル:** `user/e2e/invoice-board.spec.ts:19-20, 105`
**重要度:** Low

**問題:**
本 PR は unit（`InvoiceList.test.tsx`）の期待値に `timeZone:'Asia/Tokyo'` を付与した一方、e2e の `fmtDate`(L19) と受信日時 `receivedFmt`(L105) は端末 TZ 依存のまま。アプリ表示は JST 固定になったため、期待値生成だけ端末 TZ 依存に取り残されており、特定オフセット端末で偽陽性/偽陰性化しうる。

**修正提案:** e2e の両箇所にも `timeZone:'Asia/Tokyo'` を付与し unit と揃える。

---

### [Code Quality] Header.tsx / App.tsx の IA 変更が JST 表示 PR に同梱（スコープ混在）

- [x] 対応する

**ファイル:** `admin/src/components/Header.tsx`（-52 行）、`admin/src/App.tsx`（`resolveCompanyName` 削除）、`user/src/components/Header.tsx`
**重要度:** Low（プロセス）

**問題:**
PR タイトルは「日付・日時を一律 JST 表示」だが、実体には会社詳細文脈ヘッダーの廃止（常時グローバルメニュー化）・二重起動防止（GTSS-817-store）の `ok→status` 一本化・409 ハンドリング・z-index 修正など、JST 表示と無関係な複数機能が同梱されている。会社単位ナビは `ApplicationDetailLayout.tsx:373` の `<nav aria-label="会社詳細ナビ">` へ委譲済みで回帰テスト（`Header.test.tsx`/`application-detail-page.spec.ts`）もあり**機能上の欠落は無い**（cross-file 検証済み）が、切り戻し単位・レビュー責務が混在する。

**修正提案:** 可能なら IA 変更を別 PR へ分離。同梱するなら受け入れ条件に「会社詳細でもヘッダーはグローバル固定」を明記。

---

### [Lessons] テスト fixture `reservation-list-machida.json` の `salonStaffs[].name` が未マスク（本 PR 範囲外）

- [x] 対応する

**ファイル:** `api/src/__tests__/fixtures/salonboard/reservation-list-machida.json`（**本 PR の差分外**）
**重要度:** Low（別 Issue 推奨）

**問題:**
顧客名・予約行の `staffName` は `ダミー…` でマスク済みだが、`salonStaffs[]` 配列の `name` に実名らしき値が残存している（CLAUDE.md の「サロンスタッフ名は置換必須」に反する）。本 PR が新規に持ち込んだものではなく既存 fixture の問題のため、本 PR への指摘ではないが、別途 fixture 清掃 Issue（`akichim21/cancel`）として起票するのが妥当。lessons 横断チェックでは、本 PR が新規に過去 lessons へ違反する箇所は無し。

---

### [Codex] ok→status 契約変更のデプロイ順序（情報・要運用配慮）

- [x] 対応する

**ファイル:** `api/src/services/cancellation.service.ts:242-266`（`listImportRuns` が生 row を spread）/ `admin/src/components/ImportRunList.tsx`
**重要度:** Low（Info）

**問題:**
import-runs API のフィールドが `ok: boolean` → `status`(running/success/failed) へ変わり、新たに `running` 行も返る。admin は対応済み（`types/Cancellation.ts:182` / `ImportRunList.tsx:113,119`、旧 `ok` 参照なし＝コード不整合なし）。ただし両者は別ブランチ/別リポジトリのため、**API を admin より先にデプロイすると未更新 admin が一時的に成否表示を失う**可能性。GTSS-817 配下の協調デプロイとして admin → API（または同時）の順を運用で担保すること。指摘②（status フォールスルー）と合わせて対処すると安全。

---

## 総評

- **設計の整合性は高い。** 「API は UTC `…Z`／表示は各フロントが JST 固定」という責務分担が 3 リポジトリで一貫し、`*_str` 改名（DB カラムのみ改名・ドメイン項目名は不変）、`normalizeTimestamps`/`nullifyEmptyTemporal` の `getTableColumns` ベース自動追従、migration 0011 の `USING NULLIF(...)::type` 保全変換＋`backfill→DEFAULT→NOT NULL` 順序、ステータス一本化（部分ユニーク `WHERE status='running'` による二重起動防止）まで、呼び出しチェーンを追って重大な欠陥は見つからなかった。テストも実 Postgres の `information_schema` 検証・concurrency 検証・端末 TZ 非依存検証を備える。
- **最優先は指摘①（非ゼロ埋め/秒なし JST 値の `Invalid Date` 回帰）。** 端末非依存を掲げる PR が、実データ次第で受信日時を黙って `-` にしてしまうため、`new Date()` 任せのパースをやめて要素抽出＋ゼロ埋めに直し、回帰テストを追加するのが望ましい。指摘②（status フォールスルー）と③（scheduled の所要時間 0）は監査・運用品質に効く Medium。残りは Low / プロセス指摘。
- **スコープ混在（指摘⑨）** は機能的な問題ではないが、JST 表示 PR に IA 変更・GTSS-817-store の二重起動防止が同梱されている点はレビュー単位として留意。各機能のテストはカバーされている。
