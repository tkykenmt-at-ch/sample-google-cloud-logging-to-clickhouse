# 計画

[English](../en/planning.md) | 日本語

導入の前と PoC の前後に、利用者の環境で決めることと、大きさと費用の見積もり方をまとめます。
構成と判断の理由は [設計](design.md)、導入の手順は [導入](setup.md) にあります。

> 料金と仕様は 2026-10-05 に公式資料で確かめた値です。
> Private Preview の機能は、一般提供（GA）までに挙動や料金が変わることがあります。
> 「（確認済み）」「（公式資料）」「（PoC で確認）」の意味は [設計](design.md) の冒頭にあります。

## 利用者の環境で決めること

| 設定項目 | 本書の値 | 決め方 |
|---|---|---|
| シンクの範囲 | プロジェクトの全ログ | 複数のプロジェクトなら集約シンク |
| トピックのメッセージ保持 | なし | パイプの差し替えで遡るときだけ、短く有効にする |
| トピックの保存リージョン | 指定なし（Terraform の既定） | ClickHouse Cloud のサービスと同じリージョンに固定する（`topic_storage_regions`）。リージョンをまたぐと配信に転送料がかかる |
| ClickPipes のレプリカ | 1 つ（最小サイズ） | 「大きさの見積もり方」で流量から決め、並走中に滞留がないことを確かめる |
| ClickPipes の INSERT の待ち時間 | 5 秒（`streaming_max_insert_wait_ms` の既定） | 検証環境では約 7.7 秒ごとに平均 212 行の INSERT で、1 回で 4 つのテーブルにパートができた。量が少なくパートが多すぎる場合は延ばす（ログが見えるまでの遅れも伸びる。効果は未検証） |
| L0 の保持日数 | 7 日 | 取り込みの遅延、切り替えとバックフィル、照合とロールバックに必要な期間に余裕を加える |
| L1 の保持日数 | 400 日 | ログの種類ごとの保持要件と、個人情報の規程 |
| 本文の全文検索インデックス | `ngrams(2)` | 日本語のログがなければ `splitByNonAlpha` |
| 属性の Map の保存形式 | マージ後は `with_buckets`、分割の下限は既定（平均 32 キー） | 1 行あたりのキーの平均を測り、32 個を大きく超えて 1 つのキーでの絞り込みが多ければ下限を下げる |
| L2（型付きテーブル） | なし | [設計](design.md) の「L2 を作るかどうかの判断」に該当する要件があるときだけ作る |
| L3（集計） | 分単位の件数（L1 から） | 長い期間の推移を見るか、集計だけを長く残すか |
| 集計テーブルのパーティション | 日ごと（`sql/40`、`sql/50`） | 集計テーブルは小さい（検証環境で 13 日分 490 KB）ので、月ごと（`toYYYYMM`）にするとパーティションとパートが減る。期限切れが月単位で落ちるので、保持は最大 1 か月長くなる |
| 数値と IP の型 | `HttpLatencySeconds` は Float64、`HttpRemoteIp` は String | Float32 や IPv6 型にすると小さくなる（IPv6 型では空や不正な値が `::` になる） |
| ノイズの除外条件 | 例として Kubernetes の Lease の更新 | 並走中に件数の上位から見つける |
| サービスのレプリカ | 2 以上、アイドル停止なし | 検索の負荷と可用性の要件 |
| 監視の通知先 | ― | L0 と L1 の差、失敗した INSERT、シンクとの件数の差 |

PoC の前に、次のことを利用者の環境で決めておきます。

- 対象のプロジェクトの数と構成（集約シンクにするか）
- ログの発生源（GKE、Cloud Run、GCE など）と、そこから見込まれるノイズの種類と量
- 日本語のメッセージを出すログの有無
- ログの種類ごとの保持期間
- 個人情報の扱いと、閲覧できる人の範囲
- 過去のログを ClickHouse に移行するか
- Error Reporting、ログベース指標、ログのアラートの利用状況
- Logs Explorer の保存済みクエリや、日常の検索の使い方
- Pub/Sub を VPC Service Controls の境界の中に置いているか
- ClickHouse Cloud のリージョン

## 大きさの見積もり方

ClickPipes のレプリカと ClickHouse Cloud のサービスの大きさは、同じ流量から見積もります。
見積もりは公式の目安による出発点で、並走を始めたら [トラブルシューティング](troubleshooting.md) の確認で滞留がないことを確かめます。

**流量を出す**

