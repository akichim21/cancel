---
issue: 64
date: 2026-08-13
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: GTSS-817-qa
    toBranch: GTSS-817-slack
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: GTSS-817-qa
    toBranch: GTSS-817-slack
---

# レビュー結果: #64

## 概要

**Issue:** #64 サロンボード取り込み失敗の Slack 通知を運営向け書式へ刷新（実行経路×連携単位×エラー種別で 13 パターン出し分け）

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `GTSS-817-qa` | `GTSS-817-slack` | 2 | 23 |
| admin | `GTSS-817-qa` | `GTSS-817-slack` | 1 | 5 |

**レビュー実施時の検証結果（レビュアー側で再実行）**

| 検証 | 結果 |
|---|---|
| api `npm run typecheck` | OK |
| api `npm test` | **107 files / 1495 passed** |
| admin `npm test` | **17 files / 269 passed** |
| 変更のあった api テスト単体（unit 5 file / e2e 4 file） | 101 + 36 passed |
| admin `ImportRunList.test.tsx` | 9 passed |

Issue の [Completion] コメントに記載された数値と一致。`date-dependent-salonboard-tests` で既知の日付依存 e2e 4 件も本日時点では green。

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/services/salonboard-import-notify.ts` | +531 | -0 | **Added** |
| `src/__tests__/unit/salonboard-import-notify.test.js` | +985 | -0 | **Added** |
| `src/__tests__/unit/batch-import-failure-notify.test.js` | +155 | -0 | **Added** |
| `src/__tests__/e2e/salonboard-import-invoke-failure.test.js` | +118 | -0 | **Added** |
| `src/__tests__/unit/deploy-slack-notify-env.test.ts` | +86 | -0 | **Added** |
| `src/services/salonboard-import.service.ts` | +55 | -175 | Modified |
| `src/__tests__/e2e/salonboard-import-observability.test.js` | +149 | -219 | Modified |
| `src/__tests__/unit/slack-notifier.test.js` | +108 | -1 | Modified |
| `src/constants/cancellation-status.ts` | +91 | -0 | Modified |
| `src/observability/slack.ts` | +59 | -9 | Modified |
| `src/services/cancellation.service.ts` | +55 | -15 | Modified |
| `src/batch.ts` | +29 | -7 | Modified |
| `deploy-api.sh` | +18 | -0 | Modified |
| `deploy-batch.sh` | +17 | -0 | Modified |
| `src/__tests__/unit/url-overrides.test.js` | +16 | -3 | Modified |
| `deploy-batch-ecs.sh` | +10 | -9 | Modified |
| `.env.example` | +10 | -8 | Modified |
| `src/__tests__/e2e/salonboard-import-salon.test.js` | +9 | -0 | Modified |
| `src/config.ts` | +7 | -3 | Modified |
| `src/db/schema.ts` | +6 | -1 | Modified |
| `src/batch-cli.ts` | +5 | -1 | Modified |
| `src/__tests__/e2e/salonboard-import-concurrency.test.js` | +2 | -1 | Modified |
| `src/__tests__/e2e/salonboard-store.test.js` | +2 | -1 | Modified |

### admin

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `e2e/import-runs.spec.ts` | +56 | -0 | Modified |
| `src/components/__tests__/ImportRunList.test.tsx` | +33 | -0 | Modified |
| `e2e/fixtures.ts` | +24 | -6 | Modified |
| `src/components/ImportRunList.tsx` | +13 | -3 | Modified |
| `src/types/Cancellation.ts` | +4 | -1 | Modified |

## 指摘一覧

---

- [x] 対応する

### [Code Quality] 会社ランが店舗ループ**途中**で例外終了すると、未処理店舗が「成功」に数えられ、かつ「一時的エラー／再実行してください」に誤分類される

**ファイル:** `api/src/services/salonboard-import-notify.ts:228-233`
**重要度:** Medium

**該当コード:**

```typescript
// baseBranch側（変更前）— 旧通知は生カウンタをそのまま並べていた（成功数の導出をしていない）
    lines.push(
      `  連携単位: ${unitLabel(run.unit)} / 対象店舗: ${run.totalShops} / ` +
        `作成: ${run.created} / 対象外: ${run.skipped} / 失敗: ${run.failed}`,
    );
    lines.push(`  失敗理由: ${formatReasonBreakdown(run.byReason, notifiable)}`);
    const diag = formatDiagnosticsLine(run.diagnostics);
    if (diag) lines.push(`  診断: ${diag}`);
