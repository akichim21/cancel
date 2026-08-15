# 申請フロー（サロンのオンボーディング）

サロンが本サービスを利用開始するまでのフロー。

## 全体フロー

```
[LP申請フォーム] → [メール認証] → [運営審査] → [Stripe Connect登録] → [オンボーディング] → [利用開始]
 仮登録（未認証）    審査中(pending)  Stripe登録待ち  オンボーディング待ち       利用中
                                       ↘ 却下済み（運営却下）／ 退会（削除）
```

LP 申込送信直後は **仮登録（未認証）**（`unverified`）で保存し、申込者宛の**認証メール**の URL を
タップして初めて **審査中**（`pending`）へ進む二段階フロー（GTSS-842 / #31）。詳細は後述
「[1.5 メール認証](#15-メール認証gtss-842--31)」。

## ステータス遷移

DB 保存値・API 契約は **英語 lowercase enum**、画面表示は **日本語ラベル**（SSoT は
`cancel-billing-service-api/src/constants/application-enums.ts`。`src/config` / `src/lambda` から再 export。
admin は `src/constants/applicationStatus.ts` に別定義）。保存先は **Aurora PostgreSQL**（`applications` テーブル。
旧 DynamoDB から移行済み）。API レスポンスは `status`（英語値）+ `statusLabel`（日本語）を返す。

| enum 値（DB/API） | ラベル（statusLabel） | 状態 | 次にやること |
|---|---|---|---|
| `unverified` | 仮登録（未認証） | LP申込送信直後（メール未認証） | 申込者が認証メールの URL をタップ |
| `pending` | GTSS審査中 | メール認証完了 | 運営者が管理画面で審査 |
| `approved` | Stripe登録待ち | 運営者が承認 | サロンに Stripe Connect リンクをメール送信 |
| `onboarding` | オンボーディング待ち | Stripe アカウント作成済み | サロンがオンボーディング（本人確認・銀行口座登録）を完了 |
| `active` | 利用中 | `charges_enabled = true` | キャンセル請求の登録が可能 |
| `rejected` | 却下済み | 運営者が却下 | 終了 |
| `withdrawn` | 退会 | 運営者が申請を削除（論理削除） | 終了（後述「申請の削除」） |

> **`active` の遷移条件は `charges_enabled`（`details_submitted` ではない）**。実際に `active` へ
> 遷移させているのは `account.updated` webhook の `charges_enabled` 判定であり、`details_submitted` は
> 「サロンが提出を終えた」ことを示すだけで Stripe の確認完了を意味しない（GTSS-909 / #67 で判明した
> ドキュメントと実装の乖離を訂正）。自動リマインドの完了判定も同じ `charges_enabled` を使う。

**遷移ルールの要点（手動更新ガード）**:
- `unverified` には **LP申込送信時のみ**到達し、`unverified → pending` は**メール認証完了のみ**が行う。
  管理画面・API の手動ステータス更新（`PUT /applications/:id/status`）では `unverified` への/からの遷移を
  **400 で拒否**する（未認証申込の審査アクションを UI/API の二重で塞ぐ。GTSS-842 / #31）。
- `withdrawn` も削除操作でのみ到達する内部遷移で手動更新からは到達・離脱不可（GTSS-20。後述）。

## ステップ詳細

### 1. LP 申請

- 入口: `https://cancel.co.jp/`（`cancel-billing-service-lp`）
- フォーム: サロン名・代表者・連絡先・住所・口座希望情報 等
- 保存先: Aurora PostgreSQL `applications` テーブル（旧 DynamoDB から移行済み）
- 初期ステータス: **`unverified`（仮登録（未認証））**（メール認証完了で `pending` へ）
- 申込送信時、申請レコードに**認証トークン**（暗号学的乱数 hex）＋**有効期限（発行+24時間）**を発行し保存する。
- 申込と同時に **ログインユーザー（application_users）を 1:1 で先行作成**（`password=NULL` / 未有効化）。
  「申請在り = ログインユーザー在り」の不変条件を保つ（初期パスワードの発番は Stripe オンボーディング完了時）。
- **メールアドレス重複時の挙動**（GTSS-842 / #31）:
  - 既存が `unverified` → 既存行を**今回の入力で上書き**＋トークン再発行＋**認証メール再送**（201。
    applicationId・作成日時は維持。application_users は email 一意制約のため**再利用**＝新規作成しない）。
  - 既存が `unverified` 以外（`pending`/`approved`/`onboarding`/`active`）→ 従来どおり **409 `DUPLICATE_EMAIL`**。
  - 論理削除済み（`withdrawn`）は email がマスク（NULL）され重複判定に一致しないため、同一 email で新規申込可。
- **送信結果の画面挙動**（GTSS-883 / #51）:
  - **送信成功**（新規 201・未認証再申込の上書き＋再送 201 のいずれも）→ フォーム入力値をクリアしてから
    **認証メール送信のご案内ページ `/verify-email-sent` へ通常遷移**（`window.location.assign` による
    full page load。本番ビルドで注入される GTM が標準 Page View として検知できる）。
    旧挙動の成功時ブラウザ標準ダイアログ（alert）とフォーム直下の成功カードは廃止。
  - **409 `DUPLICATE_EMAIL`**（認証済み以降の重複）→ 遷移せず、従来どおり同一ページで
    「すでに申請済みです」を案内（alert＋フォーム直下カード。認証メールが送られないケースのため）。
  - **バリデーション NG・その他エラー・ネットワークエラー** → 遷移せず、従来どおり同一ページで表示。

### 1.5 メール認証（GTSS-842 / #31）

LP申込で入力ミス・他人のメールアドレスでの申込を弾くため、申込直後にメールアドレスの本人認証を挟む。

- **認証メール送信のご案内ページ**（`/verify-email-sent`、`cancel-billing-service-lp/src/components/VerifyEmailSent.jsx`。
  GTSS-883 / #51）: 申込送信成功時の遷移先。認証メールを送った旨・メール内リンクを押すと認証が完了すること・
  この後の流れ（①メール内リンクで認証（お客さまの操作）→②弊社で審査→③審査通過後に Stripe登録のご案内）・
  届かない場合は迷惑メールフォルダの確認、を表示し、トップページへ戻る導線を持つ。
  - 位置づけは「申込完了」ではなく**次の操作（メール認証）の依頼**。完了を意味する文言（「受け付けました」等）は
    使わない（完了の案内は認証完了画面側の役割）。申請ID・入力情報は表示せず、URL は固定パス
    （クエリ・ハッシュに個人情報・申請ID・代理店コードを含めない）。
  - 表示専用でサーバー通信を行わない（直接アクセス・再読み込みでも二重登録は起きない）。
  - **noindex**（`meta[name="robots"]` = `noindex, nofollow`）を適用する。本ページのほか、
    メール認証・Stripe 登録・決済結果系の全 7 ルート（`/verify-email`・`/verify-email-sent`・
    `/stripe-success`・`/stripe-refresh`・`/payment-success`(+`/payment-complete`)・`/payment-cancel`）と
    未知パスが noindex 対象（`noindex, nofollow` + 固有 title は本ページのみ。他はサイト名 title + `noindex`）。
    公開ページ（LP 本体／利用規約／プライバシーポリシー／特商法表記）へは波及させない。
    適用方式は**初期 HTML（ビルド時プリレンダ #56）+ JS の二重適用**: SEO 値の単一ソースは
    `cancel-billing-service-lp/src/seo.js` の `PAGE_META` で、ビルド時に `vite-plugin-seo-prerender.js` が
    ページ別初期 HTML の head へ焼き込み、JS レンダリング時に同じ値を冪等に再適用する。
    ページコンポーネント側では head を触らない（GTSS-887 で `seo.js` へ集約）。
    存在しない URL は CloudFront が HTTP 404 + 専用 404 ページ（noindex・アプリ非起動）を返す（#56）。
- **認証メール**（申込者宛）: 宛名（事業者名）＋認証URL（`{LPベースURL}/verify-email?token=...`）＋
  有効期限（24時間）の案内。送信は本番=SMTP / それ以外=SES、送信元 `info@cancel.co.jp`。
- **認証画面**（`/verify-email`、`cancel-billing-service-lp/src/components/EmailVerify.jsx`）: URL の `token` を
  取得し `POST /applications/verify-email` を呼び、結果種別で出し分ける:
  - `verified`（有効期限内）→ 「認証が完了しました」＋「この後の流れ」を表示。申請を **`pending`（審査中）** へ
    更新し、**有効期限を無効化（NULL 化）しつつトークン値は保持**（再オープン時の `already_verified` 判定用）。
    あわせて**運営管理者へ新規申請通知メールを送信**する（未認証段階では送らない。後述「メール送信タイミング」）。
  - `expired`（有効期限切れ）→ 「リンクの有効期限が切れています」＋申込フォームへの再申込導線（未認証は再申込で上書き＋再送）。
  - `already_verified`（`unverified` 以外＝認証済み）→ 「すでに認証が完了しています」＋待機案内。再遷移・通知再送はしない（冪等）。
  - `invalid`（トークン不一致・空トークン）/ 通信エラー → 無効リンク / エラー画面。
- **認証完了画面の「この後の流れ」**: ①弊社で審査 → ②審査通過後に Stripe登録案内メール → ③Stripe登録完了で利用開始。

### 2. 運営審査

- 入口: `https://admin.cancel.co.jp/`（`cancel-billing-service-admin`）
- 運営者が申請内容を確認 → 承認 / 却下
- 承認時: ステータスを `Stripe登録待ち` に更新し、サロンに Stripe Connect 用メール送信
  - メール送信: SES (ap-northeast-1)
  - 案内メール（件名 `【キャンセル請求便】Stripe登録のご案内`）には Stripe 登録リンクに加えて
    **サロン様向けご利用マニュアル URL**（Notion）を同梱し、登録手順でつまずいたサロンが自己解決できるようにする
    （#65。`updateApplicationStatus` の本文のみ。Stripeリンク再送 `send-stripe-link` の本文は対象外）
  - 初期パスワード（ユーザーポータルログイン用）の発番は Stripe オンボーディング完了（`account.updated` webhook）時
- **未認証申込のロック**: `unverified` の申請は一覧に表示されるが審査アクション（審査通過/却下）を提示しない
  （admin は `getAvailableStatusActions` の default `[]`、API は `updateApplicationStatus` のガードで二重防御。
  GTSS-842 / #31）。「申し込んだのに連絡が来ない」というサロンが未認証で止まっていることを運営が把握できる。

> **メール送信タイミング（GTSS-842 / #31 / REQ-7）**: 申込送信時は**申込者宛の認証メールのみ**送る。
> 運営管理者宛の「新しい申請が届きました」通知メールは、**メール認証完了時（`pending` へ遷移した時）**に送る
> （未認証のまま離脱した申込で管理者の受信箱にノイズが出るのを防ぐ）。

### 3. Stripe Connect オンボーディング

- サロンがメール内リンクを開く → Stripe Connect Onboarding 画面へ
- 完了後: `stripe-success` ページ (`cancel-billing-service-lp/src/components/StripeSuccess.jsx`) が `applicationId` を受け取り、`details_submitted` をAPI で確認
  - `true` → ユーザーポータルへ誘導（ステータス `利用中`）
  - `false` → 未完了画面（再オンボーディングリンク `/stripe-refresh`）
- リンク失効時: `cancel-billing-service-lp/src/components/StripeRefresh.jsx` から再発行
- 入金（payout）は **manual + 月次末日バッチ**（GTSS-854 / #33）。連結アカウント残高（net）が
  しきい値（`available ≧ ¥3,000` ≒ 回収 gross ¥4,000）に達した月にまとめて入金し、未達は翌月へ繰り越す。
  着金は標準遅延（JP は Instant 非対応・最短 4 営業日）。詳細は `docs/tech/stripe-connect.md`「入金（payout）」。

#### Stripe 登録の自動リマインド（3日後・7日後）— GTSS-909 / #67

初回案内メール 1 通だけでは Stripe オンボーディングを完了せず「Stripe登録待ち」で滞留するサロンが
出るため、**初回案内の送信日時を起点に 3 日後・7 日後の各 1 回、合計 2 回**のリマインドを自動送信する。
14 日以降は自動メールを送らず、運営の個別フォローへ切り替える。

- **起点**: 承認時に初回案内メール「【キャンセル請求便】Stripe登録のご案内」を送るタイミングで
  `applications.stripe_guide_sent_at` に記録する（**メール送信の成否によらず**記録する。送信失敗した
  申込が永久にリマインド対象外になるのを防ぐ）。既に値があれば上書きしない。
  運営の手動再送（`POST /applications/:id/send-stripe-link`）と LP の Account Link 再発行は
  **起点も回数も動かさない**（リマインドとは独立した操作として扱う）。
- **回と間隔**（JST 暦日の経過日数。「ちょうど N 日目」ではなく**窓**で判定する）:

  | 経過日数 | 判定 |
  |---|---|
  | 0〜2 日 | 送らない |
  | 3 日以上 7 日未満 | リマインド 1「Stripe登録に未完了の項目があります」（未試行なら） |
  | 7 日以上 14 日未満 | リマインド 2「Stripe登録が完了していません（決済機能のご利用に必要です）」（未試行なら） |
  | 14 日以上 | 打ち止め（運営の個別フォローへ） |

  窓で判定するのは、Stripe 確認待ちでその日だけスキップされた申込を翌日以降に拾うため、および
  バッチ障害・スケジューラ遅延をキャッチアップするため（厳密日一致だとその回が永久に欠番になる）。
  副作用の「中 1 日で 2 通」を防ぐため、リマインド 2 には**前回送信から中 3 日以上**という最小間隔を課す。
  1 回目が未試行のまま 7 日を超えた場合は 2 回目のみを送る（1 回目は欠番・後追いしない）。
- **対象判定**: 管理画面のステータス名ではなく **Stripe の実際の状態**で判定する（上から順に評価）。

  | # | 条件 | 判定 |
  |---|---|---|
  | 1 | `charges_enabled = true` | 送らない（登録完了。以降も送らない） |
  | 2 | `requirements.disabled_reason` が `rejected.*` / `platform_paused` / `under_review` | 送らない（サロンの操作では解消できない＝運営マター） |
  | 3 | `details_submitted = false` | **送る**（未着手＝滞留の主因） |
  | 4 | `requirements.currently_due` または `past_due` が 1 件以上 | **送る**（サロン側の対応が必要） |
  | 5 | 上記以外（`pending_verification` のみ / `eventually_due` のみ） | 送らない（Stripe 確認待ち。**回は消費せず**翌日以降に再評価） |

  完了判定を `charges_enabled` 単独にしているのは、申込が `active` へ遷移する条件（`account.updated`
  webhook）と揃えるため。二重基準にすると「画面上は利用中なのにリマインドが届き続ける」不整合が起きる。
- **リンク**: メール本文に Stripe の Account Link を**直接載せない**（単回利用・短時間で失効するため、
  1 日 1 回のバッチが送る時点の URL はメールが読まれる頃にはほぼ確実に失効している）。代わりに LP の
  `{LP}/stripe-refresh?applicationId=…` を載せ、サロンがクリックした時点で新しいリンクを発行する。
- **`account.updated` webhook メールとの併存**: 「Stripe登録に追加情報が必要です」メール
  （`charges_enabled=false` かつ `details_submitted` かつ `currently_due` あり・24 時間スロットル・
  回数上限なし）は**イベント駆動の別系統として併存させる**。したがって「初回案内を含め合計 3 通で
  打ち止め」は**時間駆動の自動リマインドが 2 通で打ち止め**の意味であり、サロンが受け取る Stripe 関連
  メールの総数は Stripe が追加要求を出した回数だけ増えうる（同日に 2 通届く可能性がある）。
- **リリース時のバックフィル**: リリース前から `approved` / `onboarding` で滞留している申込にも
  届くよう、マイグレーションで起点にマイグレーション適用時刻を入れる（未削除・Stripe アカウントあり・
  メールあり・起点未設定が条件）。リリースの 3 日後にリマインド 1、7 日後にリマインド 2 が届く。
- **運用**: 送信状況の管理画面表示は作らない。`application_notifications` テーブルへの SQL と
  構造化ログ（`[stripe-onboarding-reminders] summary:`）で運営が確認する。
  技術詳細・手動起動コマンドは `docs/tech/batch-jobs.md`。

### 4. ユーザーポータル ログイン

- 入口: `https://user.cancel.co.jp/`（`cancel-billing-service`）
- 初回ログイン: 申請メールアドレス + 初期パスワード（運営メール記載）
- ログイン後: JWT を localStorage に保存（有効期限 24 時間）
- **初期パスワード変更は必須**（推奨ではない）。`application_users.must_change_password = true` の間は
  `ProtectedRoute` が `/change-password`（`ChangePasswordPage.tsx`）へ強制遷移させ、他の保護画面には入れない
- **変更成功後は再ログイン不要**（GTSS-852 / #43）。API が新しい JWT と更新後ユーザー情報を返し、
  ポータルはログイン状態を保ったまま**ダッシュボードへ着地**し、上部に「パスワードを変更しました」完了バナーを
  8 秒間表示する（×で即座に閉じられる）。ログイン後の自発的な変更では遷移せず変更画面に留まり、同じバナーを出す。
  詳細は `docs/tech/auth.md`「パスワード操作」

## 適格請求書登録番号（T番号）の登録

インボイス制度対応として、サロンが自社の**適格請求書登録番号（T番号）**を登録できる（GTSS-13 で登録機能、
GTSS-851 / #44 で領収書への反映）。

- **登録手段**: ユーザーポータルの**アカウント設定**（`/settings`・`SettingsPage.tsx`）。運営（admin）側の
  入力画面は無く、**サロン本人が自分で登録する**。
- **形式**: `T` + 数字13桁（例 `T1234567890123`）。未設定（空）も許容する。
- **保存先**: `applications.t_registration_number`。**会社（申込）単位**であり店舗単位ではない
  （複数店舗を持つサロンでも 1 つ）。
- **顧客への反映**: 登録済みなら、顧客が決済後に受け取る **Stripe 領収書メールの SUMMARY 欄**へ
  `{発行者名}（適格請求書登録番号: T…）` の形で発行者名と並べて表示される。加えて決済画面の品目説明欄にも
  併記される。未登録なら発行者名のみで、括弧も付かない。仕様の詳細（発行者名の解決順・適用経路・制約）は
  `docs/product/cancellation-flow.md`「2. 送信（決済リンク送信）」を参照。
- **注意**: Stripe の領収書メールは顧客メールアドレスがある場合のみ送信されるため、**連絡先が電話番号のみの
  顧客（SMS 通知）には領収書が届かず、T番号も届かない**。
- 申請の論理削除時も T番号 は**保持**する（会計・請求履歴のため。下記「マスク対象 / 保持対象」）。

## 代理店コードの記録（紹介リンク経由の申込）

サロンがどの代理店（紹介リンク）経由で申し込んだかを記録する（GTSS-836 / #30）。詳細は
`docs/product/agent-code.md`。申請フロー上の要点:

- **取得（LP / first-touch）**: 申込ページが URL `?agent=xxx`（例 `?agent=topad`）を読み、**保持済みが
  無い場合のみ** `localStorage` に保持する（最初の値を優先・上書きしない）。申込送信時、保持値が空でなければ
  `agentCode` を申込データに含める。代理店コードはサロン・顧客向け画面には一切表示しない（裏側に閉じる）。
- **保存（API）**: `POST /applications` が `agentCode` を**正規化**（trim・空→未設定NULL・上限64文字）して
  `applications.agent_code` に保存する。任意項目のため未指定でも申込作成は従来どおり成功し、既存バリデーション
  （電話/メール/区分/同意）の挙動・文言は不変。
- **手動補正（admin）**: 申込一覧に「代理店コード」列（未設定は「未設定」表示）、申込詳細に編集UI を追加。
  `PUT /applications/:id/agent-code`（**管理者専用**）で上書き・空保存で削除でき、**手動値が最終的な正**。
  自動取得は新規申込作成時のみ働くため、既存申込を自動取得が後から上書きすることはない。

> 精算用CSV（代理店コード・支払日列・支払日期間フィルタ）は `docs/product/cancellation-flow.md` を参照。

## 申請の削除（論理削除 / 退会化 + 顧客PIIマスク + 90日バックアップ）

運営管理者が管理画面から申請（サロン）を削除する操作は、**物理削除ではなく論理削除**で行う。
削除済みサロンを業務ステータス「退会（`withdrawn`）」で明示しつつ、サロン本人の個人情報と
**キャンセル請求の顧客 PII（氏名/電話/メール）も消去**して PII 露出を最小化する。一方で誤削除に
備え、**マスク前の元データを 90 日間バックアップ**して `applicationID` 指定で復元できるようにする
（90 日経過後は復元用バックアップを物理削除して PII を恒久消去）。会計・監査に必要な請求書本体
（金額・明細）は引き続き保持する（GTSS-20 で GTSS-19 の論理削除を拡張）。

### 削除時の挙動（`DELETE /applications/:id`、管理者専用）

1. **マスク前の元データ**（application 全カラム + 紐づく全 cancellations）を **JSON 1 レコードのバックアップ**
   （`expiresAt` = 削除時刻 + 90 日）として保存する。**未削除（`deletedAt` が NULL）のときのみ**生成し、
   再削除では二重生成・`expiresAt` 延長をしない（「マスク前データを 1 度だけ」保証）。
2. 当該申請に紐づく**未決済キャンセル請求**（`sent` / `pending`）の Stripe チェックアウトセッションを
   expire し、ステータスを `canceled` に更新する。
3. 当該申請の**ログインアカウント（application_users）を物理削除**する（ログイン経路を確実に塞ぐ）。
   これに伴い `cancellations.created_by_application_user_id` は FK（`ON DELETE SET NULL`）で NULL になる。
4. 申請レコードは**残したまま**、申請 PII をマスク（NULL 上書き）し、**`status='withdrawn'`（退会）** へ変更、
   削除マーカー `deletedAt`（ISO8601）をセットする。
5. 紐づく**全 cancellations の顧客 PII（氏名/メール/電話）を固定マスク文字列 `***`** で上書きする
   （金額・明細・applicationId・Stripe 関連は保持）。

①③④⑤の DB 副作用は可能な範囲を単一トランザクションで原子化する（②の Stripe expire は外部副作用で
Tx 外・best-effort）。既に削除済みの申請を再削除しても**冪等に成功**する（再マスク・再 withdrawn で壊れない）。

### マスク対象 / 保持対象

| 区分 | カラム | 扱い |
|---|---|---|
| 常にマスク（NULL） | `applications.email`, `phone`, `representativeName`(代表者名), `contactName`(担当者名), `birthDate`(生年月日) | 個人情報のため消去 |
| 条件付きマスク | `applications.partnerName` / `partnerNameKana` | `entityType==='個人'`（個人事業主本人の氏名）→ マスク。`'法人'`（法人名）→ 保持 |
| **マスク（固定文字列 `***`）** | `cancellations.customerName` / `customerEmail` / `customerPhone` | 請求の顧客 PII を消去（NULL ではなく `***`。当該 3 列は NOT NULL） |
| ステータス変更 | `applications.status` → `withdrawn`（退会） | 退会は削除でのみ到達する内部遷移（手動変更不可） |
| 保持 | `businessName`(屋号), `corporateNumber`(法人番号), `tRegistrationNumber`(適格請求書登録番号 / T番号), 住所, `entityType`, Stripe 系 | 会計・請求履歴のため保持 |
| 保持 | キャンセル請求の金額・明細・`applicationId`・Stripe 関連 | 請求書本体として保持（行は削除しない） |

### 退会（withdrawn）ステータスのライフサイクル

- 退会は**削除操作によってのみ到達**する内部遷移ステータス（ラベル「退会」）。
- 管理画面の手動ステータス変更・API のステータス更新（`PUT /applications/:id/status`）からは
  **到達も離脱もできない**（指定 / 現ステータスが `withdrawn` のとき 400 拒否）。
- 申請一覧（`GET /applications`）の除外は従来どおり **`deletedAt IS NULL`** ベース（status には依存しない）。
- 管理画面のステータス絞り込み（フィルタ）選択肢には退会を出さない（退会申請は一覧に通常出現しない）。

### 復元（restore）と 90日経過削除（purge）

- **restore（手動バッチ、`applicationID` 指定）**: 未失効バックアップから申請 PII・`status`（元値を無条件に
  書き戻し）・顧客 PII を復元し、`deletedAt` を NULL に戻す（一覧へ再表示）。バックアップ非存在/失効時は
  エラーで何も変更しない。`applications.email` の一意制約と衝突する場合（削除後に同一 email で別申請が
  作成された等）は復元せず明示エラー。**ログインアカウント（application_users）は再作成しない**（確定）。
  利用再開にはパスワード再発行 / 再オンボーディングを運用で実施する。
- **purge（毎月 3 日 JST 00:00 の自動バッチ）**: `expiresAt <= 現在` のバックアップレコードのみを物理削除する
  （マスク済みの live な applications/cancellations 行は無傷）。以後そのサロンは復元不可（PII は恒久消去）。

### 副次的な仕様

- **ログイン遮断**: application_users を物理削除するため、削除後のサロンはログイン不可（401）。`status` は
  退会へ変更するが、一覧除外の判定は引き続き `deletedAt`（削除判定の技術マーカー）が担う。
- **店舗名表示の劣化**: 個人事業主を削除すると `partnerName` が NULL になり、請求履歴一覧の店舗名は
  `businessName`(屋号)→無ければ `不明` で解決される。法人は法人名を保持するため影響なし。
- **同一 email の再申請**: `email` を NULL マスクするため、削除済みサロンと同一 email での再申請が可能。
  ただしその後に元サロンを restore しようとすると email 一意衝突で復元失敗となる。

> 実装: `cancel-billing-service-api/src/services/application.service.ts`（`deleteApplication` / `maskApplicationPii`）、
> `src/services/application-backup.service.ts`（`createDeletionBackup` / `restoreApplication` / `purgeExpiredBackups`）、
> `src/repositories/{applications,cancellations,application-deletion-backups}.repository.ts`、`src/batch.ts`（バッチ
> エントリ）。技術面・インフラは `docs/tech/api-architecture.md` を参照。

## 関連コード

| ファイル | 役割 |
|---|---|
| `cancel-billing-service-lp/src/App.jsx` | LP 申請フォーム・独自ルーティング（`/verify-email` / `/verify-email-sent` 含む） |
| `cancel-billing-service-lp/src/components/VerifyEmailSent.jsx` | 認証メール送信のご案内ページ（申込送信成功時の遷移先。GTSS-883。title / noindex は `src/seo.js` が設定） |
| `cancel-billing-service-lp/src/utils/navigation.js` | 送信成功時の遷移ヘルパー（`goToVerifyEmailSent`。GTSS-883） |
| `cancel-billing-service-lp/src/components/EmailVerify.jsx` | メール認証結果画面（verified/expired/already_verified/invalid。GTSS-842） |
| `cancel-billing-service-lp/src/components/StripeSuccess.jsx` | Stripe登録完了判定 |
| `cancel-billing-service-lp/src/components/StripeRefresh.jsx` | Stripe リンク再発行 |
| `cancel-billing-service-admin/src/components/ApplicationList.tsx` | 申請一覧（管理画面）・ステータスフィルタ |
| `cancel-billing-service-admin/src/components/ApplicationDetailLayout.tsx` | 申請詳細・審査アクション（`getAvailableStatusActions`） |
| `cancel-billing-service-admin/src/constants/applicationStatus.ts` | admin 側ステータス enum/ラベル/バッジ/審査アクション定義 |
| `cancel-billing-service-api/src/constants/application-enums.ts` | 申請ステータス/事業区分 enum・正規化・ラベル（SSoT） |
| `cancel-billing-service-api/src/services/application.service.ts` | 申請作成（`createApplication`）・メール認証（`verifyEmail`）・ステータス更新（メール送信含む） |
| `cancel-billing-service-api/src/handlers/applications.handler.ts` | 申請ルート（`POST /applications` / `POST /applications/verify-email` / `PUT /applications/:id/status` 等） |
