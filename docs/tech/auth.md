# 認証

## 認証方式

JWT（JSON Web Token）。`jsonwebtoken` ライブラリで発行・検証。

## トークン仕様

- 有効期限: **24 時間**
- 保存場所（クライアント）: `localStorage`（サロンポータルのキーは `auth_token` / `user`）
- 付与: API リクエストの `Authorization: Bearer <token>` ヘッダ
- 自動付与の実装:
  - サロンポータル: `cancel-billing-service/src/services/api.ts`
  - 管理画面: `cancel-billing-service-admin/src/services/ApiService.ts`
- **パスワード変更成功時に JWT を再発行する（GTSS-852 / #43）**。`POST /auth/change-password` は
  `data: { token, user }` を返し、有効期限は変更時点から取り直す。ペイロード構成はログイン時と同一
  （`sub` / `application_id` / `email` / `role='user'`）。発行関数は `auth.service.ts` の `signSalonToken`
  で `login` と共有する（`adminLogin` は `application_id` を持たず `role` が可変のため共有しない）。
- **トークン発行前にログインと同一の状態検証を行う**（同 Issue）。`application_users.status === 'active'`、
  紐づく `applications` が実在し `deletedAt` が NULL かつ ACTIVE であることを確認し、満たさない場合は
  パスワードを変更せず **403「このアカウントはまだ有効化されていません」**（login と同一文言）を返す。
  この検証が無いと、凍結・論理削除・非 ACTIVE のサロンでも有効期限内の古いトークンとパスワードだけで
  24 時間トークンを更新し続けられる「トークン発行口」になる。検証は **現在のパスワード照合の後・DB 更新の前**
  に置き、既存の失敗ステータス・文言（401 / 404 等）を変えない。
  なお `POST /auth/change-password` に共通の `requireAuth` は付与しない（sub 不在時の応答が現行 404 から
  401 に変わり既存契約を壊すため。同等の検証を service 内で行う）。
- **`application_id` クレームと DB の所属が一致しない**トークンは 401 で拒否する（多層防御）。
  `requireAuth` はクレーム欠落・所属不一致をどちらも 401 にするが、`change-password` は `sub` だけで
  引くため素通りしていた。受け付けるトークンの集合を両者で揃える。

### 状態検証は 1 箇所に集約する

`login` / `change-password` / `reset-password` / `forgot-password` の 4 経路が同じ条件を見る。条件は
`auth.service.ts` の **`findActiveApplication(appUser)`** に集約し、403 応答は `inactiveAccountResponse`
を共有する（`forgot-password` だけは列挙攻撃対策のため 403 ではなく成功と同じ 200 を返す）。

手コピーで二重実装すると、片方（例えば login）にだけ条件が増えたときに `change-password` が
「ログイン条件を迂回するトークン発行口」へ逆戻りする。**条件を増やすときは必ずこの関数を直すこと。**

### パスワード変更による旧トークンの失効（`password_changed_at`）

署名と `exp` しか見ない検証では、パスワードを変更しても**変更前に発行されたトークンが最大 24 時間
生き残る**。本サービスは仮パスワードをメールで配布する運用のため、仮パスワードが第三者に渡って先に
ログインされていた場合、正規のサロンがパスワードを変えても第三者を締め出せないという実害があった。

- `application_users.password_changed_at`（ISO8601 / nullable）に最終変更時刻を記録する。
  書き込むのは `change-password` と `reset-password` の 2 経路（`updated_at` と同一時刻を使う）。
- 判定は `middleware/auth.ts` の **`isTokenStaleForUser(decoded, appUser)`**。`decoded.iat` が
  `password_changed_at` より前なら失効扱いにする。適用箇所は `requireAuth`（全保護 API）と
  `changePassword` 自身（トークン発行口を旧トークンで再利用させない）。
- `iat` は秒精度のため `password_changed_at` も秒へ切り捨て、`<` で比較する（**同一秒は有効**）。
  変更直後に発行する新トークンを自分で失効させないための境界。
- `password_changed_at` が NULL（既存行 / 一度も変更していない）なら失効させない。
  マイグレーション適用だけで既存セッションを一斉ログアウトさせないため。
- 失効時の応答は 401 で、メッセージは「アカウントが無効」ではなく
  **「パスワードが変更されています。再度ログインしてください」**（再ログインで復帰できることを区別する）。

## ログインフロー（サロンポータル）

1. サロンが申請承認後、運営者経由で初期パスワードがメール送信される
2. `https://user.cancel.co.jp/` でログイン（メール + パスワード）
   - 画面: `cancel-billing-service/src/components/LoginPage.tsx`
