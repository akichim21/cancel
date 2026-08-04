---
issue: 51
date: 2026-07-30
repos:
  - repo: lp
    repoDir: cancel-billing-service-lp
    baseBranch: main
    toBranch: GTSS-883
---

# レビュー結果: #51

## 概要

**Issue:** #51 [GTSS-883] feat(lp): 申込送信成功時に「認証メール送信のご案内」ページ /verify-email-sent へ遷移する（成功時ダイアログ・フォーム直下カード廃止 / noindex限定適用）

**PR:** GO-TODAY-SHAiRE-SALON/cancel-billing-service-lp#12

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| lp | `main` | `GTSS-883` | 2 | 12 |

レビュー実施: code-reviewer / lessons-reviewer / codex-reviewer（req-completeness-checker は Pre-PR で実施済み・指摘なし）

## 変更ファイル一覧

### lp

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/components/VerifyEmailSent.jsx` | +143 | -0 | Added |
| `src/components/SiteHeader.jsx` | +28 | -0 | Added |
| `src/components/SiteFooter.jsx` | +55 | -0 | Added |
| `src/utils/navigation.js` | +11 | -0 | Added |
| `src/utils/__tests__/navigation.test.js` | +40 | -0 | Added |
| `src/components/__tests__/VerifyEmailSent.test.jsx` | +99 | -0 | Added |
| `src/App.jsx` | +21 | -100 | Modified |
| `src/__tests__/applicationForm.test.jsx` | +103 | -9 | Modified |
| `src/__tests__/routing.test.jsx` | +31 | -0 | Modified |
| `src/__tests__/agentCodeForm.test.jsx` | +19 | -5 | Modified |
| `src/__tests__/birthDate.test.jsx` | +16 | -4 | Modified |
| `CLAUDE.md` | +11 | -2 | Modified |

## 指摘一覧

- [x] 対応する

### [Codex] robots meta の noindex 検証が先頭1件しか見ない

**ファイル:** `lp/src/__tests__/routing.test.jsx:15`
**重要度:** Low
**状態:** ✅ 対応済み（commit `4216331`・PR へ push 済み）

**該当コード:**
```javascript
// toBranch側（変更前）— querySelector で先頭1件のみ・case-sensitive
const expectNoNoindex = () => {
  const robots = document.head.querySelector('meta[name="robots"]');
  expect(robots?.getAttribute('content') ?? '').not.toMatch(/noindex/);
};
```

```javascript
// toBranch側（対応後）— 全件・大文字小文字非依存
const expectNoNoindex = () => {
  const robots = document.head.querySelectorAll('meta[name="robots"]');
  for (const meta of robots) {
    expect(meta.getAttribute('content') ?? '').not.toMatch(/noindex/i);
  }
};
```

**問題:** テストコメントは「将来 robots meta を追加しても壊れない検証」と謳うが、`querySelector`（先頭1件）検査のため、将来サイト共通の robots meta が先頭に追加されると、末尾へ漏れた noindex を見逃す。現状は静的 robots meta が存在しないため実害なし（LP SEO 整備の #50 / GTSS-887 が並行しており、近い将来に現実化しうる）。
**修正提案:** `querySelectorAll` で全件検査＋`/noindex/i`。`/verify-email-sent` 側も「全件のうちいずれかが `noindex, nofollow` を持つ」検証へ。→ 適用し、81 テスト green を確認・push 済み。

---

- [ ] 対応する（見送り: Issue の設計どおりのため）

### [Code Quality] 共通ヘッダー/フッターのナビリンクが、クエリ付き `/` 滞在時に full reload になる

**ファイル:** `lp/src/components/SiteHeader.jsx:14-18` / `lp/src/components/SiteFooter.jsx:27-31`
**重要度:** Low

**問題:** リンクを `#features` → `/#features` に統一したため、`/?agent=topad` 等クエリ付きで LP に滞在中は、ナビクリックがアンカージャンプではなくページ再読込（クエリ消失）になる。代理店コードはマウント時に localStorage へ first-touch 保存済みのため**機能影響はない**（agentCodeForm.test.jsx T-2 で担保）。
**見送り理由:** `/#features` 形式への統一は Issue #51 REQ-1 のファイル変更一覧の指定どおり。機能影響がなく、`pathname` 条件分岐の追加は共通コンポーネントを複雑化するため見送り。

---

- [ ] 対応する（見送り: 既存パターン踏襲・リファクタは別 Issue 向き）

### [Code Quality] SiteHeader の CTA が Button プリミティブのクラス文字列を複製

**ファイル:** `lp/src/components/SiteHeader.jsx:20-24`
**重要度:** Low

