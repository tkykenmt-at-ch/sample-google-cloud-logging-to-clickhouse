# 費用の見積もり

[English](../en/03-cost.md) | 日本語

ClickHouse に移したときの月額を、PoC の前は量から概算し、PoC の後は利用者の環境の実測から出します。
同じ保持日数で Cloud Logging に保管し続ける場合とも比べます。
サービスと ClickPipes の大きさは [計画](02-planning.md) の「大きさの見積もり方」で決めます。

> 料金と仕様は 2026-10-05 に公式資料で確かめた値です。
> Private Preview の機能は、一般提供（GA）までに挙動や料金が変わることがあります。
> 「（確認済み）」「（公式資料）」「（PoC で確認）」の意味は [設計](01-design.md) の冒頭にあります。

## 費用の全体像

移すと Cloud Logging の取り込みと保管が減り、Pub/Sub、ClickPipes、ClickHouse Cloud が増えます。

| 区分 | 項目 | 何に比例するか | 単価（公式資料） |
|---|---|---|---|
| 減る | Cloud Logging の取り込み | `_Default` に入れなくなるログの量 | $0.50/GiB、最初の 30 日の保管を含む（[料金](https://cloud.google.com/stackdriver/pricing)） |
| 減る | Cloud Logging の保管（30 日を超えた分） | 保管するログの量と日数 | $0.01/GiB・月（同上） |
| 増える | Pub/Sub の公開 | シンクが送る量 | $40/TiB（[料金](https://cloud.google.com/pubsub/pricing)） |
| 増える | Pub/Sub の配信 | シンクが送る量 × サブスクリプションの数 | $40/TiB（同上） |
| 増える | ClickPipes | 読んだ量と、レプリカの大きさ × 数 × 時間 | 他のストリーミング ClickPipes は $0.04/GB と、ユニット・時間あたりの料金（[料金](https://clickhouse.com/docs/products/cloud/reference/billing/clickpipes/clickpipes-for-streaming-and-object-storage)）。Pub/Sub は Private Preview で、料金は ClickHouse に確認する |
| 増える | ClickHouse Cloud の計算資源 | サービスの大きさ × 時間 | プランとリージョンごと（[料金](https://clickhouse.com/pricing)） |
| 増える | ClickHouse Cloud のストレージとバックアップ | ディスク上の量（圧縮後、インデックスを含む） | 同上 |

- 無料枠は、Cloud Logging がプロジェクトごとに毎月 50 GiB、Pub/Sub が請求先アカウントごとに毎月 10 GiB です。
- Cloud Logging の費用が下がるのは、`_Default` バケットへの保存を止めたときです（[設計](01-design.md) の「要点」）。

## PoC の前に概算する

まだ ClickHouse に流していない段階では、Cloud Logging の課金対象の量から概算します。
表計算のひな形（下の「PoC の実測から月額を出す」）に、次の値を入れます。

1. **Cloud Logging の課金対象の量（月）**：請求のレポートで、サービスを Cloud Logging に絞った SKU「Log Storage cost」の使用量です。
   ひな形の B9 に入れます。
2. **Pub/Sub と ClickPipes の量**：シンクが送る JSON は、課金対象の量より大きくなります。
   検証では、Cloud Logging が課金する種類のログで約 1.2 倍でした（[検証記録](09-findings.md) の「Pub/Sub の課金対象量」）。
   1 日あたりの課金対象の量 × 1.2 を、B6（GB）、B7 と B8（GiB）に入れます。
   `_Required` 行きのログもシンクで送るなら、その量を足します。
3. **保存量**：圧縮率を仮に置いて、1 日の量 ÷ 圧縮率を B4 と B5 に入れます。
   ClickHouse Cloud の料金計算機の既定は 10:1 です。
   実際の圧縮率と、テキストインデックスの分は PoC で測ります。
4. **計算資源とレプリカ**：[計画](02-planning.md) の「大きさの見積もり方」で決めた大きさから、1 日の計算資源の費用を出して B10 に入れます。
   ClickPipes のレプリカのユニットを B17 に入れます。

概算は、ログの構成で大きく外れることがあります。
並走を始めたら、次の節の手順で実測に置き換えます。

## PoC の実測から月額を出す

本番の量を流し始めたら、利用者の環境で測った量から月額を出します。
手順は、量を取る、ひな形に入れる、結果を読む、の順です。

### 1. 量を取る

`tools/cost_inputs.py` が、Cloud Monitoring、ClickHouse Cloud の API、サービスの system テーブルから必要な量を集め、ひな形のどのセルに入れるかを表示します。

```bash
gcloud auth application-default login        # Cloud Monitoring と Pub/Sub を読む
export CLICKHOUSE_CLOUD_API_KEY=<key id>      # clickhousectl に保存した API キーでもよい
export CLICKHOUSE_CLOUD_API_SECRET=<key secret>
python3 tools/cost_inputs.py --project <project> --topic <topic> --service <service id> --days 7
```

- 期間は、昨日までの UTC の完全な日です。
  平日と休日を含む 1 週間を基準にします。
  ログの量は曜日で変わるので、数日分だけでは偏ります。
- ClickHouse Cloud の system テーブルのログ（`query_log`、`part_log`、`metric_log`）は約 7 日で消えます（確認済み）。
  基準の 1 週間が終わったら、すぐに実行します。
- 取り込みが遅れた期間や、溜まった分を取り戻した期間は、基準にしません。
- 読めなかった項目は、最後に理由とともに表示されます。
  その項目は、下の表の「手で取る場合」で取ります。

**要る権限**

| 読む先 | 権限 |
|---|---|
| Cloud Monitoring、Pub/Sub のサブスクリプション一覧 | プロジェクトの Monitoring 閲覧者（`roles/monitoring.viewer`）と Pub/Sub 閲覧者（`roles/pubsub.viewer`） |
| ClickHouse Cloud の使用量（usageCost） | 組織の請求を読める API キー |
| ClickHouse Cloud の Prometheus のエンドポイント | サービスを読める API キー |
| system テーブル | サービスへのクエリ（`clickhousectl cloud service query`） |

**取るもの**

| ひな形のセル | 量 | スクリプトが読む先 | 手で取る場合 |
|---|---|---|---|
| B4、B5 | L1 と L0 の 1 日あたりのディスク上の量（GB） | `system.parts` の `bytes_on_disk`（日付のパーティションごと） | `verify/checks.sql` の 17 番の `on_disk_gb` を平均する |
| B6 | ClickPipes が読んだ量（GB/日） | L0 の非圧縮の量（`system.parts` の `data_uncompressed_bytes`）。パイプが報告する量とは少し違うことがある | パイプの Metrics タブ、または Prometheus のエンドポイントの `ClickPipes_FetchedBytes_Total` の 1 日の増分 |
| B7 | Pub/Sub の公開の計上量（GiB/日） | Cloud Monitoring の `pubsub.googleapis.com/topic/byte_cost`（PromQL の API） | Metrics Explorer で同じ指標を、トピックで絞って 1 日ごとに合計する |
| B8 | Pub/Sub の配信の計上量（GiB/日） | `pubsub.googleapis.com/subscription/byte_cost` を、トピックを読む全部のサブスクリプションで足す | 同上。並走が 1 か月を超えたら、請求の SKU「Message Delivery Basic」と比べる |
| B9 | Cloud Logging の課金対象の量（GiB/月） | `logging.googleapis.com/billing/bytes_ingested`（プロジェクト全体） | 請求のレポートの SKU「Log Storage cost」の使用量 |
| B10、B12、B13 | サービスの計算資源、ストレージ、バックアップ（USD/日、今のプランの定価） | ClickHouse Cloud の使用量の API（`clickhousectl cloud org usage`） | Console の Settings → Usage breakdown（[使用量の確認](https://clickhouse.com/docs/products/cloud/reference/billing/billing-overview#how-can-i-keep-track-of-my-spending)） |
| B17 | ClickPipes のレプリカの合計ユニット | Prometheus のエンドポイントの `ClickPipes_Replica_MemoryLimit`（8 GiB で 1 ユニット） | パイプの Settings → Advanced Settings → Scaling の大きさと数 |

Cloud Monitoring の PromQL の API が返す 1 日分の値は、Monitoring の v3 API で 1 日ごとに合計した値と一致しました（確認済み）。
検証では、配信の計上量は公開の約 1.6 倍でした（ack と ack 期限の延長も計上されるため）。

### 2. ひな形に入れる

ひな形は [cost_estimate.csv](../files/cost_estimate.csv)（英語版は [cost_estimate.en.csv](../files/cost_estimate.en.csv)）です。
Google スプレッドシートなら、ファイル → インポートで読み込むと式が動きます。

- B4〜B13 と B17 に、スクリプトの値を入れます。
- 単価（B14〜B16、B18〜B22）は、それぞれの料金ページでクラウド、リージョン、プランを選んで入れます。
  B14 は今のプラン、B15 は本番で使うプランの計算資源の単価です。
- B11（検索で足す計算資源）は、代表クエリを測るまで 0 のままにします（下の「計算資源の内訳を見る」）。

### 3. 結果を読む

| 行 | 意味 |
|---|---|
| B31 | ClickHouse に移した場合の月額。保持日数分のログがたまった定常状態 |
| B32 | 同じ保持日数で Cloud Logging に保管し続ける場合の月額 |
| B33 | 差額 |
| B34 | 空の状態から始めた 1 年目の平均の月額。ストレージとバックアップは保持日数分たまるまで増えるので、400 日保持なら 1 年目は定常の半分弱になる |

- 計算資源（B26）は、期間中に動いた処理の分です。
  検索の負荷が PoC より増える場合は、B11 に足します。
- 移行の途中は、Cloud Logging と ClickHouse の両方に保管する期間の費用が加わります。
- Cloud Logging と比べるときは、同じ課金対象の量を使います。

## 計算資源の内訳を見る

サービスの計算資源の大きさは、取り込み、マージ、検索のどれに CPU を使っているかで決まります。
`verify/checks.sql` の次の番号で確かめます（`python3 tools/chq.py verify/checks.sql`）。

| 番号 | 分かること | 使い方 |
|---|---|---|
| 18 | 1 日あたりの CPU 時間を、パイプの INSERT、クエリ、表ごとのマージに分けたもの | 取り込みとマージが大半なら、[トラブルシューティング](08-troubleshooting.md) の「パーツの数」やパイプの待ち時間（[計画](02-planning.md) の「利用者の環境で決めること」）で減らせる余地がある |
| 19 | レプリカごとの CPU とメモリの、1 時間ごとの平均と p99 | 平均と p99 の差が大きいほど、ピークに合わせた大きさになっている |
| 20 | L1 のインデックスごとの大きさ | ストレージのうち、本文の全文検索インデックスが占める割合 |
| 21 | 代表クエリの 1 回あたりの CPU 秒と読んだ量 | 代表クエリに `SETTINGS log_comment = 'rep:<名前>'` を付けて実行する。CPU 秒 × 1 日の実行回数 ÷ 3,600 ÷ 2 を B11 に入れる（1 ユニットは 2 vCPU） |

## 計算例

架空の量で、ひな形の順に積み上げた例です。
単価は例として置いた値で、実際の料金ではありません。

| 入力 | 値 |
|---|---|
| L1 / L0 のディスク上の量（B4、B5） | 70 GB/日、70 GB/日 |
| ClickPipes が読んだ量（B6） | 1,000 GB/日 |
| Pub/Sub の公開と配信（B7、B8） | それぞれ 931.3 GiB/日 |
| Cloud Logging の課金対象の量（B9） | 25,000 GiB/月 |
| 計算資源、ストレージ、バックアップ（B10、B12、B13） | $20.0/日、$1.0/日、$1.2/日 |
| 計算資源の単価（B14 今、B15 本番）、ストレージの単価（B16） | $0.30、$0.40/ユニット・時間、$25/TB・月 |
| ClickPipes のユニット（B17） | 1 |

| 項目 | 式 | 月額 |
|---|---|---|
| 計算資源 | $20.0 × 0.40 ÷ 0.30 × 30.42 | $811 |
| ストレージ | (70 × 400 + 70 × 7) ÷ 1,000 = 28.49 TB × $25 | $712 |
| バックアップ | $1.2 ÷ $1.0 × $712 | $855 |
| ClickPipes | 1 × $0.20 × 24 × 30.42 + 1,000 × 30.42 × $0.04 | $1,363 |
| Pub/Sub | (931.3 + 931.3) × 30.42 ÷ 1,024 × $40 | $2,213 |
| **ClickHouse に移した場合の合計** | | **$5,954** |
| Cloud Logging に保管する場合 | 25,000 × $0.50 + 25,000 × (400 − 30) ÷ 30.42 × $0.01 | $15,541 |
| 差額 | | $9,587 |
| ClickHouse に移した場合の合計（1 年目の平均） | ストレージとバックアップが定常の 0.47 倍 | $5,117 |

## 見積もりで気をつける点

- Pub/Sub の転送料は、Cloud Logging が課金しないログにもかかります。
  `_Required` 行きのログ（Admin Activity の監査ログなど）は、Cloud Logging では無料でも、シンクで送れば Pub/Sub の料金がかかります。
  量の多いものは、[運用](07-operations.md) の「ノイズの除去」を検討します。
- 配信側では、ack と ack 期限の延長も `byte_cost` に計上されました。
  料金表が課金対象として挙げるのは公開と配信で、ack と期限の延長が課金されるかは請求の内訳で確かめます。
  （PoC で確認）
- 停止したパイプの管理サブスクリプションにはメッセージが蓄積し続け、公開から 1 日を超えた分には保管料がかかります（[保管料](https://cloud.google.com/pubsub/pricing#storage_costs)）。
  使わなくなったパイプは削除します。
