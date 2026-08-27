---
issue: 61
date: 2026-08-08
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: main
    toBranch: GTSS-817-qa
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: main
    toBranch: GTSS-817-qa
---

# レビュー結果: #61

## 概要

**Issue:** #61 サロンボード取り込みのログイン失敗を原因特定可能にする（診断ログ・Sentry・Slack通知・ブロック疑い時の条件付きリトライ）

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 | PR |
|-----------|-------------|------------|----------|------------|----|
| api | `main` | `GTSS-817-qa` | 3 | 18 | #46 (→main) / #48 (→develop) |
| admin | `main` | `GTSS-817-qa` | 1 | 5 | #18 (→main) |

> **注**: api には同一 head から PR が 2 本ある（#46 base=main / #48 base=develop）。develop には既に先頭 2 コミットが入っているため、
> #48 の差分は `cc612af`（deploy-batch-ecs.sh の secrets 所有）1 件のみ。本レビューは manifest どおり **base=main で 3 コミット全体**を対象にした。

### 検証実績（レビュー時に実行）

| 項目 | 結果 |
|---|---|
| api `npm test` | ✅ **103 files / 1386 tests all passed** |
| api `npx tsc --noEmit` | ✅ exit 0 |
| admin `npm test` | ⚠️ 266 passed / **1 failed** — `src/components/__tests__/StoreList.test.tsx`。**本 PR の差分外（StoreList は未変更）で main 由来の既存 failure**。本 PR の `ImportRunList.test.tsx` 3 件は全 green |

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/services/salonboard-client.ts` | +231 | -25 | Modified |
| `src/services/salonboard-import.service.ts` | +530 | -73 | Modified |
| `src/services/salonboard-login.ts` | +65 | -13 | Modified |
| `src/observability/slack.ts` | +111 | -0 | **Added** |
| `src/constants/cancellation-status.ts` | +7 | -1 | Modified |
| `src/services/cancellation.service.ts` | +12 | -1 | Modified |
| `src/__tests__/e2e/salonboard-import-observability.test.js` | +389 | -0 | **Added** |
| `src/__tests__/e2e/salonboard-import-retry.test.js` | +322 | -0 | **Added** |
| `src/__tests__/unit/salonboard-login-diagnostics.test.js` | +311 | -0 | **Added** |
| `src/__tests__/unit/slack-notifier.test.js` | +131 | -0 | **Added** |
| `src/__tests__/unit/salonboard-login.test.js` | +163 | -5 | Modified |
| `src/__tests__/helpers/salonboard.js` | +34 | -3 | Modified |
| `deploy-batch-ecs.sh` | +79 | -13 | Modified |
| `deploy-api.sh` / `deploy-batch.sh` | +6 / +6 | -0 | Modified |
| `buildspec.yml` / `buildspec-batch.yml` | +4 / +6 | -0 | Modified |
| `.env.example` | +12 | -0 | Modified |

### admin

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/components/ImportRunList.tsx` | +26 | -7 | Modified |
| `src/types/Cancellation.ts` | +7 | -0 | Modified |
| `src/components/__tests__/ImportRunList.test.tsx` | +62 | -0 | Modified |
| `e2e/import-runs.spec.ts` | +12 | -4 | Modified |
| `e2e/fixtures.ts` | +2 | -1 | Modified |

## 指摘一覧

- [x] 対応する

### [Code Quality] `isBlockSuspected` が遮断シグナルを主判定より優先し、AC-5.1（認証拒否は即失敗）が破れる

**ファイル:** `api/src/services/salonboard-login.ts:112-117`
**重要度:** High

**該当コード:**

```typescript
// main 側（変更前）— login.ok=false は理由を問わず即 authFailed（引き直しなし）
      const login = await withDeadline(client.login(loginId, password), deadlineMs);
      if (login.ok) return { ok: true, client, login, attempts };
      await closeClient(client);
      // 認証情報誤り（アカウントロック回避のためリトライしない）。
      return { ok: false, client: null, login, authFailed: true, attempts };
```

```typescript
// GTSS-817-qa 側（変更後）— salonboard-login.ts:112
export const isBlockSuspected = (d: SalonboardLoginDiagnostics | undefined | null): boolean => {
  if (!d) return false;
  if (Array.isArray(d.blockSignals) && d.blockSignals.length > 0) return true;   // ← 最優先
  if (!d.doLoginObserved) return true;
  return !d.isLoginPage;
};
…
// salonboard-login.ts:191
      if (!isBlockSuspected(diagnostics)) {
        return { ok: false, client: null, login, diagnostics, authFailed: true, attempts };
      }
      // 遮断疑い: 新 runId（=新 IP）で 1 回だけ引き直す（REQ-5）
```

**問題:**
Issue REQ-5 は「**doLogin 応答を観測でき、かつ返ってきたページがログイン画面**（＝認証情報が拒否された）→ 真の認証失敗とみなし、従来どおり即失敗」を
判定の主軸と定義している。しかし実装は `blockSignals` を先に評価するため、**認証拒否が確定していても遮断マーカーが 1 つ当たれば引き直す**。
以下 2 点で誤検知が現実的に起こりうる。

1. **`blockSignals` は `doLoginBody` ∪ `finalHtml` の和集合**（`salonboard-client.ts:943`）。
   HTTP トランスポート（API Lambda の既定）の `finalHtml` は、ログイン失敗後も無条件に叩かれる
   **未認証状態の `POST /CNC/groupTop/` 応答**（`salonboard-client.ts:307-317`）で、**fixture による検証が一切ない**。
   このレスポンスが 403 系なら `{ name: 'forbidden', re: /<title>[^<]*(?:403 Forbidden|Forbidden)[^<]*<\/title>/i }` に当たる。
2. `{ name: 'attention_required', re: /Attention Required|Cloudflare/i }`（`salonboard-client.ts:875`）は
   **裸の `Cloudflare`** に一致する。`cdnjs.cloudflare.com` の asset URL が 1 本混じるだけでヒットする。
   （現行 fixture `login-failure.html` / `login-success.html` を全 7 マーカーで grep した結果は 0 件で、ログイン画面そのものは現状セーフ）

影響:

- **(a)** 誤った認証情報のアカウントへ 1 回余分にログインを打つ ＝ REQ-5 が避けたかったアカウントロックのリスクそのもの
- **(b)** 一過性理由 `login_blocked` になるため翌日以降も日次で延々再試行され、admin は「ログイン遮断疑い」しか出さず**運営が認証情報の誤りに気づけない**
- **(c)** 検証経路（`salonboard-auth.service.ts:88-94` / `:412-416`）の `authFailed` 分岐から外れ、パスワード誤りでも
  「IDまたはパスワードをご確認ください」ではなく「サロンボードへの接続に失敗しました」を返す

