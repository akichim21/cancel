# Slack 通知（アラート）（GTSS-817-qa）

バッチ処理の失敗を**運営へプッシュする**ための Slack 通知の規約。CloudWatch は人が見に行かないと気づけず、
Sentry は例外が起きた場合しか届かない（サロンボード取り込みのログイン失敗は例外を投げない）。その隙間を埋める。

- 関連: `docs/tech/salonboard-import.md`（取り込みの失敗理由と診断情報）/ `docs/tech/sentry.md`（Sentry 送信規約）/
  `docs/tech/ci-cd.md`・`docs/tech/secrets-management.md`（秘密の配布経路）/ `docs/tech/batch-fargate.md`（ECS 経路）
- 実装: `cancel-billing-service-api/src/observability/slack.ts`（送信）/
  `cancel-billing-service-api/src/services/salonboard-import-notify.ts`（本文の組み立てと投稿単位）
- 実装 Issue: akichim21/cancel #61（GTSS-817-qa。送信の土台）/ #64（GTSS-817-slack。運営向け書式への刷新）

## 1. 実装方針

**依存追加なし**（`fetch` 直叩き）。`@slack/web-api` を入れると esbuild バンドル（API Lambda / batch Lambda /
batch ECS で共通）が太るため、必要な 1 エンドポイントだけを自前で叩く。`postSlackMessage()` は
**throw しない契約**で、結果を `{ sent, via, reason }` で返す。呼び出し元（バッチ）の成否には一切影響させない。

## 2. 送信経路の解決（優先順）

`resolveSlackTransport(env)`（純関数）が次の優先順で決める。

| 条件 | 経路 | 送信先 |
|---|---|---|
| `SLACK_BOT_TOKEN` **と** `SLACK_ALERT_CHANNEL` が両方ある | `bot` | Slack Web API `chat.postMessage` |
| 上記が無く `SLACK_WEBHOOK_URL` がある | `webhook` | Incoming Webhook |
| どちらも無い | `none` | **何もしない**（情報ログを 1 行残すだけ） |

- Bot Token 方式は token と channel の**両方**が要る（片方だけでは `chat.postMessage` が必ず失敗するため
  Webhook へフォールバックする）。
- チャンネルは**リネーム耐性のため ID 指定**（`C…`）。
- 未設定を理由にバッチを失敗させない。デプロイもデプロイ前ガードも通る。

## 3. 送信抑止と失敗時の扱い

- **`NODE_ENV=test` は設定値の有無にかかわらず実送信しない**（CI から実チャンネルを汚染しないため）。
  テストは `postSlackMessage(text, { env, fetchImpl })` の注入シームで分岐を検証する。
- **投稿失敗は throw しない**。ネットワーク断・HTTP エラー・`chat.postMessage` の
  `ok:false`（`channel_not_found` / `not_in_channel` / `invalid_auth` 等）はすべて `console.error` のみ残す。
  Slack Web API は**失敗も HTTP 200 + `{ok:false}` で返す**ため、HTTP ステータスだけでなく本文まで確認している。
- **投稿の開始間隔を 1 秒以上空ける**（#64）。取り込み通知は会社ごと 1 通へ分割したため 1 実行で最大 11 通
  投稿しうる。`await` で直列化するだけでは応答が速いときに連続投稿になり、Slack のレート制限
  （同一チャンネルにつきおおむね毎秒 1 通）を守れない。間隔制御は `postSlackMessage` 側にあるので、
  呼び出し側は `await` で並べるだけでよい。
- **HTTP 429 は `Retry-After` の秒数だけ待って 1 回だけ再送する**。再送しても失敗したらその通知は諦め、
  呼び出し元は次の通知へ進む。`Retry-After` が無い / 解釈できないときは 1 秒、上限は 30 秒で頭打ちにする
  （Slack が異常に大きい値を返してもバッチを止めない）。

## 4. サロンボード取り込みの通知（現時点で唯一の利用者）

本文の組み立ては `src/services/salonboard-import-notify.ts` の**純関数**に閉じ込め、送信
（`postSlackMessage`）と分離している。13 パターン + 集約通知を実 Slack へ投げずに単体テストで網羅するため。

### 4.1 投稿の単位と起動条件

- **失敗のあった会社ごとに 1 通**（#64。それ以前は「1 実行 = 1 通・全会社を連結」だった）。
- **起動条件（会社ごと）**: その会社の通知対象失敗件数が 1 件以上、または会社ランが例外で落ちた
  （`ok=false`）。**全件成功した会社は投稿しない**。
