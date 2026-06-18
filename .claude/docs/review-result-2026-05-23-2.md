---
issue: 9
date: 2026-05-23
repos:
  - repo: api
    repoDir: cancel-billing-service-api
    baseBranch: feature/GTSS-7
    toBranch: feature/GTSS-9
---

# レビュー結果: #9

## 概要

**Issue:** #9 API バリデーションを zod 共有スキーマへ統一する（joi 除去）

| リポジトリ | ベースブランチ | 変更ブランチ | コミット数 | 変更ファイル数 |
|-----------|-------------|------------|----------|------------|
| api | `feature/GTSS-7` | `feature/GTSS-9` | 1 | 5 |

本 PR は REQ-1（zod 化）＋ REQ-3（joi 除去）を API 内部スコープで実施。REQ-2（フロント共有）は後続 Issue に分離されている。旧 `validateApplicationData`（正規表現＋手書き `errors.push`）を zod `superRefine` へ「完全互換」で移植する方針。

## 変更ファイル一覧

### api

| ファイル | 追加 | 削除 | 変更種別 |
|---------|------|------|---------|
| `src/schemas/application.schema.ts` | +121 | -0 | Added |
| `src/__tests__/unit/application-schema.test.js` | +121 | -0 | Added |
| `src/services/application.service.ts` | +6 | -55 | Modified |
| `package.json` | +2 | -2 | Modified |
| `package-lock.json` | +9 | -64 | Modified |

## 指摘一覧

- [x] 対応する

### [Codex] 非オブジェクト JSON 入力で旧実装との互換が崩れる（英語 zod メッセージが混入）

**ファイル:** `api/src/services/application.service.ts:35`（到達経路: `api/src/handlers/applications.handler.ts:26`）
**重要度:** High

**該当コード:**
```typescript
// baseBranch側（変更前）— 旧 imperative 実装
export const validateApplicationData = (applicationData) => {
  const errors = [];
  // 電話番号は必須
  if (!applicationData.phone) {
    errors.push('電話番号は必須です');
  } else if (!/^0\d{1,4}-?\d{1,4}-?\d{3,4}$/.test(applicationData.phone)) {
    errors.push('電話番号の形式が正しくありません（例: 03-1234-5678）');
  }
  // ... 以下メール/区分/同意/法人・個人
  return errors;
};
```

```typescript
// toBranch側（変更後）
export const validateApplicationData = (applicationData) => {
  const result = applicationInputSchema.safeParse(applicationData ?? {});
  if (result.success) {
    return [];
  }
  return result.error.issues.map((issue) => issue.message);
};
```

呼び出し元:
```typescript
// api/src/handlers/applications.handler.ts:26
const applicationData = JSON.parse((await c.req.text()) || '{}');
const validationErrors = validateApplicationData(applicationData);
if (validationErrors.length > 0) {
  return c.newResponse(
    JSON.stringify({ success: false, error: '入力値に誤りがあります', details: validationErrors }),
    400, corsHeaders
  );
}
```

**問題:**
`applicationData ?? {}` は `null`/`undefined` のみを `{}` に正規化する。クライアントが**有効な JSON の非オブジェクト**（`"hello"` / `123` / `true` / `[]`）を POST した場合、`JSON.parse` がプリミティブ/配列を返し、それがそのまま `z.object(...)` に渡って `superRefine` が走る前に zod 既定の**英語**メッセージで失敗する。worktree 上の vitest で旧/新の出力差を実測確認済み:

| 入力 | 旧実装（返り値） | 新実装（返り値） |
|------|----------------|----------------|
| `"hello"` | `['電話番号は必須です','メールアドレスは必須です','区分（法人/個人）は必須です','利用規約…同意が必須です']` | `['Expected object, received string']` |
| `123` | （同上 日本語4件） | `['Expected object, received number']` |
| `true` | （同上 日本語4件） | `['Expected object, received boolean']` |
| `[]` | （同上 日本語4件） | `['Expected object, received array']` |

旧実装はプリミティブ/配列へのプロパティアクセスが `undefined` になるため throw せず日本語必須エラー配列を返していた。新実装は英語メッセージ1件を `details` に載せて返すため、REQ-1 の「文言・判定・エラー順序の完全互換」から外れ、`details` を表示するフロント側に英語が漏れる契約ドリフトになる。`JSON.parse` 経由でこの入力が実際に到達可能。

