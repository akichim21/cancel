# 受け入れ条件の書き方

EARS形式を参考ガイドとして記載する。各ACの直下にインデントしたチェックボックスでテスト項目を配置し、ACとテストの1:Nマッピングを明示する。

## 必須ルール

- 各ACに紐づくテスト項目（Jest / Vitest / Playwright / 人力テスト）をACの直下にチェックボックスで記載すること
- **フロント（サロンポータル / 管理画面 / LP）の画面表示・操作に関するACには、必ず Playwright または人力テストを1つ以上含めること**
- **API（Express/Lambda）のロジックに関するACには、必ず Jest（unit または handler 統合）を1つ以上含めること**
- API の Jest だけでは画面の結合テストとみなさない
- 人力テストとした場合は、なぜ自動化できないか理由を明記すること
- 各テスト項目は自動テスト一覧の `T-N` を参照し、双方向でマッピングを追えるようにすること
- ACに紐づくテスト項目が不要な場合（例: 「既存テストが壊れないこと」等の確認系AC）は、テスト項目なしでよい

## アプリ別テストの使い分け

| 対象アプリ | テストツール | 備考 |
|-----------|----------|------|
| cancel-billing-service-api | Jest | unit + ハンドラ統合（HTTPレベル）E2E相当 |
| cancel-billing-service | Vitest(未整備) / Playwright | サロンポータル Web UI E2E |
| cancel-billing-service-admin | Vitest(未整備) / Playwright | 管理画面 Web UI E2E |
| cancel-billing-service-lp | Vitest(未整備) / Playwright | LP・申請フォーム Web UI E2E |

## テンプレート

```markdown
## 受け入れ条件 (Acceptance Criteria)

> **書き方ガイド（EARS形式参考）**: 条件→主語→動作の構造を意識すると、テスト可能な受け入れ条件になります。
> - Event-Driven: When [event], the [system] shall [response]
> - State-Driven: While [precondition], the [system] shall [response]
> - Unwanted: If [trigger], the [system] shall [response]
> - Ubiquitous: The [system] shall [response]

- [ ] AC-1.1: [画面表示系の条件] → [期待動作] (REQ-1) [サロンポータル]
  - [ ] T-1 Jest: [API ハンドラのテストシナリオ]
  - [ ] T-3 Playwright: [テストシナリオ] ← フロント画面表示ACなので必須
- [ ] AC-1.2: [条件] → [期待動作] (REQ-1) [管理画面]
  - [ ] T-2 Jest: [テストシナリオ]
  - [ ] T-4 Playwright: [テストシナリオ] ← 管理画面の画面表示ACなので必須
- [ ] AC-2.1: [API系の条件] → [期待動作] (REQ-2) [API]
  - [ ] T-5 Jest: [ハンドラ統合テストシナリオ]

### テスト担保方針

> **判定基準（`.claude/skills/qa-patterns/SKILL.md` 準拠）**
> - フロント（サロンポータル / 管理画面 / LP）の画面仕様は、原則 Playwright で統合テストして初めて担保されたとみなす
> - API のロジックは、原則 Jest（unit + ハンドラ統合）で担保されたとみなす
> - Playwright を省略する場合は、複数テストの組み合わせで担保できる根拠を明記すること
> - API の Jest のみでは画面の結合テストとみなさない。Playwright か人力テストが必須
> - 人力テストとした場合は、なぜ自動化できないか理由を明記すること
> - 人間がテストすべき項目は明確にチェックボックスで記載すること

#### 自動テスト一覧
- [ ] T-1 [Jest unit] [シナリオ] → [Expected] (P0, AC-1.1)
- [ ] T-2 [Jest 統合] [シナリオ] → [Expected] (P0, AC-1.2)
- [ ] T-3 [Playwright] [シナリオ] → [Expected] (P0, AC-1.1)
- [ ] T-4 [Playwright] [シナリオ] → [Expected] (P0, AC-1.2)
- [ ] T-5 [Jest 統合] [シナリオ] → [Expected] (P0, AC-2.1)

#### 人力テスト一覧（自動化不可の場合のみ）
- [ ] [テスト内容] (AC-X.X) — 自動化不可の理由: [理由]

#### 受け入れ条件ごとのテスト担保根拠
| AC | 種別 | 自動テスト | 人力テスト | 担保ロジック |
|----|------|-----------|-----------|-------------|
| AC-1.1 | 画面表示(サロンポータル) | T-1, T-3 | - | Playwright T-3 で統合検証済み |
| AC-1.2 | 画面表示(管理画面) | T-2, T-4 | - | Playwright T-4 で統合検証済み |
| AC-2.1 | API | T-5 | - | Express/Lambda ハンドラのため Jest 統合で十分 |
```

## Docs Updates の書き方

```markdown
## Docs Updates (Proposed)

### docs/product/ 更新
<!-- ほぼすべてのIssueで記載する。ユースケース・詳細仕様をどのファイルに反映するか -->
- `docs/product/{feature}.md`: [新規作成 or REWRITE] — [概要: 何をドキュメント化するか]

### docs/tech/ 更新（該当する場合のみ）
<!-- 複雑な技術的説明がある場合のみ -->
- `docs/tech/{feature}.md`: [新規作成 or REWRITE] — [概要]

### コアパターンファイル更新（該当する場合のみ）
<!-- 新しいパターンが確立された場合のみ -->
- `docs/product/ux-patterns.md`: [追加すべきパターン]
- `docs/tech/implementation-patterns.md`: [追加すべきパターン]
```
