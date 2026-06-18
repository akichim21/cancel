---
issue: 817 (PR #20)
date: 2026-06-18
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-817-proxy
    toBranch: GTSS-817-proxy-resilience
---

# レビュー結果: PR #20（サロンボード取り込みの堅牢化）

## 概要

**PR:** [#20](https://github.com/GO-TODAY-SHAiRE-SALON/cancel-billing-service-api/pull/20) feat(GTSS-817): サロンボード取り込みの堅牢化（HTTP+proxy/リトライ/観測性/帯域削減）
**要件取得元:** PR 本文（HTTP+proxy 対応・ログイン一過性リトライ・取り込み失敗の観測性強化・サードパーティ遮断による帯域削減・抽出窓の契約日基準見直し）

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-817-proxy` | `GTSS-817-proxy-resilience` | 1 | 10 |

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/services/salonboard-client.ts` | +154 | -12 | Modified |
| `src/services/salonboard-import.service.ts` | +145 | -45 | Modified |
| `src/utils/import-window.ts` | +14 | -7 | Modified |
| `src/constants/cancellation-status.ts` | +9 | -0 | Modified |
| `src/__tests__/e2e/salonboard-import.test.js` | +133 | -12 | Modified |
| `src/__tests__/unit/salonboard-playwright-client.test.js` | +127 | -4 | Modified |
| `src/__tests__/unit/import-window.test.js` | +15 | -8 | Modified |
| `package.json` | +1 | -0 | Modified |
| `package-lock.json` | +10 | -0 | Modified |
| `yarn.lock` | +5 | -0 | Modified |

## 指摘一覧

- [x] 対応する

### [Code Quality] `classifyHttpError` が `e.cause` を見ず、undici の接続/プロキシ失敗を `proxy_error` に分類できない（PR の主目的が実環境で機能しない）

**ファイル:** `api/src/services/salonboard-client.ts:460-475`（diff 612-625）
**重要度:** High

**該当コード（変更後・新規追加）:**
```typescript
// HTTP トランスポートの fetch 失敗を型付きエラーへ正規化する（REQ-7。Playwright の classifyBrowserError と対）。
// AbortSignal.timeout 超過は name='TimeoutError'（環境により AbortError）で届く → timeout 扱い。
// プロキシ/接続失敗（ECONNREFUSED 等）は proxy_error 扱いにして loginWithRetry/可観測性へ乗せる。
const classifyHttpError = (e: any): Error => {
  const name = e?.name || '';
  const msg = String(e?.message || e || '');
  if (name === 'TimeoutError' || name === 'AbortError' || /timeout|abort/i.test(msg)) {
    return new SalonboardTimeoutError(msg || 'HTTP リクエストがタイムアウトしました');
  }
  if (/proxy|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|tunnel|ECONNRESET|certificate|\bTLS\b/i.test(msg)) {
    return new SalonboardProxyError(msg);
  }
  return e instanceof Error ? e : new Error(msg);
};
```

**問題:**
Node/undici の `fetch` は接続・プロキシ・TLS 失敗を **`TypeError: fetch failed`** でラップし、実際の原因コード（`ECONNREFUSED` / `ECONNRESET` / `ENOTFOUND` / `EAI_AGAIN` / undici の `UND_ERR_*` / tunnel 407 等）は **`e.cause` 側**に入る。トップレベルの `e.message` は常に `"fetch failed"`、`e.name` は `"TypeError"`。本実装は `e.name` と `e.message` しか参照しないため:

- `name='TypeError'` → timeout 分岐に当たらない
- `msg='fetch failed'` → proxy 正規表現にも当たらない
- → 汎用 `Error('fetch failed')` にフォールスルー

結果、`classifyFailure` の fallback になり、ログイン経路では **`login_failed`**（= 非 transient → `loginWithRetry` が新 IP で引き直さない）、明細取得経路では **`detail_fetch_failed`** に化ける。本 PR のきっかけとなった「京都店の Decodo トンネル接続失敗（`tunnel connection failed: 407`）を `proxy_error` として `payload.error`・`shops[].error` に残し、新 IP で自己回復する」という **2 つの中核目的が、最も頻度の高い実プロキシ障害で成立しない**。記録されるメッセージも無情報な `"fetch failed"` になる。

E2E `T-35b` が green なのは、fake が `SalonboardProxyError` を**直接 throw** して `classifyHttpError` を通らないため。実 undici 経路の正規化はテストで一切カバーされていない（補強テスト未整備。code-reviewer / codex が独立に検出、当方も実装読みと undici 既知挙動で確認）。

※ `AbortSignal.timeout` 超過は `name='TimeoutError'`（DOMException）が伝播するため timeout サブケースは概ね機能する。問題は**接続/プロキシ系の cause ラップ**。ただし環境により timeout も `TypeError: fetch failed` + `cause.name='TimeoutError'` でラップされ得るので、cause 参照で両方とも堅牢化できる。

**修正提案:**
`e.cause`（必要なら `e.cause.cause` / `AggregateError` の `e.errors`）の `name` / `code` / `message` を分類対象に含める。code ベースのマッチも追加する。
```typescript
const classifyHttpError = (e: any): Error => {
  const cause = e?.cause ?? {};
  const name = e?.name || cause.name || '';
  const code = String(e?.code || cause.code || '');
  const msg = [e?.message, cause.message, cause.code]
    .filter(Boolean).map(String).join(' ') || String(e || '');
  const hay = `${name} ${code} ${msg}`;
  if (name === 'TimeoutError' || name === 'AbortError'
      || /UND_ERR_(CONNECT|HEADERS|BODY)_TIMEOUT|ETIMEDOUT|timeout|abort/i.test(hay)) {
    return new SalonboardTimeoutError(msg || 'HTTP リクエストがタイムアウトしました');
  }
  if (/proxy|ECONNREFUSED|ECONNRESET|ENOTFOUND|EAI_AGAIN|tunnel|certificate|\bTLS\b|UND_ERR/i.test(hay)) {
    return new SalonboardProxyError(msg);
  }
  return e instanceof Error ? e : new Error(msg);
};
```
あわせて `classifyHttpError` は純粋関数なので、`{ name:'TypeError', message:'fetch failed', cause:{ code:'ECONNREFUSED', message:'connect ECONNREFUSED ...' } }` 形を渡す**単体テストを追加**して回帰を固定する（実プロキシ不要）。

---

### [Code Quality] 既定の HTTP トランスポートで CAPTCHA が `captcha_detected` に分類されない（観測性の欠落）

**ファイル:** `api/src/services/salonboard-client.ts:176-209`（`SalonboardHttpClient.login`）/ `detectCaptcha` の使用箇所 503・770・813-814
**重要度:** Medium

**該当コード（HTTP クライアントの login。CAPTCHA 検知なし）:**
```typescript
async login(loginId: string, password: string): Promise<SalonboardLoginResult> {
  // ...doLogin...
  const doLoginHtml = await doLoginRes.text();
  const m = doLoginHtml.match(/userid\s*:\s*'([^']*)'/);
  const userId = m && m[1] ? m[1] : null;
  // ...groupTop...
  return { ok: !!userId, userId, groupTopHtml };   // ← CAPTCHA 判定なし。userId=null なら ok=false
}
```
対して Playwright クライアントは `login`/一覧/詳細で `detectCaptcha` → `SalonboardCaptchaError` を throw する（`:770`, `:813-814`）。

**問題:**
`resolveSalonboardTransport()` の既定は `'http'`（`config.ts:113-114`・第一候補）。`detectCaptcha` / `SalonboardCaptchaError` は **Playwright クライアント専用**で、HTTP クライアントでは未使用（grep で確認）。HTTP 経路で CAPTCHA HTML が返ると:
- login: `userId=null` → `ok:false` → `login_failed`（`captcha_detected` にならない）
- 一覧: `res.json()` 例外 → 店舗取得失敗
- 詳細: パース失敗 → `detail_fetch_failed`

PR 本文・`loginWithRetry` のコメントが謳う「CAPTCHA は `captcha_detected` として観測し、リトライしない」が**既定経路で観測面では守られない**。
※ 「CAPTCHA を新 IP で引き直さない（velocity 悪化回避）」という安全目的自体は、`login_failed` も非 transient なので**結果的に保たれる**（取りこぼし・アカウントロックには直結しない）。影響は主に観測性（admin で原因が `ログイン失敗` 表記になり CAPTCHA と判別できない）。

**修正提案:**
HTTP 側 `login`（`doLoginHtml`/`groupTopHtml`）でも `userId` 抽出失敗時に `detectCaptcha` で判定し `SalonboardCaptchaError` を throw する。一覧は `res.text()` で本文確認 → `detectCaptcha` → 無ければ `JSON.parse`、詳細も返却前に `detectCaptcha`。HTTP 経路の CAPTCHA を 1 件 e2e で固定する。

---

### [Code Quality] `out_of_window` 理由ログは実データではほぼ到達しない（仕様・期待値の乖離）

**ファイル:** `api/src/services/salonboard-import.service.ts:277-289`（一覧取得に window を渡す）/ `salonboard-client.ts:337-360`（GraphQL 検索条件に `startDate`/`endDate`）
**重要度:** Low〜Medium

**該当コード:**
```typescript
// import.service.ts
const firstJson = await client.fetchReservationListJson({
  startDate: ctx.window.startDate,   // ← 抽出窓 = 来店予定日範囲
  endDate: ctx.window.endDate,
  page: 1,
});
// ...後段の client 側 isWithinWindow も同じ来店予定日範囲で判定
```
```typescript
// salonboard-client.ts: fetchReservationListJson はサーバ側検索条件へ範囲を渡す
input: {
  startDate: opts.startDate,
  endDate: opts.endDate,
  // ...
  cancelStatus: ['CANCEL', 'UNAUTHORIZED_CANCEL'],
}
```

**問題:**
一覧取得は salonboard 側の検索条件 mutation に `startDate`/`endDate`（= 抽出窓）を渡し、サーバ側で来店予定日範囲＋キャンセル種別に絞り込んだ結果のみ返る。その後のクライアント側 `isWithinWindow(r.visitationDate, ctx.window)` は**同じ範囲**で判定するため、返却された予約はほぼ常に窓内 → `out_of_window` ログが残るのは**テストで窓外ノードを注入した場合か境界差分のみ**。PR 本文「窓外を理由付きログに残し、運営が後から追える」という観測性の触れ込みが実運用では成立しにくい。

データ正しさには影響なし（取りこぼしではなく、クライアント側チェックは多重防御として妥当）。仕様記述・期待値の乖離なので、(a) 監査目的で本当に窓外を可視化するなら取得範囲を広げる設計が必要、(b) 帯域削減を優先するなら `out_of_window` の説明とテストを「取得レスポンスに混入した場合のみ記録」へトーンダウンする、のどちらかに整理するとよい。

---

### [Performance] `before_contract` は再評価で結果が変わりにくく、毎ラン `logSkip`(upsert) が走る

**ファイル:** `api/src/services/salonboard-import.service.ts:389-396` / `src/constants/cancellation-status.ts:117-128`（`TERMINAL_IMPORT_LOG_REASONS`）
**重要度:** Low

**該当コード:**
```typescript
// import.service.ts: doneSet に入らないため毎ラン評価される
const cancelDate = (r.updatedAt as string) || (r.visitationDate as string);
if (!isCancelOnOrAfterContractDate(cancelDate, ctx.contractCreatedAt)) {
  await logSkip(r, IMPORT_LOG_REASON.BEFORE_CONTRACT);
  result.skipped += 1;
  result.byReason[IMPORT_LOG_REASON.BEFORE_CONTRACT] += 1;
  continue;
}
```
```typescript
// cancellation-status.ts: out_of_window / before_contract をともに terminal に含めない
// out_of_window / before_contract はここに含めない: 抽出フィルタ段（詳細取得より前）で毎回再評価するため
export const TERMINAL_IMPORT_LOG_REASONS: string[] = [ /* before_contract/out_of_window は無い */ ];
```

**問題:**
`out_of_window` を非 terminal にする判断は妥当（時間経過で窓内化し得る）。一方 `before_contract` は契約日もキャンセル日（`updatedAt`）も通常不変のため**再評価しても結果が変わらず情報価値がない**のに、`doneSet` に入らないため対象店舗にそうした予約が多数あると毎日全件 `upsertByReservation` が走り続ける（N 件 × 日次の書き込み増幅。upsert なので行は増えないが書き込み I/O は発生）。

※ 反論として `updatedAt` は再キャンセル等で変わり得るので非 terminal も完全には誤りではない。コストとのトレードオフで判断のこと。

**修正提案:**
`BEFORE_CONTRACT` を `TERMINAL_IMPORT_LOG_REASONS` に追加し `out_of_window` のみ非 terminal で残す。再キャンセルでの変化を許容するなら現状維持でもよいが、その理由をコメントへ明記する。

---

### [Code Quality] `describeTransport` の `env` 引数が `selectChromiumSource` 以外に渡らない（API 契約の不整合）

**ファイル:** `api/src/services/salonboard-client.ts:1019-1037`（diff 695-712）
**重要度:** Low

**該当コード:**
```typescript
export const describeTransport = (
  opts: { runId?: string } = {},
  env: Record<string, string | undefined> = process.env,
): string => {
  if (resolveSalonboardTransport() !== 'playwright') {          // ← env を使わず process.env を直読み
    const proxy = resolveSalonboardProxy({ runId: opts.runId || 'probe' });  // ← 同上
    return `... proxy=${proxy ? proxy.server : 'none (direct)'}`;
  }
  const src = selectChromiumSource(env);                        // ← ここだけ env を使用
  // ...
  const proxy = resolveSalonboardProxy({ runId: opts.runId || 'probe' });    // ← 同上
};
```

**問題:**
`env` 引数を受ける純粋関数の体裁だが、`resolveSalonboardTransport()` と `resolveSalonboardProxy()` は注入 `env` ではなく `process.env` を直読みする。テストは `process.env` を直接書き換えて通っているため実害はないが、`env` を非 `process.env` で渡すと一部だけ反映される不整合があり、将来の誤読の元。

**修正提案:**
解決関数を `env` 受け取りに拡張して全経路へ渡すか、`env` 引数を `selectChromiumSource` 専用と JSDoc で明記する。

---

## 総評

PR の設計方針（HTTP+proxy / 一過性リトライ / 観測性 / 帯域削減 / 抽出窓のキャンセル日基準化）は妥当で、テストの具体値アサーション・PII 非混入・リソースリーク対策（`loginWithRetry` の全分岐 `closeClient`、呼び出し側 `try/finally`）・ホスト判定の堅牢性（サブドメイン詐称弾き）・日付の二重オフセット回避（`isCancelOnOrAfterContractDate` が `cancelDate.slice(0,10)`、契約日のみ `jstDateOf`）はいずれも検証して問題なし。lessons 横断照合でも既知パターンへの違反は無し。

ただし **High 1 件が最重要**: `classifyHttpError` が `e.cause` を見ないため、本 PR のきっかけとなった実プロキシ障害（`TypeError: fetch failed` でラップされる接続失敗）が `proxy_error` に分類されず、観測性・自動リトライの中核目的が**実環境で機能しない**。fake が型付きエラーを直接 throw する e2e では検出されないため、`classifyHttpError` の cause 対応＋単体テスト追加を**マージ前に強く推奨**する。Medium（HTTP 経路の CAPTCHA 観測欠落）と Low 3 件は観測性・コスト・整合性の改善で、データ正しさには影響しない。

**検証メモ（再現せず破棄／確認のみ）:**
- code-reviewer・codex とも独立に classifyHttpError の cause 未参照を検出。当方も実装読み＋undici 既知挙動で確定。採用。
- codex の「`out_of_window` ほぼ到達不能」「HTTP の CAPTCHA 未検知」は当方が `fetchReservationListJson` のサーバ側 `startDate/endDate` フィルタと HTTP `login` を実読みして確認。採用（重要度は実影響に合わせて調整）。
- 別ブランチ・別 Issue 文脈の混入なし（全指摘が本 PR 差分の 2 ファイルに接地）。
- テストは PR 本文で「全 604 件 green」と記載。当方では再実行していない（差分レビューのみ）。
