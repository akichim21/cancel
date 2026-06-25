# 代理店コード（紹介代理店の記録・精算用CSV）

サロンが**どの代理店（紹介リンク）経由で申し込んだか**をシステムに記録し、月次精算の元データとして
**代理店コード入りのCSV** を **支払い完了日（支払日）で期間指定して** 出力できるようにする機能（GTSS-836 / #30）。

> **スコープ（フェーズ1）**: 「データの記録」と「CSV出力」に限定する。**5%計算・精算・自動送金・代理店台帳
> （代理店名/料率/還元期間/振込先）はスプレッドシートの手運用＝開発対象外**。システムは値の記録と出力に徹する。

## 実現する3機能

1. **代理店コードの自動取得（LP / first-touch）** — 申込ページが URL パラメータ `agent`（例
   `https://cancel.co.jp/?agent=topad` の `topad`）を読み取り、**first-touch**（最初の値を優先・以後上書きしない）
   でブラウザに保持し、申込送信時に申込データへ含める。
2. **admin での表示・手動編集** — 申込一覧に「代理店コード」列を表示し（未取得は「未設定」）、申込詳細で
   手動入力・変更・削除できる。**最終的な正は手動編集**。
3. **精算用CSVの拡張** — 既存キャンセル請求CSVに **代理店コード** と **支払日** の2列を追加し、**支払日で
   期間指定**して出力できるようにする。

## ユースケース

### UC-1: 紹介リンク経由の申込で代理店コードを自動記録する
1. サロン（申込者）が紹介リンク `https://cancel.co.jp/?agent=topad` を開く。
2. LP が `agent=topad` を読み取り、保持値が無いため `topad` を保持する（first-touch）。
3. 同一ブラウザで（時間を空けた再訪・別ページ経由でも）申込フォームを送信する。
4. 送信データに代理店コード `topad` が含まれ、API が申込に紐付けて保存する。
- 別の紹介リンク `?agent=other` を後から踏んでも、保持値 `topad` は**上書きされない**（first-touch）。
- `agent` なし・保持値なしで訪問した場合は代理店コード未設定で申込が作成される（未紐付けを許容）。

### UC-2: 運営が代理店コードを確認・手動補正する
1. 運営管理者が申込一覧の「代理店コード」列で紐付け状況（コード or「未設定」）を確認する。
2. 自動取得できていない申込の詳細を開き、正しいコードを入力して保存する。
3. 既存値の変更・空保存（削除）もでき、**手動値が最終的な正**となる。

### UC-3: 月次精算用CSVを支払日期間で出力する
1. 運営がキャンセル請求管理画面で**支払日の開始日〜終了日**を指定する（例：前月1日〜末日）。
2. 一覧が支払日でその範囲に絞られ、CSVも同じ範囲で出力される。
3. CSVには末尾に **代理店コード** と **支払日** の2列が含まれる（生データのみ。5%計算は含めない）。

## 仕様詳細

### 1. 取得・保持（LP）

- 入口: 申込フォーム（`cancel-billing-service-lp` の単一画面 `/`）。
- マウント時に `?agent=` を読み、**保持済みの値が無い場合のみ** `localStorage`（キー `agentCode`）へ保持する
  （first-touch）。`agent` 無し・空文字・空白のみは保持しない（no-touch）。保持値は trim する。
- 保持手段は `localStorage`（同一オリジン `cancel.co.jp`、再読み込み・長期の時間経過をまたいで保持）。
  ブラウザのプライベートモード/ストレージ削除で消えるのは**仕様上許容**（取りこぼしは admin 手動補正で救済）。
- 申込送信時、保持値が**空でなければ** `agentCode` を payload に含める（空なら未設定として送らない）。
- **代理店コードはサロン・顧客から見える画面に一切表示しない**（UI・体験は現状から変えない。裏側に閉じる）。
- 実装: `cancel-billing-service-lp/src/utils/agentCode.js`（純関数 `captureFirstTouchAgentCode` /
  `getStoredAgentCode`）+ `src/App.jsx`。

### 2. 保存・正規化（API）

- `POST /applications`: 受領した `agentCode` を**正規化して保存**する。任意項目（未指定でも申込作成は成功）。
- 新規 `PUT /applications/:id/agent-code`（**管理者専用 = `requireAdmin`**）: 手動で上書き・削除する。
  未認証/非管理者は 401/403。存在しない id は 404。手動編集は自動取得値より優先する。
- **正規化規則（作成・更新で共通）**: `trim` → 空文字/未指定は**未設定（NULL）** → **上限64文字で切り詰め**。
  形式制約は持たない（大文字小文字の区別あり・許可文字の制限なし）。値の拒否はしない（申込作成を妨げない）。
- データモデル: `applications.agent_code`（text, nullable。migration `0015_gtss836_agent_code.sql`）。
- 自動取得は新規申込作成時のみ働くため、**既存申込を自動取得が後から上書きすることはない**（手動編集のみが
  既存値を変える）。実装: `cancel-billing-service-api/src/utils/agent-code.ts`（`normalizeAgentCode`）/
  `src/services/application.service.ts`（`createApplication` / `updateApplicationAgentCode`）/
  `src/handlers/applications.handler.ts`。

### 3. 表示・編集（admin）

- **申込一覧**（`/applications`）に「代理店コード」列を追加。未設定（空/NULL）は「未設定」と表示する。
  リンクで自動取得できなかった申込を一覧でひと目で見つけ、手動補正の対象を把握できる。