```

```typescript
// toBranch側（変更後）— salonboard-import-notify.ts:224-233
  const failedShops = run.shops.filter((s) => s.failed > 0 && !silent.has(s.shopId));
  const silentShops = run.silentShopIds?.length ?? 0;
  // 結果行は店舗単位で数える。連携設定未完了の店舗は失敗にも成功にも数えない。
  const successShops = Math.max(0, run.totalShops - failedShops.length - silentShops);
  const companyRunFailed = !run.ok && failedShops.length === 0;   // ← 失敗店舗が 1 件でもあると false

  // 会社ランが例外で落ちたときは理由コードも失敗件数も無く写像が空振りするため「その他」として扱う。
  const kinds = Object.keys(failureCounts).map((r) => classifyImportErrorKind(r));
  if (otherCount > 0 || companyRunFailed) kinds.push(IMPORT_ERROR_KIND.OTHER);
```

```typescript
// 呼び出し側 — salonboard-import.service.ts:1349-1358
    const run = emptyCompanyRun(appId);
    run.totalShops = shops.length;          // ← 例外の有無に関わらず「全店舗数」
    try {
      await importCompany(run, shops, { now, window, trigger });
    } catch (e: any) {
      run.ok = false;
      run.error = `会社の取り込みに失敗しました: ${e?.message || e}`;
      if (!run.companyName) run.companyName = appId;
      captureImportExceptionToSentry(e, { applicationId: appId, trigger, scope: 'company_run' });
    }
```

**問題:**
会社単位連携の店舗ループ（`salonboard-import.service.ts:1188-1226`）には**店舗ごとの try/catch が無い**。`importShop` 内の DB 書き込み（`logSkip` / 請求の upsert）や `pace()` が例外を投げると、ループを抜けて `importCompany` ごと throw し、残りの店舗は 1 件も処理されない。

このとき `run.totalShops` は全店舗数のまま、`run.shops` には例外時点までに処理できた店舗しか入っていないため、`successShops = totalShops − failedShops − silentShops` は**未処理の店舗を成功に数える**。

**さらに深刻なのは種別の誤りのほう。** `companyRunFailed` が `failedShops.length === 0` の条件付きなので、「1 店舗目が失敗 → 2 店舗目で例外」というケースでは `kinds` に `OTHER` が積まれず、代表種別が**認証エラー / 一時的エラーへ倒れる**。結果、クラッシュしたランに対して:

- 見出し: `🚨 サロンボード取り込み 一部失敗`（「要調査」ではない）
- 対応の目安: `一時的なエラーの可能性が高いため、手動で再実行して再発するか確認`
- エンジニアメンション: **付かない**（メンションは種別 `other` のみ）

が出る。加えて `CompanyFailureInput.error`（= `run.error` にクラッシュ内容が入る）は**インターフェースに宣言されているだけで本文組み立てのどこからも読まれていない**（`grep '\.error\b'` のヒットは `console.error` 3 箇所のみ）。つまり**ランがクラッシュした事実が通知のどこにも出ず、運営は「再実行してみて」と案内される**。

dev/prod の Aurora はオートポーズ構成（[[dev-aurora-autopause-batch]]）で、長時間ラン中の接続断は実際に起こりうる経路。到達経路も確認済み: 店舗ループ（`salonboard-import.service.ts:1119-1143` / `:1183-1229`）は `try/finally` で catch が無く、`importShop` 内の DB 書き込み（`:603` / `:767` / `:772`）は未保護。

なお REQ-5 の成功店舗の定義（「対象店舗のうち失敗店舗でも黙らせた店舗でもないもの」）自体がこの穴を持っているため、件数の側は実装が仕様に忠実。**仕様側の見直しも要る指摘**。

既存テスト（T-29 / AC-5.6）は**店舗ループに入る前**の例外しか検証していない。

**修正提案:**

1. 種別（優先・小さい修正）: `:233` を `if (otherCount > 0 || !run.ok)` にして、`ok=false` なら必ず `OTHER` を種別候補へ足す。これだけで見出し「要調査」・対応の目安「エンジニア調査が必要です」・メンションが正しく出る。
2. 件数: `CompanyRunSummary` に「処理を完了した店舗数（または shopId 集合）」を持たせ、`successShops` を `処理済み − 失敗 − 黙らせた` で算出する。結果行に `・未実行：{N}店舗` を足して中断を明示するとなお良い。
3. テストは「1 店舗成功後に次店舗で例外」「1 店舗失敗後に次店舗で例外」の 2 ケースを追加する。

---

- [x] 対応する

### [Security] 通知本文へ埋め込む会社名・店舗名の改行・制御文字・長さが無制限で、固定書式の行を偽装できる

**ファイル:** `api/src/services/salonboard-import-notify.ts:87-94`
**重要度:** Medium

**該当コード:**

```typescript
// baseBranch側（変更前）— 同じ実装。ただし本文は「• 会社名（app_id）」の箇条書きで、
// 運営が直接アクションを判断する固定書式ではなかった
const escapeSlackText = (s: string): string =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const slackSafeText = (s: string | null | undefined): string =>
  escapeSlackText(String(redactPiiText(String(s ?? ''))));