- 通知対象失敗件数 = `failed` − 「連携設定が未完了」で黙らせた店舗数。**連携設定が未完了なだけの会社は
  投稿しない**（毎日「内訳なし」の空アラートが鳴るのを防ぐ既存の抑止を維持する）。
- **リトライとの関係**: ログインの引き直し・店舗取得の引き直しがすべて決着したあとの最終結果に対して
  1 度だけ通知する。リトライで復旧した失敗は通知しない。
- **投稿数の上限**: 個別通知は 1 実行あたり **最大 10 通**。超過分は「他 N 社が失敗」の集約 1 通へまとめる
  （1 実行あたり最大 11 通）。プロキシ全断のような全社同時失敗でチャンネルが埋まるのを防ぐため。
- **並び順**: エラー種別の重大度（認証エラー → その他 → 一時的エラー）を第 1 キー、会社名の昇順を第 2 キー。
  上位 10 社を個別通知し、残りを集約する。
- ある会社の投稿が失敗しても後続は継続する。**投稿の成否は取り込み結果（API レスポンス・DB の実行履歴）に
  一切影響させない**。

### 4.2 本文の共通フォーマット

```
{環境プレフィックス（本番以外のみ）}
{見出し}

■ 発生日時：{YYYY-MM-DD HH:mm}（{実行経路}）
■ 会社：{会社名}
■ 連携単位：{会社単位 | 店舗単位}
■ 結果：{結果表現}
■ エラー内容：{エラー内容}
■ 対応の目安：{対応の目安}

詳細：{管理画面の取り込み実行履歴 URL}
```

- **発生日時**は取り込み実行の開始時刻を JST（`Asia/Tokyo`）で `YYYY-MM-DD HH:mm`（ゼロ埋め・秒なし）。
- **会社名**は屋号（`business_name`）を優先し、無ければ取引先名（`partner_name`）へフォールバックする
  （個人事業主は取引先名が氏名を兼ねるため、屋号がある会社では氏名を出さない順序）。どちらも取れなければ
  `(会社名なし)`。会社ランが例外で落ちて解決前だった場合のみ申請 ID で代替する。
- **連携単位**は解決できていない場合（会社ランが例外で落ちて単位を取る前に失敗）**行ごと省略する**。
  既定へ倒すと店舗単位連携の会社が「会社単位」と誤表示されるため。
- **環境プレフィックス**: 本番以外（dev / local）は見出しの直前に `[dev]` のような行を 1 行足す。
  dev と prod が同一チャンネルへ流れるため、運営が本番のアラートだけを拾えるようにする。
- **環境判定のソースは `NODE_ENV`（`isProdEnv()`）に統一する**。環境プレフィックス・詳細リンク・
  メンション抑止の 3 つを同じ判定関数から導く（ソースが分かれると「`[dev]` なのにリンクは本番管理画面」
  という食い違いが起きる）。
- 複数行になる「対応の目安」と結果行の 2 行目以降は、行頭に**全角スペース 1 文字**（U+3000）を置いて字下げする。

### 4.3 秘匿情報（重要）

- 顧客 PII（氏名・カナ・電話・メール）とサロンボードのログイン ID / パスワードは**含めない**。
- これを確実にするため、**外部システム由来の生のエラー文字列（例外メッセージ・応答本文の抜粋）を本文へ
  一切載せない**。`■ エラー内容：` に出すのは理由コードから写像した**固定文言のみ**。
  既存の PII マスク関数が落とせるのは**メールアドレスと電話番号だけ**で、氏名・カナ・ログイン ID・
  パスワードは素通しするため、生エラーを載せる限り「含めない」は保証できない。
- 運営がエラーの詳細を追う導線は**詳細リンク（管理画面の取り込み実行履歴）に一本化**する。店舗別の
  エラー文言はそこに表示される。
- **店舗名と会社名は運営向けの識別情報として含めてよい**。ただしサロンの入力値なので mrkdwn 解釈による
  偽装（`<!channel>` のチャンネル全員メンション、`<http://…|表示文字>` のリンク偽装）を防ぐため
  エスケープしてから埋める。
- **診断ダンプ（着地 URL・ページタイトル・doLogin 応答・遮断シグナル）と CloudWatch ロググループ名は
  本文に出さない**（#64 で削除）。これらは構造化ログと Sentry に残っており、運営が Slack で判断するために
  必要な情報ではない。エンジニアの調査能力は落ちない。

### 4.4 エラー種別の写像

