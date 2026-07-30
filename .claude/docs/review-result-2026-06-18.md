---
issue: 22
date: 2026-06-18
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-817-store
    toBranch: GTSS-817-proxy
---

# レビュー結果: #22

## 概要

**Issue:** #22 [API] サロンボード取り込みを Playwright + 住宅/モバイルプロキシ(Decodo スティッキー)化（Akamai/AWS-IP遮断対策・直列化・bot検知回避）

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-817-store` | `GTSS-817-proxy` | 2 | 13 |

通信層を pure HTTP → Playwright(Chromium) + Decodo スティッキープロキシへ置換。並列詳細取得を直列化・ジッタ挿入・CAPTCHA/proxy/timeout/login_failed の失敗理由分類・Chromium 実行環境選択（Lambda+@sparticuz/chromium）・build.mjs の external 化・deploy-batch.sh の Lambda 設定引き上げ。既定 transport は安全側 `http` で、playwright 化は `SALONBOARD_TRANSPORT=playwright` + `DECODO_*` 設定時のみ。typecheck / build green、vitest 567 passed。

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/services/salonboard-client.ts` | +508 | -6 | Modified |
| `src/services/salonboard-import.service.ts` | +150 | -52 | Modified |
| `src/config.ts` | +64 | 0 | Modified |
| `src/constants/cancellation-status.ts` | +10 | 0 | Modified |
| `src/__tests__/unit/salonboard-playwright-client.test.js` | +233 | 0 | Added |
| `src/__tests__/unit/salonboard-proxy-config.test.js` | +107 | 0 | Added |
| `src/__tests__/e2e/salonboard-import.test.js` | +114 | -5 | Modified |
| `deploy-batch.sh` | +36 | -2 | Modified |
| `.env.example` | +22 | 0 | Modified |
| `build.mjs` | +9 | -1 | Modified |
| `package.json` | +2 | 0 | Modified |
| `package-lock.json` / `yarn.lock` | +382 | 0 | Modified |

## 指摘一覧

- [x] 対応する

### [Code Quality] CAPTCHA 検知をログイン後の全 DOM に対して行い、成功時でも誤検知しうる

**ファイル:** `api/src/services/salonboard-client.ts:1414-1421`（worktree 実体 `login()`）
**重要度:** High

**該当コード:**
```typescript
// toBranch側（変更後）— login() の末尾
const finalHtml = await page.content();
// CAPTCHA 昇格時は無限ループ・velocity を避けるため即失敗（理由記録は取り込みサービス）。
if (detectCaptcha(doLoginBody) || detectCaptcha(finalHtml)) {
  throw new SalonboardCaptchaError('ログイン時に CAPTCHA を検知しました');
}
const userId = parseUserId(doLoginBody) || parseUserId(finalHtml);
// groupTopHtml は遷移先 HTML（会社単位=groupTop / 単一店舗=店舗トップ）。
return { ok: !!userId, userId, groupTopHtml: finalHtml };
```

```typescript
// detectCaptcha のマーカー（salonboard-client.ts:397-408）
const CAPTCHA_MARKERS: RegExp[] = [
  /captcha/i,
  /recaptcha/i,
  /hcaptcha/i,
  /画像認証/,
  /ドラッグ(?:＆|&|アンド)?\s*ドロップ/,
  /パズル認証/,
  /スライド(?:して|させて)/,
  /bot[\s-]?(?:検知|対策|protection)/i,
];
export const detectCaptcha = (html: string): boolean =>
  CAPTCHA_MARKERS.some((re) => re.test(html || ''));
```

**問題:** `detectCaptcha` をログイン成功後の **全 DOM (`page.content()`)** に対してかけており、しかも `parseUserId` より**前**に評価して throw する。`/captcha/i` `/recaptcha/i` は素の文字列マッチのため、正常ページに `<script src=".../recaptcha/...">`・`grecaptcha` 変数・`class="...captcha..."` 等が含まれるだけで成立する。Akamai 配下のページは sensor スクリプトや CSP に `bot` 文字列を含みがちで `/bot[\s-]?protection/i` も誤爆しうる。影響は「**ログイン成功しているのに CAPTCHA 扱い→全店舗 failed**」と大きい。実ログインページ HTML は fixture 化されておらず、この経路の回帰ガードが無い（既存テストは人工 `CAPTCHA_HTML` のみ）。PDCA 実機（userid=CD34512/CD77768）では誤爆しなかったが、ページ構成変化に脆い。