```

```typescript
// toBranch側（変更後）— salonboard-import-notify.ts:87-94（実装は同一だが用途が変わった）
const escapeSlackText = (s: string): string =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

export const slackSafeText = (s: string | null | undefined): string =>
  escapeSlackText(String(redactPiiText(String(s ?? ''))));

// 埋め込み先（salonboard-import-notify.ts:359-366）
  lines.push(`■ 会社：${slackSafeText(facts.companyName || '(会社名なし)')}`);
  const unit = unitLabel(facts.unit);
  if (unit) lines.push(`■ 連携単位：${unit}`);
  lines.push(`■ 結果：${resultText(facts)}`);
  lines.push(`■ エラー内容：${errorDetailText(facts.kind, facts.failureCounts)}`);
```

**問題:**
`escapeSlackText` が処理するのは `& < >` のみで、**CR/LF・タブ・制御文字・入力長を一切制限していない**。

`businessName` は**未認証の公開 LP 申請フォーム由来**で、`src/schemas/application.schema.ts` の `applicationInputSchema` は `businessName` に対して zod の型・長さ・形式チェックを**一切持たない**（`APPLICATION_INPUT_FIELDS` の allow-list を通るだけで `.passthrough()` される）。`shopName` もサロン本人が自由に編集できる（`createMyShop` は `trim()` と非空チェックのみ）。

したがって屋号に `テスト\n■ 対応の目安：対応不要（誤検知）` を仕込むと、運営が読む固定書式へ**偽の行を挿入**できる。本 Issue の通知は「運営がメッセージ 1 通だけで次のアクションを判断する」ことが目的なので、行の偽装がそのまま誤対応につながる。加えて極端に長い名前で Slack の本文上限（40,000 字）を超えさせ、**その会社の通知だけを無音化**することもできる。

関数自体は base から変更されていないが、本 PR で本文が行構造の固定書式になり運営の判断根拠になったことで、リスクの性質が変わっている。既存テストは `<!channel>` とリンク偽装しか検証していない。

**修正提案:**
`slackSafeText` で CR/LF・タブ・制御文字を空白へ正規化し、会社名・店舗名ごとに長さ上限（例 100 字）を設けて省略記号で畳む。本文全体にも上限を設ける。入力側のバリデーション追加だけでは既存データとサロンボード由来の店舗名を防げないため、通知境界での正規化が必須。改行による偽行挿入と長大文字列のテストを追加する。

---

- [x] 対応する

### [Code Quality] ⑬ の再送出に AWS 側の自動リトライが乗り、同じ失敗で ⑬ が最大 3 通（日次では最大 186 通）投稿される

**ファイル:** `api/src/batch.ts:68-82`
**重要度:** Medium

**該当コード:**

```typescript
// baseBranch側（変更前）— catch なし。例外はそのまま Sentry ラッパへ抜けるだけで、Slack へは何も出ない
      const result = await runSalonboardImport({
        now: new Date(),
        trigger: event?.trigger || 'scheduled',
        applicationId: event?.applicationId,
        runId: event?.runId,
      });
