# 申請フロー（サロンのオンボーディング）

サロンが本サービスを利用開始するまでのフロー。

## 全体フロー

```
[LP申請フォーム] → [運営審査] → [Stripe Connect登録] → [オンボーディング] → [利用開始]
   GTSS審査中    Stripe登録待ち   オンボーディング待ち       利用中
```

## ステータス遷移

`cancel-billing-service-api/src/lambda.ts` の `APPLICATION_STATUS`:

| ステータス | 状態 | 次にやること |
|---|---|---|
| `GTSS審査中` | LP申請完了直後 | 運営者が管理画面で審査 |
| `Stripe登録待ち` | 運営者が承認 | サロンに Stripe Connect リンクをメール送信 |
| `オンボーディング待ち` | Stripe アカウント作成済み | サロンがオンボーディング（本人確認・銀行口座登録）を完了 |
| `利用中` | `details_submitted = true` | キャンセル請求の登録が可能 |
| `却下済み` | 運営者が却下 | 終了 |

## ステップ詳細

### 1. LP 申請

- 入口: `https://cancel.co.jp/`（`cancel-billing-service-lp`）
- フォーム: サロン名・代表者・連絡先・住所・口座希望情報 等
- 保存先: DynamoDB `cancel-billing-applications-{env}`
- 初期ステータス: `GTSS審査中`

### 2. 運営審査

- 入口: `https://admin.cancel.co.jp/`（`cancel-billing-service-admin`）
- 運営者が申請内容を確認 → 承認 / 却下
- 承認時: ステータスを `Stripe登録待ち` に更新し、サロンに Stripe Connect 用メール送信
  - メール送信: SES (ap-northeast-1)
  - 初期パスワード（ユーザーポータルログイン用）も同時発行

### 3. Stripe Connect オンボーディング

- サロンがメール内リンクを開く → Stripe Connect Onboarding 画面へ
- 完了後: `stripe-success` ページ (`cancel-billing-service-lp/src/components/StripeSuccess.jsx`) が `applicationId` を受け取り、`details_submitted` をAPI で確認
  - `true` → ユーザーポータルへ誘導（ステータス `利用中`）
  - `false` → 未完了画面（再オンボーディングリンク `/stripe-refresh`）
- リンク失効時: `cancel-billing-service-lp/src/components/StripeRefresh.jsx` から再発行

### 4. ユーザーポータル ログイン

- 入口: `https://user.cancel.co.jp/`（`cancel-billing-service`）
- 初回ログイン: 申請メールアドレス + 初期パスワード（運営メール記載）
- ログイン後: JWT を localStorage に保存（有効期限 24 時間）
- 初期パスワード変更を推奨（`ChangePasswordPage.tsx`）

## 関連コード

| ファイル | 役割 |
|---|---|
| `cancel-billing-service-lp/src/App.jsx` | LP 申請フォーム |
| `cancel-billing-service-lp/src/components/StripeSuccess.jsx` | Stripe登録完了判定 |
| `cancel-billing-service-lp/src/components/StripeRefresh.jsx` | Stripe リンク再発行 |
| `cancel-billing-service-admin/src/components/ApplicationList.tsx` | 申請一覧（管理画面） |
| `cancel-billing-service-admin/src/components/ApplicationDetail.tsx` | 申請詳細・承認/却下 |
| `cancel-billing-service-api/src/lambda.ts` | API ハンドラ（申請作成・ステータス更新・メール送信） |
