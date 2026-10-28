<div align="center">

# Google Cloud Logging → ClickHouse Cloud

**Cloud Logging のログを Pub/Sub ClickPipes で ClickHouse Cloud に流し込み、ClickStack で検索する。**

[![Docs](https://img.shields.io/badge/docs-site-black)](https://tkykenmt-at-ch.github.io/sample-google-cloud-logging-to-clickhouse/ja/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![ClickHouse Cloud](https://img.shields.io/badge/ClickHouse_Cloud-26.6%2B-FAFF69?logo=clickhouse&logoColor=black)](https://clickhouse.com/cloud)
[![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A5_1.9-7B42BC?logo=terraform&logoColor=white)](terraform/)
[![Pub/Sub ClickPipes](https://img.shields.io/badge/Pub%2FSub_ClickPipes-Private_Preview-orange)](docs/ja/findings.md)

[English](README.md) · 日本語

<img src="docs/images/dashboard.png" alt="取り込んだ Cloud Logging のログで作った ClickStack のダッシュボード" width="900">

</div>

> [!NOTE]
> Pub/Sub ClickPipes は検証時点（2026-10）で Private Preview で、挙動は今後変わる可能性があります。
> 主な挙動は実機で確認しています。検証日、バージョン、条件、測定値、未検証の項目は [検証記録](docs/ja/findings.md) にあります。
> 採用前に [ハンズオン](docs/ja/hands-on.md) で同じ確認を利用者の環境で行ってください。

## 特長

- **エージェント不要。** Log Router のシンクが Pub/Sub へ送り、ClickPipe が ClickHouse Cloud へ INSERT します。
- **作り直せる。** L0 が LogEntry を受け取ったまま保存するので、検索用のテーブルは SQL で作り直せます。
- **ClickStack ですぐ使える。** L1 は共通項目を列に、個別の内容を属性に持つので、ClickStack の検索とダッシュボードがそのまま動きます。
- **日本語の全文検索。** `Body` に 2 文字の n-gram のテキストインデックスを張っています。単語区切りのトークナイザでは、日本語の文が 1 つのトークンになり、検索が 0 件になります。
- **Terraform でも画面操作でも。** plan だけで動くテストつきの Terraform 構成と、同じ構成をブラウザで作る手順（画面の画像つき）があります。ClickPipes の認証は、サービスアカウントのキーか Workload Identity を選べます。
- **まず手元で試せる。** `verify/local_e2e.sh` が SQL 一式を `clickhouse local` で動かします。

## 構成

```mermaid
flowchart LR
  CL["Cloud Logging<br/>プロジェクトの全ログ"] -->|"Log Router のシンク"| T["Pub/Sub トピック<br/>メッセージ保持なし"]
  T -->|"管理サブスクリプション"| CP["ClickPipe<br/>仮想列だけを INSERT"]
  subgraph CH["ClickHouse Cloud"]
    direction LR
    L0["L0 着地<br/>受け取ったまま"] -->|"MV で解析"| L1["L1 検索<br/>共通項目は列、中身は属性"]
  end
  CP --> L0
  L1 --> CS["ClickStack<br/>検索とダッシュボード"]
```

取り込んだログは、マテリアライズドビュー（MV）で解析・整形します。

| 層 | 必須か | 内容 |
|---|---|---|
| L0 | 必須 | 受信した LogEntry をそのまま保存する。L1・L2 を再構築する際の元データ |
| L1 | 必須 | LogEntry の共通項目（時刻、重大度、ログ名、リソース、トレース、HTTP の主要項目）は列に、個別の内容は属性に保存する。検索、値の取り出し、ダッシュボードはまず L1 で行う |
| L2 | 任意 | ログの種類ごとに作る型付きテーブル。L1 で要件を満たせない場合に作成する |
| L3 | 任意 | 集計テーブル。長期間の推移を見る場合や、集計結果だけを長く保持する場合に作成する |

テーブルと MV のつながり、列の定義は [設計](docs/ja/design.md) の「全体像」と「テーブル定義」にあります。

## クイックスタート

クラウドのリソースを作らずに、SQL 一式をローカルで確認できます（`clickhouse` と `python3` が必要です）。

```bash
verify/local_e2e.sh 20000
```

L0、L1、L2、L3、ノイズの集計テーブルの件数を照合し、日本語の全文検索の確認結果とともに表で表示します。

実環境に構築する場合は、[導入](docs/ja/setup.md) の手順で Terraform を使います。
gcloud と clickhousectl で 1 つずつ作りながら仕組みを確かめる手順は、[ハンズオン](docs/ja/hands-on.md) の第 3 部にあります。

> [!WARNING]
> `terraform apply` を実行した時点から、シンクはプロジェクトの全ログを Pub/Sub へ送り、Pub/Sub の料金がかかります。
> 先に [導入](docs/ja/setup.md) の「始める前に」を読み、まず検証用のプロジェクトで試してください。

## ドキュメント

同じ文書は検索つきの [ドキュメントサイト](https://tkykenmt-at-ch.github.io/sample-google-cloud-logging-to-clickhouse/ja/) でも読めます。

| ドキュメント | 内容 |
|---|---|
| [設計](docs/ja/design.md) | 要点、層の役割、L2 を作る判断、費用の見積もり方、大きさの見積もり方、利用者の環境で決めること、設計の詳細 |
| [導入](docs/ja/setup.md) | 始める前の注意、Terraform での構築、作成後の設定の変更、削除 |
| [ブラウザで導入する](docs/ja/setup-console.md) | Terraform を使えない環境向けに、同じ構成を Google Cloud と ClickHouse Cloud の画面だけで作る（画面の画像つき） |
| [ハンズオン](docs/ja/hands-on.md) | ローカルの `clickhouse local` だけで SQL を動かす第 1 部、Terraform で実環境に構築して ClickStack で検索する第 2 部、同じものを gcloud と clickhousectl で 1 つずつ作る第 3 部 |
| [トラブルシューティング](docs/ja/troubleshooting.md) | 取り込みの遅れ、1 回の INSERT がまたぐパーティション、パーツの数を、症状から切り分ける手順 |
| [運用](docs/ja/operations.md) | 日常の確認、ノイズの除去、L2 と L3、MV のエラーへの対処、避ける操作、保持期間の変更、本番ログへの切り替え、L0・L1 の作り直し（付録） |
| [検証記録](docs/ja/findings.md) | 実機で確かめた挙動と数値 |

<details>
<summary><b>ディレクトリ構成</b></summary>

| パス | 内容 |
|---|---|
| `terraform/` | トピック、シンク、IAM、ClickPipes のサービスアカウント、テーブルと MV（`sql/` を実行）、ClickPipe、ClickStack のソースとダッシュボード。`terraform/tests/` に plan だけで動くテスト（`terraform test`、認証情報は不要） |
| `sql/` | L0、L1、MV1、L3（分単位の件数）、ノイズの件数の DDL。`{{VAR}}` は適用時に置き換える |
| `sql/examples/` | 任意の L2 の例（監査ログ、GKE のアップグレード通知） |
| `sql/runbooks/` | 変更の種類ごとの SQL ひな型 |
| `loadgen/gen_logentry.py` | 合成 LogEntry の生成と Pub/Sub への公開（標準ライブラリのみ） |
| `verify/local_e2e.sh` | ローカルの ClickHouse で SQL 一式を通して確認する |
| `verify/completeness.sh` | 公開したメッセージ ID の全件と L0、L1 を突き合わせる |
| `verify/checks.sql` | 遅延、処理が停滞したバッチ、重複、遅延到着、解析の状態、滞留、パイプの INSERT、パーツの数などの定期確認 |
| `tools/chq.py` | SQL ファイルを 1 文ずつ `clickhousectl cloud service query` で実行する |
| `tools/wait_subscriptions_gone.py` | ClickPipes が管理サブスクリプションを削除し終えるのを待つ（`terraform destroy` が使う） |
| `mkdocs.yml`, `tools/mkdocs/` | `docs/` と README から作るドキュメントサイト。`.github/workflows/pages.yml` が GitHub Pages に公開する |

</details>

## 対象外

- Cloud Logging の Logs Explorer の機能と ClickStack の機能の対応付け
- 負荷試験によるパイプとサービスの大きさの確定（[設計](docs/ja/design.md) の見積もりは公式の目安によるもので、検証記録の負荷試験は小規模です）
- `_Default` バケットのシンクの変更（本番ログへの切り替えは利用者の環境で定めた手順で行います）

## ライセンス

Apache License 2.0 です。
[LICENSE](LICENSE) を参照してください。
