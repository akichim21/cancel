# cancel-billing-service-admin（運営者向け管理画面）

GTSS 運営者がサロン申請の審査やキャンセル請求の管理を行う画面。URL: https://admin.cancel.co.jp/

## 技術スタック

- React 19 + TypeScript + Vite
- Tailwind CSS
- React Router v7
- 状態管理: Zustand / React Query (TanStack)
- フォーム: React Hook Form + Zod
- 認証: JWT（24 時間）

## 画面一覧

| 画面 | コンポーネント | 用途 |
|---|---|---|
| ログイン | `LoginPage.tsx` | 管理者ログイン |
| ダッシュボード | `Dashboard.tsx` | 概況・統計 |
| 申請一覧 | `ApplicationList.tsx` | 申請を絞り込み・並び替え。「詳細」は `/applications/:id` の詳細ページへ遷移 |
| 申請詳細（ページ） | `ApplicationDetailLayout.tsx` / `ApplicationDetail.tsx` | `/applications/:id`。常時表示ヘッダー（承認/却下・削除・Stripe メール送信・**連携単位選択**）＋会社スコープのサブナビ＋`<Outlet>` |
| 店舗 | `StoreList.tsx` / `StoreForm.tsx` | 会社詳細の店舗一覧・作成・更新・削除。店舗単位はサロンボード連携（ログインのみ・単一店舗自動取得）を伴う。会社単位は読み取り専用 |
| キャンセル請求管理 | `CancellationManagement.tsx` | キャンセル請求の登録・進捗管理。`applicationId` props で会社スコープ表示＋その会社のみの取り込み実行 |
| 取り込みログ | `ImportLogList.tsx` | 取り込みログ。`applicationId` でフィルター |
| 取り込み実行履歴 | `ImportRunList.tsx` | 実行記録（会社単位）。`applicationId` でフィルター |
| サロンボード連携（会社単位） | `SalonboardIntegration.tsx` | 会社単位のログイン検証→ヘアサロン一覧確認→保存 |
| Stripe 再オンボーディング | `StripeReauth.tsx` | サロン代理での再リンク発行 |
| Stripe 完了 | `StripeSuccess.tsx` | サロン Stripe 登録結果確認 |
| 管理者ユーザー一覧 | `AdminUserList.tsx` | `/admin-users`。運営管理者の一覧（無効化済みも表示）・追加・編集 |
| 管理者ユーザー作成/編集 | `AdminUserForm.tsx` | モーダル。氏名・メールのみ（**パスワード欄は無い**）＋パスワードメール送信 |
| パスワード設定/再設定 | `SetPasswordPage.tsx` | `/set-password` と `/reset-password`（**公開ルート**）。文言だけ切り替えて共有 |
| パスワードを忘れた | `ForgotPasswordPage.tsx` | `/forgot-password`（**公開ルート**）。応答は実在有無によらず同一 |
| パスワード変更 | `ChangePasswordPage.tsx` | `/change-password`。ログイン必須。成功後も画面に留まる |
| 共通ヘッダ | `Header.tsx` | 全体一覧のグローバルメニュー 6 項目（**会社詳細でも出し分けない**）＋右上アバターのドロップダウン（パスワード変更 / ログアウト）＋モバイルはハンバーガー |
| トースト通知 | `Toast.tsx` | 操作結果表示 |

ルーティング: `src/App.tsx`（`/applications/:id` 配下に `shops`/`cancellations`/`import-logs`/`import-runs` のネストルート。
キャンセル請求管理・取り込みログ・取り込み実行履歴はグローバルと会社詳細で**同一コンポーネントを再利用**し、差分は
`applicationId` フィルターの有無のみ）。

