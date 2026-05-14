# Shaire Project - Claude Code Guide

## CRITICAL RULES (MUST ALWAYS FOLLOW)

**IMPORTANT: shaire-server(TypeScript), shaire-stylist-react, shaire-customer-react(React Native), shaire-admin(React)のロジックを修正する際は、必ず以下を実行すること:**
1. vitest/maestro/playwrightを追加または修正する
2. 追加/修正したvitest/maestro/playwrightを実行してすべてgreenになることを確認する
3. E2E は未実行（ローカル環境制約）は禁止とする。修正/追加したなら環境をセットアップしてgreenを確認すること

**YOU MUST NOT: コードを変更してテストを書かずに終了すること**

テスト実行コマンド・環境セットアップは `.claude/skills/vitest/SKILL.md`, `.claude/skills/maestro/SKILL.md`, `.claude/skills/playwright/SKILL.md` を参照。

## Issue 登録先の制約（MUST）

- **`GO-TODAY-SHAiRE-SALON/*` 配下のリポジトリへの Issue 新規作成は禁止**
  - `gh issue create` / `gh api` 経由問わず登録しない
  - 対象: `GO-TODAY-SHAiRE-SALON/shaire-admin`, `GO-TODAY-SHAiRE-SALON/shaire-server`（移行後含む）ほか同組織配下の全リポジトリ
- Issue 登録先は **`akichim21/shaire`** を使用すること（プロジェクト横断の Issue トラッカ）
- `.claude/settings.json` の `permissions.deny` でも `gh issue create *GO-TODAY-SHAiRE-SALON*` をブロック済み

## ワークツリー運用ルール

- **対象**: shaire-server, shaire-admin, shaire-customer-react, shaire-stylist-react
- **対象外**: shaire（親リポジトリ）はworktreeを使用しない
- Issue作業時は `issue-start` が変更対象リポジトリにworktreeを自動作成する
- すべてのコード編集・テスト実行・gitコミットはworktreeディレクトリ内で行う
- **並列Issue対応**: manifest は `.claude/worktree-manifests/GTSS-{N}.json` にIssue毎の個別ファイルで管理
- テスト実行やサーバー起動は、作業中Issueのmanifestで参照先を解決（worktreeがあればそこ、なければ元ディレクトリ）
- 詳細: `.claude/rules/worktree-workflow.md`

## Verification Before Done（完了前に必ず検証する）

- 動作を証明できるまで、タスクを完了とマークしない
- 必要に応じて自分の変更の差分を確認する
- 「スタッフエンジニアはこれを承認するか？」と自問する
- テストを実行し、ログを確認し、正しく動作することを示す

## Issue作業ログ

GitHub Issueベースの実装作業時は、GitHub Issueコメントとして作業ログを記録すること:
- `[Analysis]`: 実装開始前に方針・変更ファイル・懸念を投稿（必須）
- `[Decision]`/`[Discovery]`: 実装中の重要な判断・発見を投稿（任意）
- `[CodeReview]`: 実装完了後にコード解説を投稿（必須）
- `[Completion]`: 実装完了時にサマリー・テストカバレッジ・レビュー注目点を投稿（必須）
- `[Modification]`: 追加修正時に変更理由・内容・影響範囲を投稿（追加修正時は必須）

詳細フォーマット: `.claude/skills/issue-start/SKILL.md` を参照

## プロジェクト概要
フリーランスのスタイリスト(美容師)にシェアサロン(店舗+このアプリ)を提供するサービスで、顧客管理(カルテ)、予約/決済、メッセージのやりとりなどの機能を提供してる
shaire-server: サーバーサイドexpress + parse
shaire-stylist-react: スタイリストが使うアプリ
shaire-customer-react: 顧客が使うアプリ
shaire-admin: 運営管理者、施設管理者が使う。adminのroleによってだしワケしてる
shaire-lp-nextjs: LP・静的ページ・web予約ページ(Next.js)。スタイリストが発行するonelink(AppsFlyer)のリダイレクト先として使用。カスタマーがここからアプリを起動するパターンもある。今後web予約機能を実装予定
shaire-lp-strapi: LPコンテンツCMS (Strapi v4 + PostgreSQL)。`shaire-lp-nextjs` の `(lp)` ルート（`/`, `/[slug]`）が `getPageData` / `getGlobalData` で取得する `Page` / `Global` を管理する。本番/開発(AWS EC2)では同一ドメイン配下で `/admin` が管理画面、`/server` が REST API (`/server/api/pages`, `/server/api/global`) として配信される（リバースプロキシでパスベースルーティング）。詳細: `docs/shaire-lp-strapi/`