失敗理由コードを **認証エラー / 一時的エラー / その他** の 3 種別へ写像する
（`IMPORT_ERROR_KIND_BY_REASON` / `constants/cancellation-status.ts`）。

| 失敗理由コード | 種別 | エラー内容の文言 |
|---|---|---|
| `login_failed` | **認証エラー** | ログインできませんでした |
| `login_blocked` | 一時的エラー | ログインが遮断された可能性があります |
| `timeout` | 一時的エラー | ページの取得がタイムアウトしました |
| `proxy_error` | 一時的エラー | プロキシ接続に失敗しました |
| `captcha_detected` | 一時的エラー | CAPTCHA（人間確認）が表示されました |
| `detail_fetch_failed` | 一時的エラー | 予約詳細の取得に失敗しました |
| 理由コードなし（分類不能） | **その他** | 想定外のエラーが発生しました（画面構造の変化などの可能性） |

- **写像の入力は上表の失敗系コードに限る**（`IMPORT_FAILURE_REASONS`）。会社別集計の `byReason` は
  14 コード全部を 0 で初期化して加算するため、正常な実行でもスキップ系理由（現地払い以外・規定なし・
  対象期間外など）に件数が入る。これを写像へ流し込むと未知コードとして「その他」へ倒れ、**一時的エラー
  だけで落ちた会社が毎回「失敗（要調査）」で鳴る**。
- 「その他」の件数は「通知対象の失敗数 − 失敗系コードの件数合計」の**差分**で求める。
- **未知の理由コードはすべて「その他（要調査）」へ倒す**。誤って一時的エラーとして黙殺されるより安全側。
  → `IMPORT_LOG_REASON` に新しい失敗理由を追加する際は、**この写像テーブルへの追記が必須**。
- **会社ランが例外で落ちた場合**（失敗店舗 0・`ok=false`）は理由コードも失敗件数も無いため、種別は
  「その他」として扱う。
- **代表種別**（1 会社に複数種別が混在する場合）は **認証エラー > その他 > 一時的エラー** の優先順。
  認証エラーはサロンへの連絡が必要で運営の一次対応が最重要、その他はエンジニア調査が必要で放置すると
  翌日も同じ失敗を繰り返すため、いずれも一時的エラー（翌日の自動リトライで解消しうる）より優先する。
- **同一種別内で理由が複数のとき**は件数が最も多い理由の文言を出し、他が残っていれば末尾に `（ほか{n}件）`
  を付ける。同数なら上表の並び順で先に来る理由を採る。
- **件数の単位に注意**: ここでいう件数は**理由別の失敗件数**で店舗数とは一致しない。ログイン系は店舗ごとに
  1 件だが `detail_fetch_failed` は**予約ごとに 1 件**計上される。結果行が数えるのは店舗数なので、
  両者の数字が食い違うのは正常。混同を避けるためエラー内容は「件」、結果行は「店舗」で単位を明示する。

### 4.5 見出し

| 代表種別 | 見出し |
|---|---|
| 認証エラー | `🚨 サロンボード取り込み失敗（認証エラー）` |
| 一時的エラー | `🚨 サロンボード取り込み 一部失敗` |
| その他 | `🚨 サロンボード取り込み失敗（要調査）` |

実行経路がサロン本人の手動実行のときは末尾に ` ※サロン本人の実行` を付ける（サロン側の画面でも失敗が
見えており、問い合わせが来る可能性があることを運営へ伝えるため）。

### 4.6 実行経路の表記

| `trigger_type` の値 | 発生源 | 発生日時行の表記 |
|---|---|---|
| `scheduled` | EventBridge Scheduler の日次実行（毎日 0:10 JST） | 自動実行 |
| `manual_admin` | 運営の手動取り込み（`POST /cancellations/import`） | 手動実行：運営 |
| `manual_salon` | サロン本人の手動取り込み（`POST /salonboard/import`） | 手動実行：サロン |
| `manual`（旧値） | #64 以前に記録された実行履歴 | 手動実行 |
| 上記以外 | — | 値をそのまま表記へ用いる |

### 4.7 結果行

数える単位は**店舗**。失敗店舗は「失敗件数が 1 件以上、かつ連携設定未完了で黙らせた店舗ではないもの」、
成功店舗は「対象店舗のうち失敗店舗でも黙らせた店舗でもないもの」。

