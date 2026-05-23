---
name: coding-standards
description: コーディング規約・セキュリティ・コード参照の記法など共通ルール。
---

# Coding Standards

## 一般原則

- 必要でない限り新しいファイルを作成しない
- 既存のファイルを編集することを優先
- 未使用のコードは完全に削除（後方互換性のハックは避ける）
- 過度なエンジニアリングを避け、要求された変更のみを実施

## セキュリティ

以下の脆弱性を導入しないよう注意:
- コマンドインジェクション
- XSS (Cross-Site Scripting)
- SQLインジェクション
- その他OWASP Top 10の脆弱性

## コード参照の記法

ファイルやコードの場所を参照する際は、マークダウンリンク形式を使用:

- ファイル: `[filename.rb](path/to/filename.rb)`
- 特定の行: `[filename.rb:42](path/to/filename.rb#L42)`
- 行の範囲: `[filename.rb:42-51](path/to/filename.rb#L42-L51)`
- フォルダ: `[app/controllers/](app/controllers/)`

## その他

- 絵文字は明示的に要求された場合のみ使用
- 時間の見積もりや予測は提供しない
- 技術的な正確性と真実性を優先
- 不明な点がある場合はAskUserQuestionツールを使用
