# 認可チェックリスト（実装時・レビュー時）

対象: `cancel-billing-service-api`（Hono ルート / handler / service）。認可ミドルウェアは
[src/middleware/auth.ts](../../../cancel-billing-service-api/src/middleware/auth.ts) の
`requireAdmin(event, corsHeaders)` / `requireAuth(event, corsHeaders)`。ルート登録は `src/handlers/*.handler.ts`。

---

## 観点1: ルート認可カバレッジ（sibling 付け忘れを潰す）

**原則**: 破壊的（作成/更新/削除）・状態変更・PII を返すルートは、認可ガードを**明示**する（意図的に公開なら、その旨をコメントで明記）。

### 実装時
- 新規/改修ルートを登録したら、**同一リソースの全ルートを 1 箇所で見比べて認可を揃える**。1 つだけ付け忘れない。
  - 例（applications）: `/status` `/agent-code` `/send-stripe-link` `GET` `DELETE` には `requireAdmin` が付く（運営専用）。一方 `/approve` `/stripe-account-link` も「同じ**判断プロセス**」にかけるが、結論は同じとは限らない（下記⚠️）。
- Hono の標準パターン: ハンドラ先頭で `const adminCheck = requireAdmin(buildEvent(c), corsHeaders); if (adminCheck) return ...;`。これが**無い**ルートは公開＝意図的か確認。

> ### ⚠️ `requireAdmin` を足す前に、必ず呼び出し元を cross-file で追う（「欠落 = 即バグ」ではない）
>
> 認可ガードの欠落は**設計意図の公開エンドポイント**であることがある。盲目的に `requireAdmin` を足すと正規フローを壊す。確定の前に必ず:
>
> 1. **呼び出し元を grep する**（フロント横断）。`grep -rn "<route-path>" cancel-billing-service-lp cancel-billing-service cancel-billing-service-admin`
>    - 呼び出し元が **LP / サロンポータルの申込者・本人**（無認可で `fetch`、`Authorization` ヘッダ無し）なら、それは公開が前提のエンドポイント。`requireAdmin` を足すとフローが壊れる。
>    - 呼び出し元が **admin のみ**なら `requireAdmin` 付与が妥当。
> 2. **「バイパス」懸念が別ガードで既に塞がれていないか確認する**。リソースの前提条件（例: `stripeAccountId` 未作成 → 400、ステータス前提）で、攻撃シナリオが既に成立しないことがある。
> 3. 公開のままにする場合は、**理由をコードコメントに明記**する（「LP の◯◯が無認可で呼ぶ公開エンドポイント。△△ガードで××は塞がれている」）。レビュアー/将来の自分が再び「認可漏れでは？」と誤指摘するのを防ぐ。
>
> **実例（GTSS-842）**: `/approve` と `/stripe-account-link` はどちらも `requireAdmin` 無しの sibling だったが、対応は分かれた。
> - `/approve`（`approveApplication`）→ **ロックダウン**: 呼び出し元は admin 操作で、未認証 → approved の越権が成立した。`requireAdmin` ＋ ステータスガードを付与。
> - `/stripe-account-link`（`regenerateStripeAccountLink`）→ **公開のまま据え置き**: LP の `StripeSuccess.jsx` / `StripeRefresh.jsx` が申込者として無認可で呼ぶオンボーディング再開フロー。`requireAdmin` を付けると LP が壊れる。未認証バイパス懸念は、未認証申請が approve 未経由で `stripeAccountId` を持たず、既存ガード `!application.stripeAccountId → 400` で既に塞がれている。理由はコードコメントに明記した。

### レビュー時（grep で認可マトリクスを作る）
```bash
cd cancel-billing-service-api
# 変更されたリソースの handler で、ルートと requireAdmin/requireAuth を並べて見る
grep -nE "app\.(get|post|put|delete|patch)\(|requireAdmin|requireAuth" src/handlers/<resource>.handler.ts
```
- ルート一覧に対し「ガード有 / 無」を表にし、**破壊的・状態変更・PII 返却なのにガード無し**の行を探す。
- 特に「sibling ルートの片方だけガード有り」は付け忘れの強いシグナル。