**修正提案:** `userId` を取得できた場合は CAPTCHA 判定をスキップする（成功シグナルを優先）。例:
```typescript
const userId = parseUserId(doLoginBody) || parseUserId(finalHtml);
if (!userId && (detectCaptcha(doLoginBody) || detectCaptcha(finalHtml))) {
  throw new SalonboardCaptchaError('ログイン時に CAPTCHA を検知しました');
}
return { ok: !!userId, userId, groupTopHtml: finalHtml };
```
あわせて検査対象を doLogin 応答本文中心に絞り、`/captcha/i` `/recaptcha/i` の素マッチは実 CAPTCHA UI 文言（日本語マーカー）に寄せる。PII 置換済みの実ログイン後 HTML を fixture 化し `detectCaptcha === false` を担保するテストを追加するのが望ましい。

---

### [Code Quality] プロキシ未設定の throw が `login_failed` に誤分類される（可観測性）

**ファイル:** `api/src/config.ts:1054-1064` / `api/src/services/salonboard-import.service.ts`（importCompany の login catch）
**重要度:** Medium

**該当コード:**
```typescript
// config.ts — fail-safe は plain Error を投げる
export const requireSalonboardProxy = (
  proxy: SalonboardProxyConfig | null,
): SalonboardProxyConfig | null => {
  if (proxy) return proxy;
  if (process.env.NODE_ENV === 'dev' || process.env.NODE_ENV === 'prod') {
    throw new Error(
      'SALONBOARD_PROXY_NOT_CONFIGURED: dev/prod はサロンボードプロキシ必須です（AWS 直 IP は遮断）',
    );
  }
  return null;
};
```

```typescript
// salonboard-import.service.ts — login 経路の catch（会社/店舗単位とも同型）
let client;
try {
  const password = await decryptSecret(integration.encryptedSecret);
  client = createSalonboardClient({ runId }); // ← ここで requireSalonboardProxy が throw しうる
  const login = await client.login(integration.loginId, password);
  ...
} catch (e: any) {
  const { reason, message } = classifyFailure(e); // fallback = LOGIN_FAILED
  markCompanyShopsFailed(run, shops, `ログイン処理に失敗: ${message}`, reason);
  await closeClient(client);
  return run;
}
```

**問題:** `requireSalonboardProxy` は `SalonboardPlaywrightClient` のコンストラクタ（=`createSalonboardClient({runId})`）で発火する。これは login の try 内なので catch に入り、`classifyFailure(e)` が `SalonboardProxyError` でも `code==='proxy_error'` でもない plain Error を fallback の `LOGIN_FAILED` に分類する。運用者には「ログイン失敗」と見え、真因（プロキシ設定漏れ）が `proxy_error` として観測できない。`transport=playwright` かつ dev/prod かつ proxy 未設定時のみだが、まさに本番投入直後に起きやすい設定ミスである。

**修正提案:** `requireSalonboardProxy` を `SalonboardProxyError`（`code:'proxy_error'`）で throw する。または import 側で `/SALONBOARD_PROXY_NOT_CONFIGURED/` を `PROXY_ERROR` にマップする。proxy 未設定時の分類テストを追加。

---

### [Code Quality] CAPTCHA 検知が enterStore / 一覧 GraphQL 応答で行われない（REQ-7 の理由分類が弱い）

**ファイル:** `api/src/services/salonboard-client.ts`（`enterStore` / `enterSingleStore` / `fetchReservationListJson`）
**重要度:** Medium

**該当コード:**
```typescript
// detectCaptcha が呼ばれるのは login() と fetchReservationDetailHtml() のみ。
// enterStore / enterSingleStore / fetchStoreTopHtml / 一覧 GraphQL の応答本文では未チェック。
async enterStore(externalStoreId: string): Promise<void> {
  const page = await this.ensurePage();
  try {
    const forward = await this.pageFetch('/CNC/groupTop/forward', { ... });
    if (forward.status >= 400) { throw new Error(`enterStore forward failed ...`); }
    const top = await this.pageFetch('/CLP/bt/top/', { ... });
    ...
  } catch (e) {
    throw classifyBrowserError(e); // captcha は分類されない
  }
}
```

