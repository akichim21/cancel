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

管理者側（`users` / `role='admin'`）も同じ構図なので、判定を
**`services/admin-account.service.ts` の `isActiveAdmin(user)` / `findActiveAdmin(id)`** へ集約する
（GTSS-72 / #72）。この条件（`role='admin'` かつ `status='active'`）を見る経路は 6 つある。

| 経路 | 満たさないときの応答 |
|---|---|
| `requireAdmin`（middleware） | 401「このアカウントは無効です」 |
| `adminLogin` | 403（`status` なら「このアカウントはまだ有効化されていません」/ `role` なら「管理者権限がありません」。**現行文言のまま**） |
| `POST /admin/users/:id/password-email` | 404（非 admin・不在）/ 400（inactive） |
| `POST /auth/admin-forgot-password` | 200（列挙対策で成功と同一） |
| `POST /auth/admin-reset-password` | 403「このアカウントは無効です」 |
| `POST /auth/admin-change-password` | 403「このアカウントは無効です」 |

**応答コードは経路ごとに異なってよいが、判定条件そのものを経路側に書かない。**
条件を増やすときはこの関数だけを直す。

### パスワード変更による旧トークンの失効（`password_changed_at`）

署名と `exp` しか見ない検証では、パスワードを変更しても**変更前に発行されたトークンが最大 24 時間
生き残る**。本サービスは仮パスワードをメールで配布する運用のため、仮パスワードが第三者に渡って先に
ログインされていた場合、正規のサロンがパスワードを変えても第三者を締め出せないという実害があった。

- `application_users.password_changed_at`（ISO8601 / nullable）に最終変更時刻を記録する。
  書き込むのは `change-password` と `reset-password` の 2 経路（`updated_at` と同一時刻を使う）。
- 判定は `middleware/auth.ts` の **`isTokenIssuedBefore(decoded, changedAt)`**。`decoded.iat` が
  基準時刻より前なら失効扱いにする。適用箇所は `requireAuth`（全保護 API）と
  `changePassword` 自身（トークン発行口を旧トークンで再利用させない）。
  **サロン側と管理者側で同じ関数を共有する**（GTSS-72 / #72）。基準時刻の列名だけが異なるため
  （サロン = `application_users.password_changed_at` / 管理者 = `users.last_password_change`）、
  列ではなく「基準時刻そのもの」を引数で受け取る。片方にだけ条件が増えて非対称になるのを防ぐ。
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
- ~~管理者（`users` テーブル）側には `password_changed_at` 相当が無い。`requireAdmin` は DB を引かない~~
  **解消済み（GTSS-72 / #72）**。管理者を画面から無効化できるようにするにあたり、`requireAdmin` を
  DB 検証ありへ変更した（後述「管理画面のログイン」）。基準時刻は既存の
  `users.last_password_change` 列を再利用する。補足:
  - **書き込みトリガがサロン側と非対称**。サロン = `change-password` / `reset-password` の 2 経路、
    管理者 = 本人のパスワード変更 / リンクからの設定・再設定 / **無効化** の 3 経路。
  - 列名は `last_password_change` のままだが、実態は「発行済み JWT の失効基準時刻」。
    リネームは別 Issue とする。
  - 無効化 → 再有効化した管理者の旧トークンは
    「パスワードが変更されています。再度ログインしてください」で弾かれる。パスワードは変わっていないが、
    「再ログインで復帰できる」ことを伝える区別としては整合する。

## トークン方式の比較（パスワード再設定 / メール認証）

「ランダム hex トークン＋有効期限＋DB保存＋トークン検証」を共有する 3 系統がある。保存先テーブル・
**保存形式**・エンドポイント・戻り先 URL が異なる。

| 用途 | トークン保存先 | **保存形式** | 発行 | 有効期限 | 検証エンドポイント | 戻り先 URL |
|---|---|---|---|---|---|---|
| パスワード再設定（サロン） | `application_users.reset_token` / `reset_token_expiry` | **平文（残課題）** | `crypto.randomBytes(32).hex` | 発行+24h | `POST /auth/reset-password` | `{ユーザーポータル}/reset-password?token=` |
| メール認証（GTSS-842 / #31） | `applications.verification_token` / `verification_token_expiry` | **平文（残課題）** | `crypto.randomBytes(32).hex` | 発行+24h | `POST /applications/verify-email` | `{LP}/verify-email?token=` |
| パスワード設定/再設定（管理者。GTSS-72 / #72） | `users.reset_token_hash` / `reset_token_expiry` | **SHA-256 ダイジェスト** | `crypto.randomBytes(32).hex`（平文はメールのリンクのみ） | 発行+24h | `POST /auth/admin-reset-password` | `{管理画面}/set-password?token=` または `/reset-password?token=` |

