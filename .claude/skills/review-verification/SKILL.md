---
name: review-verification
description: サブエージェントによるコードレビュー指摘の cross-file 検証チェックリスト。UI挙動・認可・バリデーション・コールバック・委譲に関する指摘を確定する前に呼び出しチェーン全体を追跡するための手順。
---

# Cross-File 検証チェックリスト

## 目的

サブエージェントが **ファイル単独の読み取り** で誤指摘を出すのを防ぐ。
JSX レンダリング層・親子コンポーネント・middleware チェーン・Parse Cloud hooks・delegate・基底クラスなど、呼び出しチェーンの一部しか見ていないと「実装されていない」「消えない」「検証されていない」等の誤った指摘を生む。

## 適用対象の指摘タイプ

以下のタイプの指摘は **必ず本チェックリストに従って裏取り** してから確定する:

1. 「UI 要素が表示されない / 消えない / disabled にならない」
2. 「バリデーションが欠けている」
3. 「認可 / 権限チェックが欠けている」
4. 「コールバック / フック / イベントが呼ばれない」
5. 「ロジックが実装されていない」
6. 「A と B で挙動が違う / 不整合」類の cross-file 整合性指摘
7. 「エラーハンドリングが不足」

## 必須チェック手順

### Frontend（React + Vite: サロンポータル / 管理画面 / LP）

該当ファイルが UI コンポーネントの場合:

1. **親子コンポーネントを 1 段以上追跡**
   - ファイル内の JSX を読み、子コンポーネント名を抽出
   - `Grep "<ChildComponentName"` で使用箇所を確認
   - 子コンポーネントの実装ファイルを `Read` する
2. **JSX レンダリング層を最後まで追う**
   - submit ボタン等の UI 要素は、親で条件分岐していなくても子コンポーネントで `showXxx` フラグ等により非表示になる場合がある
   - 「親が return している JSX」と「実際に画面に出る要素」は別物として扱う
3. **カスタムフック / HOC / Context を追跡**
   - `useXxx` / `withXxx` / `Context.Provider` で挙動が注入されている可能性
4. **同じ機能の他フローと比較する指摘**
   - 「他 N フローでは X している」類は、各フローの **呼び出しチェーンの末端まで** 読んでから対比する

### Server（Parse + Express + TypeScript）

該当ファイルが Route / Cloud Function / Service の場合:

1. **middleware チェーンを追跡**
   - `app.use` / `router.use` で先行ミドルウェアが認証・バリデーションを担当している可能性
   - `Grep "app.use\|router.use" -r src/`
2. **Parse Cloud hooks**
   - `Parse.Cloud.beforeSave` / `beforeFind` / `afterSave` / `beforeDelete` などで前段処理が入っている可能性
   - `Grep "Parse.Cloud.(before|after)" -r`
3. **共通バリデータ / Zod / Joi スキーマ**
   - 該当エンドポイント単独に validation がなくても、共通スキーマでカバーされている可能性
4. **Express 認可 / ACL**
   - `passport` / 独自認可ミドルウェア / Parse ACL の適用有無を確認
5. **認可カバレッジ（cancel-billing-service-api は `.claude/skills/authz/checklist.md` 参照）**
   - 「認可/権限チェックが欠けている」「状態遷移ロックがバイパスされる」類の指摘は、**同一リソースの全ルートを grep して横並びで**確認してから確定する（`grep -nE "app\.(get|post|put|delete)\(|requireAdmin|requireAuth" src/handlers/<resource>.handler.ts`）。
   - 状態遷移ロックの指摘は、状態を変えうる**全経路**（`/status` 以外の専用ルート・webhook）を `grep "status: APPLICATION_STATUS\|\.update(.*status"` で洗い出してから「ロック済み/未達」を判定する。
   - serializer の機微フィールド漏洩の指摘は、その serializer を返す全エンドポイントの認可と、公開エンドポイントのレスポンス実体を裏取りする。

### Rails（Controller / Service / Model）— 他リポジトリから流用される場合

1. **before_action / concern / delegate / STI / 基底クラス** を全て追跡してから指摘する

## 「A と B で挙動が違う」類の指摘の特別ルール

両ファイルを **同時に Read してから対比** すること。片方だけ読んで「もう片方は違うはず」と推測してはいけない。

## 確認できなかった指摘の扱い

呼び出しチェーンを最後まで追えなかった、または時間制約で確認しきれなかった指摘は、以下のように `[未検証]` プレフィックスを付けてメインエージェントに返す:

```
[未検証] ButtonComponent.tsx で submit ボタンが showBlockedGuide で非表示にされていない可能性がある
（子コンポーネントの実装まで追跡できていない）
```

メインエージェントは `[未検証]` 付きの指摘を **必ず再検証してから** コメント投稿の判断をする。

## 過去事例

- **hotel PR #1938**: `BookingForm.tsx` の onSubmit 層だけ読み「submit ボタンが消えない」と誤指摘。実際は子コンポーネント `BookingStepFormSecond.tsx` の `showBlockedGuide` 判定で非表示になっていた。描画層を追跡しなかったことが原因。