**問題:** Akamai の CAPTCHA/チャレンジ昇格はログイン後（店舗遷移・一覧取得）でも起きうるが、その経路では `detectCaptcha` が呼ばれない。`fetchReservationListJson` は `JSON.parse(listRes.text)` するため、200+CAPTCHA HTML が返ると JSON parse 例外 → 店舗失敗にはなるが、`captcha_detected` ではなく**汎用失敗（reason=null）**に落ちる。REQ-7（CAPTCHA を理由別に記録）が login/詳細経路に限定され、中間経路で弱い。

**修正提案:** `enterStore`/`enterSingleStore` のナビゲーション後 `page.content()` と、一覧/store-top の `pageFetch` 戻り本文を `detectCaptcha` に通し、検知時は `SalonboardCaptchaError` に統一する。一覧経路の CAPTCHA ケースのテストを追加。

---

### [Code Quality] ジッタ（pace）が詳細取得の2件目以降のみ。店舗遷移・一覧ページング・店舗ループ間には入らない（REQ-3/4 部分実装）

**ファイル:** `api/src/services/salonboard-import.service.ts:320-358`（詳細取得ループ）
**重要度:** Medium

**該当コード:**
```typescript
// toBranch側（変更後）— pace() は詳細取得ループ内だけ
// 直列実行（同時 inflight=1）。2 件目以降は各取得の前にジッタを挟む（REQ-3/REQ-4）。
for (let i = 0; i < localCandidates.length; i++) {
  if (i > 0) await pace();
  await processCandidate(localCandidates[i]);
}
```

**問題:** REQ-3 は「各リクエスト/ナビゲーションの間にランダム遅延（ジッタ）を挿入する」と規定。直列化（inflight=1）は満たすが、`pace()` は詳細取得の2件目以降にしか入らない。`enterStore`→`bt/top`→`reservations/init`→一覧 GraphQL（page2..N の `?page=` ナビ含む）→複数店舗ループ（会社単位）の各境界は連続実行され、velocity 抑制の隙になる。

**修正提案:** 最低でも enterStore 後・一覧ページ境界・店舗ループ境界に `pace()` を挟む（理想はクライアント側で外部リクエスト/ナビゲーション前に共通 pacing）。T-6 を一覧/店舗遷移にも拡張。

---

### [Test Coverage] Playwright クライアントのデータ取得経路が自動テスト未カバー

**ファイル:** `api/src/services/salonboard-client.ts`（`enterStore` / `fetchReservationListJson` / `refreshQueriesFromBundle` / `graphql` / `fetchReservationDetailHtml`）
**重要度:** Medium

**問題:** 追加 unit テストは `login` / `detectCaptcha` / `shouldAbortResource` / `buildContextOptions` / `selectChromiumSource` を押さえるが、データ取得経路（`enterStore`・`enterSingleStore`・`fetchReservationListJson` の「初回 4xx→`refreshQueriesFromBundle`→再試行」分岐・`fetchReservationDetailHtml`・`graphql`・`pageFetch`）が一切テストされていない。これらは HTTP 実装と並ぶ最も壊れやすい 3 層フォールバックを Playwright 側に持つのに回帰ガードが無い。e2e テストは fake クライアントを注入するため実クライアントの内部は通らない。

**修正提案:** 既存の fake page（`evaluate`/`goto` を返す）を拡張し、少なくとも「一覧の 4xx→query 差し替え→再試行成功」分岐、`fetchReservationDetailHtml` の CAPTCHA throw、`enterStore` の `forward.status>=400` で `Error`→`classifyFailure` が **null（汎用失敗）** に落ちることを検証。実プロキシ実ログインは引き続き人手（T-11）で担保で可。

---

### [Code Quality] deploy-batch.sh が Chromium 同梱 zip を `--zip-file` で直接アップロード（50MB 上限に抵触しうる）

**ファイル:** `api/deploy-batch.sh:102-110`
**重要度:** Medium