**修正提案:**

```typescript
export const isBlockSuspected = (d: SalonboardLoginDiagnostics | undefined | null): boolean => {
  if (!d) return false;
  // doLogin 応答あり＋ログイン画面＝認証拒否。遮断シグナルの誤検知で覆さない（AC-5.1）。
  if (d.doLoginObserved && d.isLoginPage) return false;
  if (Array.isArray(d.blockSignals) && d.blockSignals.length > 0) return true;
  if (!d.doLoginObserved) return true;
  return !d.isLoginPage;
};
```

併せて `salonboard-client.ts:875` を `/Attention Required!\s*\|\s*Cloudflare/i` へ絞る。
テストは指摘「REQ-5 の最重要分岐が未カバー」に記載のケースを追加すること。

---

- [x] 対応する

### [Performance] REQ-8 のセッション引き直し上限が実効的に効いておらず、batch Lambda の 600s を超えうる

**ファイル:** `api/src/services/salonboard-import.service.ts:343` / `:991-1017` / `:122-140`
**重要度:** High

**該当コード:**

```typescript
// main 側（変更前）— セッション引き直しの概念が無い。
// 会社単位は 1 ログイン=1 ラン=1 スティッキーセッションで、ログイン後の再ログインは発生しない。
const importCompany = async (
  applicationId: string,
  shops: any[],
  ctx: { now: Date; window: { startDate: string; endDate: string } },
): Promise<CompanyRunSummary> => {
```

```typescript
// GTSS-817-qa 側（変更後）
// salonboard-import.service.ts:343
const MAX_SESSION_RENEWALS_PER_RUN = 2;   // ← 「2 回/実行」のはずが…

// salonboard-import.service.ts:991
const renewClient = async (loginId, password, shop) => {
  if (sessionRenewals >= MAX_SESSION_RENEWALS_PER_RUN) {
    logRenewEvent('session_renew_skipped', shop, { message: `セッション引き直しの上限（…）に達した…` });
    return { skipped: true, client: null };
  }
  sessionRenewals += 1;
  const outcome = await loginWithRetry(loginId, password);   // ← 内部で最大 3 試行
  ...
};

// salonboard-import.service.ts:122 / :132
const MAX_LOGIN_ATTEMPTS = 3;
const loginWithRetry = async (loginId, password) => {
  const outcome = await transportLoginWithRetry(loginId, password, {
    maxAttempts: MAX_LOGIN_ATTEMPTS,   // ← 1 renewal で最大 3 セッション（3 IP）を消費する
    closeClient,                        // ← 取り込み経路は totalBudgetMs / attemptTimeoutMs 無し
    sleep: () => pace(),
  });
```

**問題:**
`sessionRenewals` が数えているのは **`renewClient` の呼び出し回数**であって、実際に張られる新規スティッキーセッション（＝新 IP・新ログイン）の数ではない。
`renewClient` が呼ぶ `loginWithRetry`（取り込みサービス側ラッパ）は `maxAttempts: MAX_LOGIN_ATTEMPTS = 3` を渡すため、
**1 回の引き直しで最大 3 回のログイン／3 個の新 IP を消費**する。結果、1 会社ランのログイン試行は最悪
**初回 3 + 引き直し 3 + 引き直し 3 = 9 回**になる。

`MAX_SESSION_RENEWALS_PER_RUN` の定義コメント自身が上限の目的を

> 再ログインは velocity を上げるため無制限にはしない …
> 手動取り込みが動く batch Lambda の実行時間（600s）を食い潰さないための歯止めでもある

と書いているが、増幅を勘案すると**どちらも成立していない**。取り込み経路は `totalBudgetMs` / `attemptTimeoutMs` を渡さず
各リクエストの transport timeout に委ねるため、1 ログインは `NAV_TIMEOUT = 60_000` 級（実測 72s の事象あり）。
1 店舗全滅で `attempt1(60s) + 再ログイン(≤210s) + attempt2(60s) ≒ 330s`、2 店舗目で **600s 超過**。
Lambda が killed されると `external_import_runs` が `running` のまま残る（`IMPORT_RUN_STALE_MS` による回収待ち）。

**修正提案:**
引き直し用のログインは試行回数を絞る（renewal 自体が既に「新 IP での引き直し」なので、内側でさらに 3 回粘る必要がない）。

```typescript
// loginWithRetry に maxAttempts を渡せるようにする
const loginWithRetry = async (loginId, password, opts: { maxAttempts?: number } = {}) => {
  const outcome = await transportLoginWithRetry(loginId, password, {
    maxAttempts: opts.maxAttempts ?? MAX_LOGIN_ATTEMPTS,
    closeClient,
    sleep: () => pace(),
  });
  ...
};

// renewClient 側
const outcome = await loginWithRetry(loginId, password, { maxAttempts: 1 });
```

あるいは run 開始時刻からの wall-clock 予算を持ち、残時間が足りなければ `session_renew_skipped` 相当で打ち切る。
テスト: renewal 中のログインが `SalonboardTimeoutError` を throw するケースを追加し、
`fake.calls.logins` が設計値（初回 + 2）を超えないことを固定する。

---

- [x] 対応する

### [Code Quality] Slack の起動条件と内訳のズレ — 連携設定未完了で毎日「内訳なし」通知が鳴り、分類不能な失敗は情報ゼロ

**ファイル:** `api/src/services/salonboard-import.service.ts:1318-1327` / `:1389` / `:862`
**重要度:** Medium

**該当コード:**

```typescript
// main 側（変更前）— Slack 通知が存在しない
```

```typescript
// GTSS-817-qa 側（変更後）
// :1318 内訳はハードコード集合しか走査しない
const FAILURE_REASONS_FOR_NOTIFY: string[] = [
  ...LOGIN_FAILURE_REASONS,
  IMPORT_LOG_REASON.DETAIL_FETCH_FAILED,
];
const formatReasonBreakdown = (byReason: Record<string, number>): string => {
  const parts = FAILURE_REASONS_FOR_NOTIFY.filter((r) => (byReason?.[r] ?? 0) > 0).map(
    (r) => `${IMPORT_LOG_REASON_LABELS[r] ?? r} ${byReason[r]} 件`,
  );
  return parts.length ? parts.join(' / ') : '内訳なし';
};

// :1389 起動条件は totalFailed だけを見る
  if (input.totalFailed <= 0 && !input.fatalError) return;

// :862 一方、構造化ログ / Sentry は reasonCode 無しを意図的に黙らせている
  // 連携設定未完了（reasonCode なし）は既知状態のため静かに扱う（admin の shops[].error には表示される）。
  if (!reasonCode) return;
```

