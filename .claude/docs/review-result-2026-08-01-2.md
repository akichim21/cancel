---
issue: 59
date: 2026-08-01
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: main
    toBranch: GTSS-890
    pr: GO-TODAY-SHAiRE-SALON/cancel-billing-service-api#44
  - repo: admin
    repoDir: cancel-billing-service-admin
    baseBranch: main
    toBranch: GTSS-890
    pr: GO-TODAY-SHAiRE-SALON/cancel-billing-service-admin#17
---

# レビュー結果: #59

## 概要

**Issue:** #59 fix: サロンボード連携の「連携単位 × ログイン種別」ミスマッチを検出し単位変更を促すエラーを表示（1店舗の会社アカウント検出漏れも厳格化）

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `main` | `GTSS-890` | 2 | 10 |
| admin | `main` | `GTSS-890` | 1 | 8 |

> ローカルの `main` が admin だけ古かったため（`93d4d38` vs `origin/main` `89442b4`）、両リポジトリとも **`origin/main`** をベースに差分を取得した。差分は PR #44（10 files / +796 -88）・PR #17（8 files / +1058 -47）と一致することを確認済み。

**レビュアーによる検証実行:** api の変更テスト 5 ファイルをローカル実行し **171 tests passed** を確認（`salonboard-parser` / `salonboard-shop-verify` / `salonboard-verify-retry` / `salonboard-store` / `salonboard-integration`）。

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/services/salonboard-auth.service.ts` | +129 | -14 | Modified |
| `src/constants/salonboard-messages.ts` | +26 | -0 | Added |
| `src/repositories/shop-integrations.repository.ts` | +26 | -0 | Modified |
| `src/utils/salonboard-parser.ts` | +25 | -0 | Modified |
| `src/__tests__/e2e/salonboard-store.test.js` | +367 | -21 | Modified |
| `src/__tests__/e2e/salonboard-integration.test.js` | +111 | -1 | Modified |
| `src/__tests__/unit/salonboard-shop-verify.test.js` | +58 | -50 | Modified |
| `src/__tests__/unit/salonboard-parser.test.js` | +35 | -0 | Modified |
| `src/__tests__/unit/salonboard-verify-retry.test.js` | +14 | -2 | Modified |
| `src/__tests__/helpers/salonboard.js` | +5 | -0 | Modified |

### admin

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `yarn.lock` | +832 | -31 | Modified |
| `e2e/company-detail-context.spec.ts` | +62 | -0 | Modified |
| `src/components/__tests__/StoreForm.test.tsx` | +52 | -4 | Modified |
| `e2e/salonboard-integration.spec.ts` | +48 | -7 | Modified |
| `src/components/__tests__/SalonboardIntegration.test.tsx` | +42 | -0 | Modified |
| `src/components/StoreForm.tsx` | +9 | -2 | Modified |
| `src/services/ApiService.ts` | +8 | -2 | Modified |
| `src/components/SalonboardIntegration.tsx` | +5 | -1 | Modified |

## T-31（REQ-1(a) の前提検証）の実施結果 — **完了**

レビュー時点で「未実施」だった T-31 を、**実サロンボードへの実ログイン**で検証した（2026-08-01。ID/PW・実店舗ID・実店舗名は非記録）。

| 検証 | 方法 | 結果 |
|---|---|---|
| 単一店舗アカウントは店舗一覧テーブルを持たない | 実アカウントでログインし会社トップ HTML を取得 | ✅ `biyouStoreInfoArea` / `kireiStoreInfoArea` とも**不在**。システムエラー画面＋hidden `STORE_ID` あり → `detectAccountUnit()='shop'` |
| 会社アカウントは店舗一覧テーブルを持つ | 実会社アカウントでログイン | ✅ 両区分のテーブルあり（ヘア13＋キレイ1＝14件）→ `detectAccountUnit()='company'` |
| **配下 1 店舗でも店舗一覧テーブルが 1 行で描画される** | 同じ会社トップの**キレイ区分テーブルが実機で 1 店舗のみ** | ✅ `<thead>` のヘッダ行＋データ行 1 行の完全なテーブルとして描画されていた（`<tr>` 数 = 2） |

**結論: REQ-1(a) の前提は成立する。** 店舗一覧テーブルの描画は区分ごとにリスト内容から生成されており、**件数によるしきい値（2 件未満なら描画しない等）は存在しない**ことを実マークアップで確認した。したがって「配下 1 店舗の会社アカウントでもテーブルが 1 行で描画される」＝厳格化しても新規の店舗単位登録が理不尽に弾かれることはない。**ロールバック条件には該当しない。**

残る限界: 検証できたのは「14 店舗の会社アカウント内の、1 店舗しか持たない区分テーブル」であり、**会社全体の店舗数が 1 のアカウントそのものは未入手**。ただし単一店舗アカウントが会社トップでシステムエラーになるのは**アカウント種別**の違い（1 店舗 1 ログイン）であって店舗数によるものではなく、会社アカウントは常に会社コンテキストを持つため、区分テーブルは同じ経路で描画されると判断できる。

**自動テスト化:** 上記の実マークアップを PII 置換して fixture 化し、回帰テストを追加した（下記「追加した変更」）。

## 追加した変更（レビュー中に実施）

| ファイル | 内容 |
|---|---|
| `api/src/__tests__/fixtures/salonboard/group-top-one-store-company.html`（新規） | 実会社アカウントの会社トップからヘア区分テーブルを除去し、**実在の 1 行キレイ区分テーブル**だけを残した「配下 1 店舗の会社アカウント」fixture。店舗ID → `H000999002` / 店舗名 → `テストサロン キレイ1号店` へ置換済み（実値の残存が 0 件であることを検証済み） |
| `api/src/__tests__/unit/salonboard-parser.test.js` | T-31: 実マークアップで `parseSalons()===1` / `detectAccountUnit()==='company'` / hidden `STORE_ID` と `parseStoreTop` が立たないことを固定。合成 HTML では再現できない `<thead>` ヘッダ行を件数に数えないことも同時に担保 |
| `api/src/__tests__/e2e/salonboard-store.test.js` | T-31: 実マークアップの 1 店舗会社アカウントで `POST /admin/shops` → 400・会社アカウント文言・3 テーブル無変更。裏返しとして救済成立時（`PUT /admin/shops/:id`）は 200・採用されることも固定 |

**テスト結果:** api 全体で **87 files / 1150 tests passed**（追加前 1147 → +3）。`npm run typecheck` も通過。

> 変更はコミットしていません（push は PR を更新するため未実施）。

## 指摘一覧

- [x] 対応する

### [Code Quality] 検証成功 → 認証情報変更 → 再検証失敗 で、前回取得した外部店舗ID・種別が表示されたまま残る

**ファイル:** `admin/src/components/StoreForm.tsx:98-104` / `admin/src/components/StoreForm.tsx:226`
**重要度:** Medium

**該当コード:**

```tsx
// baseBranch側（変更前）— 検証失敗時の処理
      if (!result.success) {
        // 会社アカウント検出 / ログイン失敗 / 店舗取得不可 などのエラーをそのまま表示する。
        setError(result.error)
        setVerified(false)
        return
      }
      // 単一店舗を自動取得。店舗名・住所が未入力なら自動入力。種別は検証結果を表示に反映する。
      setExternalStoreId(result.shop.externalStoreId)
