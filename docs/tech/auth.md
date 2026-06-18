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

## JWT クレーム構造

### サロンポータル（`POST /auth/login`）

```json
{
  "sub": "<application_user.id (UUID)>",
  "application_id": "<applications.application_id>",
  "email": "<application_user.email>",
  "role": "user",
  "iat": 1700000000
}
```

- `sub` = ログインしている **application_user の UUID**（誰が操作したかの監査識別子）
- `application_id` = 紐づく **applications.application_id**（リソース所有者の判定キー）
- `email` = ログイン時のメールアドレス
- 1 サロン（applications）に対して N 個の application_users（ログインユーザー）を持てる構造

### 管理画面（`POST /auth/admin-login`）

```json
{
  "sub": "<users.id (UUID)>",
  "email": "<users.email>",
  "role": "admin",
  "iat": 1700000000
}
```

- `sub` = `users.id`（UUID 採番）。`email` 変更時に sub が壊れない設計
- 表示用には UUID ではなく `email` クレームを参照する

## 認可ロジック（サーバー側）

- サロンが自分のリソースかを判定する箇所: `item.applicationId === decoded.application_id`
- cancellation 作成時:
  - `applicationId: decoded.application_id`（リソース所有者）
  - `createdByApplicationUserId: decoded.sub`（作成者の application_user.id）
- `middleware/auth.ts` の `requireAuth` は `applicationsRepo.getById(decoded.application_id)` で
  サロンの存在と ACTIVE ステータスを検証する

## データモデルの分離（REQ-1 / GTSS-17）

| テーブル | 役割 |
|---|---|
| `applications` | 申請・審査・Stripe・住所・通知抑止。**認証関連カラムは持たない** |
| `application_users` | サロン側ログインユーザー。PK は UUID。email は UNIQUE。1 applications ↔ N application_users（has_many） |
| `users` | 運営管理者。PK は UUID。email は別カラム + UNIQUE |

- パスワード / mustChangePassword / reset_token / reset_token_expiry / userActivatedAt はすべて
  `application_users` に保持される
- `application_users.application_id` → `applications.application_id` に FK（ON DELETE CASCADE）

## ログインフロー（サロンポータル）

1. サロンが Stripe Connect オンボーディング完了
2. システムが Stripe webhook (`account.updated`) で:
   - `applications.status` を `利用中` に更新
   - `application_users` を 1 件新規作成（UUID 採番 + 初期パスワード + `mustChangePassword=true`）
   - 認証情報メール（初期パスワード）と管理者通知メールを送信
3. サロンが `https://user.cancel.co.jp/` でログイン（メール + 初期パスワード）
   - 画面: `cancel-billing-service/src/components/LoginPage.tsx`
4. API が `application_users.email` で検索し、`application_users.password` を検証 → JWT 発行
5. クライアントが `localStorage.setItem('auth_token', ...)` で保存
6. 以降の API リクエストには JWT が自動付与される

## パスワード操作

| 操作 | 画面 | 永続化先 |
|---|---|---|
| 初期パスワード変更 | `ChangePasswordPage.tsx` | `application_users.password` |
| パスワード忘れ | `ForgotPasswordPage.tsx` | `application_users.reset_token` |
| リセット（メールリンク経由） | `ResetPasswordPage.tsx` | `application_users.password` + token NULL クリア |

リセットフローは API が SES でリセット用 URL 付メールを送信する。

## 管理画面のログイン

`https://admin.cancel.co.jp/`（`cancel-billing-service-admin/src/components/LoginPage.tsx`）

- dev 環境の初期管理者:
  - ID: `a.hayashida@shairesalon-go.today`
  - PW: `TempPassword123!`

## 冪等性（Stripe webhook 二重配信対策）

`processStripeAccountUpdated` は以下の 3 層で冪等性を担保する:

1. **applications.updateStatusIfIn**: status が `Stripe登録待ち` / `オンボーディング待ち` の行のみ
   `利用中` に遷移する条件付き更新（影響行数 0 → 既に ACTIVE）
2. **applicationUsersRepo.findFirstByApplicationId**: 既に application_user が存在すれば作成スキップ
   かつ副作用（認証情報メール / 管理者通知）も実行しない（パスワード使い回し防止）
3. **(application_id, email) UNIQUE**: 並行 webhook で重複 INSERT が来た場合は UNIQUE 違反を
   recheck して握りつぶす

## ロール

現状ロールは「サロン」（`role=user`）「運営者」（`role=admin`）の 2 種類で、ログインエンドポイント自体が
分かれている（管理画面 API ⇄ サロンポータル API）。RBAC は実装されていない。

## 関連コード

| ファイル | 役割 |
|---|---|
| `cancel-billing-service-api/src/handlers/auth.handler.ts` | `/auth/login`, `/auth/admin-login`, `/auth/forgot-password`, `/auth/reset-password` 等のルート |
| `cancel-billing-service-api/src/services/auth.service.ts` | application_users / users 認証ロジック |
| `cancel-billing-service-api/src/services/application.service.ts` | `processStripeAccountUpdated` の application_user 作成 / 冪等性 |
| `cancel-billing-service-api/src/middleware/auth.ts` | `requireAuth`（application_id 検証）, `requireAdmin`, `verifyToken` |
| `cancel-billing-service-api/src/repositories/application-users.repository.ts` | application_users CRUD |
| `cancel-billing-service-api/src/db/schema.ts` | 新 schema（applications / application_users / users / cancellations / monthly_sales） |
| `cancel-billing-service/src/contexts/AuthContext.tsx` | サロン側 JWT 管理。`user.applicationId` / `user.id`（application_user.id）を保持 |
| `cancel-billing-service-admin/src/services/ApiService.ts` | 管理画面側 JWT 管理 |