### ドメイン用語
- 「クルー」= 「スタイリスト」の別名。コードベースでは CUSTOMER と HAIRSTYLIST の2ロールのみ
- 「カルテ」= 顧客に対するメモ。以下の4フィールドで構成される
  - shaire-stylist-react（クライアント）: `PrivateMemo` / `PublicMemo`
  - shaire-server（サーバー）: `Booking.publicMemo` / `Booking.privateMemo`
  - `publicMemo` はカスタマーに共有される、`privateMemo` はスタイリスト内部用

### Cloud function命名規則
- `m_` プレフィックス: モバイルアプリ(stylist/customer)から呼ばれる関数
- `web_` プレフィックス: admin画面から呼ばれる関数
- `GroupCloudFunction` パターンで定義

## ドキュメント参照ルール
- `docs/product/`, `docs/tech/` にコアパターン・機能別ドキュメントを格納する（`docs-sync`コマンドで生成・同期）
- `docs/shaire-*/` は各リポジトリ固有のドキュメント（既存のまま維持。shaire-lp-nextjs含む）
- 複雑な機能の場合は、必ず docs/ 配下の該当ドキュメントを読むこと

## テスト、受け入れ条件について
- 基本全て自動テストを実施する。ただし、実装が難しいと判断したら、理由とともに人間がテストするで問題ない。
- エッジケースなどのパターンが多いものは可能な限りunitテスト、できないものやe2eでしか担保できないものはe2eとする。
- テスト実行終了時にはprocessやログファイルが可能な限り残らないようにする

## Maestro テスト実行の基本方針

**Maestroテストは基本的にAndroidエミュレーターで実行する。** iOSが必要な場合のみiOSを使用する。

### Android (デフォルト)

```bash
# Terminal 1: テストサーバー起動
cd shaire-server && npm run test-server

# Terminal 2: テスト用.envでアプリビルド (localhost→10.0.2.2に自動変換)
cd shaire-customer-react && npm run android:test

# Terminal 3: Maestroテスト実行
cd shaire-customer-react && npm run maestro:android
```

### iOS (必要な場合のみ)

`npm run ios:test` を実行する際は **`--simulator` を必ず明示指定**すること。

```bash
# 1. 先に利用可能なシミュレーターを確認
xcrun simctl list devices available | grep iPhone

# 2. 明示的に指定してビルド
npm run ios:test -- --simulator="iPhone 16e"
```

**react-native-config の仕組み**: `.env` の値はビルド時にネイティブコードに埋め込まれる（ランタイムではない）。Xcode スキームの PreAction スクリプトが毎ビルド時に `ENVFILE` で指定したファイルを `.env` にコピーする。`ENVFILE` を渡さないと `configs/development/.env` が使われる。

## Maestro テスト実行後のクリーンアップ (必須)

テスト・サーバー・エミュレーター/シミュレーターは一連のタスク終了後に必ず停止すること。

```bash
# テストサーバー停止
lsof -i :1338 -t | xargs kill 2>/dev/null

# Metro停止
lsof -i :8081 -t | xargs kill 2>/dev/null

# Android: エミュレーター停止
adb emu kill 2>/dev/null

# iOS: シミュレーター停止 (使用した場合)
xcrun simctl shutdown all 2>/dev/null

# テスト結果ログ・スクリーンショット削除（蓄積するため）
rm -rf ~/.maestro/tests/
```

## CI/CD
- モバイルビルド: Bitrise
- Firebase App Distribution: 環境変数はBitriseシークレットで管理（リポジトリ.envには未定義）
  - `FIREBASE_APP_DISTRIBUTION_IOS_APP`, `FIREBASE_APP_DISTRIBUTION_ANDROID_APP`, `FIREBASE_CI_TOKEN`
  - パッケージ名: production=`app.shaire.customer.android`, dev=`com.c2c_platform.shaire.customer.dev`, staging=`com.c2c_platform.shaire.customer.staging`
  - `BUILD_ENV`とFirebase App IDの不一致に注意

## リファレンス

- テスト: `.claude/skills/vitest/SKILL.md`, `.claude/skills/maestro/SKILL.md`, `.claude/skills/playwright/SKILL.md`
- QAパターン: `.claude/skills/qa-patterns/SKILL.md`
- Issue: `.claude/skills/issue/SKILL.md`
- Docs: `.claude/skills/docs/SKILL.md`
- コーディング規約: `.claude/skills/coding-standards/SKILL.md`
- その他: `.claude/skills/` 配下を参照