**問題:**
2 つの経路で通知が壊れる。

1. **連携設定未完了で毎日 Slack が鳴る（不整合）**
   `markCompanyShopsFailed(run, shops, '連携設定が未完了です', undefined, logCtx)`（`:1095` / `:1032`）は
   `reasonCode` 無しで**全店舗を `failed` 計上**する。`:862` の設計はこれを「既知状態」としてログにも Sentry にも出さないと決めているのに、
   Slack だけは `totalFailed > 0` で発火する。結果、**連携設定が未完了の会社があるだけで日次実行のたびに
   「失敗: 14 / 失敗理由: 内訳なし」という中身の無いアラートが飛ぶ**。REQ-4 の「1 実行 1 通」は守れても通知の氾濫防止の趣旨に反する。

2. **理由分類できない失敗が「内訳なし」になる**
   `importShop` は `classifyFailure(e, null)` で理由を出せなかった失敗（誤店舗 forward の 4xx・HTML 構造変化・パース失敗）でも
   `result.failed += 1` するが `byReason` にキーを立てない（`:456` / `:470-474`）。
   このとき Slack 本文は `失敗: 1 / 失敗理由: 内訳なし` で、**具体的なエラー文字列は本文のどこにも出ない**
   （`shops[].error` は出力対象外、`run.error` は会社レベルの致命的失敗にしか入らない）。REQ-8 はこのケースを明示的に想定している。

**修正提案:**
起動条件と内訳の両方を、ハードコード集合から `byReason` 由来へ揃える。

```typescript
// (a) 起動条件を「分類済み失敗 ≥1 or fatalError or !run.ok」に揃える（連携設定未完了だけでは鳴らさない）
const classifiedFailed = input.runs.reduce(
  (n, r) => n + FAILURE_REASONS_FOR_NOTIFY.reduce((m, k) => m + (r.byReason?.[k] ?? 0), 0), 0,
);
if (classifiedFailed <= 0 && !input.fatalError && input.runs.every((r) => r.ok)) return;

// (b) 内訳は byReason から導出し、差分を「その他 N 件」で必ず出す（将来 reason 追加時の二重メンテも消える）
const classified = FAILURE_REASONS_FOR_NOTIFY.reduce((n, r) => n + (byReason?.[r] ?? 0), 0);
const other = Math.max(0, failed - classified);
if (other > 0) parts.push(`その他 ${other} 件`);
const sampleShopError = run.shops.find((s) => s.failed > 0 && s.error)?.error;
if (sampleShopError) lines.push(`  代表エラー: ${sampleShopError}`);
```

---

- [x] 対応する

### [Code Quality] 会社ラン全体が例外で落ちたとき Slack にも Sentry にも何も飛ばない

**ファイル:** `api/src/services/salonboard-import.service.ts:1292-1299` / `:1389`
**重要度:** Medium

**該当コード:**

```typescript
// main 側（変更前）— Slack 通知が存在しないため「通知されない」問題自体が無かった
    let run: CompanyRunSummary;
    try {
      run = await importCompany(appId, shops, { now, window });
    } catch (e: any) {
      run = emptyCompanyRun(appId);
      run.totalShops = shops.length;
      run.ok = false;
      run.error = `会社の取り込みに失敗しました: ${e?.message || e}`;
    }
    if (runId) await finalizeRun(runId, run);
```

```typescript
// GTSS-817-qa 側（変更後）— 例外パスは failed を 1 件も立てない（変更前と同じ）
    try {
      run = await importCompany(appId, shops, { now, window, trigger });
    } catch (e: any) {
      run = emptyCompanyRun(appId);   // ← failed = 0 のまま
      run.totalShops = shops.length;
      run.ok = false;
      run.error = `会社の取り込みに失敗しました: ${e?.message || e}`;
    }

// :1382 notifyImportFailure
  if (input.totalFailed <= 0 && !input.fatalError) return;   // ← ここで弾かれる

// :1359 buildImportFailureSlackText — 本文側は !run.ok を通す設計になっている
  for (const run of input.runs) {
    if (run.failed <= 0 && run.ok) continue;   // ← run.ok=false は本来出したい
```

**問題:**
`importCompany` が throw する（`applicationsRepo.getById` / `externalIntegrationSettingsRepo.getUnit` などの DB エラー、
renewSession 内の想定外例外 等）と、`run.ok=false` / `run.error` は立つが **`run.failed` は 0 のまま**になる。
`summary.failed` は 0、トップレベルの `fatalError` も未設定なので `notifyImportFailure` は先頭ガードで即 return し、
**Slack 通知が出ない**。Sentry も `markCompanyShopsFailed` 経由でしか送らないためこの経路では発火しない。
`external_import_runs` に failed 行だけが残り、Issue が解消しようとした「CloudWatch を見に行かないと気づけない」状態がこのパスに残る。
`buildImportFailureSlackText` は `!run.ok` を本文に出す前提で書かれており、呼び出し側ガードと矛盾している。

**修正提案:**
上記「Slack の起動条件と内訳のズレ」の修正案 (a) に `input.runs.every((r) => r.ok)` を含めれば同時に解消する。
テスト: `applicationsRepo.getById` を throw させ、`failed=0 / run.ok=false` でも `postSlackMessage` が 1 回呼ばれることを固定する。

---

- [x] 対応する

### [Security] Slack / 構造化ログ / Sentry へ PII マスクを通さない自由文が 3 経路ある

**ファイル:** `api/src/services/salonboard-client.ts:853-866` / `:953`、`api/src/services/salonboard-import.service.ts:1330-1340` / `:1356` / `:1370`
**重要度:** Medium

**該当コード:**

```typescript
// main 側（変更前）— 診断情報・Slack 通知が存在しない
    return { ok: !!userId, userId, groupTopHtml: finalHtml, landingUrl: page.url() };
  }
```

