---
issue: 50
date: 2026-07-30
repos:
  - repo: lp
    repoDir: cancel-billing-service-lp
    baseBranch: main
    toBranch: GTSS-887
---

# レビュー結果: #50

## 概要

**Issue:** #50 LP(cancel.co.jp) SEO基本整備: ページ別 title・meta description・canonical・noindex・OGP・sitemap.xml・robots.txt

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| lp | `main` | `GTSS-887` | 2 | 9 |

PR: GO-TODAY-SHAiRE-SALON/cancel-billing-service-lp#11（実装）/ 親リポ #52（docs README REWRITE）

レビュー体制: code-reviewer / lessons-reviewer / codex-reviewer の 3 サブエージェント並列 + メインエージェントによる Step 6.5 再検証。

## 変更ファイル一覧

### lp

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/seo.js` | +161 | -0 | Added |
| `src/App.jsx` | +12 | -3 | Modified |
| `index.html` | +7 | -1 | Modified |
| `public/sitemap.xml` | +15 | -0 | Added |
| `public/robots.txt` | +4 | -0 | Added |
| `src/__tests__/seo.test.jsx` | +277 | -0 | Added |
| `src/__tests__/staticSeoFiles.test.js` | +48 | -0 | Added |
| `src/__tests__/gtm.test.js` | +66 | -0 | Modified |
| `CLAUDE.md` | +9 | -2 | Modified |

## 指摘一覧

### [Code Quality] window.location.search の二重パース（対応済み）

- [x] 対応する → **対応済み（commit `8084f80`）**

**ファイル:** `lp/src/App.jsx:388-394`
**重要度:** Low

**該当コード:**
```jsx
// 変更前（初回実装時）— search の読み取りと typeof ガードが重複
const currentPath = typeof window !== 'undefined' ? window.location.pathname : '/';
const searchParams = typeof window !== 'undefined' ? new URLSearchParams(window.location.search) : new URLSearchParams();
const pageParam = searchParams.get('_page');

const pageKey = resolvePageKey(currentPath, typeof window !== 'undefined' ? window.location.search : '');
```

```jsx
// 変更後（レビュー対応後）— currentSearch へ一度だけ読み取り共用
const currentPath = typeof window !== 'undefined' ? window.location.pathname : '/';
const currentSearch = typeof window !== 'undefined' ? window.location.search : '';
const searchParams = new URLSearchParams(currentSearch);
const pageParam = searchParams.get('_page');

const pageKey = resolvePageKey(currentPath, currentSearch);
```

**問題:** 既に `searchParams` を生成しているのに `resolvePageKey` へ生の `window.location.search` を渡して内部で再パースしており、同一情報の二重パース + typeof ガードの重複があった（挙動上の問題はなし）。
**修正提案 → 対応:** search 文字列を `currentSearch` として一度だけ読み取り共用。修正後 `npm test` 13 files / 131 tests green を再確認し push 済み。

## 総評

- **code-reviewer**: High / Medium なし・Low 2 件（上記）。hooks 配置（早期 return より前・無条件実行・StrictMode 二重実行にも冪等で安全）、resolvePageKey と App.jsx 実分岐の評価順完全一致、DOM 操作の XSS リスクなし（createElement + setAttribute のみ・値はすべて Object.freeze 定数由来）、`<head>` 開始タグ無変更（GTM 注入正規表現の前提維持）、テスト網羅性良好、をそれぞれ実ファイルで裏取り済み。
- **lessons-reviewer**: 違反なし。外部 API モック、`expect.any` 不使用・具体値アサーション、テスト間の head 状態隔離（beforeEach で静的 head 再現）、テスト専用分岐の混入なし、を確認。
- **codex-reviewer**: 指摘なし（6 観点）。resolvePageKey の評価順一致・upsert の高々 1 件保証・noindex ページの og 扱い・sitemap/robots の Issue 整合を再検証済み。別セッション混入なし。
- **メインエージェント再検証（Step 6.5）**: Low #1 は App.jsx:388-394 を直接 Read して裏取りし、その場で修正（テスト green 維持）。Low #2 は Issue の確認事項回答（noindex 方式・dev 運用）と照合しスコープ外の follow-up と判断。

テスト: `npm test` 13 files / 131 tests green（修正後再実行済み）・`npm run lint` 0 errors。人力確認（T-8: dev curl、T-9: dev 実ブラウザ、T-10: リリース後 Search Console）が残タスク。