**公開ルート**（`/login` / `/forgot-password` / `/set-password` / `/reset-password`）では、起動時のトークン検証・
申込一覧の取得・ヘッダー表示のいずれも行わない（GTSS-72 / #72）。これが無いと、**期限切れトークンが残っている
管理者はパスワード設定リンクを開いた瞬間ログイン画面へ飛ばされ、パスワードを設定できない**。
保護ルートの起動時検証は `GET /auth/admin-me`。401 のみログアウトし、404 / 500 / ネットワークエラーでは
保持している管理者情報で表示を継続する（API → 管理画面 のデプロイ順序が入れ替わっても致命傷にしない）。

## API 通信

`src/services/ApiService.ts` に集約。JWT を `Authorization: Bearer` ヘッダで付与。
ベース URL は **`VITE_API_URL`**（サロンポータルが `VITE_API_BASE_URL`。取り違えに注意）。

`localStorage` には `authToken` と **`adminUser`**（ヘッダー表示用）の 2 つを保持し、
**ログアウト時と 401 応答時の両方で同時に破棄する**（`clearStoredSession`）。片方だけだと
前の利用者の氏名・メールアドレスが端末に残る。
ただし `POST /auth/admin-change-password` の 401 は「現在のパスワードの打ち間違い」であり
セッション切れではないため、**共通の 401 リダイレクトを経由させない**（打ち間違えただけで
ログアウトされないようにする）。公開ルートから出るリクエストも同様に経由させない。

## ローカル起動

```bash
npm install
npm run dev    # http://localhost:5173 で起動
```

`.env.local`:
```bash
VITE_API_URL=http://localhost:3000
```

## ビルド & デプロイ

```bash
npm run build:dev
npm run build:prod
./deploy-admin.sh dev    # ※ deploy.sh ではなく deploy-admin.sh
./deploy-admin.sh prod
```

## 管理者アカウントの追加

**管理画面から追加する**（GTSS-72 / #72）。ヘッダーの「管理者ユーザー」→「管理者を追加」で
氏名・メールアドレスを入力すると、本人宛にパスワード設定メールが届く。
**パスワードは画面の入力欄では設定させない**（平文が第三者を経由しないため）。
ライフサイクル（招待 → 設定 → 運用 → 無効化 → 再有効化）と入力ルールは
`docs/product/admin-users.md` を参照。

緊急復旧（全管理者が締め出された等、画面から復旧できない場合）のみ CLI を使う:
```bash
cd ../cancel-billing-service-api
NODE_ENV=prod AWS_PROFILE=cancel-billing-service-prod npx tsx scripts/upsert-admin-user.ts
```

> `cancel-billing-service-api/create-admin-user.js` は**旧 DynamoDB へ書く死んだスクリプト**。
> 使わないこと（削除は別 Issue）。

## 初期管理者アカウント（dev 環境）

- ID: `a.hayashida@shairesalon-go.today`
- PW: `TempPassword123!`

## テスト

整備済み。**Vitest**（コンポーネント unit。`src/components/__tests__`・`npm run test` = `tsc -p tsconfig.vitest.json` + `vitest run`）と
**Playwright**（e2e。`e2e/`・`npm run test:e2e`。API は `e2e/fixtures.ts` の `mockApi` でルートモックし実 API 不要）。
画面仕様は原則 Playwright で統合テスト、出し分け・props 伝播・バリデーションは Vitest で補完する。

## 注意事項

- デプロイスクリプト名が他のリポジトリ (`deploy.sh`) と異なり `deploy-admin.sh`
- API URL 環境変数名は `VITE_API_URL`（LP と同じ。**サロンポータルだけが `VITE_API_BASE_URL`**）

## 関連ドキュメント

- `docs/product/application-flow.md` — 申請審査フロー
- `docs/product/cancellation-flow.md` — キャンセル請求の登録
- `docs/product/salonboard-import.md` — サロンボード取り込み（連携単位・店舗CRUD・会社スコープIA）
- `docs/tech/salonboard-import.md` — サロンボード取り込みの技術仕様
- `docs/product/admin-users.md` — 運営管理者アカウントのライフサイクル・画面仕様
- `docs/tech/auth.md` — 管理者認証（`requireAdmin` の DB 検証・パスワード導線・トークンのダイジェスト保存）