**問題:** App.jsx 内の `Button` プリミティブ（App.jsx:197-208）のクラス文字列を生 `<button>` にコピーしており、将来の Button スタイル変更に追従漏れしうる。また `<a><button>` は HTML 仕様違反（旧ヘッダーからの既存パターン踏襲で回帰ではない）。
**見送り理由:** 見た目不変（マークアップ移動のみ）が本 Issue の要件。`Button` の `src/components/ui/` への抽出と `<a>` スタイル直付け化はリファクタとして別途。

---

- [ ] 対応する（見送り: Issue の技術的考慮事項で許容済み）

### [Code Quality] 遷移開始〜ページアンロード完了までの一瞬、送信ボタンが再活性化して見える

**ファイル:** `lp/src/App.jsx:557-563`
**重要度:** Low

**問題:** `goToVerifyEmailSent()` 後に onSubmit が resolve すると `isSubmitting` が false に戻り、新ページ読込完了まで空フォーム＋有効ボタンが一瞬見える。reset() 済みのため再クリックしてもバリデーションで止まり、二重 POST は構造的に不可能（T-11 で担保）。
**見送り理由:** Issue #51「技術的な考慮事項」で明示的に許容済み（万一再クリックでも未認証上書き＋再送・201 で実害なし）。

---

- [ ] 対応する（スコープ外: 別 Issue 候補）

### [Code Quality] `/verify-email`（認証結果ページ）にも noindex / document.title の手当てがない

**ファイル:** `lp/src/components/EmailVerify.jsx`
**重要度:** Low

**問題:** 同じくトランザクショナルな認証結果ページには noindex・タイトル設定がない。
**見送り理由:** Issue #51 のスコープ境界（noindex は新設するご案内ページのみ・LP 全体の SEO 整備は別 Issue で検討中）どおり。SEO 整備（#50 / GTSS-887）側で `/verify-email` への適用を検討するとよい。

## 不採用（精査で破棄した指摘）

- **[Codex]「navigation.test.js が jsdom 29 で TypeError になり CI が全落ちする」** — 実環境（worktree・jsdom 29.1.1・vitest 2.1.9）で `npx vitest run` 全 green を実行確認済みのため事実誤認として破棄。vitest の jsdom 環境では `window.location` プロパティ自体は configurable であり、テストはそれを差し替えて descriptor を復元する実装（素の jsdom との挙動混同と判断）。

## 再評価（2026-07-30 /pr-review-respond）

未チェック 4 件を「対応した方が良いか」の観点で個別に再評価した結果、**全件見送りを維持**（追加コミットなし）。

1. **ナビの full reload**: `/#features` 統一は Issue #51 のファイル変更一覧で明示指定。#50 でも「LP はページ間リンクがすべて通常遷移・クライアントサイド遷移は存在しない」ことが前提化されており、pathname 分岐の追加は設計に反する
2. **Button クラス複製 / `<a><button>`**: 同パターンはヒーロー CTA（App.jsx:657, 663）にも存在する LP 全体の既存パターン。SiteHeader だけ直すと不整合が増えるため、`ui/Button` 抽出とセットの別リファクタが正
3. **送信ボタン一瞬再活性**: Issue「技術的な考慮事項」で明示許容済み。逆方向の修正（成功後 isSubmitting 維持）は遷移失敗時にボタンが固まる副作用があり改悪リスク
4. **`/verify-email` の noindex**: **#50 REQ-4 の noindex 対象一覧に `/verify-email` が明記され、GTSS-887 側で T-3 Vitest（`seo.test.jsx`）まで実装済み**。本ブランチで先行対応すると #50 と確実に競合するため対応しないのが正

再評価後も `npx vitest run` 13 files / 81 tests green。コード変更なしのため codex 再レビュー・commit/push は対象なし。

## 総評

High / Medium の指摘なし、ブロッカーなし。lessons 照合も違反なし。

- **仕様適合**: 成功時のみ遷移・409/500/ネットワーク/バリデーション NG の非遷移・固定パス（PII/申請ID/代理店コード不含）・noindex 限定適用・reset() 維持・二重送信防止の全要件が実装・テストともに確認された
- **セキュリティ**: 新規ログ出力なし、URL への PII 露出なし、noindex の他ルート漏れは全ルートで自動検証。API 差分なしのため authz 観点は対象外
- **テスト**: Vitest 13 files / 81 tests green（レビュー対応後も green）。AC→テスト対応が網羅的
- 対応済み1件（noindex 検証強化）を push 済み。見送り4件はいずれも Low で、Issue の設計・スコープ判断と整合
- **並行 Issue への注意**: #50（GTSS-887・LP SEO 整備）が同じ LP の meta/title 周りを触っており、マージ順によっては競合・noindex 方式のすり合わせが必要になりうる
