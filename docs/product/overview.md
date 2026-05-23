# 製品概要

## サービス名

Cancel Billing Service（キャンセル請求便）

## 何をするサービスか

サロン (美容室・ネイル・エステ等) 向けの **顧客キャンセル料 請求代行サービス**。

予約をドタキャンした顧客に対する請求・回収業務をサロンに代わって行う。サロンは Stripe Connect 経由でオンボーディングし、本サービスが集金 → サロン口座へ payout する。

## ターゲット顧客

- 美容サロン事業者（個人〜小規模法人）
- ドタキャン被害を金額面で取り戻したいが、自社で督促業務を行いたくない事業者

## 主要なバリュー

1. サロンが請求業務を負担しない（メール／SMS 督促は本サービスが代行）
2. Stripe Connect で資金フローが明確（売上は本サービス → サロンへ送金）
3. LP からの申請・オンボーディングまで完全 Web 完結

## システム構成

| 役割 | サブリポジトリ | URL (prod) |
|---|---|---|
| LP・申請フォーム | `cancel-billing-service-lp` | https://cancel.co.jp |
| サロン向けポータル | `cancel-billing-service` | https://user.cancel.co.jp |
| 運営者管理画面 | `cancel-billing-service-admin` | https://admin.cancel.co.jp |
| バックエンドAPI | `cancel-billing-service-api` | https://api.cancel.co.jp |

詳細: `docs/tech/architecture.md`

## ステークホルダー別の使い方

| ステークホルダー | 主な接点 | 主なアクション |
|---|---|---|
| **サロン（利用者）** | LP → ユーザーポータル | 申請・Stripe オンボーディング・請求一覧確認 |
| **顧客（サロンのお客）** | メール/SMS の決済リンク | キャンセル料の決済 |
| **運営者（GTSS）** | 管理画面 | 申請審査・キャンセル請求登録・対応状況管理 |