```typescript
// GTSS-817-qa 側（変更後）
// salonboard-client.ts:853 — タグを剥がすだけで PII マスクも loginId 置換もしていない
export const extractAuthErrorText = (html: string): string | null => {
  const h = html || '';
  for (const re of AUTH_ERROR_SELECTORS) {   // /<[^>]+(?:class|id)=["'][^"']*error[^"']*["'][^>]*>([\s\S]{1,400}?)<\//i
    const m = h.match(re);
    if (!m) continue;
    const text = m[1].replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
    if (text) return text.slice(0, 100);   // ← 生テキストをそのまま返す
  }
  return null;
};

// salonboard-client.ts:961 bodySnippet は redactPiiText + loginId 置換を通るが…
    bodySnippet: htmlSnippet(finalHtml || doLoginBody, { loginId: input.loginId ?? null }),
// salonboard-client.ts:953 authErrorText は無加工
    authErrorText: extractAuthErrorText(primary),

// salonboard-import.service.ts:1330 → Slack 本文へ素通し
const formatDiagnosticsLine = (d?: SalonboardLoginDiagnostics | null): string | null => {
  …
    `認証エラー文言=${d.authErrorText ?? 'なし'}`,

// salonboard-import.service.ts:1356 / :1370 — 生の例外メッセージも無加工
  if (input.fatalError) lines.push(`実行全体の致命的失敗: ${input.fatalError}`);
  if (run.error) lines.push(`  エラー: ${run.error}`);
```

**問題:**
Issue REQ-1 の「秘匿情報の扱い（必須）」と技術的考慮事項の「診断の**本文抜粋・エラー文言**は PII マスクを通す」に対し、
実際にマスクが効いているのは `bodySnippet` と `loginIdMasked` だけ。

- `AUTH_ERROR_SELECTORS` は `class`/`id` に `error` を含む要素の内側 400 文字を拾う緩いパターン（`data-id="…error…"` にも当たる）。
  サロンボード側が将来 `<div class="errorMsg">ログインID CD12345 は無効です</div>` を出した瞬間に、
  **ログイン ID が構造化ログ（CloudWatch）・Sentry context・Slack 本文の「認証エラー文言」へそのまま載る**。
- Sentry の `beforeSend` スクラブは**キー名ベース**（`PII_KEY_PATTERNS`）で、`authErrorText` はどのパターンにも一致せず素通りする。
- `fatalError` / `run.error` は生の例外メッセージで、DB エラー等が PII をエコーしうる。

テスト側も裏取りになっていない。`salonboard-login-diagnostics.test.js:169` の「診断オブジェクト全体を JSON 化しても原文が 1 つも残らない」は
入力 HTML に `class="error"` 系の要素が無いため `authErrorText` が常に `null` で、この経路を一度も通していない。
同テストの `expect(json).not.toContain('SuperSecretPw')` は入力に一度も現れない文字列との比較でトートロジー。

**修正提案:**
診断の自由文フィールドを 1 つのスクラバーに集約し、Slack 本文の自由文も同じ関数へ通す。

```typescript
const scrubDiagnosticText = (
  text: string | null,
  opts: { loginId?: string | null; password?: string | null },
): string | null => {
  if (!text) return null;
  let out = String(redactPiiText(text));
  const loginId = String(opts.loginId ?? '');
  if (loginId.length >= 3) out = out.split(loginId).join(maskLoginId(loginId) as string);
  const password = String(opts.password ?? '');
  if (password.length >= 3) out = out.split(password).join('[Filtered]');
  return out;
};

// buildLoginDiagnostics
authErrorText: scrubDiagnosticText(extractAuthErrorText(primary), { loginId: input.loginId, password: input.password }),
bodySnippet:   scrubDiagnosticText(htmlSnippet(finalHtml || doLoginBody), { loginId: input.loginId, password: input.password }),

// buildImportFailureSlackText
if (input.fatalError) lines.push(`実行全体の致命的失敗: ${redactPiiText(input.fatalError)}`);
if (run.error) lines.push(`  エラー: ${redactPiiText(run.error)}`);
```

テスト: `authErrorText` と `bodySnippet` の**両方**に実 loginId・実パスワード・メール・電話を埋めた HTML を与え、
診断 JSON 全体から全て消えることを固定する（`SuperSecretPw` のトートロジーも実値埋め込みに直す）。

---

- [x] 対応する

### [Code Quality] Slack への `fetch` にタイムアウトが無く、通知の遅延が取り込み実行を巻き込む

**ファイル:** `api/src/observability/slack.ts:72-105`
**重要度:** Medium

**該当コード:**

```typescript
// main 側（変更前）— 新規ファイル。該当コードなし
```

```typescript
// GTSS-817-qa 側（変更後）
    if (transport.kind === 'bot') {
      const res = await doFetch(CHAT_POST_MESSAGE_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          Authorization: `Bearer ${transport.token}`,
        },
        body: JSON.stringify({ channel: transport.channel, text }),
      });                                   // ← signal 指定なし
      …
    }

    const res = await doFetch(transport.webhookUrl as string, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
      body: JSON.stringify({ text }),
    });                                     // ← signal 指定なし
```

**問題:**
`postSlackMessage` は `runSalonboardImport` の**最後で `await`** される（`salonboard-import.service.ts:1487` → `:1400`）。
undici の既定は headers timeout 300s で、Slack 側が応答しない／egress が詰まると
batch Lambda（600s）・ECS タスクの残り時間をそのまま食い潰す。取り込み自体は先に `finalizeRun` 済みでデータは守られるが、
呼び出し元はサマリを返せず、REQ-4 の「Slack への投稿失敗は取り込み結果に影響させない」を満たさない。
現行テスト（`slack-notifier.test.js`）は即 reject と HTTP エラーのみで、**応答が返らないケース**を検証していない。

**修正提案:**

```typescript
const SLACK_TIMEOUT_MS = 5_000;
const res = await doFetch(url, { …, signal: AbortSignal.timeout(SLACK_TIMEOUT_MS) });
```

abort も既存の catch が `{ sent:false, reason }` として拾うので、呼び出し元の契約は変わらない。
テスト: 解決しない Promise を返す `fetchImpl` を注入し、タイムアウトで `sent:false` が返り取り込みが完了することを固定する。

---

- [x] 対応する

### [Code Quality] 日次 ECS 経路は成功終了パスに `Sentry.flush()` が無く、REQ-3 のイベント送信が確定しない

**ファイル:** `api/src/batch-cli.ts:64-80`（未変更）+ `api/src/services/salonboard-import.service.ts:367-401`（新規）
**重要度:** Medium

**該当コード:**

