---
issue: GTSS-854
date: 2026-07-11
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    prs:
      - { pr: 28, baseBranch: GTSS-842, toBranch: GTSS-854 }
      - { pr: 29, baseBranch: GTSS-854, toBranch: GTSS-854-34 }
      - { pr: 30, baseBranch: GTSS-854-34, toBranch: GTSS-854-payout-safeguards }
---

# レビュー結果: GTSS-854（連結アカウント入金 manual + 月次バッチ）— stacked PR #28/#29/#30

Codex（gpt-5.6-sol, xhigh）＋メタレビュー（各指摘を実コードで裏取り）で3つの stacked PR をレビュー。

## PR 構成（stacked）

| PR | 内容 | base | head | +/- | files |
|---|---|---|---|---|---|
| #28 | manual + 月次バッチ（しきい値ゲート）化 | `GTSS-842` | `GTSS-854` | +1444/-9 | 23 |
| #29 | 90日期限を GTSS 側で強制スイープ | `GTSS-854` | `GTSS-854-34` | +807/-33 | 11 |
| #30 | 90日担保の堅牢化（例外/打切りスイープ・stale回復・webhook購読） | `GTSS-854-34` | `GTSS-854-payout-safeguards` | +901/-36 | 13 |

各 PR の判定（メタレビュー最終、Codex は3つとも NG → 裏取りで格下げ）:
- **PR #28: 条件付きOK** — 基盤コードは高品質・テスト厚い。ただし #28 単体では 90日担保・processing回復が未実装（→ #29/#30 で解消）
- **PR #29: 条件付きOK** — 通常系は正しい。90日担保の edge（暦月ロック・lookback窓・打切り）と cutover/cron 依存
- **PR #30: 条件付きOK** — コア安全機構は健全、指摘は全て堅牢化ギャップ（財務二重入金なし）

**総合: コードとしてはスタック全体をマージ可（条件付きOK）。ただし本番で月次バッチを稼働させる前に運用前提3件が必須。ハードな code-correctness / 二重入金ブロッカーは3レビューとも未検出。**

---

## マージ前に潰したい指摘（コード・低コスト）

### [Codex/#30] webhook 購読スクリプトが対象 endpoint を host で絞らない — Low〜Medium(Security)
**ファイル:** `cancel-billing-service-api/scripts/ensure-stripe-webhook.ts:74-81`（`isTargetEndpoint`）
`URL(ep.url).pathname.endsWith('/webhook/stripe')` だけで判定し host 未検証。同一 Stripe アカウント内の古い/検証用 endpoint も対象化し `checkout.session.completed` 等の購読を想定外先へ拡張し得る。加えて Stripe SDK は `connect` フラグを露出せず、非 Connect endpoint に `payout.*` を付けて「OK」と誤判定し得る（謳う購読保証が不完全）。
→ 環境ごとに **対象 endpoint ID を固定**（または host allowlist）し、複数候補・想定外 host は fail closed。Connect 有効性は API 検証不能なため前提を明文化 or リリースチェックで Dashboard 確認。

### [自己発見/#30] staleAlert が「若い正常残高」に誤発火 — Medium(improve)
**ファイル:** `cancel-billing-service-api/src/services/payout.service.ts:356-366`
基点が「直近入金からの経過(idleDays)」で、実際の90日リスク基準（最古未払い決済の available 化からの経過）と異なる。若い未払い決済で available を説明できる正常口座でも「90日規制超過の恐れ・要手動確認」と誤通知し、force(75) で掃けるまで日次継続 → アラート疲れ。
→ `oldestUnpaidChargeAt` が古い場合に限定、またはメッセージを「滞留可能性・要確認」に緩める。

### [自己発見/#29] PR本文・テストコメントの定数 stale — Low
**ファイル:** `cancel-billing-service-api/src/constants/payout.ts:35` / `src/__tests__/unit/oldest-unpaid-charge.test.js`
PR #29 本文は `PAYOUT_LOOKBACK_BUFFER_DAYS=14` と記載だが実コードは `90`（commit `adeaf5a` で 14→90）。test コメント「// バッファは 14 日超」も実アサート `>=90` と矛盾。→ PR本文・コメントを実値 90 に更新（レビュアー混乱防止）。

---