**修正提案:**
`validateApplicationData` で `null/undefined` だけでなく配列・プリミティブも `{}` に寄せてから `safeParse` する。
```typescript
export const validateApplicationData = (applicationData) => {
  const input =
    applicationData && typeof applicationData === 'object' && !Array.isArray(applicationData)
      ? applicationData
      : {};
  const result = applicationInputSchema.safeParse(input);
  return result.success ? [] : result.error.issues.map((issue) => issue.message);
};
```
あるいはスキーマ側で `z.preprocess` を使い object 以外を `{}` に正規化する。あわせて `"x"` / `123` / `true` / `[]` の回帰テストを `application-schema.test.js` に追加して固定する。

---

### [Test Coverage] 個人区分の生年月日「形式不正」分岐が新テストで未カバー

**ファイル:** `api/src/schemas/application.schema.ts:385-389`
**重要度:** Medium

**該当コード:**
```typescript
// 個人の場合
else if (d.entityType === '個人') {
  if (!d.partnerName) add(VALIDATION_MESSAGES.individualPartnerNameRequired);
  if (!d.birthDate) {
    add(VALIDATION_MESSAGES.individualBirthDateRequired);
  } else if (!BIRTHDATE_REGEX.test(String(d.birthDate))) {
    add(VALIDATION_MESSAGES.birthDateFormat);  // ← この分岐が未テスト
  }
}
```

**問題:**
`application-schema.test.js:210-224` の「形式不正」テストは `validCorporate`（法人）ベースのため、法人ブロック（`schema.ts:376-380`）の `birthDateFormat` 分岐しか通らない。既存 `pure-logic.test.js` の生年月日形式テストも法人ベース。法人・個人で同じ `birthDateFormat` メッセージを共有するが**コードパスは別の `else if` ブロック**であり、個人側の形式不正分岐は退行検知できていない。

**修正提案:**
個人区分で `birthDate: '1980/01/01'`（形式不正）を与えるケースを 1 件追加し、`[VALIDATION_MESSAGES.birthDateFormat]` を期待値とする。両分岐の退行を固定できる。

---

### [Code Quality] 生年月日の必須＋形式チェックが法人/個人ブロックで重複（DRY）

**ファイル:** `api/src/schemas/application.schema.ts:376-380, 385-389`
**重要度:** Low

**問題:**
`BIRTHDATE_REGEX` の必須＋形式チェックが法人ブロックと個人ブロックに複製されている。旧 imperative 実装の重複をそのまま移植したもので互換性上は正しい判断だが、ヘルパー（例: `validateBirthDate(value, requiredMessage)`）に括ると保守性が上がる。順序・文言互換を壊さない範囲の任意改善。

---

## 総評

joi→zod の挙動保存移植として全体的に質の高い PR。3 つのサブエージェント（code-reviewer / lessons-reviewer / codex-reviewer）の出力をメインエージェントが worktree 上で再検証し、以下を確認した。

- **互換性（通常入力）**: 旧 imperative と新 superRefine の分岐ごとの合否・文言・**エラー順序**の完全一致を確認。zod の `addIssue` は呼び出し順に `error.issues` へ積まれ、順序テスト（`.toEqual([...])`）が意味を持つ。`null/undefined` 入力で throw しなくなった点は handler 経路に退行を生まない安全側の改善。
- **joi 除去**: `src/`・`package.json`・`package-lock.json`・`node_modules` すべてで joi 参照ゼロ（grep ヒットは `.join()` の誤検出のみ）。`@standard-schema/spec` の `dev:true` 降格は joi 本番依存消滅に伴う lockfile 再計算の正常結果で、zod は当該パッケージへ実行時依存しないためランタイム影響なし。
- **lessons 違反**: 該当なし。テストは弱いアサーションを避け順序まで強検証しており lesson 準拠。

マージ前に対応すべきは **High（非オブジェクト入力の互換崩れ）** が必須。Medium（個人 birthDate 形式テスト追加）は同時に入れると堅牢。Low は任意。High の修正に対する回帰テストを追加すれば、REQ-1 の「完全互換」が入力境界まで担保される。