```typescript
// main 側（変更前）— 取り込みは Sentry へ何も送っていなかったため、
// ECS の成功終了パスに flush が無くても実害が無かった
  try {
    const result = await dispatchBatchAction(event);
    console.log('[batch-cli] completed:', event.action, JSON.stringify(result));
    return 0;                     // ← flush なし
  } catch (err) {
    …
    Sentry.captureException(err, { tags: { 'batch.action': event.action } });
    await Sentry.flush(2000);     // ← 例外パスにだけ flush がある
    return 1;
  }
```

```typescript
// GTSS-817-qa 側（変更後）— ログイン失敗は throw しないので、
// captureMessage は必ず「成功して return 0 する実行」の中で発火する
const captureLoginFailureToSentry = (payload: {…}): void => {
  try {
    Sentry.captureMessage(`[salonboard-import] ログイン失敗（${payload.reason}）`, {
      level: 'error',
      tags: { feature: 'salonboard-import', 'import.reason': payload.reason, … },
      contexts: { salonboard_login: { …, ...(payload.diagnostics ?? {}) } as any },
      fingerprint: ['salonboard-import', 'login-failure', payload.reason],
    } as any);
  } catch (e: any) {
    console.error(`[salonboard-import] Sentry への送信に失敗しました: ${e?.message || e}`);
  }
};
```

**問題:**
`login_failed` / `login_blocked` は例外を投げないため、`runCli` は **`return 0`（成功）パス**を通る。
このパスには `Sentry.flush()` が無く、Fargate は `process.exitCode` 設定後にイベントループが空になり次第終了する。
既存コード自身が例外パスに「Fargate は exit で即停止するため」と明記して flush を置いているのだから、
**送信を追加した今、成功パスにも同じ保証が要る**。日次取り込み＝ECS 経路は REQ-3 が最も効いてほしい経路であり、
Lambda 経路（`Sentry.wrapHandler` が flush する）とは非対称になっている。
`T-7` は `Sentry.captureMessage` のモック呼び出しを検証しているだけで、配送ライフサイクルは担保していない。

**修正提案:**

```typescript
  try {
    const result = await dispatchBatchAction(event);
    console.log('[batch-cli] completed:', event.action, JSON.stringify(result));
    await Sentry.flush(2000).catch(() => {});   // 成功パスでも送信を確定させる（DSN 未設定なら no-op）
    return 0;
  } catch (err) {
```

---

- [x] 対応する

### [Code Quality] `deploy-batch-ecs.sh` の secrets 和集合が追加専用で、削除経路が無い

**ファイル:** `api/deploy-batch-ecs.sh:149-162`
**重要度:** Medium

**該当コード:**

```bash
# main 側（変更前）— image と environment のみ差し替え。secrets は describe の値がそのまま残る
  NEW_DEF=$(echo "$CURRENT" | jq \
    --arg IMAGE "$IMAGE_URI" \
    --argjson CONTAINER_ENV "$ENV_JSON" '
      .containerDefinitions[0].image = $IMAGE
      | .containerDefinitions[0].environment = $CONTAINER_ENV
      | { family, taskRoleArn, executionRoleArn, networkMode, containerDefinitions,
          requiresCompatibilities, cpu, memory, runtimePlatform }
      | with_entries(select(.value != null))
    ')
```

```bash
# GTSS-817-qa 側（変更後）
      | .containerDefinitions[0].secrets =
          ((((.containerDefinitions[0].secrets // []) + $CONTAINER_SECRETS)
            | group_by(.name) | map(.[-1])))
```

**問題:**
既存（describe）とスクリプト定義の**和集合**なので、`BATCH_CONTAINER_SECRETS`（＝ Terraform 側の一覧）から名前を外しても
**task definition からは永久に消えない**。この状態で SSM パラメータ側を削除すると、次回のタスク起動が
`ResourceInitializationError` で落ちる（＝ Terraform 上は消したはずなのに ECS だけが古い参照を握り続ける）。
「TF の `ignore_changes` で追加が反映されない」問題を解消した一方で、逆向き（削除）に同じクラスの罠が残っている。

なお、`environment` 側の秘密混入ガード・`valueFrom` の ARN 検証・`environment` との名前衝突チェックは正しく、
`group_by(.name) | map(.[-1])` がスクリプト定義後勝ちになる点も意図どおり。`set -euo pipefail` で node の exit 1 も効く。

**修正提案:**
`BATCH_CONTAINER_SECRETS` が設定されているときは**置換**（未設定時のみ既存温存）にする。

```bash
      | .containerDefinitions[0].secrets =
          (if ($CONTAINER_SECRETS | length) > 0
           then $CONTAINER_SECRETS
           else (.containerDefinitions[0].secrets // []) end)
```

置換にできない事情があるなら、「削除は手動 register が必要」であることをスクリプト冒頭のコメントに明記する。

---

- [x] 対応する

### [Test Coverage] REQ-5 の最重要分岐が未カバー／新規純関数が未テスト／型だけ検証しているアサーション

**ファイル:** `api/src/__tests__/unit/salonboard-login.test.js:143` / `:199`、`api/src/__tests__/e2e/salonboard-import-observability.test.js:179` / `:219` / `:359`、`api/src/__tests__/unit/salonboard-login-diagnostics.test.js:219`
**重要度:** Medium

**該当コード:**

```javascript
// main 側（変更前）— 診断・リトライ分岐が存在しないため該当テストなし
```

```javascript
// GTSS-817-qa 側（変更後）
// salonboard-login.test.js:143 — 既定の diag() は blockSignals を常に空にする
  blockSignals: [],
// salonboard-import-observability.test.js:359 — AC-5.1 も明示的に空
      loginDiagnostics: { ...blockedDiagnostics, doLoginObserved: true, isLoginPage: true, blockSignals: [] },

// salonboard-import-observability.test.js:219 — 決定的な値なのに型だけ検証
    expect(typeof ctx.tags['import.route']).toBe('string');
// salonboard-login-diagnostics.test.js:219 — 実 fixture 入力で予測可能なのに型だけ検証
    expect(typeof d.bodySnippet).toBe('string');

// salonboard-import-observability.test.js:179 — fake が loginIdMasked:'CD***' を返すだけで
// 本番のマスク実装を一切通っていない
    expect(JSON.stringify(log)).not.toContain('CD00000');
```

**問題:**
`.claude/skills/vitest/lesson.md`「`expect.any(Object)/(Array)/(Number)` は使わない（必須）」に照らして、以下が担保不足。

- **AC-5.1 の最重要分岐が未カバー**: `doLoginObserved:true × isLoginPage:true × blockSignals 非空`（＝ High 指摘 1 の組み合わせ）を通すテストが 1 本も無い。
  AC-5.1 のテスト 2 本はどちらも `blockSignals: []` を明示している。