## 本番バッチ稼働の前提（デプロイ運用ブロッカー — コードでは塞げない）

### 1. 既存 active 連結アカウントの manual 移行 cutover が無い — High
**ファイル:** `cancel-billing-service-api/src/services/application.service.ts:368` / `:942`（新規 `accounts.create` の2経路のみ manual 付与）。`:728` の `accounts.update` は `business_profile` のみで payout schedule に触れない。
既存サロンは従来の自動入金のままで、月次バッチ実行時に残高が残っておらず**しきい値ゲートが機能しない**＝PR 目的が既存サロンに適用されない。3 PR いずれにも cutover は含まれない。
→ 対象口座へ `accounts.update({settings:{payouts:{schedule:{interval:'manual'}}}})` を一度流す cutover ＋ `lastPayoutAt` seeding（#29 の初回 cutover 前提）を用意し、完了までバッチを無効化するデプロイ順を運用手順化。

### 2. 外部 Terraform の日次 cron 切替への依存 — High
`FORCE_PAYOUT_AGE_DAYS=75` は**日次実行前提**（定数コメント自身が「月次維持なら~50へ下げる必要」と明記）。cron（外部 `cancel-billing-service-infra`）が月末のままだと 90日を追い越す。
→ EventBridge 日次 cron を本チェーンと同時/先行で適用、未適用なら閾値を月次前提値へ下げる。

### 3. 暦月 period ロックで最大 ~2日 90日超過 — High（作者が受容済み）
**ファイル:** `cancel-billing-service-api/src/services/payout.service.ts`（冪等スキップ, 実 249-257 付近）
同一 `(account, YYYY-MM)` が pending/paid だと残高取得せずスキップ。月初にスイープ済み口座で月内に別決済が75日到達→翌月頭まで再スイープ不可（最悪~92日）。作者が受容リスクとして明記し period 日次粒度化を別 Issue へ委譲済み。→ 追認 or 別 Issue 化。

---

## 3レビューが「問題なし」と確認した主要項目
- 承認2経路に漏れなく manual 付与。連結アカウント作成は `application.service` の2経路のみ。
- `available`/`pending` の JPY フィルタ＋合算（`sumJpy`）正。¥3,000 境界（`<3000` で held）妥当・テスト担保。
- `(stripe_account_id, period)` ユニーク、migration 0018→0019 の FK CASCADE→RESTRICT、`_journal.json`（idx18/19）整合。
- CSV の BOM・base64 折返し・CSV injection 対策（`csvCell`）妥当。
- webhook 署名検証（`constructEvent`）、skip は `NODE_ENV==='dev' && SKIP_WEBHOOK_SIGNATURE==='true'` 二重ガード。
- backfill は `status='processing'` 限定 finalize で pending/paid を上書きしない（`(account,period)` 一意）。
- claim の `setWhere`（held/failed or 古い processing）＋ ON CONFLICT 行ロックで新鮮 processing の二重確保防止＝**同一資金の二重 payout は構造上発生し得ない**（#30 Finding 3 の裏取り結論）。
- 秘密鍵の新規ログ出力なし。ensure スクリプトは `sk_` プレフィックス検証で `pk_` 拒否。

## 未検証（外部仕様依存）
- [未検証] Stripe が manual スケジュールの連結アカウント（JP）残高を90日で自動強制出金するか。コードから判定不能。→ 本 PR チェーンは Stripe 任せにせず GTSS 側 sweep を実装しているので実害は緩和。

## テスト
- PR本文は Vitest green（#28: 835 passed 主張）＋ dev 実機で webhook 経路（pending→paid）E2E 実証。
- ただしメタレビューはDB依存のためローカル独立実行せず静的追随確認。**マージ前に CI/ローカルで Vitest green を最終確認推奨。**

## 総評
通常系ロジック（threshold ゲート／age判定／rejected・withdrawn への強制スイープ／`deletedAt` 排他列挙／claim→create→finalize 冪等）は正しく、e2e/unit のカバレッジも良好。残る指摘は 90日担保の edge（暦月ロック・長期reserve・打切り）と cutover/cron のデプロイ順で、多くは後続 PR で解消済み or 作者が明示受容。**即マージブロッカーというより「デプロイ前提条件付き」。スタック全体をまとめてマージし、本番バッチ有効化は上記運用3件の充足後**が推奨。
