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

## トークン方式の比較（パスワード再設定 / メール認証）

「ランダム hex トークン＋有効期限＋DB保存＋トークン検証」を共有する 2 系統がある。保存先テーブルと
エンドポイント・戻り先 URL が異なる。

| 用途 | トークン保存先 | 発行 | 有効期限 | 検証エンドポイント | 戻り先 URL |
|---|---|---|---|---|---|
| パスワード再設定 | `application_users.reset_token` / `reset_token_expiry` | `crypto.randomBytes(32).hex` | 発行+24h | `POST /auth/reset-password` | `{ユーザーポータル}/reset-password?token=` |
| メール認証（GTSS-842 / #31） | `applications.verification_token` / `verification_token_expiry` | `crypto.randomBytes(32).hex` | 発行+24h | `POST /applications/verify-email` | `{LP}/verify-email?token=` |

### メール認証トークン（GTSS-842 / #31）

LP 申込時に `applications.verification_token`（hex）＋ `verification_token_expiry`（発行+24h の ISO8601）を発行し、
申込者宛の認証メールに `{LPベースURL}/verify-email?token=...` を埋め込む。`POST /applications/verify-email`（無認可）が
`{ token }` を受け取り、結果種別を返す（HTTP 200 + `result` フィールド）:

- `invalid`: トークン不一致（**空トークンは早期に弾き `verification_token IS NULL` 行へ誤ヒットさせない**）
- `already_verified`: 申請が `unverified` 以外（すでに認証済み・以降のステータス）
- `expired`: `unverified` かつ有効期限切れ（状態を変更しない）
- `verified`: `unverified` かつ有効期限内 → `pending` へ更新し、**有効期限を NULL 化（無効化）しつつトークン値は保持**
  （認証済みリンク再オープンを `already_verified` 判定するため）。あわせて運営管理者へ新規申請通知メールを送信。

トークン保存先が `application_users.reset_token` ではなく `applications` 側なのは、メール認証が申請の状態遷移
（`unverified → pending`）を司るため。実装は `cancel-billing-service-api/src/services/application.service.ts`
（`createApplication` / `verifyEmail`）、`src/repositories/applications.repository.ts`（`findByVerificationToken`）。
申請フロー全体は `docs/product/application-flow.md`。

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
| `cancel-billing-service-api/src/handlers/auth.handler.ts` | `/auth/login`, `/auth/admin-login`, `/auth/me`, `/auth/change-password`, `/auth/forgot-password`, `/auth/reset-password` のルート登録 |
| `cancel-billing-service-api/src/services/auth.service.ts` | 認証ロジック（ログイン・パスワード再設定トークン発行/検証） |
| `cancel-billing-service-api/src/handlers/applications.handler.ts` | `POST /applications/verify-email`（メール認証。無認可） |
| `cancel-billing-service/src/contexts/AuthContext.tsx` | サロン側 JWT 管理 |
| `cancel-billing-service-admin/src/services/ApiService.ts` | 管理画面側 JWT 管理 |