- **新規 export 関数に直接の unit テストが無い**: `resolveExecutionRoute`（`salonboard-import.service.ts:346`）と
  `isBlockSuspected`（`salonboard-login.ts:112`）は export されているのに `src/__tests__/` に直接の呼び出しが 0 件（grep 済み）。
  `resolveExecutionRoute` の `lambda` / `ecs` 分岐は本 Issue の主目的（手動=Lambda / 日次=ECS の切り分け）そのもので、
  タグ側の担保が無い。
- **型だけ検証**: `import.route` は `AWS_LAMBDA_FUNCTION_NAME` / `ECS_CONTAINER_METADATA_URI*` をテスト環境でセットしていない
  （リポジトリ全体 grep 済み）ため決定的に `'local'`。`bodySnippet` も実 fixture 入力なので予測可能。現状は空文字や誤値でも green になる。
  ※ `d.timings.*` の `typeof`（`:222` / `:305-307`）は実時間依存なので現状のままで妥当。
- **PII アサーションが実装を通っていない**: `:179` の `not.toContain('CD00000')` は fake が渡す手書き診断（`loginIdMasked:'CD***'`）を見ているだけで、
  AC-1.2 の根拠には数えられない（実マスクは diagnostics unit で担保済みなので害は無い）。
- **`session_renew_skipped` は会社単位（T-27）のみ**。`sessionRenewals` は `importCompany` スコープで店舗をまたいで共有されるため、
  店舗単位連携で上限到達する経路が未カバー。

**修正提案:**

```javascript
// 1. AC-5.1 × blockSignals 非空
it('AC-5.1 ログイン画面が返っていれば遮断シグナルがあっても引き直さない', async () => {
  const client = makeFakeClient({ loginOk: false, loginDiagnostics:
    diag({ doLoginObserved: true, isLoginPage: true, blockSignals: ['attention_required'] }) });
  const out = await loginWithRetry('CD00000', 'pw', { createClient: () => client });
  expect(out.authFailed).toBe(true);
  expect(out.attempts).toBe(1);
});

// 2. resolveExecutionRoute の 3 分岐
expect(resolveExecutionRoute({ AWS_LAMBDA_FUNCTION_NAME: 'x' })).toBe('lambda');
expect(resolveExecutionRoute({ ECS_CONTAINER_METADATA_URI_V4: 'x' })).toBe('ecs');
expect(resolveExecutionRoute({})).toBe('local');

// 3. 型だけ検証を具体値へ
expect(ctx.tags['import.route']).toBe('local');
```

---

- [x] 対応する

### [Security] Slack 本文へ申請者入力（会社名）を無加工で埋め込んでいる（mrkdwn / `<!channel>` 注入）

**ファイル:** `api/src/services/salonboard-import.service.ts:935` / `:1362`
**重要度:** Low

**該当コード:**

```typescript
// main 側（変更前）— Slack 通知が存在しない
```

```typescript
// GTSS-817-qa 側（変更後）
// :935 会社名は申請フォーム（LP）由来のユーザー入力
  run.companyName = application?.businessName || application?.partnerName || null;

// :1362 chat.postMessage の text へそのまま埋める
    lines.push(`• ${run.companyName || '(会社名なし)'}（${run.applicationId}）`);
```

**問題:**
`businessName` / `partnerName` は LP の申請フォームから入る**申請者制御の文字列**で、エスケープなしに Slack の `text` へ入る。
`<!channel>` / `<!here>` を会社名に仕込めば運営チャンネル全員へのメンションが発生し、`<http://…|表示文字>` でリンク偽装もできる。
また `partnerName` は個人事業主では本人氏名を兼ねるため、屋号未入力の会社では**個人名が Slack へ出る**（コメントもその点を認識している）。

**修正提案:**

```typescript
const escapeSlackText = (s: string): string =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

lines.push(`• ${escapeSlackText(run.companyName || '(会社名なし)')}（${run.applicationId}）`);
```

氏名の混入を避けるなら `partnerName` フォールバックをやめ、`businessName` が無ければ申請 ID のみで識別する
（`entityType === 'corporate'` のときだけ `partnerName` を法人名として使う、でも可）。

---

- [x] 対応する

### [Code Quality] `shop_fetch_retry` を `renewSession()` の前に出しており、Logs Insights の再試行カウントが過大になる

**ファイル:** `api/src/services/salonboard-import.service.ts:458-470`
**重要度:** Low

**該当コード:**

```typescript
// main 側（変更前）— リトライが無く、失敗は 1 行の人間向け文字列のみ
  } catch (e: any) {
    const { reason, message } = classifyFailure(e, null);
    result.failed += 1;
    …
    console.error(
      `[salonboard-import] shop fetch failed store=${shop.externalStoreId} ` +
        `reason=${reason ?? 'unknown'}: ${message}`,
    );
    return result;
  }
```

```typescript
// GTSS-817-qa 側（変更後）
      if (attempt < MAX_SHOP_FETCH_ATTEMPTS && isTransientShopFailure(reason) && ctx.renewSession) {
        logShopEvent('shop_fetch_retry', { attempt, reason, message });   // ← 引き直し前に出す
        await pace();
        const renewed = await ctx.renewSession();
        if (renewed) { ops = renewed; continue; }
        // 引き直せなかった（上限到達 / 再ログイン失敗）
        note = '（セッション引き直し不可）';
      }
```

**問題:**
`shop_fetch_retry` を `renewSession()` の**前**に出しているため、上限到達（`session_renew_skipped`）や再ログイン失敗でも 1 行出る。
T-27 の実行がまさにその形（3 店舗目は引き直していないのに `shop_fetch_retry` が出る）。
CloudWatch Logs Insights で「実際に何回引き直したか」を数えると過大になる。

**修正提案:** `renewSession()` が truthy を返した後に `shop_fetch_retry` を出す（または `renewed: boolean` をフィールドに持たせる）。

---

- [x] 対応する

### [Code Quality] `lastBlockedLogin` が throw 経路で落ち、`login_blocked` 分類が失われる

**ファイル:** `api/src/services/salonboard-login.ts:214-228`
**重要度:** Low

**該当コード:**

```typescript
// main 側（変更前）— 遮断疑いの概念が無い
```

```typescript
// GTSS-817-qa 側（変更後）
      blockRetries += 1;
      lastBlockedLogin = login;     // ← 予算超過分岐（:153-164）でしか読まれない
      await sleep(attempt);
      continue;
    } catch (e: any) {
      await closeClient(client);
      lastError = e;
      if (!isTransient(e) || attempt >= maxAttempts) {
        return { ok: false, client: null, error: e, attempts };   // ← loginBlocked / diagnostics が落ちる
      }
      await sleep(attempt);
    }
```