**保存形式の非対称は意図的**。管理者のトークンは管理者権限を取得できる bearer 相当の値で、DB の
読み取り権限が漏れた時点で管理者乗っ取りに直結するため、平文を保存しない（列名 `reset_token_hash` も
それを表す）。「サロン側と対称にする」ことは安全性を下げる理由にならないので非対称を許容する。
**列を足さずに行だけ追加すると、この非対称が表から読み取れず、次に読む人が新経路を平文で実装する。**

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
- **管理者アカウントは管理画面から追加できる**（GTSS-72 / #72。`/admin-users`）。運用手順と画面仕様は
  `docs/product/admin-users.md`。CLI（`scripts/upsert-admin-user.ts`）は緊急復旧手段として残す。

### 管理者のパスワード導線（GTSS-72 / #72）

**パスワードは管理画面の入力欄では設定させない。** 平文が第三者（作成した運営者）を経由しないよう、
メールリンク経由で本人に設定させる。

| 導線 | エンドポイント | 認可 | 画面 |
|---|---|---|---|
| 招待 / 再送（運営が送る） | `POST /admin/users/:id/password-email` | requireAdmin | 管理者編集モーダル |
| パスワードを忘れた（本人が申請） | `POST /auth/admin-forgot-password` | 無認可 | `/forgot-password` |
| リンクからの設定・再設定 | `POST /auth/admin-reset-password` | 無認可 | `/set-password` / `/reset-password` |
| ログイン中の本人による変更 | `POST /auth/admin-change-password` | requireAdmin | `/change-password` |

**`POST /auth/admin-change-password` の 401 は 2 種類ある。** この API は `requireAdmin` を先に通るため、
「現在のパスワードの打ち間違い」だけでなくトークン期限切れ / 不正 JWT / 無効化済み /
`last_password_change` による失効も 401 で返る。前者だけ本文に
`code: 'WRONG_CURRENT_PASSWORD'` を付けて識別できるようにしてある（#72 レビュー指摘 2）。
**画面側は「401 = 打ち間違い」と決め打ちしてはならない。** 決め打ちすると、`requireAdmin` の 401 本文
（`{ error: 'Unauthorized', message: '...' }`）から拾った英語の `Unauthorized` が画面に出るうえ、
セッションが破棄されないまま無効化済みの管理者が画面に留まる。
`code` を持たない 401 は保持情報を破棄してログイン画面へ遷移させること。
なお画面側は `code` が無くてもサービス層の本文形（`success: false`）なら打ち間違い扱いにする。
**API を管理画面より先にロールバックしても**打ち間違いで強制ログアウトさせないための後方互換
（`requireAdmin` の 401 本文は `success` を持たない）。同じ理由で、画面へ出す文言は
`success === false` のときの `error` だけを採用する（403 の `Forbidden` も画面へ出さない）。

- トークンは `users.reset_token_hash`（SHA-256 ダイジェスト）+ `users.reset_token_expiry`（発行+24h）。
  **リンクは 1 回きり**で、消費は「ダイジェストが一致する行に対してのみ」という条件付き UPDATE 1 文で
  原子的に行う（read-then-update だと同一リンクの同時オープンで二重消費される）。
- **メールを送っただけでは既存パスワードを無効化しない。** 誤操作で管理者を締め出さないため。
  再送すると以前のリンクだけが無効になる。
- 未使用トークンは **メールアドレス変更 / 無効化 / 本人のパスワード変更** で同時に失効させる。
- `POST /auth/admin-forgot-password` は**アカウントの実在有無・メール送信の成否によらず常に 200**
  （列挙対策）。失敗はサーバーログにのみ残す。**画面はレスポンス本文で分岐してはならない。**
- **メールアドレスによる引き当ては大小文字を無視する**（`admin-account.service.ts` の
  `findActiveAdminByEmail` / `findUserByEmailInsensitive`。#72 レビュー指摘 5）。
  書き込み側（作成・更新）は zod が `trim().toLowerCase()` で正規化するが、読み出し側を完全一致に
  したままだと (a) 保存値に大文字を含む既存行（移行スクリプトが DynamoDB の値を素通しする）へ
  「パスワードを忘れた」が到達できず**常に 200 なのでサイレントに失敗する**、
  (b) 入力に大文字や前後空白が混じるとログインが 401 になる、の 2 つが起きる。
  「入力を小文字化して完全一致」では (a) を直せないので、**照合そのものを大小文字非依存にする**
  （既存の大文字行の管理者を締め出さず、本番データの事前正規化も要らない）。
  大小文字違いの重複行がありうる（UNIQUE は生の `email` に対するもの）ため、**完全一致を最優先**し、
  無ければ有効な管理者を優先して 1 行へ畳む。