| 連携単位 | 条件 | 結果行 |
|---|---|---|
| 会社単位 | 全店舗が失敗（未完了店舗なし） | `全店舗失敗（{N}店舗）` |
| 会社単位 | 一部失敗 / 未完了店舗あり | `・成功：{M}店舗` + `・失敗：{店舗名…}` の 2 行（成功 0 なら成功行を省く） |
| 店舗単位 | 失敗 1 店舗 | `{店舗名}が失敗` |
| 店舗単位 | 失敗 2 店舗以上（全滅を含む） | 上記と同じ 2 行形式 |
| — | 会社ランが例外で落ちた | `取り込みを開始できませんでした` |

- 店舗単位は店舗ごとに独立して失敗しているため、全店舗が落ちても「全店舗失敗」は使わず**列挙する**
  （どの店舗が落ちたかが運営の次の一手に直結するため）。会社単位は 1 回のログインで全店舗が巻き添えに
  なるので「全店舗失敗」がそのまま原因を表す。
- 失敗店舗名の列挙は**最大 10 件**。超えた分は `ほか{n}店` と省略する。
- 店舗名が取れない店舗は外部店舗 ID（サロンボードの `H…`）、それも無ければ `(店舗名なし)` で代替する。

### 4.8 対応の目安

**実行経路 × 連携単位 × エラー種別**で出し分ける（実装は 認証 3 経路 × 2 単位 = 6 通り、一時的 3 通り、
その他 1 通りの計 10 通り）。

| 実行経路 | 連携単位 | 種別 | 対応の目安 |
|---|---|---|---|
| 自動 / 手動：運営 | 会社単位 | 認証 | サロンにサロンボードのID/PASS変更有無を確認 → 管理画面で再連携 |
| 自動 / 手動：運営 | 店舗単位 | 認証 | サロンに{店舗名}のID/PASS変更有無を確認 → 管理画面で当該店舗を再連携 |
| 手動：サロン | 会社単位 | 認証 | サロン側でも失敗が見えているため、運営から先回りでフォロー連絡を推奨。（改行）ID/PASS変更有無を確認 → 管理画面で再連携 |
| 手動：サロン | 店舗単位 | 認証 | サロンに{店舗名}のID/PASS変更有無を確認 → 管理画面で当該店舗を再連携。（改行）サロン側でも失敗が見えているため、先回りでフォロー連絡を推奨 |
| 自動 | 会社 / 店舗 | 一時的 | 一時的なエラーの可能性が高いため、手動で再実行して再発するか確認 |
| 手動：運営 | 会社 / 店舗 | 一時的 | 一時的なエラーの可能性が高いため、時間をおいて再実行して再発するか確認 |
| 手動：サロン | 会社 / 店舗 | 一時的 | 一時的なエラーの可能性が高い。サロンから問い合わせが来た場合は（改行）「時間をおいて再度お試しください」と案内 |
| すべて | すべて | その他 | エンジニア調査が必要です{メンション} |

- **認証エラーは連携単位で文言が変わり**、実行経路がサロン本人のときだけフォロー連絡の勧奨が加わる。
  **一時的エラーは実行経路だけで変わり、連携単位では変わらない**。
- 店舗単位 × 認証エラーで失敗店舗が複数のとき、`{店舗名}` は「先頭の店舗名 ほか{n}店」の表現にする。
- 旧値 `manual` は**運営の手動実行と同じ文言**を用いる。
- `{メンション}` は **本番環境かつ** `SLACK_ENGINEER_MENTION_ID` が設定されているときのみ ` <@{メンバーID}>`
  を付ける。素のテキスト（`@名前`）は Slack で通知されないためメンバー ID 形式のみを扱う。
  **本番以外ではメンションしない**（dev の検証で担当者へ通知が飛ぶのを避ける）。これは運用上の要請なので
  **環境変数を dev へ配布しない運用だけに頼らず、コード側の本番判定でもガードする**（二重の防御）。

### 4.9 集約通知（個別 10 通の超過分）

```
🚨 サロンボード取り込み 他{N}社が失敗

■ 発生日時：{YYYY-MM-DD HH:mm}（{実行経路}）
■ 影響範囲：他{N}社（認証エラー{a}社 / 要調査{b}社 / 一時的エラー{c}社）
■ 対応の目安：管理画面の取り込み実行履歴で対象会社を確認

詳細：{管理画面の取り込み実行履歴 URL}
```

環境プレフィックスの扱いは会社単位の通知と同じ。内訳の並びは重大度順（認証エラー → 要調査 → 一時的エラー）。

### 4.10 バッチ全体の失敗（⑬）