**問題:**
「1 回目 = 遮断疑い → 2 回目が `SalonboardTimeoutError` を throw」で終わると、`lastBlockedLogin` は使われず
`loginBlocked` / `diagnostics` が失われて `timeout` として記録される。診断情報も Sentry / Slack へ載らない。
どちらも一過性理由なので取り込みの再試行挙動は変わらないが、原因特定という Issue の主目的では情報が欠ける。

**修正提案:** 例外 return 時にも `lastBlockedLogin` があれば `loginBlocked: true` / `diagnostics` を添えて返す。

---

- [x] 対応する

### [Code Quality] ECS（日次）経路の通知で CloudWatch ロググループ名を案内できていない / 実行時刻が UTC

**ファイル:** `api/src/services/salonboard-import.service.ts:1391-1399` / `:1421`
**重要度:** Low

**該当コード:**

```typescript
// main 側（変更前）— Slack 通知が存在しない
```

```typescript
// GTSS-817-qa 側（変更後）
    const fn = process.env.AWS_LAMBDA_FUNCTION_NAME;
    const text = buildImportFailureSlackText({
      environment: process.env.SENTRY_ENVIRONMENT || process.env.NODE_ENV || 'unknown',
      trigger: input.trigger,
      startedAt: input.startedAt,          // ← :1421 で now.toISOString()（UTC）
      runs: input.runs,
      fatalError: input.fatalError,
      logGroup: fn ? `/aws/lambda/${fn}` : null,   // ← ECS では常に null
    });
…
    lines.push(`• CloudWatch Logs: ${input.logGroup || 'batch の実行ログ（ECS タスクのログストリーム）'}`);
```

**問題:**

1. **ロググループ名**: `AWS_LAMBDA_FUNCTION_NAME` があるときしか具体名を出せず、**日次取り込みが動く ECS 経路では常に汎用文言**になる。
   REQ-4 の「確認先の案内（CloudWatch のロググループ名…）」を、通知が一番効いてほしい経路で満たしていない。
2. **実行時刻**: `startedAt` は `now.toISOString()`（例 `2026-08-06T02:55:17.000Z`）で UTC。
   admin 側は `formatJstDateTime` で一律 JST に揃えている一方 Slack だけ UTC なので、運営が 9 時間ずれて読む。

**修正提案:**

