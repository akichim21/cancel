---
name: setup-local-stripe
description: cancel-billing-service-api のローカル開発で Stripe（テストモード決済・Connect オンボーディング・Webhook 受信）をセットアップ／デバッグする時に使用する skill。「ローカルで決済が通らない」「支払い済みにならない」「webhook が届かない」時にも参照する。
---

# ローカル Stripe セットアップ

`cancel-billing-service-api` をローカル（`npm run dev`, `:3000`, `NODE_ENV=local`）で動かし、Stripe の
**テストモード決済 / Connect オンボーディング / Webhook 受信**を成立させるための手順とハマりどころ集。

## 大前提（最初に必ず理解する）

1. **テスト/本番の切替はキーだけで決まる。** `STRIPE_SECRET_KEY` が `sk_test_` ならサンドボックス、`sk_live_`
   なら本番。`NODE_ENV` は無関係（`src/clients.ts` は `new Stripe(process.env.STRIPE_SECRET_KEY)` のみ）。
   ローカルの `.env` は必ず `sk_test_` を使う。`pk_`（公開鍵）は絶対に入れない。
2. **このアプリは「直接課金（direct charge）」。** Checkout を `{ stripeAccount }` 付きで作る
   （`src/services/invoice.service.ts`）。そのため `checkout.session.completed` も `account.updated` も
   **連結アカウント（Connect）のイベント**として発生する。→ ローカル受信は **`--forward-connect-to`** が必須。
3. **ローカルは Webhook 署名検証が有効。** `SKIP_WEBHOOK_SIGNATURE` は `NODE_ENV=dev` の時しか効かない
   （`src/services/webhook.service.ts`）。ローカル（`NODE_ENV=local`）では `STRIPE_WEBHOOK_SECRET` が
   受信エンドポイントの署名鍵と一致している必要がある。
4. **`API_BASE_URL` 等の URL 上書きは Webhook 登録とは無関係。** 支払い短縮リンク（`/pay/:id`）や
   オンボーディング戻り先の URL を差し替えるだけ。Webhook を届かせるのは CLI / エンドポイント登録の役割。

## セットアップ手順

### Step 0: 前提

- ローカル DB・サーバが動くこと（README の「ローカル開発」参照。`npm run dev:setup` → `npm run dev`）。
- `.env` の `STRIPE_SECRET_KEY=sk_test_...`（dev と同じテストキーで可）。

### Step 1: Stripe CLI を入れる

```bash
brew install stripe/stripe-cli/stripe
stripe version
```

### Step 2: Webhook をローカルへ転送（★ Connect 必須）

`stripe login` は対話が必要。テストキーを使えば login 不要で回せる：

```bash
# .env の sk_test_ をそのまま使う例（login 不要）
stripe listen \
  --api-key "$(grep -E '^\s*STRIPE_SECRET_KEY=' .env | sed -E 's/^[^=]*=//')" \
  --forward-connect-to localhost:3000/webhook/stripe
```

- `--forward-connect-to` … **連結アカウントのイベント**を転送（このアプリで必要なのはこれ）。
  `--forward-to`（自アカウントのイベント）では `checkout.session.completed`(direct charge) は来ない。
- Webhook パスは `/webhook/stripe`（`src/handlers/webhook.handler.ts`）。ポートは `PORT`（既定 3000）。
- 起動時に表示される **`whsec_...`** を控える。この値は同じ端末なら再起動しても基本変わらない。

### Step 3: 署名鍵を `.env` に設定して dev サーバを再起動

```env
# .env
STRIPE_WEBHOOK_SECRET=whsec_xxxxxxxx   # ← Step 2 の stripe listen が出した値
```

```bash
npm run dev   # .env を再読込するため必ず再起動
```

`stripe listen` は**テスト中ずっと起動したまま**にする（別ターミナルで回す）。

### Step 4: 決済を試す

請求リンク（SMS/メール or UI）から Checkout を開き、テストカードで支払う：

- カード番号 `4242 4242 4242 4242` / 任意の将来日 / 任意の CVC / 任意の郵便番号
- 成功すると連結アカウントの `checkout.session.completed` が `stripe listen` 経由で届き、
  `cancellations.status` が `paid` に更新され、`monthly_sales` に加算される。

確認：
```bash
# listen 側に "--> connect checkout.session.completed ... <-- [200]" が出る
# dev サーバ側に "Webhook signature verified successfully" が出る（400 Invalid signature でない）
docker exec cancel-billing-api-local-postgres-local-1 \
  psql -U postgres -d cancel_local -c \
  "SELECT id,status,paid_at FROM cancellations ORDER BY created_at DESC LIMIT 5;"
```

## 決済の前提：連結アカウントのオンボーディング完了

直接課金は連結アカウントが `charges_enabled=true`（オンボーディング完了）でないと通らない。未完了だと
Checkout 画面で **「We can't process payments right now.」** が出る（カードは無関係）。

