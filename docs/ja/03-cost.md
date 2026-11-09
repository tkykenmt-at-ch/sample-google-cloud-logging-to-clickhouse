# 費用の見積もり

[English](../en/03-cost.md) | 日本語

ClickHouse に移したときの月額を、PoC の前は量から概算し、PoC の後は利用者の環境の実測から出します。
同じ保持日数で Cloud Logging に保管し続ける場合とも比べます。
サービスと ClickPipes の大きさは [計画](02-planning.md) の「大きさの見積もり方」で決めます。

> 料金と仕様は 2026-10-05 に公式資料で確かめた値です。
> Private Preview の機能は、一般提供（GA）までに挙動や料金が変わることがあります。
> 「（確認済み）」「（公式資料）」「（PoC で確認）」の意味は [設計](01-design.md) の冒頭にあります。

## 費用の見積もり方

**料金の要素**

| 要素 | 料金（公式資料） | 課金対象 |
|---|---|---|
| Cloud Logging の取り込み（削減対象） | $0.50/GiB（[料金](https://cloud.google.com/stackdriver/pricing)。プロジェクトごとに毎月 50 GiB まで無料） | `_Default` に入れなくなるログの量 |
| Pub/Sub の公開 | $40/TiB（[料金](https://cloud.google.com/pubsub/pricing)） | シンクの送出量 |
| Pub/Sub の配信 | $40/TiB（サブスクリプションごと） | シンクの送出量 × サブスクリプションの数 |
| ClickPipes（Pub/Sub） | Private Preview（[ClickPipes の一覧](https://clickhouse.com/docs/integrations/clickpipes)）。Preview 中と GA 後の料金は公開の料金表になく、ClickHouse に確認する。他のストリーミング ClickPipes は、取り込み $0.04/GB とレプリカの時間料金（[料金](https://clickhouse.com/docs/products/cloud/reference/billing/clickpipes/clickpipes-for-streaming-and-object-storage)） | 取り込み量、レプリカ数とサイズ |
| ClickHouse Cloud | 料金ページのコンピュートとストレージ | サービスのサイズ、保存量（圧縮後） |

Pub/Sub の無料枠は、公開と配信を合わせて請求先アカウントごとに毎月 10 GiB です。

**並走中に測るもの**

| 量 | Cloud Monitoring の指標 |
|---|---|
| Cloud Logging の課金対象の取り込み量 | `logging.googleapis.com/billing/bytes_ingested` |
| シンクの送出量 | `logging.googleapis.com/exports/byte_count`（シンクで絞る） |
| Pub/Sub の公開の計上量 | `pubsub.googleapis.com/topic/byte_cost` |
| Pub/Sub の配信の計上量 | `pubsub.googleapis.com/subscription/byte_cost` |

**見積もりで気をつける点**

- Pub/Sub の転送料は、Cloud Logging が課金しないログにもかかります。
  `_Required` 行きのログ（Admin Activity の監査ログなど）は、Cloud Logging では無料でも、シンクで送れば Pub/Sub の料金がかかります。
  量の多いものは、後述のノイズの対処を検討します。
- シンクが送る JSON は、Cloud Logging の課金対象の量より大きくなります。
  検証では、Cloud Logging が課金する種類のログで約 1.2 倍でした。
  この場合、Pub/Sub（公開と配信）の料金は Cloud Logging の取り込み料の約 2 割になります（1.2 × $40/TiB × 2 ÷ $0.50/GiB）。
- ログの構成で比率は大きく変わるので、並走を始めてから上の指標で実測して見積もります。
- 配信側では、ack と ack 期限の延長も `byte_cost` に計上されました。
  料金表が課金対象として挙げるのは公開と配信で、ack と期限の延長が課金されるかは請求の内訳で確かめます。
  （PoC で確認）
- 停止したパイプの管理サブスクリプションにはメッセージが蓄積し続けます。
  （確認済み）
  公開から 1 日を超えた分には保管料がかかります。
  （公式資料：[保管料](https://cloud.google.com/pubsub/pricing#storage_costs)）
  使わなくなったパイプは削除します。

## PoC の実測から月額を出す

本番の量を流し始めたら、利用者の環境で測った量から月額を出します。
測る量はすべて利用者の Cloud Logging、Pub/Sub、ClickHouse Cloud から取れます。
表計算のひな形は [cost_estimate.csv](../files/cost_estimate.csv)（英語版は [cost_estimate.en.csv](../files/cost_estimate.en.csv)）です（Google スプレッドシートなら、ファイル → インポートで読み込むと式が動きます）。

**基準の期間**

- 平日と休日を含む 1 週間の、日付ごとの量を平均します。
  ログの量は曜日で変わるので、数日分だけでは偏ります。
- 取り込みが遅れた期間や、溜まった分を取り戻した期間を、取り込んだ時刻で平均しません。
  L1 はログの時刻、L0 は公開された日付でパーティションを分けているので、遅れて入った行もその日に数えられます。
- 今日の分は途中で、パーツのマージも終わっていないので外します。

**測る量**

| 量 | 測り方 |
|---|---|
| 1 日あたりの保存量と圧縮率 | `verify/checks.sql` の 17 番（表と日付ごと）。ストレージは `on_disk_gb` で課金され、スキップインデックスを含む（L1 では Body のテキストインデックスが大きな割合を占める）。`compressed_gb` と `ratio` は列のデータだけの値 |
| ClickPipes が読んだ量 | パイプの Metrics タブ、または Prometheus の `ClickPipes_FetchedBytes_Total`（[ClickPipes のモニタリング](https://clickhouse.com/docs/integrations/clickpipes/monitoring)） |
| Pub/Sub の公開と配信の計上量 | 上の「並走中に測るもの」の `topic/byte_cost` と `subscription/byte_cost`。配信は、同じトピックを読む全部のサブスクリプション（パイプごとの管理サブスクリプション）を足す。並走が 1 か月を超えたら、請求の SKU「Message Delivery Basic」と比べる |
| サービスの計算資源、ストレージ、バックアップ | ClickHouse Cloud Console の Settings → Usage breakdown（日ごと、定価、CSV で書き出せる。[使用量の確認](https://clickhouse.com/docs/products/cloud/reference/billing/billing-overview#how-can-i-keep-track-of-my-spending)） |
| Cloud Logging の課金対象の量 | 請求のレポートで、サービスを Cloud Logging に絞った SKU「Log Storage cost」の使用量、または `logging.googleapis.com/billing/bytes_ingested` |

**組み立て方**

| 項目 | 式 |
|---|---|
| ストレージ | (L1 の 1 日のディスク上の量 × L1 の保持日数 + L0 の 1 日のディスク上の量 × L0 の保持日数) × ストレージの単価。L2 や集計の表を作ったら、同じように足す |
| バックアップ | 今のバックアップ ÷ 今のストレージ × 上のストレージ |
| サービスの計算資源 | Usage breakdown の 1 日の計算資源 × 日数。本番で使うプランの単価が今と違えば、単価の比を掛ける |
| ClickPipes | レプリカの合計ユニット × 計算資源の単価 × 時間 + 読んだ量 × 取り込みデータの単価 |
| Pub/Sub | (公開の計上量 + 配信の計上量) × $40/TiB |
| Cloud Logging に保管する場合 | 課金対象の量 × $0.50/GiB + 課金対象の量 × (保持日数 − 30) ÷ 30.42 × $0.01/GiB（30 日を超えた保管、[料金](https://cloud.google.com/stackdriver/pricing)）。プロジェクトごとの無料枠（毎月 50 GiB）は含めていない |

- 単価は、それぞれの料金ページでクラウド、リージョン、プランを選んで入れます（[ClickHouse Cloud](https://clickhouse.com/pricing)、[ClickPipes](https://clickhouse.com/docs/products/cloud/reference/billing/clickpipes/clickpipes-for-streaming-and-object-storage)、[Pub/Sub](https://cloud.google.com/pubsub/pricing)）。
  Pub/Sub の ClickPipes の料金は、上の「料金の要素」のとおり ClickHouse に確認します。
- 計算資源は、PoC の間の取り込みだけの値です。
  代表クエリの測定が済んだら、検索の分を足します（[計画](02-planning.md) の「大きさの見積もり方」の「サービス」）。
- ストレージは、保持日数分のログがたまった定常状態の値です。
  移行の途中は、Cloud Logging と ClickHouse の両方に保管する期間の費用が加わります。
- Cloud Logging と比べるときは、同じ課金対象の量を使います。
  Pub/Sub と ClickPipes の量は、シンクが送る JSON の大きさで、Cloud Logging の課金対象の量より大きくなります（上の「見積もりで気をつける点」）。