**該当コード:**
```bash
cd "$DEPLOY_DIR"; zip -r "../$ZIP_FILE" . -x "*.DS_Store*" "*.git*" > /dev/null; cd "$PROJECT_DIR"
...
aws lambda update-function-code \
  --function-name "$LAMBDA_FUNCTION" \
  --zip-file "fileb://$ZIP_FILE" \
  --profile "$AWS_PROFILE"
```

**問題:** `--zip-file fileb://` の直接アップロードは **zip 50MB 上限**。本 PR は `@sparticuz/chromium`（brotli 圧縮 Chromium ~50MB 級）+ `playwright-core` を `node_modules` 同梱する（deploy-batch.sh の npm install 追加部分）。既存バンドル + これらで zip が 50MB を超えると `update-function-code` が失敗する。サイズ検証も無いため、初回 batch デプロイ時に判明する。

**修正提案:** S3 経由アップロード（`--s3-bucket/--s3-key`、unzip 250MB 上限）か Lambda Layer 分離へ切替。zip 後に圧縮/非圧縮サイズを閾値チェックし、超過時は明示 fail。dev 実機デプロイでサイズを確認すること（CLAUDE.md「デプロイ前は dev 環境で動作確認」）。

---

### [Code Quality] `page.on('response')` リスナーを login 内で登録し除去しない

**ファイル:** `api/src/services/salonboard-client.ts:1398-1407`
**重要度:** Low

**該当コード:**
```typescript
let doLoginBody = '';
page.on('response', async (resp: any) => {
  try {
    if (String(resp.url()).includes('/CNC/login/doLogin/')) {
      const t = await resp.text();
      if (t) doLoginBody = t;
    }
  } catch { /* 個別応答の本文取得失敗は無視 */ }
});
await page.click('a.loginBtnSize');
```

**問題:** 同一ページを使い回す（`ensurePage` で 1 ページ・login→enterStore→一覧→詳細）ため、リスナーは login 後の全ナビゲーション/全 fetch 応答ごとに走り続ける。各応答で `resp.url()` 判定が残り、`doLoginBody` も後続で上書きされ続ける（戻り後は未参照なので実害は軽微）。会社単位で 1 ページに複数店舗のナビが乗るほど積み上がる。

**修正提案:** login 戻り直前に `page.off('response', handler)` で解除、または `page.waitForResponse('**/CNC/login/doLogin/**')` 方式に置換して固定待機（指摘下記）ごと不要にする。

---

### [Code Quality] env 値の検証不足（`sessionduration-NaN` / here-doc JSON 破損）

**ファイル:** `api/src/config.ts:1036-1039` / `api/deploy-batch.sh:165-178`
**重要度:** Low

**該当コード:**
```typescript
// config.ts — durationMin は検証せず username へ補間（jitter 側には Number.isFinite ガードがあるのに不整合）
const durationMin = Number(process.env.SALONBOARD_PROXY_SESSION_DURATION_MIN || '10');
const username = `user-${user}-country-${country}-session-${sessionId}-sessionduration-${durationMin}`;
```