3. API がパスワード検証 → JWT 発行
4. クライアントが `localStorage.setItem('auth_token', ...)` / `localStorage.setItem('user', ...)` で保存
5. 以降の API リクエストには JWT が自動付与される

## パスワード操作

| 操作 | 画面 | 成功後の遷移先 |
|---|---|---|
| 初期パスワード変更（`mustChangePassword=true`） | `ChangePasswordPage.tsx` | **ダッシュボード（`/`）**。再ログインさせない（GTSS-852） |
| 通常のパスワード変更（ログイン後の自発的変更） | `ChangePasswordPage.tsx` | **遷移せず変更画面に留まる**（入力欄はクリア） |
| パスワード忘れ | `ForgotPasswordPage.tsx` | 送信完了表示 |
| リセット（メールリンク経由） | `ResetPasswordPage.tsx` | 完了表示 → ログイン |

リセットフローは API が SES でリセット用 URL 付メールを送信する。

**リセット経路にもログインと同一の状態検証を適用する**（GTSS-852 / #43）。`forgot-password` は
非 ACTIVE・論理削除済み・凍結ユーザーにはトークンを保存せずメールも送らない（応答は列挙攻撃対策で
常に成功）。`reset-password` は同条件で **403「このアカウントはまだ有効化されていません」** を返し、
パスワードもリセットトークンも変更しない。これが無いと「凍結ユーザーは change-password では 403 なのに
リセットメール経由なら変更できる」という片側だけ開いた状態になる。

### パスワード変更成功後の状態更新（GTSS-852 / #43）

変更成功時、ポータルはログアウトせず `AuthContext.replaceSession(token, user)` で **メモリ上の state と
localStorage（`auth_token` / `user`）を同時に差し替える**。API が返さない項目（適格請求書登録番号など）は
保存済みユーザーへ上書きマージして失わない。これにより `mustChangePassword` が解除され、`ProtectedRoute` の
強制遷移ガード（UX 上の誘導であり、セキュリティ境界ではない）を再ログインなしで抜けられる。

いずれの画面でも完了は共通の**完了バナー**（`SuccessBanner.tsx` / `FlashContext.tsx`）で伝える。
表示要求はメモリ上のみに保持し、リロード・ログアウトで破棄する。自動消灯（8 秒）のタイマーは
バナー側ではなく `FlashContext` が持つ（保護ルートは画面ごとに別インスタンスのため、バナー側に持たせると
画面遷移で張り直されて 8 秒が延長される）。

**デプロイ順序は API → ポータル**。逆順（ポータル先行）に備え、レスポンスに `data.token` / `data.user` が
無い場合はポータルが従来どおりログアウトして `/login` へ遷移し「パスワードを変更しました。新しいパスワードで
ログインしてください。」を表示する（`LoginPage` が `location.state.message` を表示する）。

**応答待ち中のログアウト**: 変更 API の応答を待つ間にヘッダーからログアウトされても `await` の継続処理は
キャンセルされない。そのまま `replaceSession` するとログイン状態が復活してしまうため、
`ChangePasswordPage` は**送信時の `auth_token` を控え、応答到着時に一致する場合だけ差し替える**。
別タブで別アカウントへ切り替わった場合も同様に破棄する。

**失敗時の文言**: `apiService.changePassword` は `makeRequest` の `passthroughError: 'client'` を使い、
**400 番台に限りサーバーの日本語 `error` を透過**する（既定では非 2xx を `HTTP 401: Unauthorized` へ潰す）。
500 番台・ネットワークエラーはサーバー内部の情報を画面に出さないため汎用文言に統一する。
`error` が文字列でない場合も透過しない（React の子として描画されるため）。

**ログ衛生**: `makeRequest` はレスポンス本文を `console` へ出さない（login のレスポンスには JWT が含まれ、
Sentry のブラウザ SDK は console breadcrumb を既定で有効にするため、エラー送信時に外部へ渡り得る）。
併せて `src/instrument.ts` の `beforeBreadcrumb` で `category === 'console'` の breadcrumb を落とす。
非 2xx / 例外時は endpoint と HTTP status だけを記録する（本番での切り分けに要る最小限）。

**既知の課題（本 Issue のスコープ外）**:
- 別タブ・別デバイスの `mustChangePassword` は stale になりうる（`AuthContext` は `storage` イベントを
  購読していない）。リロードまたは再ログインで解消する。トークンはリクエストごとに localStorage から
  読むため、別タブでも新トークンへ自動追随し API 呼び出しは壊れない。
- 管理者（`users` テーブル）側には `password_changed_at` 相当が無い。`requireAdmin` は DB を引かない
  設計のため、失効判定を入れるとリクエストごとの DB アクセスが増える。管理者アカウント数が増えた
  段階で再評価する。

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
