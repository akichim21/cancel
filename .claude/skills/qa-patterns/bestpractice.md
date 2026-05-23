# QA検証パターン ベストプラクティス

## 構成
- Express + AWS Lambda (Node.js) (`cancel-billing-service-api/`)
- React 19 + TS + Vite — サロン向けユーザーポータル (`cancel-billing-service/`)
- React 19 + TS + Vite — 運営管理者ダッシュボード (`cancel-billing-service-admin/`)
- React 18 + JSX + Vite — LP・申請フォーム (`cancel-billing-service-lp/`)
- Jest（API Unit / API 統合）
- Vitest（Frontend Unit、未整備・追加時に導入）
- Playwright（Web 画面 E2E: user / admin / lp）
- 外部依存（Stripe / DynamoDB / SES / Twilio）はすべてmockで対応

---

## 1. テストピラミッドに基づく責務分担

各レイヤーで「何を保証するか」を明確にし、重複テストを排除する。

### 1.1 API Unit Test（Jest unit）

ビジネスロジックの正しさを保証する層。**最も厚くする。**

**担当する検証：**
- バリデーション（存在・形式・一意性・カスタム）
- ステート遷移（申請ステータス等の全パス）
- 計算ロジック（請求額計算、手数料計算、日付計算、集計）
- ユーティリティ関数
- エッジケースの大半はここで網羅

**エッジケースの深度：**
- 境界値（0, 1, max, max+1）
- null / undefined / 空文字 / 空配列
- 型の境界（整数の最大値、文字列長上限）
- 時間系（月末、年末、うるう年、タイムゾーン）

ユニットテストは高速なので「やりすぎ」を恐れる必要はない。

### 1.2 API 統合 Test（Jest handler integration = e2e 相当）

Express ハンドラの契約（リクエスト→レスポンスの対応関係）を保証する層。

**担当する検証：**
- ハンドラの正常系レスポンス
- 認証・認可（未ログイン、権限不足、他ユーザーリソースへのアクセス）
- パラメータバリデーション（不正パラメータでエラーが返るか）
- 権限チェック（403 等）

**エッジケースの深度：**
- 正常系1〜2パターン + 主要な異常系（認証エラー、バリデーションエラー）に絞る
- ロジックの分岐網羅はunit testの責務

### 1.3 Frontend Unit Test（Vitest）

各 React アプリ（user / admin / lp）のコンポーネント・hooks・表示ロジックの正しさを保証する層。

**担当する検証：**
- 表示ロジック（条件付きレンダリング、フォーマット）
- フォームバリデーション
- 状態管理・カスタム hooks
- API レスポンスのモックに対する画面の出しわけ

**エッジケースの深度：**
- 表示分岐・バリデーションの主要パターンを網羅
- フロー全体の統合は Playwright の責務

### 1.4 Playwright E2E（Web 画面: user / admin / lp）

Web 画面のユーザーシナリオ全体の統合動作を保証する層。**最もコストが高いので薄く保つが、新機能のクリティカルパスは省略しない。**

**担当する検証：**
- クリティカルパス（ログイン→主要機能→ログアウト、申請フォーム送信等）
- 複数画面にまたがるデータの整合性
- リダイレクト・ナビゲーション

**「薄くする」の正しい意味：**
「不必要に重複させない」であり「新機能のクリティカルパスを省略する」ではない。
新機能開発時、そのフローがE2Eでカバーされていなければ追加してからリリースする。

---

## 2. E2E ツールの判断基準

| 対象アプリ | E2Eツール |
|-----------|----------|
| cancel-billing-service (ユーザーポータル) | Playwright |
| cancel-billing-service-admin (管理画面) | Playwright |
| cancel-billing-service-lp (LP・申請フォーム) | Playwright |
| cancel-billing-service-api (API) | Jest handler integration（e2e 相当） |

Web 画面はすべて Playwright、API はすべて Jest 統合テスト。迷う余地はない。

---

## 3. 他機能との整合性テスト