```typescript
logGroup: fn ? `/aws/lambda/${fn}` : (process.env.BATCH_LOG_GROUP || null),   // ECS の値は deploy-batch-ecs.sh の environment で配布
`実行時刻: ${new Date(input.startedAt).toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' })}`
```

---

- [x] 対応する

### [Test Coverage] リトライ e2e が Slack モジュール未モックで、送信ガード 1 枚に依存している

**ファイル:** `api/src/__tests__/e2e/salonboard-import-retry.test.js`（先頭に `vi.mock` なし）
**重要度:** Low

**該当コード:**

```javascript
// 同 PR の salonboard-import-observability.test.js:13 — こちらはモック済み
vi.mock('../../observability/slack', () => ({
  postSlackMessage: vi.fn(),
}));
```

```javascript
// salonboard-import-retry.test.js — vi.mock が 1 つも無い（grep 済み）
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
…
```

**問題:**
T-24 / T-27 / T-28 は `failed > 0` で終わるため実体の `postSlackMessage` を呼び、
`NODE_ENV=test` の early return と環境変数未設定だけで実送信を止めている。
`.claude/skills/vitest/lesson.md`「外部 API はモックし、正常系で実通信しない」に照らすとガードが 1 枚しかない。
同 PR 内で方針が不揃いでもある。

**修正提案:** 同ファイルにも `vi.mock('../../observability/slack')` を置く。
ついでに「リトライ成功時（T-22 / T-23）は Slack を呼ばない」を assert できる。

---

- [x] 対応する

### [Code Quality] admin: リスト `key` が index のまま（当該行を書き換えているのに据え置き）

**ファイル:** `admin/src/components/ImportRunList.tsx:148`
**重要度:** Low

**該当コード:**

```tsx
// main 側（変更前）
                            {fails.map((s, i) => (
                              <li key={i} className="text-red-700">
                                {(s.shopName || s.externalStoreId || '店舗')}: {s.error}
                              </li>
                            ))}
```

```tsx
// GTSS-817-qa 側（変更後）— コールバックを丸ごと書き換えているのに key={i} が残存
                            {fails.map((s, i) => {
                              const reason = reasonText(s)
                              return (
                                <li key={i} className="text-red-700">
                                  {(s.shopName || s.externalStoreId || '店舗')}
                                  {reason && (
                                    <span … data-testid="import-run-shop-reason">{reason}</span>
                                  )}
                                  : {s.error}
                                </li>
                              )
                            })}
```

**問題:**
`.claude/lessons.md`「リスト要素の key には行のユニーク値を含める」の典型形。
`<li>` に内部状態が無いため実害は小さいが、当該行を書き換えるタイミングで直しておきたい。

**修正提案:** ``key={s.externalStoreId || `${run.id}-${i}`}``

---

- [x] 対応する

### [Code Quality] 細かい一貫性・ハードニング（まとめ）

**重要度:** Low

| # | ファイル | 内容 | 修正提案 |
|---|---|---|---|
| 1 | `api/deploy-batch-ecs.sh:259` | 書式エラー時に `${item}` 全体をログ出力。`BATCH_CONTAINER_SECRETS` に裸のトークン／Webhook URL を誤設定すると**実値が CodeBuild ログに残る**（ARN 検証側は `name` しか出さず正しい） | 項目番号のみ出す: `` `…の ${i + 1} 番目の項目が NAME=ARN 形式ではありません` `` |
| 2 | `api/src/services/salonboard-client.ts:952-961` | `pageTitle` / `isLoginPage` / `authErrorText` は `doLoginBody \|\| finalHtml`、`bodySnippet` だけ `finalHtml \|\| doLoginBody` と**逆順**。HTTP 経路で別ページ混在になり読み違えやすい | 優先順を揃える（揃えない理由があるならコメントで明記） |
| 3 | `api/src/services/salonboard-client.ts:884-889` | `maskLoginId` は `length <= 2` で `` `${v}***` `` を返し**原文が残る**（テストが現仕様を固定している） | `'***'` を返す |
| 4 | `api/deploy-batch-ecs.sh:194` | `log_info "secrets: …"` の行末に余分な空白 | 削除 |
| 5 | `admin/e2e/import-runs.spec.ts:41-70` | T-20 は「会社詳細の取り込み実行履歴を開く」受け入れ条件だが、テストはグローバル画面 `/import-runs` を直接開いている。ネストしたルート・`applicationId` の受け渡し・会社別レスポンスでの描画が未検証（Vitest 側で分岐は網羅済みのため実害は小さい） | `/applications/:id/import-runs` を開くケースを 1 本追加し、会社別フィルタも同時に固定する |

---

## 本 PR 外（別途対応の推奨）

- **fixture に実スタッフ名らしき値が残存**: `api/src/__tests__/fixtures/salonboard/detail-cancel-zero-fee.html` /
  `detail-no-policy.html` / `detail-cancel-with-policy.html` / `detail-unauthorized-with-policy.html` の 4 件に
  `大庭邦彦（ＧＩＤ）` が含まれる。CLAUDE.md の PII 規約は「サロンスタッフ名」を fixture の置換対象として明記しているため、
  別 PR で `テスト担当` 等へ置換したい。**本 PR の差分には含まれない**。
- **admin `StoreList.test.tsx` の既存 failure**: 本 PR の差分外（StoreList 系は未変更）で main 由来。別途 main 側で対応が必要。

## 総評

**設計・実装品質は総じて高い。** 特に次の点は妥当で、そのまま進めてよい。

- **REQ-5 のフェイルセーフの向き**が正しい。診断が無い（旧クライアント / テスト fake / HTML を取れない）ときは
  `isBlockSuspected` が `false` を返して従来どおり即失敗に倒し、「認証情報誤りを毎回引き直してロックする」最悪ケースを構造的に避けている。
- **`#22 レビュー High`（CAPTCHA 判定は `userId` が取れなかった時のみ）の規約が維持**されている。HTTP（`salonboard-client.ts:323`）/
  Playwright（`:1300`）とも `!userId &&` ゲートのままで、新設の成功時 early return（`:327` / `:1305`）は CAPTCHA 判定の**後**。順序不変。
- **enum 追加の更新漏れが無い**。`login_blocked` は `IMPORT_LOG_REASON` / `_LABELS` / `emptyByReason()` / `LOGIN_FAILURE_REASONS` /
  `FAILURE_REASONS_FOR_NOTIFY` に反映され、`TERMINAL_IMPORT_LOG_REASONS` へは意図的に非追加（＝一過性理由として翌日再試行）。
  admin は独自ラベル表を持たず API の `reasonLabel` を使うため二重管理も無い。
- **認可・機微フィールド露出**: API 面の差分は `listImportRuns` の `reasonLabel` 付与のみ。`cancellation.service.ts:259` で `requireAdmin` が先頭、
  sibling の `/import-logs`（`:240`）も同様で付け忘れ無し。`finalizeRun`（`:1189-1200`）は列を明示 pick するため
  新設の `diagnostics` / `companyName` / `unit` は DB にも admin にも出ない。
- **検証経路の 29s 予算**は不変。`config.ts` の `totalBudgetMs=24s` / `minAttemptBudgetMs=9s` に対し、
  遮断疑いの引き直しも `salonboard-login.ts:197-213` で残予算を評価してから行うため超過しない。
- **`deploy-batch-ecs.sh` の secrets 所有権をスクリプト側へ移した判断**が良い。TF の `ignore_changes = [container_definitions]` が
  「更新時のみ効き新規作成時は効かない」ため既存 family に落ちない、という実測（GTSS-886 の `TWILIO_AUTH_TOKEN`）を踏まえた構造的な解消。
  register 前の自己検証（environment 配列性・秘密の平文混入・`valueFrom` の ARN 判定・name 重複）も丁寧。
- **テストが行動ベース**。`makeFakeClient` の `enterStoreErrors` / `listErrors`（`times` 指定で N 回だけ失敗）は
  「引き直して復旧した」を実際に再現しており、トートロジーではない。`expect.any(Object/Array/Number)` の使用も 0 件。
  日付依存も無い（`NOW` 注入 + fixture 側の `visitationDate` 固定）。T-1〜T-29 は api / admin いずれかのテストに対応が付いている。

**マージ前に対応したいのは High 2 件と Medium 7 件。** 優先順は次のとおり。

1. **`isBlockSuspected` の判定順（High）** — AC-5.1 が壊れると、避けたかったアカウントロックのリスクと
   「運営が認証情報の誤りに気づけない」という Issue の目的そのものへの逆行が同時に起きる。関数の 1 行追加で直る。
2. **セッション引き直し上限が効いていない（High）** — `MAX_SESSION_RENEWALS_PER_RUN` の目的（velocity 抑制・600s 死守）を実際には満たしておらず、
   遮断時に 1 会社で最大 9 回ログインを叩き batch Lambda の timeout を単独で超えうる。`maxAttempts: 1` にするだけで直る。
3. **Slack の起動条件（Medium ×2）** — 連携設定未完了の会社があるだけで日次「内訳なし」通知が鳴り続ける一方、
   会社ランが例外で落ちると逆に何も鳴らない。どちらも `notifyImportFailure` の先頭ガード 1 箇所で解消できる。
4. **自由文の PII マスク漏れ（Medium）** — `authErrorText` / `fatalError` / `run.error`。
   今は実害が出ないが、サロンボードが文言を出し始めた瞬間にログイン ID が 3 経路へ漏れる。
5. **Slack fetch の無タイムアウト / ECS 成功パスの `Sentry.flush` 欠落 / secrets 削除経路（Medium）** — いずれも数行で、
   REQ-3 / REQ-4 の「取り込みを壊さない」「確実に届く」と運用の詰まりに直結する。
6. **テスト追加（Medium）** — 上記 1 の組み合わせ、`resolveExecutionRoute` の 3 分岐、`typeof` の具体値化。

Low の 6 件は運用上の使い勝手とハードニングで、後追いでも構わない。

**レビュー体制**: codex-reviewer / code-reviewer / lessons-reviewer の 3 エージェントの出力を、
メインエージェントが worktree の実ファイルで cross-file 再検証（`.claude/skills/review-verification/SKILL.md`）した上で採録した。
再検証で裏取りできなかった指摘（「遮断疑い後に timeout が throw されると 3 回目まで進む＝上限違反」など。
`maxAttempts=3` は既存の一過性リトライ上限の範囲内であり仕様違反ではない）は破棄している。