```

```typescript
// toBranch側（変更後）— batch.ts:68-82
      } catch (err) {
        // アクション実行そのものが例外で終了したケース（GTSS-817-slack / REQ-7 の ⑬）。
        // 通知後は**再送出**して既存の契約（Sentry の捕捉・非同期 invoke の失敗・CLI の終了コード 1）を保つ。
        await notifyImportBatchFailure({
          trigger,
          startedAt: new Date(),
          companyName: await resolveCompanyNameForBatchFailure(event?.applicationId),
        });
        throw err;                      // ← AWS 側がこの失敗を見てリトライする
      }
```

**問題:**
`throw err` 自体は REQ-7 の c（「通知 → **再送出**」）どおりで正しい。問題は、その再送出が **AWS の自動リトライを起動し、リトライのたびに ⑬ が投稿される**こと。

- **手動取り込み経路**: `cancellation.service.ts` の `invokeBatchImportAsync` は `InvocationType: 'Event'`（非同期）。infra リポジトリ（`~/infra/cancel-billing-service-infra`）を全 `.tf` で grep しても `aws_lambda_function_event_invoke_config` / `maximum_retry_attempts` は**1 件も存在しない**ため、Lambda 既定の 2 回リトライが効く。⑬ は最大 3 通、取り込み本体も 3 回走る。
- **日次スケジュール経路**: `modules/batch-compute/main.tf:202-219` の `aws_scheduler_schedule.salonboard_import` はターゲットが `aws_lambda_function.batch.arn`（Lambda）で、`retry_policy` ブロックが無い。EventBridge Scheduler 既定は `maximum_retry_attempts = 185`。
- **ECS(CLI) 経路**は終了コード 1 を返すだけなので影響なし。

リトライ自体は base でも同じ（catch が無くても throw は抜けていた）だが、**⑬ の投稿がリトライ回数だけ増幅されるのは本 PR で新しく生じた挙動**。REQ-1 が「1 実行あたり最大 11 通」と投稿数を厳密に設計し、`observability/slack.ts` に 1 秒間隔と 429 再送まで入れているのに、⑬ だけがその外側で多重化される。

なお [[prod-ecs-batch-not-live]] のとおり prod の取り込みは現状 Lambda 経路なので、手動取り込み側は**いま実際に該当する**。日次スケジュールは現在 DISABLED のため、有効化前に手当てできれば十分。

**修正提案:**
infra 側で Event 呼び出しに `aws_lambda_function_event_invoke_config { maximum_retry_attempts = 0 }` を、Scheduler ターゲットに `retry_policy { maximum_retry_attempts = 0 }` を明示する。本 PR の範囲外なら Issue の「リリース手順で人手が必要な項目」へ追加する。アプリ側だけで閉じるなら、⑬ を投稿済みかどうかのフラグ（runId 単位）を持たせて再投稿を抑止する手もある。

---

- [x] 対応する

### [Code Quality] ラベル辞書の「未知値はそのまま表示」フォールバックが、プロトタイプ継承プロパティで破れる

**ファイル:** `admin/src/components/ImportRunList.tsx:28` / `api/src/constants/cancellation-status.ts:231`
**重要度:** Low

**該当コード:**

```typescript
// baseBranch側（変更前）— 厳密等価の三項演算子。プロトタイプ参照が起きない
/** 実行契機の日本語ラベル。 */
const triggerLabel = (t: string): string =>
  t === 'manual' ? '手動' : t === 'scheduled' ? '自動（日次）' : t
