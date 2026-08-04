# 認可関連 lesson（実例）

このスキルが防ぐべき、実際に起きた / レビューで検出した認可の不備。

## 1. sibling ルートの `requireAdmin` 付け忘れで状態遷移ロックがバイパスされた（GTSS-842 / #31）

- **事例**: メール認証（`unverified` ステータス新設）で、`updateApplicationStatus`（`PUT /applications/:id/status`）に「`unverified` への/からの遷移を 400 拒否」するガードを追加し「API 直叩きでもロックを突破できない」（REQ-6）と謳った。しかし `POST /applications/:id/approve`（→ `approveApplication`）は **`requireAdmin` も現在ステータス検査も無い**ままで、`unverified` → `approved` へ直行できた。`/status` `/agent-code` `/send-stripe-link` `GET` `DELETE` には `requireAdmin` が付いていたのに、`/approve` `/stripe-account-link` だけ抜けていた（認可欠落自体は既存だが、本機能の安全目標を未達にした）。
- **なぜ起きた**: 「状態遷移ロック = `updateApplicationStatus` にガードを足す」と考え、状態を変える**別経路**（専用ルート `approveApplication`）を見落とした。同一リソースのルート群の認可を**横並びで**確認しなかった。
- **正しい対応**: [checklist.md](./checklist.md) 観点1（ルート認可カバレッジ）＋観点2（状態遷移ロックの多層防御）。リソースの全ルートを grep して認可マトリクスを作り sibling 付け忘れを潰す。状態を変えうる全経路（`grep "status: APPLICATION_STATUS" / .update(...status"`）にサーバ側ガードを置き、ロック対象は全経路で 400/403 をテスト固定する。

## 1b.（反例）認可ガードの欠落は「即バグ」ではない — 公開が設計意図のこともある（GTSS-842 / #31）

- **事例**: 観点1の `/approve` バイパスと**同じ PR・同じ「`requireAdmin` 無し sibling」**だった `POST /applications/:id/stripe-account-link` は、レビューでは（括弧書きで）`requireAdmin` 付与を提案された。しかし cross-file で呼び出し元を追うと、これは LP の `StripeSuccess.jsx` / `StripeRefresh.jsx` が**申込者として無認可で呼ぶ公開エンドポイント**（Stripe オンボーディング再開フロー）だった。`requireAdmin` を付けると LP が壊れる。
- **なぜ据え置きが正解か**: 未認証バイパスの懸念は、未認証申請が approve を経ておらず `stripeAccountId` を持たないため、`regenerateStripeAccountLink` の既存ガード（`!application.stripeAccountId → 400`）で**既に塞がれている**。したがって `/approve` のみロックダウンするのが正解。理由はコードコメントにも明記した。
- **教訓**: 「`requireAdmin` 欠落 = 即バグ」と決めつけない。確定の前に (1) 呼び出し元を grep（LP/本人が無認可で呼ぶ＝公開意図か、admin のみか）、(2) 「バイパス」がリソースの前提条件（ステータス・`stripeAccountId` 等）で既に成立しないか、を裏取りする。公開のまま据え置く場合は**理由をコードコメントに残す**（再誤指摘の防止）。→ [checklist.md](./checklist.md) 観点1 の ⚠️ ブロック。

## 2. spread passthrough な serializer に機微列を足して無認可 GET から漏れた（GTSS-836 / #30）

- **事例**: `serializeApplication` が `{ ...item }` で全列を透過するため、`agentCode`（代理店コード）列を足しただけで `requireAdmin` の無い `GET /applications` / `GET /applications/:id` のレスポンスに乗った。これらの GET は以前から email/phone 等の PII も無認可で返していた。
- **派生（GTSS-842 / #31）**: 同じ serializer 経由で、新設した認証トークン `verificationToken` が**公開 `POST /applications` のレスポンス**に乗り、メール受信なしで self-verify できる状態になった（メール認証の目的を無効化）。`toMatchObject`（部分一致）アサーションのため余剰キー混入をテストが検知できなかった。
- **正しい対応**: [checklist.md](./checklist.md) 観点3（レスポンス露出）。spread passthrough な serializer に機微列を足すときは、それを返す全エンドポイントの認可と露出を確認。公開向けは別 serializer / pick で除外し、非露出アサーション（`not.toHaveProperty`）で固定する。

## 3.（関連）`.passthrough()` 入力の `{ ...input }` 保存によるマスアサインメント（GTSS-842 / #31 で検出）

- **事例**: 入力スキーマが `.passthrough()` で、ハンドラが検証後の生 body を service に渡し、未認証上書き経路が `update(id, { ...applicationData, ... })` を実行。`toRow` が許す制御列（`deletedAt`/`stripeAccountId`/`applicationId` 等）が body から素通りし、未認証窓の間に他人の行を改変できた。
- **正しい対応**: [checklist.md](./checklist.md) 観点4（マスアサインメント）。保存可フィールドのみ pick する builder を使い、制御列を body から採用しない。