- **申込詳細**（`/applications/:id`）に代理店コードの入力欄＋保存ボタンを追加。現在値を表示し、保存で
  `PUT /applications/:id/agent-code` を呼ぶ。成功時は表示更新＋成功通知、失敗時はエラー通知（画面状態は変更しない）。
  空にして保存すると未設定（削除）になる。自動取得済みの値も手動で上書きできる。
- 代理店コードの編集 UI は**運営管理者のみがアクセスする管理画面内に閉じる**（サロン・顧客には見せない）。
- 実装: `cancel-billing-service-admin/src/components/ApplicationList.tsx` /
  `ApplicationDetailLayout.tsx` / `src/services/ApiService.ts`（`updateApplicationAgentCode` /
  一覧マッピングに `agentCode` を含める）。

### 4. 精算用CSVの拡張（admin）

- 元データ: `GET /cancellations`（**管理者専用 = `requireAdmin`**）の各行に、発生元申込（サロン）の
  `agentCode` を付与する。会社スコープ（`?applicationId=`）・グローバル一覧のどちらでも同一形状で返す。
  実装: `cancel-billing-service-api/src/repositories/cancellations.repository.ts`（`adminListSelect` /
  `toAdminListDomain`）。
- CSV: キャンセル請求管理画面のクライアント側生成CSV（`buildCancellationCsv`）の**末尾に2列を追加**する:
  - **代理店コード**: `GET /cancellations` の `agentCode`（未設定は空）。
  - **支払日**: 既存レスポンスの支払い完了日時 `paidAt`（JST 表示）。**未払い行は空**。
  - 既存16列の列順・PII列（お客様名/電話/メール）は不変。CSVに口座番号は出力しない（元々データに存在しない）。
- **支払日期間フィルタ**: 絞り込みバーに支払日の開始日・終了日の日付ピッカーを追加。指定すると、支払日が
  その範囲（JST 暦日・両端含む）に含まれる請求のみを**一覧表示・CSV出力の対象**にする。範囲外および**支払日が
  無い（未払い）請求は除外**する。期間未指定のときは全件（支払日の有無に関わらず）が対象。
  - 支払日の値は UTC ISO8601。期間判定は JST 暦日へ換算して比較する（端末TZ非依存）。境界は「終了日 23:59 JST
    までを当日扱い、翌 00:00 JST は範囲外」。
  - 実装: `cancel-billing-service-admin/src/constants/cancellationStatus.ts`
    （`CANCELLATION_CSV_HEADERS` / `buildCancellationCsv` / `filterCancellations` の `paidFrom`/`paidTo`）/
    `src/components/CancellationManagement.tsx`（日付ピッカー。`filteredInvoices` がそのまま CSV 出力元のため
    期間指定が一覧と CSV の双方に効く）。

## PII / セキュリティ

- 代理店コードの値は**サロン・顧客から見える画面（LP / ユーザーポータル）には一切出さない**。admin の運営用途に閉じる。
- 精算用CSVおよびその元データ（`GET /cancellations`）は **admin 限定**（未認証/非管理者は取得不可）。
- 代理店へ共有する非PIIデータ（代理店コード等）は、運営がスプレッドシートへ**非PII列のみ手転記**して生成する
  運用とする（システムの既存CSVは admin 運用ツールとして顧客情報列を現状維持。顧客PIIを代理店へ渡さない）。

## スコープ外（フェーズ2以降）

代理店マスタ管理画面、代理店別の自動集計・ダッシュボード、5%の自動計算・精算・自動送金、会計ツール連携、
返金・チャージバック追跡、代理店台帳（料率・還元期間・振込先・登録番号）。判定・集計・精算はスプレッドシート側。

## 関連コード

| ファイル | 役割 |
|---|---|
| `cancel-billing-service-lp/src/utils/agentCode.js` | first-touch 取得・保持の純関数 |
| `cancel-billing-service-lp/src/App.jsx` | URL `agent` 取得・送信 payload 付与 |
| `cancel-billing-service-api/src/utils/agent-code.ts` | 正規化（`normalizeAgentCode`） |
| `cancel-billing-service-api/src/services/application.service.ts` | 作成時保存・`updateApplicationAgentCode` |
| `cancel-billing-service-api/src/handlers/applications.handler.ts` | `PUT /applications/:id/agent-code`（requireAdmin） |
| `cancel-billing-service-api/src/repositories/cancellations.repository.ts` | 一覧レスポンスへ `agentCode` 付与 |
| `cancel-billing-service-api/src/db/schema.ts` / `migrations/0015_gtss836_agent_code.sql` | `applications.agent_code` 列 |
| `cancel-billing-service-admin/src/components/ApplicationList.tsx` | 一覧の代理店コード列 |
| `cancel-billing-service-admin/src/components/ApplicationDetailLayout.tsx` | 詳細の編集UI |
| `cancel-billing-service-admin/src/constants/cancellationStatus.ts` | CSV 2列追加・支払日範囲フィルタ |
| `cancel-billing-service-admin/src/components/CancellationManagement.tsx` | 支払日ピッカー（一覧/CSV連動） |

> 関連: 申込フローは `docs/product/application-flow.md`、精算用CSV・キャンセル請求は `docs/product/cancellation-flow.md`。