会社ごとの通知とは別に、**取り込みバッチ自体が実行できなかった場合**の通知を出す。

```
{環境プレフィックス（本番以外のみ）}
🚨 サロンボード取り込みバッチが実行できませんでした

■ 発生日時：{YYYY-MM-DD HH:mm}（{実行経路}）
■ 影響範囲：{影響範囲}
■ エラー内容：バッチ実行エラー
■ 対応：エンジニア調査が必要です{メンション}

詳細：{管理画面の取り込み実行履歴 URL}
```

- **影響範囲**は、対象会社を指定しない実行（日次スケジュール）では `全連携会社（本日分の取り込みが未実行です）`、
  対象会社を指定した実行（手動取り込み）では `{会社名}（当該会社の取り込みが未実行です）`。会社名が取れない
  場合は申請 ID で代替する。
- **エラー種別の写像は用いず固定文言**（⑬ は常に「エンジニア調査が必要」なため）。
- **会社ごとの通知とは排他**。この通知が出るとき会社ごとの通知は投稿しない（同一実行で二重に鳴らさない）。
  会社ループを回す関数は 1 会社の失敗を握り潰して結果配列へ積むため、**この関数が例外を投げるのは会社ループを
  最後まで回せなかったとき**に限られ、そのとき呼び出し元が受け取る会社別結果は空になる。

**投入箇所は 3 経路**（いずれも「失敗しても呼び出し元を壊さない」通知関数 `notifyImportBatchFailure` を共有する）。

| 実行基盤 | 契機 | 通知後の挙動 |
|---|---|---|
| batch Lambda / batch ECS | 会社ループに入る前の致命的失敗（連携会社一覧の取得失敗など） | 通知 → 取り込みは summary へ畳んで終了 |
| batch Lambda / batch ECS | 取り込みアクションの実行が例外で終了 | 通知 → **再送出**（Lambda は Sentry の捕捉と非同期 invoke の失敗契約、ECS は終了コード 1 を維持） |
| API Lambda | 手動取り込みで batch Lambda の非同期 invoke が失敗 | 通知 → 既存どおり再送出（API は 500） |

> **アクション例外時の通知は `dispatchBatchAction`（`src/batch.ts`）の 1 箇所だけ**に置く。Lambda handler と
> ECS の `runCli` は同じ関数を通るため、`batch-cli.ts` にも置くと ECS 経路だけ 2 通飛ぶ。

**検知範囲の限界**: **日次スケジュール**で ECS タスクが 1 秒も動かなかったケース（コンテナイメージの取得失敗、
RunTask API のスロットリング、EventBridge Scheduler の停止）は、アプリのコードが 1 行も動かないため本通知では
検知できない。これらは infra 側の 3 層（EventBridge Scheduler の DLQ / `TaskFailedToStart` の EventBridge ルール
→ SNS / `[batch-cli] failed` のメトリクスフィルタ + アラーム → SNS）に委ねる。→ `docs/tech/batch-fargate.md`

## 5. 環境変数

| 変数 | 秘密 | 用途 | 未設定時 |
|---|---|---|---|
| `SLACK_BOT_TOKEN` | ○ | Slack App の Bot Token（`xoxb-…` / 要 `chat:write`） | Webhook へフォールバック |
| `SLACK_ALERT_CHANNEL` | × | 通知先チャンネル **ID** | Webhook へフォールバック |
| `SLACK_WEBHOOK_URL` | ○ | Incoming Webhook URL | 通知 no-op |
| `SLACK_ENGINEER_MENTION_ID` | × | 「その他（要調査）」通知のメンション先メンバー ID（`U…`） | メンションなしで通知（通知自体は出る） |
| `ADMIN_URL` | × | 通知末尾の詳細リンクの基底 URL | prod=`https://admin.cancel.co.jp` / それ以外=`https://dev.admin.cancel.co.jp` |

> **`SLACK_ENGINEER_MENTION_ID` は prod にのみ配布する**（dev では鳴らさない運用）。アプリ側も本番判定で
> ガードしているため、仮に dev へ値が入っても通知は付かない（二重の防御）。

> **`ADMIN_URL` を CI の環境変数から素通しで配布してはならない。** CI 側に定義が無いと空文字になり、
> 設定の既定（prod URL）へ落ちて dev のリンクが本番管理画面を指す。`API_BASE_URL` と同じく
> **デプロイ対象の環境名から導出する**（`deploy-*.sh` の `ADMIN_URL_ENV` / ECS は `DEPLOY_ENV` の三項）。