```bash
# 対象申請の stripe_account_id を確認
docker exec cancel-billing-api-local-postgres-local-1 \
  psql -U postgres -d cancel_local -c \
  "SELECT application_id,status,stripe_account_id FROM applications WHERE deleted_at IS NULL;"

# アカウント状態を確認（charges_enabled を見る）
stripe accounts retrieve acct_xxxxx \
  --api-key "$(grep -E '^\s*STRIPE_SECRET_KEY=' .env | sed -E 's/^[^=]*=//')"
```

`charges_enabled=false` の場合はオンボーディングリンクを発行し、ブラウザで開いて**テストデータ**で完了させる
（テストモードは「テストデータを使用」ボタンで自動入力、本人確認はスキップ可。銀行は routing `1100000`）。
リンクは管理画面の Stripe リンク再送機能、または `stripe.accountLinks.create({ account, type:'account_onboarding', refresh_url, return_url })` で発行する。

> 注意: `applications.stripe_account_status` は作成時に `pending_onboarding` を入れたまま更新されない
> （`processStripeAccountUpdated` は `applications.status` のみ `active` 化する）。完了済みでも
> `pending_onboarding` のままが正常。実態は `stripe accounts retrieve` の `charges_enabled` で判断する。

## URL 上書き（任意・ローカル限定）

webhook / 決済 / 通知メールのリンクのベース URL を `.env` でローカルだけ差し替えられる（未設定なら従来の既定値。
dev/prod は設定しないので不変）。解決ロジックは `src/config.ts`。

| env | 用途 | 既定値 |
|---|---|---|
| `LP_BASE_URL` | Stripe オンボーディング戻り先 / 決済完了ページ | prod=cancel.co.jp / 他=dev.cancel.co.jp |
| `API_BASE_URL` | SMS の支払い短縮リンク `/pay/:id` | api.cancel.co.jp |
| `USER_PORTAL_URL` | 通知メールのログイン導線 / パスワード再設定 | user.cancel.co.jp（再設定の非prod既定は localhost:5173） |
| `ADMIN_URL` | 管理者向け通知メールのリンク | admin.cancel.co.jp |

- **`API_BASE_URL` を設定しても Stripe webhook は飛んでこない**（リンク生成用であり、エンドポイント登録ではない）。
- オンボーディングの `return_url`（`/stripe-success` 等）は **LP のルート**。API トンネルに向けると 404 になるが、
  課金有効化はフォーム完了時点で済むため無害。

## よくあるハマりどころ

| 症状 | 原因 | 対処 |
|---|---|---|
| 決済画面が「We can't process payments right now.」 | 連結アカウントが `charges_enabled=false`（オンボーディング未完了） | オンボーディングをテストデータで完了（上記） |
| 決済成功でも `status` が `paid` にならない | `checkout.session.completed`(Connect) がローカルに届いていない | `stripe listen --forward-connect-to` を起動。`--forward-to` では届かない |
| 届くが `400 Invalid signature` | `STRIPE_WEBHOOK_SECRET` が受信先の鍵と不一致（dev の鍵のまま等） | `stripe listen` が出した `whsec_` を `.env` に設定して再起動 |
| ローカルで本番 Stripe を叩きそう | `.env` に `sk_live_` が入っている | 必ず `sk_test_`。`NODE_ENV` ではガードされない |
| `stripe events resend ... --stripe-account` が権限エラー | 連結アカウント上のエンドポイント設定は不可 | 過去イベントの再送ではなく、新規決済 or `stripe trigger ... --stripe-account acct_xxx` で再現 |

## dev/prod への影響

- ローカルと dev は**同じテストキー＝同一 Stripe アカウント**。webhook は各エンドポイントへ独立配信されるため、
  ローカル用エンドポイント（CLI の一時エンドポイント含む）を足しても **dev の `dev.api.cancel.co.jp` への配信は不変**。
- 同一アカウント共有の副作用として、ローカルの決済イベントは dev にも届くが、dev は自分の Aurora に該当
  session/account が無ければ `No invoice found` で no-op（その逆も同様）。**データは混ざらない**（local=Postgres :5440 / dev=Aurora）。
- `stripe listen` の一時エンドポイントは CLI 終了で消える。dev の Dashboard エンドポイントには触れない。

## 注意（外向き副作用）

実ハンドラで請求が `pending→paid` に遷移すると、**実 Twilio SMS と SES メールが顧客宛に送信される**
（`src/services/webhook.service.ts`）。ローカルでの動作確認時、テスト顧客の電話/メールに実送信される点に注意。
パイプライン（署名検証・ルーティング）だけ確認したい時は、DB の請求に当たらないテストイベント
（`stripe trigger checkout.session.completed --stripe-account acct_xxx`）を使えば副作用は出ない（`No invoice found` で 200）。

## 代替：Cloudflare トンネル等で受ける場合

CLI を使わず公開 URL で受けるなら、Stripe Dashboard → Developers → Webhooks にエンドポイントを追加：

- URL: `https://<tunnel>/webhook/stripe`
- **「Listen to events on Connected accounts」を有効化（重要）**
- イベント: `checkout.session.completed`, `account.updated`
- 発行された署名シークレットを `.env` の `STRIPE_WEBHOOK_SECRET` に設定して `npm run dev` 再起動

トンネル URL は起動ごとに変わり、その都度再登録が必要。**ローカルは Stripe CLI を推奨**。