```

```typescript
// toBranch側（変更後）— ImportRunList.tsx:22-28
const TRIGGER_LABELS: Record<string, string> = {
  scheduled: '自動（日次）',
  manual_admin: '手動（運営）',
  manual_salon: '手動（サロン）',
  manual: '手動',
}
const triggerLabel = (t: string): string => TRIGGER_LABELS[t] ?? t
```

```typescript
// 同型の新規実装 — api/src/constants/cancellation-status.ts:229-232
export const importTriggerRouteLabel = (trigger: unknown): string => {
  const t = String(trigger ?? '');
  return IMPORT_TRIGGER_ROUTE_LABELS[t] ?? t;
};
```

**問題:**
オブジェクトリテラルへの添字アクセスは継承プロパティも拾うため、`??` が発火しない。実測:

```
L['__proto__']    -> object   ("[object Object]")
L['constructor']  -> function
L['toString']     -> function
L['brand_new']    -> 'brand_new'（正常なフォールバック）
```

admin 側では React が object/function を子として描画できず例外または空表示になり、AC-9.2「未知の値は値のまま表示して画面を壊さない」を満たさない。api 側は `[object Object]` が通知本文へ出る。

`trigger_type` はサーバーが `IMPORT_TRIGGER` の値か batch payload の `event.trigger` から書くカラムで、**外部の攻撃者が直接注入できる経路は無い**（batch Lambda の invoke には AWS 権限が要る）ため実害は限定的。ただし置き換え前の三項演算子には無かった穴で、AC-9.2 の文言にも反する。

**修正提案:**
`Object.hasOwn(TRIGGER_LABELS, t) ? TRIGGER_LABELS[t] : t`、または `Map` + `get(t) ?? t` にする。api 側の `importTriggerRouteLabel` / `classifyImportErrorKind` / `IMPORT_ERROR_DETAIL_TEXTS` も同じ形なので揃えると良い。T-43 に `__proto__` / `constructor` ケースを追加する。

---

- [x] 対応する

### [Test Coverage] Playwright fixture が実 API の `applicationId` 検証と 202 応答を再現していない

**ファイル:** `admin/e2e/fixtures.ts:483-499`
**重要度:** Low

**該当コード:**

```typescript
// toBranch側（変更後）— e2e/fixtures.ts:485-499
    if (options.importAdds && options.importAdds.length > 0) {
      cancellations.push(...options.importAdds);
    }
    // 実 API と同じく、取り込みを開始すると実行履歴へ 1 行増える（新しい順で返すため先頭へ入れる）。
    if (options.importRunAdds && options.importRunAdds.length > 0) {
      importRuns.unshift(...options.importRunAdds);
    }
    const result = options.importResult ?? {
      success: true,
      ...
    };
    return route.fulfill({ json: result });
```

```typescript
// 実 API — api/src/services/cancellation.service.ts:165-179
    if (isAsyncImportEnv()) {
      try {
        await invokeBatchImportAsync(applicationId, runId, trigger);
      } catch (invokeErr) { ... }
      return {
        statusCode: 202,                       // ← fixture は既定の 200
        headers: corsHeaders,
        body: JSON.stringify({ success: true, started: true }),
      };
    }
```

**問題:**
fixture は POST body の `applicationId` を検証せずに `importRunAdds` を積み、`started: true` でも `route.fulfill()` の既定で **HTTP 200** を返す。実 API は `applicationId` 必須（無ければ 400）で、非同期経路は **202** を返す。

そのため新規の T-42 は「UI が `applicationId` を落とす / 誤送信する」回帰を検出できない。なお `ApiService.importCancellations` は `response.ok`（200-299）でしか分岐しないため、200 と 202 で UI 挙動は変わらず**製品バグではない**。テストの忠実性の問題。

**修正提案:**
`route.request().postDataJSON()` の `applicationId` を検証し、不正なら行を追加せず 400 を返す。追加行も要求された会社に連動させ、`started: true` のときは `status: 202` で fulfill する。

**あわせて（同カテゴリ・Low）:** `admin/e2e/import-runs.spec.ts:136-139` の `rows.nth(0).getByText('手動（運営）')` は行スコープ止まりで、実行契機カラム（`ImportRunList.tsx:126` の `td`）に出ていることを保証しない。`.claude/skills/playwright/lesson.md:194-208`（全文 contains 禁止 → セル単位検証）に従い `rows.nth(0).getByRole('cell', { name: '手動（運営）' })` にする。既存 `:38` と同じ書き方なので新規混入ではない。

---

- [x] 対応する

### [Test Coverage] 投稿間隔のアサーションが弱く、かつ実時計依存でフレーキー。`awaitPostSlot` 自体にも競合の余地がある

**ファイル:** `api/src/observability/slack.ts:47-51` / `api/src/__tests__/unit/slack-notifier.test.js:194-199`
**重要度:** Low

**該当コード:**

```typescript
// toBranch側（変更後）— observability/slack.ts:46-51（新規追加）
// 前回の投稿開始から MIN_POST_INTERVAL_MS 経つまで待ってから次の投稿を開始する。
const awaitPostSlot = async (): Promise<void> => {
  const wait = lastPostStartedAt + MIN_POST_INTERVAL_MS - Date.now();
  if (wait > 0) await sleepImpl(wait);
  lastPostStartedAt = Date.now();     // ← await の「後」に更新
};
```

```javascript
// toBranch側（変更後）— slack-notifier.test.js:194-199
    expect(fetchImpl).toHaveBeenCalledTimes(3);
    expect(sleepSpy).toHaveBeenCalledTimes(2);
    for (const [ms] of sleepSpy.mock.calls) {
      expect(ms).toBeGreaterThan(0);
      expect(ms).toBeLessThanOrEqual(1000);
    }
  });