### 実行経路ごとの配布

| 経路 | スクリプト | 配布方法 |
|---|---|---|
| API Lambda | `deploy-api.sh` | Slack 3 変数 + `SLACK_ENGINEER_MENTION_ID` + `ADMIN_URL` を Lambda の全置換 `environment` へ |
| batch Lambda | `deploy-batch.sh` | 同上 |
| batch ECS(Fargate) | `deploy-batch-ecs.sh` | **`SLACK_ALERT_CHANNEL` / `SLACK_ENGINEER_MENTION_ID` / `ADMIN_URL` のみ** task definition の `environment` へ |

> **手動取り込みの通知は batch 側から飛ぶ**。dev / prod では手動取り込み（運営・サロン本人とも）が
> batch Lambda へ非同期委譲されるため、通知を投稿するのは API Lambda ではなく batch Lambda になる
> （API は `202 Accepted` を返した時点で通知の成否を知らない）。日次は batch ECS。したがって上記 5 変数は
> **batch Lambda と batch ECS の両方へ確実に配布する**必要がある。API Lambda 側は同期実行になる local でのみ
> 投稿するが、環境変数の欠落で挙動が分岐しないよう同じ変数を配布する。

> **ECS だけ扱いが異なる理由**: `deploy-batch-ecs.sh` は GTSS-860 のレビュー指摘［Security］で
> 「実秘密を task definition の `environment`（平文）に入れない」方針を採っており、`ecs:DescribeTaskDefinition`
> 権限だけで平文が読めてしまうのを避けている。`SLACK_BOT_TOKEN` / `SLACK_WEBHOOK_URL` は
> `STRIPE_SECRET_KEY` / `DECODO_PASSWORD` と同じく **ECS `secrets`（`valueFrom`=SSM Parameter Store）**
> 経由で注入する。register 前の自己検証がこの 2 変数の `environment` 混入を実際に弾く。

> **⚠️ Lambda の env 全置換**: `deploy-api.sh` / `deploy-batch.sh` は
> `update-function-configuration --environment` で環境変数セットを**全置換**する。生成 JSON に含めないと
> 毎デプロイで消える（`SENTRY_DSN` と同じ罠）。コンソールでの手動設定は次回デプロイで消えるため禁止。

### dev の配線状況（適用済み）

**dev は shaire ワークスペースの Bot Token を流用**して配線済み（インフラリポジトリ
`~/infra/cancel-billing-service-infra` の `GTSS-817-qa`）。

| 項目 | 値 |
|---|---|
| SSM パラメータ | `/cancel/api/slack_bot_token`（SecureString・実値は CLI 直 push で state 非搭載） |
| 通知先チャンネル | `C0BP5RM3709`（`var.slack_alert_channel`。#64 で専用チャンネルへ切替え。dev / prod 共通） |
| Slack workspace | `GO TODAY SHAiRE SALON`（`TGCRC9VDY`。`var.slack_team_id` と同一） |
| bot | `shaire`（`U08R3QQ1M2M`。shaire-server の `SlackNotifier` と同じトークン） |

配線の内訳:
- `dev/codebuild.tf` の `ci_api_secret_keys` へ `slack_bot_token` を追加 → `ci_api` の `ssm_env_vars` に
  `SLACK_BOT_TOKEN` が自動で入り、`deploy-api.sh` / `deploy-batch.sh` が Lambda の全置換 environment へ投入する
- `var.slack_alert_channel` を `ci_api` / `ci_batch_image` の `plain_env_vars` へ `SLACK_ALERT_CHANNEL` として供給
- `batch_fargate.container_secrets` へ `SLACK_BOT_TOKEN` を追加（タスク実行ロールの `ssm:GetParameters` 許可）
- `ci_batch_image.plain_env_vars` へ `BATCH_CONTAINER_SECRETS` を追加 → `deploy-batch-ecs.sh` が
  task definition の `secrets` へ載せる（後述）

#### ECS task definition の `secrets` は deploy スクリプトが所有する

`aws_ecs_task_definition` は `lifecycle { ignore_changes = [container_definitions] }` を持つ。これは
「TF apply のたびに task definition が `:bootstrap` イメージ + 最小 env へ巻き戻るのを防ぐ」ための
所有分割（TF = 骨組み / deploy スクリプト = イメージタグと環境変数）だが、**`ignore_changes` は更新時のみ
効き、新規作成時は効かない**。そのため `container_secrets` へ後から追加しても、**既に存在する family の
リビジョンには永久に反映されない**。