- **認証・パスワード系の catch では DB 例外を `console.error(error)` でそのまま出さない**
  （`utils/log-error.ts` の `logError` を使う。#72 レビュー指摘 4）。drizzle-orm 0.45 は
  `DrizzleQueryError` の message に SQL と**バインド値**を連結するため（`pg-core` は node-postgres と
  aws-data-api の共通層なので本番も同じ）、パスワードハッシュ・**平文の `reset_token`**（サロン側）・
  トークンダイジェスト・メールアドレスが CloudWatch に平文で残る。
  ハッシュがソルト無し SHA-256（Issue #41）である以上「ハッシュだから平気」は成り立たず、
  Aurora のオートポーズ復帰失敗で catch に到達すること自体が現実に起きる。
  `logError` は message / stack / params を出さず、**原因側の例外名・SQLSTATE・AWS の requestId**
  だけを出す（`DrizzleQueryError` は `name` を設定しないので、原因側を見ないと `Error` としか出ない）。
  - **移行済み**: `middleware/auth.ts` の `requireAdmin` / `requireAuth`、`auth.service.ts` の
    adminLogin / change-password / forgot / reset、`admin-auth.service.ts`、`admin-user.service.ts`。
    あわせて `adminLogin` の「入力メールアドレスを常時 `console.log` する」行も削除した。
  - **未移行（別 Issue）**: `cancellation.service.ts` / `cancellation-send.service.ts` /
    `notification.service.ts` など 30 箇所強。これらのバインド値には**顧客の氏名・電話・メール**が
    載るため本来は同じ扱いが要るが、決済・通知の広範囲に及ぶので GTSS-72 には含めていない。

### `requireAdmin` の DB 検証（GTSS-72 / #72 / REQ-7）

トークン検証に成功したあと `users` を `sub` で引き、`isActiveAdmin` を満たす場合だけ通す。

1. トークン不在 / 不正 → 401（**英語のまま**。既存クライアントの契約を変えない）
2. `role` クレームが `admin` でない → 403 `{ error: 'Forbidden', message: 'Admin role required' }`
   （**必ず DB へ到達する前に判定する**。`getCancellation` は `requireAdmin` → `requireAuth` の
   二段構えで、サロンユーザーの `GET /cancellations/:id` は必ずここを 1 度通る。DB を引くと
   サロン側ホットパスに空振りの Aurora Data API 往復が 1 回増える）
3. 行なし / DB の `role` が非 admin / `status` が非 active → 401「このアカウントは無効です」
4. `last_password_change` より前に発行された `iat` → 401「パスワードが変更されています。再度ログインしてください」
   （秒精度・**同一秒は有効**。NULL は失効させない）
   - `<` にしているのは、パスワード変更と同じ秒に発行する新トークンを自分で失効させないため。
   - **裏返しの例外**: 無効化と同一秒に発行済みのトークンは失効しない（#72 レビュー指摘 15）。
     無効化中は `status` チェックで 401 になるが、**再有効化すると `exp` まで復活する**。
     恒久失効が要件になったら `session_version` 方式へ寄せる（別 Issue）。
   - `last_password_change` が ISO としてパースできない値の場合は **fail-open**（その管理者だけ
     失効判定が無効化される）。移行スクリプトは値を無検証でコピーするため、リリース前に
     実データを確認すること（下記「リリース前に確認する本番データ」）。
5. DB アクセス失敗 → 500

`requireAdmin` は **async** で、戻り値は判別可能ユニオン `Promise<AuthGuardResult>`。api の
`tsconfig` は `strict:false` のため、**戻り値型を明示しないと `await` 付け忘れが型検査を素通りし、
`authCheck.error` が undefined = falsy になって認可が丸ごと無効になる**。呼び出しは 28 箇所
（`salonboard-auth.service.ts` 9 / `applications.handler.ts` 6 / `cancellation.service.ts` 6 /
`admin-users.handler.ts` 4 / `auth.handler.ts` 2 / `cancellation-send.service.ts` 1）で、
全経路の無認証 401 回帰テストも置いている。
**この節を根拠に認可監査をするときは内訳を実測し直すこと**（GTSS-72 で新設した
`admin-users.handler.ts` 4 / `auth.handler.ts` 2 が初版の 22 箇所から漏れていた。#72 レビュー指摘 13）。

## 残課題

- **サロン側 `application_users.reset_token` は平文保存のまま**（管理者側だけ GTSS-72 でダイジェスト
  保存へ移行した）。ダイジェスト保存へ揃えるのは別 Issue とする。同様に
  `applications.verification_token` も平文。