```

**問題:**
2 点ある。

1. **アサーションが弱い。** 待機量を `> 0` かつ `<= 1000` でしか見ていないため、間隔が **1ms でもこのテストは緑**になる。REQ-1 が要求するのは「1 秒以上空ける」ことなので、この 1 本だけが仕様を実質検証していない。`.claude/skills/vitest/lesson.md:37`（型だけ・範囲だけのチェックは使わず具体値で検証）に反する。同ファイルの 429 系テストは `toHaveBeenCalledWith(3000)` / `(1000)` / `(30_000)` と具体値で固定できているので、この 1 本だけ強度が落ちている。
2. **実時計依存でフレーキー。** `sleepImpl` はテストで no-op に差し替わるため `lastPostStartedAt` は実経過時間でしか進まない。CI で 2 通目と 3 通目の間に実時間で 1000ms 以上かかると `wait <= 0` になり `sleepImpl` が呼ばれず、`toHaveBeenCalledTimes(2)` が red になる。

加えて実装側にも小さな穴がある: `lastPostStartedAt` の更新が `await` の**後**なので、並行呼び出しでは両者が同じ `wait` を計算して同時に発射する。現状の呼び出し元は `notifyCompanyImportFailures` の直列ループ 1 箇所だけなので**実害は無い**が、将来別経路（例: リマインド通知）を足すと静かに壊れる。

**修正提案:**
`nowImpl` の注入シームを足すか `vi.useFakeTimers()` を使い、`expect(sleepSpy).toHaveBeenNthCalledWith(1, 1000)` と具体値で固定する。実装側は await 前にスロットを予約する形へ変える:

```typescript
const slot = Math.max(Date.now(), lastPostStartedAt + MIN_POST_INTERVAL_MS);
lastPostStartedAt = slot;
const wait = slot - Date.now();
if (wait > 0) await sleepImpl(wait);
```

---

- [x] 対応する

### [Test Coverage] AC-7.6 の T-48 / T-49 が「ハンドラ経由で invoke が throw」を検証していない

**ファイル:** `api/src/__tests__/e2e/salonboard-import-invoke-failure.test.js:52,74`
**重要度:** Low

**該当コード:**

```javascript
// toBranch側（変更後）— テストは後始末関数を直接呼んでいる
    const runId = await claimImportRun({ applicationId: 'app_1', trigger: 'manual_admin' });
    expect(runId).toBeTruthy();

    await handleBatchInvokeFailure(runId, 'app_1', 'manual_admin', INVOKE_ERROR);
```

```typescript
// 未検証の配線 — cancellation.service.ts:166-173（運営）/ :223-228（サロン本人）
      try {
        await invokeBatchImportAsync(applicationId, runId, trigger);
      } catch (invokeErr) {
        await handleBatchInvokeFailure(runId, applicationId, trigger, invokeErr);
        throw invokeErr;
      }