**問題:** `SALONBOARD_PROXY_SESSION_DURATION_MIN` に非数値を設定すると `durationMin=NaN` となり `sessionduration-NaN` を Decodo に送る（セッション解釈失敗の恐れ）。また `deploy-batch.sh` の env JSON は here-doc 生生成で、`DECODO_PASSWORD` に `"` `\` 改行が混入すると JSON が壊れる。

**修正提案:** `durationMin` に `Number.isFinite` ガード＋既定 10 フォールバック。deploy-batch.sh の env JSON は `jq -n --arg` か Node の `JSON.stringify` で生成。

---

### [Performance] 固定 `waitForTimeout(1200)` がログイン毎に必ず乗る

**ファイル:** `api/src/services/salonboard-client.ts:1413`
**重要度:** Low

**該当コード:**
```typescript
await page.waitForLoadState('networkidle', { timeout: NAV_TIMEOUT }).catch(() => {});
// response handler（async text）の settle 待ち。
await page.waitForTimeout(1200).catch(() => {});
const finalHtml = await page.content();
```

**問題:** response handler の settle 待ちのための固定 1.2s。ジッタに加えてログイン毎に必ず乗る。店舗単位連携（1 店舗 1 ログイン）では店舗数ぶん積み上がり、Lambda timeout 600s / スティッキー ~10 分の制約に効く。

**修正提案:** `page.waitForResponse('**/CNC/login/doLogin/**', { timeout: ... })` で doLogin 応答を明示的に待てば固定待機を消せ、より確実（前述のリスナー解除も不要化）。

---

### [Code Quality] 軽微: `selectChromiumSource({})` の bundled フォールバック / proxy 二重指定

**ファイル:** `api/src/services/salonboard-client.ts:1263-1297`
**重要度:** Low

**問題:**
1. 依存は `playwright-core` のみ（フル playwright/browser install 無し）。`selectChromiumSource({})` の `bundled` 分岐は `executablePath`/`channel` を設定せず `chromium.launch()` がブラウザを見つけられず失敗する設定漏れフットガン（Lambda は `AWS_LAMBDA_FUNCTION_NAME`→`sparticuz`、ローカルは `.env.example` 案内の `CHROMIUM_CHANNEL=chrome` で回避可）。
2. `defaultLauncher` が `chromium.launch({ proxy })` に proxy を渡し、`ensurePage` が `newContext(buildContextOptions(proxy))` でも proxy を渡す二重指定（context 側優先で害は無いが意図が読みにくい）。

**修正提案:** `bundled` を廃止し未設定は設定エラーにするか、現状の暗黙フォールバックを許容するか方針を明示。proxy 指定は context 側に一本化。`buildLaunchOptions(src, proxy)` を純粋関数化すれば REQ-5 の launchOpts 組み立ても unit テスト可能。

---

### [Code Quality] スコープ確認: API Lambda の連携検証経路は playwright 配線対象外

**ファイル:** `api/src/services/salonboard-auth.service.ts:49,164`（本 PR 差分外）
**重要度:** Low（要スコープ確認）

**問題:** `verifySalonboardLogin` / `verifySalonboardShopLogin` は `createSalonboardClient()`（runId/close 無し）を使う。API Lambda には `SALONBOARD_TRANSPORT`/`DECODO_*`/chromium 依存が投入されない（`deploy-api.sh` 側未対応）。本 PR は playwright transport を batch Lambda のみへ意図的にスコープ（既定 http）しており Issue の REQ-5/Open Questions とも整合するため**現状は問題なし**。ただし将来 API Lambda で `transport=playwright` を有効化する場合、`createSalonboardClient()` が Playwright を返すと `client.close()` 未呼び出しでブラウザリーク＋依存未同梱で `Cannot find module` になる。本 Issue で対応するか別 Issue 化するかを作者判断願いたい。

---

## 総評

設計は堅実で、transport 抽象（http/playwright 切替・既定 http で安全側）・型付きエラー・fail-safe・直列化（inflight=1）・PII/シークレットの扱い（proxy password はログ/レスポンス/`external_import_runs.error` のいずれにも補間されず、`.env.example` は空値、`requireSalonboardProxy` の fail-safe）はよく考えられている。**マージのブロッカーは無い**。

取り込み前に対処を推奨する順:
1. **High — `detectCaptcha` の誤検知**（userid 取得済みなら captcha 判定をスキップ + 実ログイン後 HTML の回帰テスト）。ログイン全失敗を誘発しうる唯一の High で、修正は数行と低コスト。
2. **Medium 4件 — 可観測性（proxy 未設定の誤分類・中間経路の CAPTCHA 未検知）／ペーシング網羅／デプロイの zip サイズ／データ取得経路の未テスト**。いずれも実運用（特に playwright 有効化後・初回 batch デプロイ）で顕在化しやすい。
3. **Low — リスナー解除・env 検証・固定待機・bundled フォールバック・auth 経路のスコープ確認**。任意だが zip サイズと併せて Low の env 検証は早めが安全。

lessons チェック（PII / テスト方針 / 外部 API 依存 / env 置き場所 / fixture 個人情報）への違反は無し。むしろ playwright lesson の「最終ページで成功判定すると false-negative → doLogin 応答を捕捉」パターンを T-1b 込みで踏襲している。
