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

## 申請の削除（論理削除 / ソフトデリート）

運営管理者が管理画面から申請（サロン）を削除する操作は、**物理削除ではなく論理削除**で行う。
キャンセル請求（請求書データ）や法人情報は会計・監査のために残しつつ、個人情報のみを消去する。

### 削除時の挙動（`DELETE /applications/:id`）

1. 当該申請に紐づく**未決済キャンセル請求**（`sent` / `pending`）の Stripe チェックアウトセッションを expire し、ステータスを `canceled` に更新する。
2. 当該申請の**ログインアカウント（application_users）を物理削除**する（ログイン経路を確実に塞ぐ）。これに伴い `cancellations.created_by_application_user_id` は FK（`ON DELETE SET NULL`）で NULL になる。
3. 申請レコードは**残したまま**、個人情報をマスク（NULL 上書き）し、削除マーカー `deletedAt`（ISO8601）をセットする。
4. 申請一覧（`GET /applications`）からは `deletedAt` がセット済みの申請を除外する。詳細取得・請求の店舗名解決（JOIN）では削除済み申請も参照できる。

既に削除済みの申請を再削除しても**冪等に成功**する（再マスクで壊れない）。

### マスク対象 / 保持対象

| 区分 | カラム | 扱い |
|---|---|---|
| 常にマスク（NULL） | `email`, `phone`, `representativeName`(代表者名), `contactName`(担当者名), `birthDate`(生年月日) | 個人情報のため消去 |
| 条件付きマスク | `partnerName` / `partnerNameKana` | `entityType==='個人'`（個人事業主本人の氏名）→ マスク。`'法人'`（法人名）→ 保持 |
| 保持 | `businessName`(屋号), `corporateNumber`(法人番号), `tRegistrationNumber`(インボイス登録番号), 住所(`zip`/`prefecture`/`city`/`address`/`building`), `entityType`, `status`, Stripe 系 | 会計・請求履歴のため保持 |
| 保持 | キャンセル請求（`cancellations`） | 請求書データとして保持（行は削除しない） |

### 副次的な仕様

- **ログイン遮断**: application_users を物理削除するため、削除後のサロンはログイン不可（401）。`applications.status` は変更しない（`deletedAt` を削除判定の唯一の真実とする）。
- **店舗名表示の劣化**: 個人事業主を削除すると `partnerName` が NULL になり、請求履歴一覧の店舗名は `businessName`(屋号)→無ければ `不明` で解決される。法人は法人名を保持するため影響なし。
- **同一 email の再申請**: `email` を NULL マスクするため、削除済みサロンと同一 email での再申請が可能になる（PII 消去の帰結として許容）。

> 実装: `cancel-billing-service-api/src/services/application.service.ts`（`deleteApplication` / `maskApplicationPii`）、`src/repositories/applications.repository.ts`（`getAll` の `deletedAt IS NULL` フィルタ / `softDelete`）。技術面は `docs/tech/api-architecture.md` を参照。

## 関連コード

| ファイル | 役割 |
|---|---|
| `cancel-billing-service-lp/src/App.jsx` | LP 申請フォーム |
| `cancel-billing-service-lp/src/components/StripeSuccess.jsx` | Stripe登録完了判定 |
| `cancel-billing-service-lp/src/components/StripeRefresh.jsx` | Stripe リンク再発行 |
| `cancel-billing-service-admin/src/components/ApplicationList.tsx` | 申請一覧（管理画面） |
| `cancel-billing-service-admin/src/components/ApplicationDetail.tsx` | 申請詳細・承認/却下 |
| `cancel-billing-service-api/src/lambda.ts` | API ハンドラ（申請作成・ステータス更新・メール送信） |