```

```tsx
// toBranch側（変更後）— コメントは更新されたが、state のクリアは追加されていない
      if (!result.success) {
        // 会社アカウント検出（連携単位ミスマッチ）/ ログイン失敗 / 店舗取得不可 などのエラーを
        // **サーバ文言のまま**表示する（クライアント側の固定文言で上書きしない。GTSS-890 / REQ-3）。
        setError(result.error)
        setVerified(false)
        return
      }
      // 単一店舗を自動取得。店舗名・住所が未入力なら自動入力。種別は検証結果を表示に反映する。
      setExternalStoreId(result.shop.externalStoreId)
      setSalonType(result.shop.salonType ?? null)
```

取得結果の表示条件（変更なし・`StoreForm.tsx:226`）:

```tsx
            {/* 連携済みの場合は外部店舗ID・種別を読み取り表示する（連携の確認用）。 */}
            {(externalStoreId || salonType) && (
              <div className="flex flex-wrap items-center gap-4" data-testid="store-form-detail">
                {externalStoreId && (
                  <div>
                    <span className="block text-sm font-medium text-gray-500">外部店舗ID</span>
```

**問題:**
`store-form-detail` の表示条件は `externalStoreId || salonType` であり **`verified` に依存していない**。検証失敗時に `setVerified(false)` はするが `externalStoreId` / `salonType` はクリアされない。ログインID・パスワードの `onChange`（`:271-274` / `:290-293`）も `setVerified(false)` のみで同様。

そのため店舗**作成**フォームで次の順に操作すると、運営に誤った情報が残り続ける:

1. 単一店舗アカウントで「連携（検証）」→ 成功（`externalStoreId = H000xxx` が表示される）
2. 別のログイン情報に入れ替えて再度「連携（検証）」→ 単位ミスマッチで 400
3. エラー文言は出て保存ボタンも非活性になるが、**手順 1 で取得した外部店舗ID・種別が表示されたまま**

追加された T-21（`StoreForm.test.tsx`）・T-24（`e2e/salonboard-integration.spec.ts`）は「取得結果（外部店舗ID・種別）は表示されない」を検証しているが、いずれも**初回の検証が失敗するケースのみ**のため、この再試行経路を検出できない。保存自体は `canSave` の `verified` 条件で塞がれているためデータ不整合は起きないが、「検証が通った店舗」と誤認させる表示になる。

なお、この state クリア漏れ自体は本 PR で持ち込まれたものではない（既存挙動）。ただし本 PR が「検証失敗時は取得結果を表示しない」というアサートを新規に追加しているため、その主張を実挙動に合わせるか、実挙動を主張に合わせるかの判断が必要。

**修正提案:**
`handleVerify` の失敗分岐（`catch` も含む）で、作成モードでは `setExternalStoreId(null)` / `setSalonType(null)` をクリアする。編集モードは既存連携の表示を保持したいため、「既存連携の値」と「今回の検証結果」を別 state に分けるのが本筋。あわせて「成功 → 認証情報変更 → 単位ミスマッチ失敗 → 詳細欄が消える」ケースの unit テストを追加する。

---

### [Security] テスト fixture・テストコードに**実在の店舗ID・店舗名**がそのまま入っている（PII 規約違反）

**ファイル:** `api/src/__tests__/fixtures/salonboard/group-top.html`（既存）/ `api/src/__tests__/e2e/salonboard-store.test.js`（本 PR で 1 件追加）
**重要度:** Medium（大半は既存だが、本 PR で 1 件増えている）

**問題:**
T-31 の実ログイン検証で取得した実 HTML と、コミット済みの fixture を突き合わせたところ、**実在の店舗ID・店舗名がそのまま残っている**ことが判明した。

| ファイル | 実在店舗ID | 実在店舗名 | 由来 |
|---|---|---|---|
| `fixtures/salonboard/group-top.html` | **14 種** | **14 種** | 既存（GTSS-817 期） |
| `e2e/salonboard-store.test.js` | 2 種 | – | うち **1 種は本 PR で新規追加**（T-13 の `externalStoreId: 'H000764880'`） |
| `e2e/salonboard-integration.test.js` | 2 種 | – | 既存 |

CLAUDE.md の PII 規約は次のとおり定めており、これに違反している。

> サロンボード等の**実 HTML を fixture 化する際は、コミット前に個人情報を必ず別値へ置換**する。対象: … ログイン/管理者ID（`CDxxxxx`）、**店舗ID（`Hxxxxxx`）**、**店舗名** … 置換後に元値が残っていないことを grep で検証する。
> fixture 置換例: ログインID `CD00000`、店舗ID `H000999001`、店舗名 `テストサロン …`

ログインID（`CDxxxxx`）とスタッフ名は正しく置換されているため、**店舗ID・店舗名だけが置換漏れ**している。これらは公開リポジトリではないものの、サロン事業者を特定できる情報であり、規約上は置換対象。

**修正提案:**
1. 本 PR で追加された `salonboard-store.test.js` の実店舗ID 1 件をダミー（`H000999003` 等）へ差し替える。テスト内の値は fixture と独立なので影響範囲は小さい。
2. 既存の `group-top.html` の 14 件は別 Issue として一括置換する（fixture とそれを参照するテストの期待値を同時に書き換える必要があるため、本 PR に混ぜないほうが安全）。
3. `grep -E 'H[0-9]{6,}' src/__tests__/` を CI かレビュー手順に組み込み、実店舗ID の混入を機械的に弾く。

> 本レビューで追加した `group-top-one-store-company.html` は、店舗ID を `H000999002`・店舗名を `テストサロン キレイ1号店` へ置換し、実値の残存が 0 件であることを検証済み。

---

### [Test Coverage] T-8 の後半 2 ケースがステータスコードしか検証しておらず、別原因の 400 でも緑になる

**ファイル:** `api/src/__tests__/e2e/salonboard-store.test.js:491-498`
**重要度:** Medium

**該当コード:**

```js
// toBranch側（新規追加）
    // 同じ会社の別店舗のリンクとしか一致しない（編集対象自身は未連携）。
    const bySibling = await verify('app_1', targetShop.id);
    expect(bySibling.status).toBe(400);
    expect((await bySibling.json()).error).toBe(COMPANY_ACCOUNT_UNIT_LOCKED_MESSAGE); // 連携済みが居るので lock

    // 別会社の店舗 ID を渡しても救済されない（applicationId と一致しないため）。
    const byOtherCompany = await verify('app_1', otherCompanyShop.id);
    expect(byOtherCompany.status).toBe(400);

    // 別 source のリンクとしか一致しない店舗（salonboard のリンクを持たない）。
    const byOtherSource = await verify('app_1', otherSourceShop.id);
    expect(byOtherSource.status).toBe(400);
```

**問題:**
1 ケース目（`bySibling`）はエラー文言まで検証しているのに、後続 2 ケースは `status === 400` のみ。AC-1.4 が担保したいのは「別会社／別 source のリンクでは**救済されない**こと」だが、この形ではログイン失敗・店舗情報取得失敗・別のガードなど**まったく別の原因による 400 でも緑**になり、救済判定を通過していないことを検証できていない（将来 `shopId` の所有者検証を足して別文言を返すようにしても気づけない）。

呼び出しチェーンで裏取り済み: 両ケースとも `shopIntegrationsRepo.findLinkedByApplicationShopSource` が `applicationId` 不一致（別会社）／`source` 不一致（別 source）で `null` を返す → `hasMatchingLinkedShop = false` → `decideShopVerify` が `'company-account'`。`app_1` には `linked=true` の店舗（`連携済み店`）が居るため `unitLocked = true` となり、`bySibling` と同じ `COMPANY_ACCOUNT_UNIT_LOCKED_MESSAGE` が返る。

**修正提案:**
両ケースにも文言アサートを追加する。

```js
    const byOtherCompany = await verify('app_1', otherCompanyShop.id);
    expect(byOtherCompany.status).toBe(400);
    expect((await byOtherCompany.json()).error).toBe(COMPANY_ACCOUNT_UNIT_LOCKED_MESSAGE);

    const byOtherSource = await verify('app_1', otherSourceShop.id);
    expect(byOtherSource.status).toBe(400);
    expect((await byOtherSource.json()).error).toBe(COMPANY_ACCOUNT_UNIT_LOCKED_MESSAGE);
```

---

### [Code Quality] lock 済み会社の「連携なし店舗」に 1 店舗会社アカウントを後付け連携する経路が、実行不能な案内で詰む

**ファイル:** `api/src/services/salonboard-auth.service.ts:363-371, 382-389`（保存経路は `:635-642`）
**重要度:** Medium（実装は REQ-1(b) に忠実でコード側の欠陥ではないが、返す文言が実行不能な案内になっており GTSS-890 の目的そのものを満たさない。Issue の「未解決の質問」と同一事象で、マージ前に運用方針の決定が必要）

**該当コード:**

```ts
// toBranch側（新規追加）
      // 救済（グランドファザリング）は「店舗編集の再検証」かつ「対象店舗自身の連携済みリンク」に限る。
      // 取得できた店舗が 1 件のときしか使わないため、その場合だけ照合する。
      if (context.shopId && salons.length === 1) {
        const link = await shopIntegrationsRepo.findLinkedByApplicationShopSource(
          context.applicationId,
          context.shopId,
          source,
        );
        hasMatchingLinkedShop = !!link && link.externalStoreId === salons[0].externalStoreId;
      }
    ...
    if (decision === 'company-account') {
      return {
        ok: false,
        error: unitLocked ? SHOP_VERIFY_COMPANY_ACCOUNT_UNIT_LOCKED : SHOP_VERIFY_COMPANY_ACCOUNT,
      };
    }
```

**問題:**
すべて既存機能の組合せで到達する経路がある。

1. 会社 C（`unit=shop`）で店舗 A が連携済み → `unitLocked=true`
2. 運営が店舗 B を**連携なし店舗**として作成（`saveSalonboardShop` の `!wantsLink` パス。検証を伴わない）
3. 店舗 B を編集し、B の資格情報（＝**配下 1 店舗の会社アカウント**）を入力
4. B には salonboard リンクが無い → `hasMatchingLinkedShop=false` → `company-account` → `unitLocked=true` なので下段の文言:
   > 会社単位のログイン情報です。ただし店舗単位の連携が確定しているため連携単位を変更できません。**この店舗の店舗単位ログイン情報を入力してください**

B には店舗単位ログインが存在しないため、案内どおりの操作が実行できず B を連携する手段が無い（旧実装では 1 件パスで採用され成功していた経路）。GTSS-890 の目的である「次に何をすべきか分かる文言」が、この分岐だけ満たされない。

**これは Issue 本文の「未解決の質問」で既に挙げられている事象**（「店舗単位で連携確定済みの会社に『1 店舗の会社アカウント』の店舗を後から追加する経路が塞がる」）であり、lock 解除には連携済み店舗の全削除が必要で破壊的なため文言では推奨しない、という判断も記載済み。したがってコードの誤りではなく、**運用手順を決めるべき仕様の穴**として残っている。

**修正提案:**
Issue の未解決の質問として起票者に確認する。運用上このケースを許容しないなら、lock 側の文言に逃げ道（対応不可である旨・運営内エスカレーション先）を含めることを検討する。許容するなら、救済条件を「対象店舗に salonboard リンクが無く、かつその外部店舗 ID が会社内で未使用」まで広げる案がある（ただし REQ-1(b) の「新規作成経路は救済しない」との整合を要検討）。

---

### [Code Quality] `会社単位連携が設定されています。店舗の追加はできません` だけ定数化されずリテラル重複している

**ファイル:** `api/src/services/salonboard-auth.service.ts:380` / `api/src/services/salonboard-auth.service.ts:507`
**重要度:** Low

**該当コード:**

```ts
// toBranch側 :380（本 PR で新規追加。decideShopVerify の company-unit-guard 分岐）
    if (decision === 'company-unit-guard') {
      // 会社単位連携の会社で店舗単位の検証を実行するのは想定外の操作。既存の店舗追加ガードと同じ文言を返す。
      return { ok: false, error: '会社単位連携が設定されています。店舗の追加はできません' };
    }
```

```ts
// toBranch側 :507（既存。saveSalonboardShop の先頭ガード）
  const unit = await getEffectiveUnit(applicationId, source);
  if (unit === 'company') {
    return { ok: false, error: '会社単位連携が設定されています。店舗の追加はできません' };
  }
```

**問題:**
本 PR は `src/constants/salonboard-messages.ts` を「用途は実装内の重複排除のみ」として新設し 4 文言を定数化したのに、`company-unit-guard` 用のこの文言だけハードコードのまま。しかも本 PR の `decideShopVerify` 追加で重複箇所が 1 → 2 に増えている。片方だけ直す事故を招く。

**修正提案:**
他 4 文言と同様に `salonboard-messages.ts` へ `SHOP_VERIFY_COMPANY_UNIT_GUARD` として切り出し、両箇所から参照する。テスト側（`salonboard-store.test.js:558`）が独立リテラルを持つ方針はそのまま維持する。

---

### [Performance] DB だけで確定する `company-unit-guard` を、サロンボードへのログイン完了後に評価している

**ファイル:** `api/src/services/salonboard-auth.service.ts:335-360`
**重要度:** Low

**該当コード:**

```ts
// toBranch側 — login（リトライ込み）が先、DB 解決が後
  const retry = resolveSalonboardVerifyRetry();
  const outcome = await loginWithRetry(loginId, password, {
    maxAttempts: retry.maxAttempts,
    ...
  });
  ...
  try {
    const salons = parseSalons(result.groupTopHtml);

    // ── 判定に必要な DB 事実の解決（GTSS-890 / REQ-1）。会社の指定が無いときは DB を一切参照しない。 ──
    if (context.applicationId) {
      const unitState = await getIntegrationUnit(context.applicationId, source);
```

**問題:**
`company-unit-guard` は `applicationId` と DB だけで確定でき、サロンボードへのネットワークアクセスを必要としない。現状は既定 `maxAttempts=8` の `loginWithRetry` を先に実行するため、会社単位運用が確定している会社に対して:

- API GW 29s / Lambda 30s の同期経路でリトライ予算を丸ごと浪費してから 400 を返す
- 使う予定のない資格情報をサロンボードへ実送信する

ただし影響は限定的で、`saveSalonboardShop:505-508` / `updateShop:605,617-619` は `verifySalonboardShopLogin` を呼ぶ**前**に自前の会社単位ガードで弾いている。この経路が問題になるのは `POST /admin/salonboard/shop-verify` の単体検証のみ。

副次的に、`saveSalonboardShop` / `updateShop` は `getEffectiveUnit` を呼んだ直後に `verifySalonboardShopLogin` 内で `getIntegrationUnit`（= `getEffectiveUnit` + `existsLinked` + `anyLinked`）を再度引くため、Data API 経路で 2〜4 ラウンドトリップ増えている。

**修正提案:**
`context.applicationId` があるときの unit 解決を `loginWithRetry` の前へ前倒しして fail-fast にする。ただし「ID/PW 誤り」との文言優先順位が変わるため、どちらを先に案内すべきかは要判断（現状は「ログインできませんでした」が優先）。あわせて `context` に解決済み unit を渡せるようにして二重取得を解消する。

---

### [Code Quality] Issue と無関係な `yarn.lock` の +832/-31 が PR に混入している

**ファイル:** `admin/yarn.lock`
**重要度:** Low

**問題:**
`package.json` は無変更、`package-lock.json` も無変更なのに `yarn.lock` だけが +832/-31 で再生成されている。中身は GTSS-859 で導入された ESLint 系の依存（`@eslint/config-array`、`@eslint-community/*`、`typescript-eslint` 等）の追記が大半で、本 Issue と関係がない。

admin の CI/デプロイは `npm ci`（`buildspec.yml:29` / `.github/workflows/ci.yml:36,59`）＋ `package-lock.json` を使うためビルド結果には影響しないが、

- レビュー差分の 8 ファイル中 1 ファイル・行数の 8 割弱をロックファイルが占め、実質的な変更が埋もれる
- `package-lock.json` と `yarn.lock` の依存グラフが乖離したまま残る（Yarn を使った場合だけ別バージョンになる）

**修正提案:**
本 PR からは `yarn.lock` の差分を落とす（`git checkout origin/main -- yarn.lock`）。ロックファイルの同期が必要なら、依存差分を単独でレビューできる別 PR に切り出す。そもそも `npm ci` 運用なら `yarn.lock` の追跡自体をやめる選択肢もある。

---

### [Test Coverage] Playwright の入力欄・「検証」ボタンの locator が panel にスコープされていない

**ファイル:** `admin/e2e/company-detail-context.spec.ts:192-194` / `admin/e2e/company-detail-context.spec.ts:219-221`
**重要度:** Low

**該当コード:**

```ts
// toBranch側（新規追加・T-25）
    const panel = page.getByTestId('salonboard-integration');
    await expect(panel).toBeVisible();

    await page.getByLabel('ログインID').fill('CD00000');          // ← panel スコープでない
    await page.getByLabel('パスワード').fill('single-store-pw');   // ← panel スコープでない
    await page.getByRole('button', { name: '検証' }).click();      // ← panel スコープでない

    // 文言はパネル内のエラー表示領域にスコープを絞って検証する。
    await expect(panel.getByRole('alert')).toHaveText(UNIT_MISMATCH_MESSAGE);
```

**問題:**
直前に `panel` を取得しているのに、入力とクリックだけ `page.` 起点のまま（`alert` の検証は panel スコープ済み）。会社詳細ページは店舗タブ側の `StoreForm` にも同じ「ログインID」「パスワード」ラベルと連携ボタンを持つ。

今回の fixture は `shops: []` かつ `StoreForm` はモーダルのため**現時点では strict mode 違反にならない**（同ファイル `:156-158` の既存テストも同じ書き方で、新規の逸脱ではない）。ただし `.claude/skills/playwright/lesson.md` は「同ラベルの要素が増えても壊れないよう先に container スコープにする」を必須としており、`panel` 変数が手元にある以上ここは揃えられる。

**修正提案:**
`panel.getByLabel('ログインID')` / `panel.getByLabel('パスワード')` / `panel.getByRole('button', { name: '検証' })` に置換する（T-25・T-27 の 2 か所）。

---

### [Test Coverage] 保存経路（`PUT /admin/shops/:id`）と `shopId` 単独指定の回帰が固定されていない

**ファイル:** `api/src/__tests__/e2e/salonboard-store.test.js`
**重要度:** Low

**問題:**
本 PR で挙動が変わった経路のうち、次の 2 つが自動テストで固定されていない。

1. **PUT で「リンクの無い店舗／`linked=false` の店舗」へ初回連携付与**（＝上記「lock 済み会社で詰む」経路）。旧実装では 1 件パスで成功していた経路が、本 PR で 400 になる。現状 T-4 は POST（`/admin/shops`）、T-6 は PUT だが「外部店舗 ID 不一致」のみ、T-7 は `linked=false` だが `shop-verify` エンドポイント経由で、**PUT + リンク無し**の組合せが無い。実装上は `updateShop:635-642` の委譲で塞がっていることを読んで確認済みだが、本 PR の振る舞い変更点そのものなので回帰テストの価値が高い。
2. **`applicationId` 無し + `shopId` のみ**の検証リクエスト。`verifySalonboardShopLogin` は `if (context.applicationId)` で DB 解決全体をガードしているため、`shopId` だけでは救済されず未確定側の文言になる。T-10 は「両方無し」のみで、この組合せ（クライアント実装ミス・API 直叩き）は未固定。

**修正提案:**
e2e を 2 本追加する。

- `PUT /admin/shops/:id` にリンク無し店舗 + 1 店舗会社アカウントの資格情報 → 400 かつ `shop_integrations` / `external_integrations` が不変であることをアサート
- `POST /admin/salonboard/shop-verify` に `shopId` のみ（`applicationId` 無し）+ 店舗 1 件 → 400・未確定側の文言

---

### [Test Coverage] テスト ID（T-N）が同一ファイル内で別 Issue のものと重複している

**ファイル:** `api/src/__tests__/e2e/salonboard-store.test.js` / `admin/e2e/company-detail-context.spec.ts`
**重要度:** Low

**該当箇所:**

| ファイル | 新（GTSS-890） | 既存（別 Issue・同一ファイル） |
|---|---|---|
| `api/src/__tests__/e2e/salonboard-store.test.js` | `:155` T-11 / `:220` T-12 | `:737` T-11（unit=shop 既定）/ `:759` T-12（unitLocked） |
| `admin/e2e/company-detail-context.spec.ts` | `:205` `(T-27)` 単位切替 | `:59` `(T-27)` 取り込み実行履歴 |
| `api/src/__tests__/unit/salonboard-shop-verify.test.js` | `:342` describe「decideShopVerify（T-3）」 | `:261` describe「住所スクレイピング（REQ-2 / T-3,4,8）」 |

**問題:**
`.claude/lessons.md`「issue-start完了前にテスト一覧を全チェックする」は、完了前チェックの手段として「各 T-N のテスト ID を `grep` で検索し、未実装のテスト ID があれば実装する」を定めている。同一ファイル内で T-N が二重に使われていると、`grep 'T-11'` がどちらの Issue のテストにヒットしたのか判別できず、この機械的チェックが成立しなくなる。

**修正提案:**
テストタイトルの ID に Issue プレフィックスを付ける（`(AC-1.5 / GTSS-890 T-11)`）。AC 番号は既にコメントに併記されているため、タイトル側を AC 主体に寄せるのが低コスト。

---

### [Codex] `updateShop` の会社単位ガードが REQ-1(a) 評価順 1 と別文言で、かつ当該経路のテストが無い

**ファイル:** `api/src/services/salonboard-auth.service.ts:617-619`
**重要度:** Low（既存挙動・本 PR では未変更）

**該当コード:**

```ts
// baseBranch / toBranch 共通（本 PR では変更していない）
  // 会社単位連携でも店舗マスタの名称・住所は編集できる（運営の手当て）。ただし連携情報の変更（再連携・
  // 初回連携付与）は会社単位では行わせない（連携はアプリ単位の会社認証情報で一括管理されるため）。
  if (unit === 'company' && wantsLink) {
    return { ok: false, error: '会社単位連携では連携情報は変更できません。名称・住所のみ編集できます' };
  }
```

**問題:**
REQ-1(a) 評価順 1 は「実効的な連携単位が会社単位である場合 → 『会社単位連携が設定されています。店舗の追加はできません』を返す」と定めており、`decideShopVerify` の `'company-unit-guard'` はそのとおり実装されている。しかし `updateShop`（`PUT /admin/shops/:id`）では `:617` の**既存ガードが先に発火**するため `verifySalonboardShopLogin` に到達せず、別文言が返る。

- 実害は小さい: どちらのガードでも「会社アカウントです / 単位を変更してください」という**単位ミスマッチの文言は返らない**ため、REQ-1(a) の意図（ミスマッチ文言を出さない）は満たされている。編集経路では「店舗の追加はできません」より既存文言のほうが実態に合っている。
- ただし本 PR で追加された評価順 1 の e2e は `/admin/salonboard/shop-verify` のみで、`PUT /admin/shops/:id` を会社単位設定下で叩く経路は**テストが存在しない**（`grep '会社単位連携では連携情報は変更できません' src/__tests__/` → 0 件）。

**修正提案:**
文言はこのままでよいと判断するなら、Issue 本文 / `docs/tech/salonboard-import.md` の評価順の記述に「保存経路（`updateShop`）では先行する既存ガードが別文言を返す」旨を注記して、仕様と実装の食い違いを残さない。あわせて `PUT /admin/shops/:id` を会社単位設定下で認証情報付きで叩く e2e を 1 本追加すると、この既存ガードの回帰も押さえられる。

## 総評

**実装品質は高い。** 特に評価できる点:

- **判定と DB 参照の分離**が徹底されている。`decideShopVerify` を `{ salonCount, effectiveUnit, hasMatchingLinkedShop }` だけを取る純粋関数に切り出したことで、REQ-1(a) の 4 分岐の評価順が一目で読め、`salonboard-shop-verify.test.js` の「DB 非依存の unit ファイル」という方針も壊れていない。組合せ網羅（件数 0/1/2/14 × 実効単位 × 一致リンク有無）も unit 側に置けている。
- **救済（グランドファザリング）の照合範囲が正しく絞られている。** `findLinkedByApplicationShopSource` は `applicationId` + `shopId` + `source` + `linked=true` の 4 条件すべてを `and()` に入れており、別会社・別 source・別店舗・未連携のいずれでもヒットしない。既存 `findByApplicationSourceStore`（`linked` 非条件）を流用しなかった判断は妥当。
- **マスアサインメント対策が要件どおり。** `saveSalonboardShop` は `applicationId` のみ（`shopId` を渡さない＝救済対象外）、`updateShop` は `existing.applicationId` とパスの `id` を渡しており、body の識別子は救済判定に一切使っていない。body から識別子を受けるのは保存を伴わない `/shop-verify` のみで、こちらも `requireAdmin` 配下。
- **REQ-2(b) の判定不能分岐が潰れていない。** `detectAccountUnit` は「店舗一覧 ≥1 → company」を最優先にし、`extractHiddenStoreId` / `parseStoreTop` の OR で 2 トランスポートを吸収、いずれも取れなければ `null` を返して従来文言へ倒す。会社アカウント fixture（`group-top.html`）が `STORE_ID value=""` かつ `sc_data storeid` / `data-store-id` を持たないことを実 fixture で確認済みで、店舗一覧のパースが壊れた場合でも「店舗単位へ変更してください」と誤案内する経路は無い。
- **文言定数をテストから import していない**方針が守られている（`grep 'salonboard-messages' src/__tests__/` → 0 件）。既存テストの期待値反転も `.toContain('会社アカウント')` → `.toBe(定数)` へ**強化**されており、実装に合わせて緩めた形跡は無い。#28 の住所スクレイピング担保（`enterStore` / `enterKireiStore` → プレビュー取得の順序を `calls.order` で固定）も削除ではなく救済成立ケースの e2e へ移設されて維持され、AC-9 の空名ガードも新テストで保持されている。
- **検証失敗時の副作用なし。** `saveSalonboardIntegration:154-157` / `saveSalonboardShop:540-542` / `updateShop:640-642` はいずれも `getDb().transaction` の前に return しており、認証情報・店舗・リンク・`external_integration_settings` のいずれも不変。T-18 / T-4 が DB 側からも固定している。
- **認可・PII**: `/admin/salonboard/*` と `/admin/shops/*` の sibling ルート全 9 本に `requireAdmin` が付いており付け忘れは無い。エラー文言 4 種にログインID・パスワード・店舗ID・店舗名は含まれず、レスポンスへの機微フィールドの新規露出も無い。

**テスト:** api の変更テスト 5 ファイルをレビュアー側でも実行し **171 passed** を確認した。

**マージ前の判断事項:**

**T-31 は本レビューで実施し、REQ-1(a) の前提が成立することを実マークアップで確認した**（冒頭の「T-31 の実施結果」参照）。当初の最大リスクだった「前提が崩れて新規の店舗単位登録が理不尽に弾かれる」懸念は解消され、ロールバック条件には該当しない。回帰テストも追加済み。

残る判断事項は 2 点。

1. 「lock 済み会社の連携なし店舗に 1 店舗会社アカウントを後付け連携する経路が詰む」は Issue の未解決の質問と同一事象であり、**マージ前に運用手順を決めておく**のが望ましい。
2. テスト資産の**実店舗ID・店舗名の置換漏れ**（PII 規約違反）。本 PR 起因の 1 件は本 PR で、既存 16 件は別 Issue で対応する。

**指摘の優先度:**
- Medium 4 件。うち「StoreForm の state クリア漏れ」「T-8 の弱いアサート」「PII 置換漏れ（本 PR 起因の 1 件）」は本 PR で対応推奨。「lock 済み会社で詰む」はコード修正ではなく**運用方針の決定**が先。
- Low 6 件のうち `yarn.lock` の差分落としと文言定数化はコストが低いので同時に。残りはフォローアップでも可。
