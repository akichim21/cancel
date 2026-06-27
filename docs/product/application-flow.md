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
| `active` | 利用中 | `details_submitted = true` | キャンセル請求の登録が可能 |
| `rejected` | 却下済み | 運営者が却下 | 終了 |
| `withdrawn` | 退会 | 運営者が申請を削除（論理削除） | 終了（後述「申請の削除」） |

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

### 1.5 メール認証（GTSS-842 / #31）

LP申込で入力ミス・他人のメールアドレスでの申込を弾くため、申込直後にメールアドレスの本人認証を挟む。

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

### 4. ユーザーポータル ログイン

- 入口: `https://user.cancel.co.jp/`（`cancel-billing-service`）
- 初回ログイン: 申請メールアドレス + 初期パスワード（運営メール記載）
- ログイン後: JWT を localStorage に保存（有効期限 24 時間）
- 初期パスワード変更を推奨（`ChangePasswordPage.tsx`）

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
| 保持 | `businessName`(屋号), `corporateNumber`(法人番号), `tRegistrationNumber`(インボイス登録番号), 住所, `entityType`, Stripe 系 | 会計・請求履歴のため保持 |
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
| `cancel-billing-service-lp/src/App.jsx` | LP 申請フォーム・独自ルーティング（`/verify-email` 含む） |
| `cancel-billing-service-lp/src/components/EmailVerify.jsx` | メール認証結果画面（verified/expired/already_verified/invalid。GTSS-842） |
| `cancel-billing-service-lp/src/components/StripeSuccess.jsx` | Stripe登録完了判定 |
| `cancel-billing-service-lp/src/components/StripeRefresh.jsx` | Stripe リンク再発行 |
| `cancel-billing-service-admin/src/components/ApplicationList.tsx` | 申請一覧（管理画面）・ステータスフィルタ |
| `cancel-billing-service-admin/src/components/ApplicationDetailLayout.tsx` | 申請詳細・審査アクション（`getAvailableStatusActions`） |
| `cancel-billing-service-admin/src/constants/applicationStatus.ts` | admin 側ステータス enum/ラベル/バッジ/審査アクション定義 |
| `cancel-billing-service-api/src/constants/application-enums.ts` | 申請ステータス/事業区分 enum・正規化・ラベル（SSoT） |
| `cancel-billing-service-api/src/services/application.service.ts` | 申請作成（`createApplication`）・メール認証（`verifyEmail`）・ステータス更新（メール送信含む） |
| `cancel-billing-service-api/src/handlers/applications.handler.ts` | 申請ルート（`POST /applications` / `POST /applications/verify-email` / `PUT /applications/:id/status` 等） |