```

**問題:**
Issue の AC-7.6 / T-48・T-49 は「`POST /cancellations/import` で invoke が throw」「`POST /salonboard/import` で invoke が throw」と**ハンドラ経由**で規定しているが、実際のテストは `handleBatchInvokeFailure` を直接呼んでいる。そのため両ハンドラの catch 配線（特に**運営／サロン本人の `trigger` の取り違え**）が自動テストで守られていない。

テストファイル冒頭のコメントが理由を説明しているとおり（`isAsyncImportEnv()` が `NODE_ENV` で切り替わり、同じ変数が DB ドライバも切り替えるため `app.request()` 経由では通せない）、制約自体は正当。問題は **AC の記述と実体がずれたまま「完了」になっている**こと。

**修正提案:**
`invokeBatchImportAsync` を注入可能なシームにして両ハンドラ経由で 1 本通す。通せないなら AC-7.6 の T-48 / T-49 の記述を実態（純関数の直呼び）に合わせて Issue 側を修正し、ハンドラ配線は人力テスト項目へ移す。

---

- [x] 対応する

### [Test Coverage] Issue のテスト一覧で T-7 の参照先ファイルが実在しない

**ファイル:** Issue #64 本文 L487 / L634
**重要度:** Low

**該当箇所:**

```markdown
- [x] T-7 Vitest E2E: ログイン引き直しが成功する経路 → 投稿されない ✅ src/__tests__/e2e/salonboard-import-retry.test.js
```

```javascript
// 実体 — src/__tests__/e2e/salonboard-import-observability.test.js:563
  it('T-16 / AC-1.7・T-7 引き直しが成功したら取り込みが継続し、失敗計上も通知もされない', async () => {
```

**問題:**
Issue は T-7 の担保先を `salonboard-import-retry.test.js` と記載しているが、**このファイルは存在しない**。テスト自体は `salonboard-import-observability.test.js:563` に（[PreReview] で `AC-1.7・T-7` のラベルを併記した形で）存在するため、テストの抜けではなく**参照先の誤り**。`.claude/lessons.md`「issue-start 完了前にテスト一覧を全チェックする」（各 T-N を grep で照合）に該当する。

T-1〜T-64 のうち、記載ファイルに実在しないのはこの 1 件のみ（他は grep で実在確認済み）。

**修正提案:**
Issue 本文 L487 / L634 の参照先を `src/__tests__/e2e/salonboard-import-observability.test.js` へ修正する。

---

- [x] 対応する

### [Code Quality] REQ-3「会社ランのエラー文言」と REQ-2「固定文言のみ」の仕様衝突を、実装が REQ-2 側へ倒している（要確認）

**ファイル:** `api/src/services/salonboard-import-notify.ts:167-183`
**重要度:** Low

**該当コード:**

```typescript
// toBranch側（変更後）— errorDetailText。kind='other' は常に固定文言を返す
export const errorDetailText = (
  kind: ImportErrorKind,
  failureCounts: Record<string, number>,
): string => {
  if (kind === IMPORT_ERROR_KIND.OTHER) return IMPORT_ERROR_DETAIL_OTHER;
  ...
};

// IMPORT_ERROR_DETAIL_OTHER = '想定外のエラーが発生しました（画面構造の変化などの可能性）'
```

```javascript
// 対応するテスト — e2e/salonboard-import-observability.test.js（T-29）
    expect(text).toContain('■ 結果：取り込みを開始できませんでした');
    expect(text).toContain('■ 対応の目安：エンジニア調査が必要です');
    // 生の例外メッセージは本文へ載せない（PII をエコーしうるため。REQ-2）。
    expect(text).not.toContain('db down');
```

**問題:**
Issue 本文に内部矛盾がある。

- REQ-3（issue 本文 161 行目）: 「会社ランが例外で落ちた場合…見出しは『失敗（要調査）』、**エラー内容は会社ランのエラー文言**、対応の目安は『エンジニア調査が必要です』とする」
- REQ-2: 「`■ エラー内容：` に出すのは REQ-3 の写像で理由コードから生成した**固定文言のみ**とする」

実装は REQ-2（PII の厳格側）を採用し、`run.error` を本文から落としている。判断としては妥当（`redactPiiText` はメールと電話しか落とせない）だが、[Decision] コメントには**この衝突の記載が無く**、`req-completeness-checker` の [PreReview] も「文言は 1 文字単位で仕様一致」と報告している。

結果として、会社ランが DB エラーで落ちた通知は「想定外のエラーが発生しました（画面構造の変化などの可能性）」となり、実際の原因（画面構造とは無関係な DB 障害）とずれた文言が運営に出る。

**修正提案:**
実装を変える必要は無いが、（a）Issue の REQ-3 の該当文を「会社ラン例外時も固定文言」に修正して衝突を解消し、（b）会社ラン例外の専用文言（例: 「取り込み処理でエラーが発生しました」）を用意して「画面構造の変化」という誤誘導を避けることを検討したい。

---

## 総評

**仕様適合度は非常に高い。** REQ-1〜REQ-10 を Issue 本文と 1 行ずつ突き合わせたが、書式・文言・分岐（代表種別の優先順、スキップ系理由の混入除外、「その他」件数の差分算出、投稿上限 10 + 集約 1、旧値 `manual` の後方互換、`■ 対応：` と `■ 対応の目安：` の使い分け、全角スペース字下げ）はいずれも仕様どおり。設計面でも良い判断が多い。

- **本文組み立てを純関数へ切り出した**構造が正しい。13 パターン + 集約 + ⑬ を実 Slack へ投げずに 985 行の unit で網羅できており、テストが実装定数を import せず独立リテラルで期待値を書いている点も良い。
- **⑬ の投入を `dispatchBatchAction` の 1 箇所へ集約**した判断（Lambda / ECS の両経路が同じ分岐を通るため二重投稿にならない）は妥当。`batch-cli.ts` の `Sentry.flush(...).catch(() => {})` も「失敗は必ず終了コード 1」の契約を守るために必要な修正。
- **`importCompany` のシグネチャ変更**（集計オブジェクトを呼び出し側で生成）は、会社ラン例外時に会社名・連携単位を保全するための構造として理にかなっており、T-29 が店舗単位連携で「会社単位と誤表示しない」ことまで検証している。
- **環境判定の `NODE_ENV` 統一**は正しく効いている。`isProdEnv()` は `NODE_ENV === 'prod'` で、`deploy-api.sh` / `deploy-batch.sh` / `deploy-batch-ecs.sh` の 3 経路とも `NODE_ENV: DEPLOY_ENV` を投入しているため、prod で `[dev]` プレフィックスやメンション抑止が誤発火する事故は無い。`ADMIN_URL` を env 素通しにせず環境名から導出した点も、過去の `API_BASE_URL` の教訓を踏襲していて良い。
- **`trigger_type` のマイグレーション不要**は裏取り済み。`0005_gtss817_external_import_runs.sql` は `"trigger_type" text NOT NULL` で CHECK 制約・enum 型なし。
- **削除物の残骸ゼロ**も確認（`buildImportFailureSlackText` / `formatDiagnosticsLine` / `formatReasonBreakdown` / `BATCH_LOG_GROUP` / `notifyImportFailure` の参照は 1 件も残っていない）。
- **user portal への波及なし**を確認（`triggerType` / `triggerLabel` の参照が無い）。

**レート制御（`observability/slack.ts`）** も良い出来。投稿開始間隔をモジュールグローバルの `lastPostStartedAt` で管理し、`sleepImpl` をテスト注入シームにして実時間を消費せず 429 再送・Retry-After 上限 30s・非 429 は再送しない、を全部固定している。`awaitPostSlot()` が `test_env` / `not_configured` の早期 return より後にあるため、テストとローカルで無駄に待たない点も配慮されている。

**指摘は 9 件、うち Medium 3 件 / Low 6 件。** Medium 3 件はいずれも「通知が運営を誤誘導する / 通知設計の前提を壊す」系で、本 Issue の目的（1 通で次のアクションを決められる）に直接効くため対応を推奨する。

- **最優先は 1 件目の種別誤り**。`:233` を `if (otherCount > 0 || !run.ok)` に変えるだけで、クラッシュしたランが「一時的エラー・再実行してください」ではなく「要調査・エンジニア調査が必要です（＋メンション）」になる。1 行の修正で運営の誤対応を防げる割に効果が大きい。
- **2 件目（改行注入）と 3 件目（⑬ の多重投稿）** は、それぞれ「運営が読む固定書式を偽装できる」「投稿数上限 11 通の設計が ⑬ だけ素通しになる」という、本 PR が組み立てた仕組みそのものを崩す種類の穴。3 件目は infra 側の対応になるためリリース手順へ組み込む形でもよい。

残り 6 件は Low で、リリースブロッカーではない。うち 3 件（`awaitPostSlot` の弱いアサーション、AC-7.6 のテスト経路、T-7 の参照先）はテスト・ドキュメントの精度の問題で、[PreReview] が「T-1〜T-64 欠落 0・文言 1 文字単位で仕様一致」と報告している水準から見ると取りこぼしになっている。

**リリース前の残作業**（Issue の [Completion] 記載どおり、コードレビュー範囲外）: prod の Slack Bot Token の SSM 投入、通知先チャンネル `C0BP5RM3709` への bot 招待（未招待だと `not_in_channel` で**無音**になるため要注意）、apply 後の API Lambda / batch Lambda / batch ECS の再デプロイ、人力テスト M-1〜M-7。