| 整合性の種類 | 担当レイヤー | 例 |
|-------------|------------|-----|
| データ整合性（モデル層の関連） | Jest Unit | 申請削除時の関連データの処理 |
| API間の整合性 | Jest 統合 | キャンセル請求作成→請求一覧にその請求が含まれるか |
| 画面をまたぐ整合性（Web） | Playwright | 申請作成→一覧表示→詳細確認 |
| 設定反映の整合性（管理画面） | Playwright | 設定変更→一覧に反映→詳細確認 |

---

## 4. エッジケースの優先度マトリクス

| 優先度 | 基準 | 例 |
|-------|------|-----|
| P0（必須） | データ損失・金銭的損害・セキュリティに直結 | 認証・認可の全パターン、決済関連の全分岐、データ整合性 |
| P1（標準） | ユーザー体験に影響 | バリデーションの主要パターン、境界値、状態遷移の全パス、エラーハンドリング |
| P2（推奨） | 発生頻度が低い or 影響が軽微 | 極端に長い入力、特殊文字（絵文字、サロゲートペア）、同時操作 |
| テストしない | フレームワーク・ライブラリが保証するもの | DynamoDB のクエリ動作自体、Reactの再レンダリング自体 |

---

## 5. Mock戦略

| レイヤー | ツール | 方針 |
|---------|--------|------|
| Jest Unit | jest.mock | 外部サービスをmock。DB操作不要 |
| Jest 統合 | DynamoDB mock / ローカル DynamoDB | DB操作はモックまたはローカル DynamoDB。外部API（Stripe, SES, Twilio等）はmock |
| Vitest (Frontend) | vi.mock / MSW | API レスポンスを mock してコンポーネントを検証 |
| Playwright | seed data / API mock | テストデータでDB準備、または `page.route` で APIレスポンスをmock |

---

## 6. テストケース記述フォーマット

### 6.1 自動テスト用（Claude Codeが実装する）

#### API Unit Test（Jest unit）

```markdown
### API Unit Test (Jest unit - [対象モジュール名])
| # | Category | Scenario | Input | Expected | Priority |
|---|----------|----------|-------|----------|----------|
| 1 | 正常系 | [シナリオ] | [入力値] | [期待結果] | P0/P1/P2 |
| 2 | 異常系 | [シナリオ] | [入力値] | [期待結果] | P0/P1/P2 |
| 3 | 境界値 | [シナリオ] | [境界値] | [期待結果] | P0/P1/P2 |
```

#### API 統合 Test（Jest handler integration）

```markdown
### API 統合 Test (Jest - [エンドポイント])
| # | Category | Scenario | Precondition | Params | Expected | Priority |
|---|----------|----------|-------------|--------|----------|----------|
| 1 | 正常系 | [シナリオ] | [前提条件] | [パラメータ] | [期待結果] | P0/P1/P2 |
| 2 | 認証 | 未認証 | - | [パラメータ] | 401 | P0 |
| 3 | 認可 | 権限不足 | [前提条件] | [パラメータ] | 403 | P0 |
| 4 | バリデーション | [シナリオ] | [前提条件] | [不正パラメータ] | 400 | P1 |
```

#### Frontend Unit Test（Vitest）

```markdown
### Frontend Unit Test (Vitest - [対象コンポーネント/hook名])
| # | Category | Scenario | Input | Expected | Priority |
|---|----------|----------|-------|----------|----------|
| 1 | 表示 | [シナリオ] | [props/state] | [期待表示] | P0/P1/P2 |
| 2 | バリデーション | [シナリオ] | [入力値] | [エラー表示] | P0/P1/P2 |
```

#### Playwright E2E（Web 画面: user / admin / lp）

```markdown
### Playwright E2E ([アプリ]/[機能名].spec.ts)
| # | Scenario | Precondition | Steps | Expected |
|---|----------|-------------|-------|----------|
| 1 | [シナリオ] | [seed/前提] | [操作手順] | [期待結果] |
```

### 6.2 人力テスト用

```markdown
## 手動検証チェックリスト: [画面/機能名]

### デザイン・レイアウト
- [ ] デザインとの一致確認
- [ ] 画像・アイコンの表示品質
- [ ] 長いテキストでの表示（truncation / 折り返し）

### UX
- [ ] 操作完了までの導線が直感的か
- [ ] エラー時にユーザーが何をすべきか明確か
- [ ] ローディング中の体験
```