実例（dev 実測）: GTSS-886 で追加した `TWILIO_AUTH_TOKEN` は新規 family の `reminders` にだけ入り、
既存の `import` / `payouts` には入っていなかった。`SLACK_BOT_TOKEN` も同じ理由で落ちる。

そこで `deploy-batch-ecs.sh` が `environment` と同様に `secrets` も所有する（GTSS-817-qa）。

- 供給源は CI が注入する `BATCH_CONTAINER_SECRETS`（`NAME=SSM の ARN` のカンマ区切り）
- Terraform 側で `container_secrets`（= IAM 許可）と**同じ `local` から生成**するため、スクリプトの
  一覧と実行ロールの許可がズレない（ズレると `ResourceInitializationError` で起動失敗する）
- 既存（`describe`）との**和集合**にし、同名はスクリプト定義を優先する。TF や手動で足された参照を
  落として起動時 env が欠ける事故を避ける
- **未設定なら既存 `secrets` を温存**（従来挙動。prod / 手元実行の後方互換）
- `valueFrom` が ARN でなければ parse 時と register 前ガードの二重で拒否する（実値を渡した場合に
  task definition へ平文で焼き込まないため）

> **秘匿性**: `secrets[].valueFrom` に入るのは **SSM の ARN（参照）であって値ではない**。実値は起動時に
> ECS agent が SSM から取得し、task definition にも CodeBuild ログにも載らない。「実秘密を
> `environment`（平文）へ入れない」という GTSS-860 の不変条件は維持される。

> **通知先は dev / prod とも `C0BP5RM3709`**（#64 / REQ-10）。以前は shaire の業務チャンネル
> （`C08NVDWCS5T`）を暫定流用していた。dev と prod を同一チャンネルへ流し、本文冒頭の環境プレフィックス
> （本番以外のみ `[dev]`）で運営が本番のアラートだけを拾えるようにする。運用してノイズが多ければ
> チャンネル分割を検討する。
>
> **チャンネルへ bot を招待しておくこと。** 未招待だと `chat.postMessage` が `not_in_channel` で失敗し、
> **無音で通知だけが届かない**。この bot は `chat:write` のみで `channels:read` を持たないため、参加確認は
> Slack API から取れない。
>
> **チャンネル変更は apply だけでは反映されない。** チャンネル ID は CodeBuild の環境変数 → デプロイ
> スクリプト → Lambda の環境変数 / ECS のタスク定義、という経路で届くため、apply 後に
> **API Lambda・batch Lambda・batch ECS の再デプロイ**が必要になる。

### 未対応（インフラリポジトリ側の別作業）

- **Webhook 方式は未使用**。`SLACK_WEBHOOK_URL` を使う場合も SSM + `ssm_env_vars` へ同様に追加する。

未実施の間は Slack 通知が no-op になるだけでデプロイもバッチも通常どおり完走する
（`buildspec.yml` / `buildspec-batch.yml` にコメントで明記済み）。

### prod の配線状況（コードは投入済み・**apply は未実施**）

`prod/codebuild.tf` / `prod/main.tf` を dev と同一構成にしてある（インフラリポジトリ `GTSS-817-qa`）。
**apply と SSM 実値投入は本番のため人手**で行う。

plan（`-target` なしの完全 plan でも同一。無関係 drift 無し）:

```
Plan: 1 to add, 4 to change, 0 to destroy
  aws_ssm_parameter.api_secret["slack_bot_token"]                create
  module.batch_fargate.aws_iam_role_policy.task_exec_secrets[0]  update in-place
  module.ci_api.aws_codebuild_project.this                       update in-place
  module.ci_api.aws_iam_role_policy.codebuild                    update in-place
  module.ci_batch_image.aws_codebuild_project.this               update in-place
```

task definition の再 register も destroy も発生しない。

**実施順序（重要）**

1. `cd prod && terraform apply` — SSM プレースホルダ作成 + CodeBuild env 更新
2. `aws ssm put-parameter --overwrite --name /cancel/api/slack_bot_token --type SecureString --value <Bot Token>`
   （**apply より先に put すると `aws_ssm_parameter` の作成が `ParameterAlreadyExists` で落ちる**）
3. 次の prod デプロイで反映される。ECS 側は `deploy-batch-ecs.sh` が `secrets` を載せるので
   **task definition の `-replace` は不要**