| 段 | 求め方 | 根拠 |
|---|---|---|
| 1. 月の量 | Cloud Logging の課金対象の取り込み量（`logging.googleapis.com/billing/bytes_ingested`、または請求の Log Storage の量）。並走中ならシンクの送出量（`logging.googleapis.com/exports/byte_count`） | 利用者の環境 |
| 2. 平均の流量 | 月の量 ÷ 2,592,000 秒（30 日） | 計算 |
| 3. Pub/Sub に送る量 | シンクが送る JSON は課金対象の量より大きい。並走を始めたら、シンクの送出量と課金対象の量の比を測って掛ける | 利用者の環境 |
| 4. `_Required` 行きのログ | シンクで送るなら、その分を加える。量はログの構成で大きく変わる | 利用者の環境 |
| 5. ピーク | `bytes_ingested` を 1 分ごとに見て、最大と平均の比を掛ける | 利用者の環境 |

例（数字は説明用）：課金対象が月 10 TiB なら、平均は 10 × 1,099,511,627,776 ÷ 2,592,000 ≈ 4.2 MB/s です。
送出量が課金対象の 1.2 倍なら、Pub/Sub に送る量は約 5.1 MB/s です。

**ClickPipes のレプリカ**

| 大きさ | vCPU、メモリ | 想定スループット |
|---|---|---|
| XS（既定） | 0.125、512 MiB | 7 MB/s |
| S | 0.25、1 GiB | 15 MB/s |
| M | 0.5、2 GiB | 31 MB/s |
| L | 1、4 GiB | 63 MB/s |
| XL | 2、8 GiB | 126 MB/s |

- 大きさと vCPU、メモリは公式資料の値です（[レプリカの大きさ](https://clickhouse.com/docs/products/cloud/reference/billing/clickpipes/clickpipes-for-streaming-and-object-storage)）。
- 公式に公開されている処理量は、Kafka の ClickPipes で L が JSON 63 MB/s（1 メッセージ 1.6 KB、ClickHouse 側が律速しない条件の参考値）だけです（[ベンチマーク](https://clickhouse.com/docs/integrations/clickpipes/kafka/best-practices)）。
  ほかの大きさは、これを vCPU に比例させ、小数点以下を切り捨てた推定です。
  Pub/Sub の ClickPipes の処理量は公開されていません。
- ピークの流量を上回る大きさを選び、レプリカは 2 つ以上にします。
  2 つ以上で、ゾーンに分散した高可用性の構成になります（[公式資料](https://clickhouse.com/docs/integrations/clickpipes/pubsub/overview#scaling)）。
  レプリカを増やすと、管理サブスクリプションのメッセージがレプリカに分けて配られます。
- 止まったあとに追いつく速さも、合計の処理量で決まります。
  流量 F、合計の処理量 C で T 時間止まった場合、追いつくまでに T × F ÷ (C − F) 時間かかります。
  管理サブスクリプションの保持は 7 日なので、それまでに追いつく余裕を残します。
- 既定（XS が 1 つ）は約 7 MB/s で、検証には足りても本番の量には足りないことがあります。
  [導入](setup.md) の `pipe_replicas` などと、[ブラウザで導入する](setup-console.md) の大きさは、本番ではこの見積もりの値にします。

**サービス**

- 取り込みには、継続する流量（非圧縮）10 MB/s ごとに 1 vCPU を見込みます。
  検索には別に、流量 10 MB/s ごとに 1 QPS あたり 1 vCPU を見込みます（[ClickStack の資源の見積もり](https://clickhouse.com/docs/clickstack/managing/estimating-resources)）。
- パイプを大きくすると、サービスに届く量も増えます。
  滞留を取り戻している間は、パイプの合計の処理量まで届きます。
- 自動スケールの上限は、取り込みと検索の vCPU の合計を下回らないようにします。

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
表計算のひな形は `verify/cost_estimate.csv`（英語版は `verify/cost_estimate.en.csv`）です（Google スプレッドシートなら、ファイル → インポートで読み込むと式が動きます）。

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
  代表クエリの測定が済んだら、検索の分を足します（上の「大きさの見積もり方」の「サービス」）。
- ストレージは、保持日数分のログがたまった定常状態の値です。
  移行の途中は、Cloud Logging と ClickHouse の両方に保管する期間の費用が加わります。
- Cloud Logging と比べるときは、同じ課金対象の量を使います。
  Pub/Sub と ClickPipes の量は、シンクが送る JSON の大きさで、Cloud Logging の課金対象の量より大きくなります（上の「見積もりで気をつける点」）。
