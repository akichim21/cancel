# 認証

## 認証方式

JWT（JSON Web Token）。`jsonwebtoken` ライブラリで発行・検証。

## トークン仕様

- 有効期限: **24 時間**
- 保存場所（クライアント）: `localStorage`
- 付与: API リクエストの `Authorization: Bearer <token>` ヘッダ
- 自動付与の実装:
  - サロンポータル: `cancel-billing-service/src/services/api.ts`
  - 管理画面: `cancel-billing-service-admin/src/services/ApiService.ts`

## ログインフロー（サロンポータル）

1. サロンが申請承認後、運営者経由で初期パスワードがメール送信される
2. `https://user.cancel.co.jp/` でログイン（メール + パスワード）
   - 画面: `cancel-billing-service/src/components/LoginPage.tsx`
3. API がパスワード検証 → JWT 発行
4. クライアントが `localStorage.setItem('token', ...)` で保存
5. 以降の API リクエストには JWT が自動付与される

## パスワード操作

| 操作 | 画面 |
|---|---|
| 初期パスワード変更 | `ChangePasswordPage.tsx` |
| パスワード忘れ | `ForgotPasswordPage.tsx` |
| リセット（メールリンク経由） | `ResetPasswordPage.tsx` |

リセットフローは API が SES でリセット用 URL 付メールを送信する。

## 管理画面のログイン

`https://admin.cancel.co.jp/`（`cancel-billing-service-admin/src/components/LoginPage.tsx`）

- dev 環境の初期管理者:
  - ID: `a.hayashida@shairesalon-go.today`
  - PW: `TempPassword123!`

## ロール

現状ロールは「サロン」「運営者」の 2 種類で、ログインエンドポイント自体が分かれている（管理画面 API ⇄ サロンポータル API）。RBAC は実装されていない。

## 関連コード

| ファイル | 役割 |
|---|---|
| `cancel-billing-service-api/src/lambda.ts` | `/login`, `/admin/login`, `/forgot-password`, `/reset-password` 等のハンドラ |
| `cancel-billing-service/src/contexts/AuthContext.tsx` | サロン側 JWT 管理 |
| `cancel-billing-service-admin/src/services/ApiService.ts` | 管理画面側 JWT 管理 |