> プレースホルダのまま先にデプロイしても ECS / Lambda は起動する（SSM パラメータは存在するため
> `GetParameters` は成功する）。値が `PLACEHOLDER_...` なので `chat.postMessage` が `invalid_auth` で
> 失敗し、**通知だけが届かない**（バッチ本体は正常に完走する）。

**あわせて実施すること（#64 / REQ-10）**

- 通知先 default は dev / prod とも `C0BP5RM3709`。**このチャンネルへ bot を招待**しておく
  （未招待だと `not_in_channel` で無音になる）。
- `prod/codebuild.tf` の `ci_api` / `ci_batch_image` の `plain_env_vars` へ `SLACK_ENGINEER_MENTION_ID`
  （`U0427P7UCMB`）を追加済み。**prod のみ**で dev へは配布しない。
- apply 後に **API Lambda・batch Lambda・batch ECS を再デプロイ**する（env は CI → デプロイスクリプト →
  Lambda / task definition の経路で届くため）。
- **自動実行のパターンは日次スケジュールを有効化しない限り本番で一度も発火しない**。dev / prod とも
  取り込みスケジュールは現在停止中（2026-07-25 に ECS 移行の様子見で停止したまま）。有効化しないまま
  「自動実行の通知が来ない」と判断すると誤診になる。手動実行の経路では全パターンを検証できる。

## 6. Slack 側の準備手順

どちらか一方でよい（両方設定した場合は Bot Token が優先される）。

### A. Bot Token 方式（推奨）

1. Slack App を用意する（既存 shaire ワークスペースの App を流用するか、cancel 専用 App を作る）。
2. OAuth スコープに **`chat:write`** を付与し、ワークスペースへインストールして Bot Token（`xoxb-…`）を取得する。
3. 通知先チャンネルへ **bot を招待する**（`/invite @<app名>`）。招待しないと `not_in_channel` で失敗する。
4. チャンネル ID を取得して `SLACK_ALERT_CHANNEL` に設定する（チャンネル名ではなく ID）。

### B. Incoming Webhook 方式

1. Slack App の Incoming Webhooks を有効化し、通知先チャンネルを選んで Webhook URL を発行する。
2. `SLACK_WEBHOOK_URL` に設定する（URL 自体が秘密なので SSM / env で扱い、コミットしない）。

## 7. 動作確認（dev）

1. 上記を設定して dev へデプロイする（Slack 3 変数 + `SLACK_ENGINEER_MENTION_ID` は prod のみ）。
2. admin から手動取り込みを 1 回実行する（失敗が出る会社を対象にする）。
3. 通知先チャンネルへ**当該会社ぶんの 1 通**が届くことを確認する。本文に次が載っている:
   - 冒頭の環境プレフィックス `[dev]`（本番では付かない）
   - 見出し（種別で切り替わる）・`■ 発生日時：`（JST・`（手動実行：運営）`）・`■ 会社：`・`■ 連携単位：`
   - `■ 結果：`（連携単位と失敗の広がりで出し分け）・`■ エラー内容：`（理由コード由来の固定文言）
   - `■ 対応の目安：`（実行経路 × 連携単位 × 種別）
   - `詳細：https://dev.admin.cancel.co.jp/import-runs`
4. **本文に載っていないこと**も確認する: 診断ダンプ（着地 URL・doLogin 応答・遮断シグナル）、
   CloudWatch ロググループ名、外部システムの生エラー文言。
5. 改行・全角スペースのインデント・絵文字が Slack クライアントで意図どおり表示されることを目視確認する。
6. 「詳細」リンクを開き、**dev 管理画面**（`dev.admin.cancel.co.jp`）の取り込み実行履歴が開くことを確認する。
7. サロンポータルからサロン本人として手動取り込みを実行し、見出しに ` ※サロン本人の実行` が付き、
   対応の目安がサロン向け文言になることを確認する。
8. **dev で「その他（要調査）」種別の通知を発生させ、メンションが飛ばないこと**を確認する
   （`SLACK_ENGINEER_MENTION_ID` を dev へ配布していなくても、コード側の本番判定でも抑止される）。
9. 環境変数を**未設定のまま**デプロイしても、デプロイが成功し取り込みが完走することを確認する
   （情報ログ `[slack] 通知先が未設定のため送信をスキップしました` が 1 行出るだけ）。

### prod でのみ確認できること

- 「その他（要調査）」種別の通知で **実際に担当者へメンションが飛ぶ**こと（`SLACK_ENGINEER_MENTION_ID`）。
- `SLACK_ALERT_CHANNEL` が `C0BP5RM3709` を指し、bot が招待済みであること（未招待だと無音）。