---

## 観点2: 状態遷移ロックの多層防御（UI で隠す ≠ ロック）

**原則**: あるステータス（例: `unverified`）への/からの遷移を禁止するなら、**状態を変えうる全経路**にサーバ側ガードを置く。UI でボタンを出さないのは UX であってロックではない。

### 全経路の洗い出し（実装時もレビュー時も）
状態を変える経路は `/status` だけではない。以下を grep して全て塞ぐ:
```bash
# applications の status を書き換える箇所を全列挙
grep -rnE "status:\s*APPLICATION_STATUS|\.update\(.*status|updateStatusIfIn" src/services src/repositories
```
- 専用ルート（`/approve` → `approveApplication`、`/reject` 等）が**現在ステータスを検査せず**遷移していないか。
- webhook（`account.updated` 等）のゲート条件に新ステータスが想定外に通らないか。
- 「`updateApplicationStatus` にガードを入れたから API 直叩きロック達成」と書いてあっても、**別ルートが同じ遷移を別関数で行っていればロックは未達**。

### テストで固定
- ロック対象ルートは**全経路**で 400/403 を返すことを統合テストで固定する（`/status` だけでなく `/approve` 等も）。

---

## 観点3: レスポンス露出（serializer の機微フィールド漏洩）

**原則**: 「画面に出さない」だけでは API レスポンスの漏洩は塞げない。serializer / repository が全列を透過する設計だと、列を足すだけで漏れる。

### チェック
- spread passthrough な serializer（`{ ...item }`）/ `getTableColumns` 由来の全列出し入れを使うエンティティに**機微列（トークン・暗号 blob・PII・内部 ID）を足す**ときは、それを返す**全エンドポイント**の認可と露出を確認する。
- 露出制御の手段:
  - (a) エンドポイントに `requireAdmin`/`requireAuth` を付ける、
  - (b) 公開／サロン向けは**別 serializer または pick** で機微列を除外する。
- **特に公開（無認可）エンドポイントのレスポンス**（例: `POST /applications`）に、認証トークン等を絶対に乗せない。トークンが乗ると、メール受信なしで self-verify できる等、認証の意味が無効化される。

### テストで固定
- 非 admin / 未認証応答に機微フィールドが**出ない**こと（`expect(body).not.toHaveProperty('verificationToken')` 等）。`toMatchObject`（部分一致）だけでは余剰キー混入を検知できないので、不在アサーションを明示する。
- admin 応答には出る（必要なら）/ 非 admin は 401/403、を両方固定。

---

## 観点4: マスアサインメント（入力の allow-list）

**原則**: ユーザー入力を `{ ...input }` でそのまま保存しない。保存可フィールドのみ pick する。

### チェック
- 入力スキーマが `.passthrough()`（未知キーを落とさない）で、ハンドラが**検証後に生 body** を service へ渡していないか。
- `repository.update(id, { ...input, ... })` / `create({ ...input })` で、`toRow` が許す DB 列（`applicationId`/`status`/`deletedAt`/`stripeAccountId`/`createdAt`/トークン列）が body から素通りしないか。
  - 特に**既存行の UPDATE**（上書き経路）は、他人の行の制御列を書き換えられる越権になり得る。
- 対策: LP 入力等から保存可フィールド（`partnerName`/`representativeName`/`birthDate`/`phone`/`entityType`/`agentCode` 等）のみ明示 pick する builder を、新規・上書き双方で使う。制御列は body から採用しない。

### テストで固定
- 制御列を body に入れた POST/PUT が、その列を**書き換えない**ことを固定する。

---

## まとめ: 提出/承認前の最終確認

- [ ] 変更したリソースの全ルートに認可の意図が明示されている（sibling 付け忘れ無し）
- [ ] 状態遷移ロックは全経路（専用ルート・webhook 含む）にサーバ側ガードがある
- [ ] 機微列がレスポンスに乗らない（公開エンドポイントは特に）。不在アサーションをテストで固定
- [ ] 入力は allow-list で保存。制御列を body から採用しない