- **無認可のパスワード関連エンドポイントにレート制限が無い**
  （`/auth/forgot-password` / `/auth/reset-password` / `/auth/admin-forgot-password` /
  `/auth/admin-reset-password`）。総当たり・メール爆撃の対象になりうる。現状この API 群には
  レート制限の基盤が一切なく、一部だけに導入しても全体の穴は塞がらないため別 Issue とする。
  応答時間差による列挙も残る（実在アカウントのみ DB 更新とメール送信を行うため）。
- **ログイン応答は列挙可能**。`POST /auth/admin-login` は「ユーザーが見つかりません」と
  「パスワードが正しくありません」を出し分ける。統一は別 Issue（既存クライアントの契約と
  回帰テストを壊さないため GTSS-72 では変えていない）。
- **パスワードハッシュはソルト無し SHA-256**。GTSS-72 で増えた 3 経路（管理者のパスワード設定・
  再設定・変更）も既存の `hashPassword` を使う（同一テーブル内でハッシュ形式が混在すると
  `adminLogin` が壊れるため）。方式移行は Issue #41 の範囲で、**#41 の実装時にこの 3 経路も
  移行対象へ含めること**。

## ロール

現状ロールは「サロン」「運営者」の 2 種類で、ログインエンドポイント自体が分かれている（管理画面 API ⇄ サロンポータル API）。RBAC は実装されていない。

管理者の `role` は作成時にサーバーが `admin` で固定し、画面にロール選択は出さない（GTSS-72）。ただし
**列のガードは外さない**: 移行スクリプト（`scripts/migrate-dynamodb-to-aurora.ts`）は DynamoDB の値を
そのまま写すため、`users.role` は `admin` 以外や NULL を持ち得る。一覧は `role='admin'` で絞り、
更新・パスワードメール送信は非 admin 行を 404 で弾く。

## 関連コード

| ファイル | 役割 |
|---|---|
| `cancel-billing-service-api/src/middleware/auth.ts` | 認証ガード本体（`requireAuth` / `requireAdmin` / `verifyToken` / `isTokenIssuedBefore`）。`AuthGuardResult` 型もここ |
| `cancel-billing-service-api/src/handlers/auth.handler.ts` | `/auth/login`, `/auth/admin-login`, `/auth/me`, `/auth/change-password`, `/auth/forgot-password`, `/auth/reset-password`, `/auth/admin-me`, `/auth/admin-change-password`, `/auth/admin-forgot-password`, `/auth/admin-reset-password` のルート登録 |
| `cancel-billing-service-api/src/services/auth.service.ts` | 認証ロジック（ログイン・パスワード再設定トークン発行/検証） |
| `cancel-billing-service-api/src/services/admin-account.service.ts` | **「管理者として有効か」の唯一の判定**（`isActiveAdmin` / `findActiveAdmin`） |
| `cancel-billing-service-api/src/services/admin-auth.service.ts` | 管理者のパスワード設定/再設定/変更、トークン発行・メール送信、`admin-me` |
| `cancel-billing-service-api/src/services/admin-user.service.ts` | 管理者ユーザーの一覧・作成・更新・パスワードメール送信 |
| `cancel-billing-service-api/src/handlers/admin-users.handler.ts` | `/admin/users` 系のルート登録（すべて `await requireAdmin`） |
| `cancel-billing-service-api/src/schemas/admin-user.schema.ts` | 管理者ユーザー入力の zod スキーマ・日本語メッセージ・ステータス enum |
| `cancel-billing-service-api/src/handlers/applications.handler.ts` | `POST /applications/verify-email`（メール認証。無認可） |
| `cancel-billing-service/src/contexts/AuthContext.tsx` | サロン側 JWT 管理 |
| `cancel-billing-service-admin/src/services/ApiService.ts` | 管理画面側 JWT 管理（`clearStoredSession` / `getStoredAdminUser`。公開ルート・パスワード変更は共通 401 リダイレクトを経由しない） |
| `cancel-billing-service-admin/src/utils/sentryScrub.ts` | Sentry へ送るイベント・breadcrumb から URL のクエリ（`?token=`）を除去する純関数（**Replay の録画には効かない**。多層防御用） |
| `cancel-billing-service-admin/src/utils/passwordSetupToken.ts` | `Sentry.init()` より前にパスワード設定トークンを URL から退避・除去する（Replay の `initialUrl` / rrweb Meta イベント対策） |
| `cancel-billing-service-api/src/services/admin-account.service.ts` | 「管理者として有効か」の唯一の判定（`isActiveAdmin` / `findActiveAdmin`）とメールの大小文字非依存な引き当て（`findActiveAdminByEmail` / `findUserByEmailInsensitive`） |
| `cancel-billing-service-api/src/utils/log-error.ts` | Error をそのまま `console.error` しないための `logError` / `isUniqueViolation`（DrizzleQueryError はバインド値を message に含む） |
