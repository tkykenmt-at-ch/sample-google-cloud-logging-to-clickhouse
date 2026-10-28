# トラブルシューティング

[English](../en/troubleshooting.md) | 日本語

取り込みの不調を、症状から原因と対処まで切り分ける手順です。
クエリは `verify/checks.sql` の番号で示します（実行は `python3 tools/chq.py verify/checks.sql`）。
日常の確認の項目と目安は [運用](operations.md) の「日常の確認」にあります。

| 症状 | 見る節 |
|---|---|
| 新しいログが出てこない、遅れて出る | 「取り込みが遅れる」 |
| パイプが Degraded や Failed になる、L1 に届かない行がある | [運用](operations.md) の「MV のエラーの検知と復旧」 |
| INSERT が `TOO_MANY_PARTITIONS` で失敗する | 「1 回の INSERT がまたぐパーティションが多すぎる」 |
| パーツが多すぎるように見える | 「パーツの数」 |
| シンクの送出件数と ClickHouse の行数が合わない | [運用](operations.md) の「日常の確認」の経路全体の欠損 |

## 取り込みが遅れる

### 1. 遅れを測る

いちばん手早いのは、ClickHouse Cloud Console でパイプを開き、Metrics タブの「Latency (s)」のグラフを見ることです。
同じ値は Prometheus のエンドポイントの `ClickPipes_Latency` でも取れます（[ClickPipes のモニタリング](https://clickhouse.com/docs/integrations/clickpipes/monitoring)）。

ClickHouse 側からは、16 番で、直近 10 分に L1 に入った行について、Pub/Sub に公開されてから入るまでの遅れを見ます。
パイプは遅くとも 5 秒ごとに INSERT するので、追いついていれば遅れは数秒です。
数分以上の値が出たり、増え続けたりする場合は、次へ進みます。

1 番は公開時刻で行を選ぶので、滞留している間は行がほとんど出ません。
1 番の行数が普段より少ないことも、遅れの兆候です。

### 2. 滞留を確かめる

Cloud Monitoring で、管理サブスクリプション `clickpipes-<パイプ ID>` の次の指標を見ます（[Pub/Sub のモニタリング](https://cloud.google.com/pubsub/docs/monitoring)）。

- `pubsub.googleapis.com/subscription/oldest_unacked_message_age_by_region`（未処理で最も古いメッセージの経過時間）
- `pubsub.googleapis.com/subscription/num_unacked_messages_by_region`（未処理のメッセージの数）

両方が増え続けていれば、パイプの処理が流量に追いついていません。

ClickHouse 側からは 11 番で確かめます。
直近 1 時間に L0 へ書き込まれた行を、公開日ごとに数えます。
L0 は公開日でパーティションを分けているので、追いついていれば今日の日付だけが出ます。
前の日付に多くの行が入っていれば、過去に公開されたメッセージを今も処理しています。

### 3. パイプとサービスのどちらが遅いかを見分ける

12 番で、パイプの INSERT の回数と所要時間を 10 分ごとに見ます。
13 番で、1 回の INSERT で L0 に入った行数を見ます。

パイプは、10 万行かレプリカのメモリ 1 GB あたり 32 MB に達するか、5 秒たつとバッチを閉じて INSERT します（[公式資料](https://clickhouse.com/docs/integrations/clickpipes/pubsub/overview)）。

| 滞留 | INSERT の間隔と行数 | INSERT の所要時間 | 判断 |
|---|---|---|---|
| ある | 約 5 秒ごと、上限より少ない行数 | 間隔よりずっと短い（`busy_ratio` がパイプのレプリカ数より十分小さい） | パイプが読む速さが上限。5 秒の間にバッチを満たせていない |
| ある | 上限に近い行数で、間隔が短い | 間隔よりずっと短い | パイプは上限まで書いている。レプリカを増やすか大きくする |
| ある | ― | 間隔に近い、または失敗がある（6 番） | サービス側が遅い |
| ない | 約 5 秒ごと | 短い | 正常。滞留がない限り、間隔が 5 秒でも問題ない |

### 4. 対処する

**パイプ側が遅い場合**

[設計](design.md) の「大きさの見積もり方」で流量からレプリカの大きさと数を決め、変更します。
レプリカは 2 つ以上にします。

- ブラウザ：ClickHouse Cloud Console でパイプを開き、Settings → Advanced Settings → Scaling
- Terraform：`pipe_replicas`、`pipe_replica_cpu_millicores`、`pipe_replica_memory_gb`（[導入](setup.md) の「作成後に設定を変える」）

追いつくまでの時間は、流量 F、合計の処理量 C、遅れ T のとき T × F ÷ (C − F) です。

**サービス側が遅い場合**

- 自動スケールの上限が、取り込みと検索に要る vCPU を下回っていないかを確かめます（[設計](design.md) の「大きさの見積もり方」）。
  パイプを大きくすると、滞留を取り戻している間はサービスに届く量も増えます。
- 6 番で失敗した INSERT があれば、[運用](operations.md) の「MV のエラーの検知と復旧」に従います。

### 5. 追いついたことを確かめる

- 11 番で、今日の日付だけが出る。
- 16 番の遅れが数秒に戻る。
- Pub/Sub の 2 つの指標が下がり、横ばいになる。

### 遅れの監視

ClickPipes の通知（メール、コンソール、Slack）は、パイプの失敗や問題のときに届きます（[通知](https://clickhouse.com/docs/products/cloud/features/monitoring/notifications)）。
処理が追いつかないだけではパイプは Running のままなので、遅れは次のどちらかで監視します。

- Cloud Monitoring で、管理サブスクリプションの `oldest_unacked_message_age_by_region` にアラートを設定する
- Prometheus のエンドポイントから `ClickPipes_Latency` を取り込み、利用中の監視ツールでアラートを設定する

### 滞留が長く続いた場合の注意

- 管理サブスクリプションの保持は 7 日です（[公式資料](https://clickhouse.com/docs/integrations/clickpipes/pubsub/overview)）。
  7 日を過ぎても処理されないメッセージは破棄され、トピックに保持がなければ Pub/Sub からは取り戻せません。
  Cloud Logging のログバケットに残っていれば、[運用](operations.md) の「既存ログのバックフィル」の手順で入れられます。
- 公開から 1 日を超えた未処理のメッセージには、保管料がかかります（[保管料](https://cloud.google.com/pubsub/pricing#storage_costs)）。

## 1 回の INSERT がまたぐパーティションが多すぎる

L1 は `Timestamp` の日付でパーティションを分けます。
1 回の INSERT の 1 ブロックがまたげるパーティションは既定で 100 までで、超えると INSERT が失敗します（[max_partitions_per_insert_block](https://clickhouse.com/docs/reference/settings/session-settings/max-partitions)）。
L1 への INSERT は MV が行うので、失敗は MV のエラーと同じ扱いになり、パイプは同じバッチを再試行し続けると考えられます（MV の別の例外での挙動からの推定、この例外では未検証）。

Cloud Logging は、古いタイムスタンプのエントリーも API で受け付け、ログバケットには保存せずシンクへ送ります（[Cloud Logging の上限](https://cloud.google.com/logging/quotas)）。
保持期間（L1 の TTL）の長さとは関係なく、1 回のバッチの中の `Timestamp` が 100 を超える日付にまたがると起こります。

- 14 番で、1 回の INSERT が L1 のいくつのパーティションに書いたかを見ます。
- 4 番の遅延到着は直近 8 日分の `Timestamp` だけを読むので、それより古い `Timestamp` は数えません。
- 起きた場合は、MV で極端に古い `Timestamp` を公開時刻に置き換えるか除外する対処が考えられます（未検証）。

## パーツの数

パーツの上限は、表ごとに数えます。

| 設定 | ClickHouse Cloud での値（2026-10-28 確認） | 数える範囲 |
|---|---|---|
| `parts_to_delay_insert` | 1,000 | 1 つのパーティションのアクティブなパーツ。超えると INSERT を遅らせる |
| `parts_to_throw_insert` | 3,000 | 同上。超えると INSERT が失敗する |
| `max_parts_in_total` | 10,000 | 1 つの表の全パーティションのアクティブなパーツ |

- 8 番で、表ごとのパーティションとパーツの数を見ます。
- サービス全体のパーツの数には、システム表（`system.query_log` など）のパーツも入ります。
  システム表は構造が変わると古い表を番号付きで残すので（`query_log_11` など）、ユーザー表より多くなることがあります。
  ユーザー表の上限には影響しません。
- 日ごとのパーティションを 400 日残す L1 では、`max_parts_in_total` が先に効きます。
  古いパーティションがマージで数個のパーツにまとまることが前提で、1 パーティションに 25 パーツ残ったままなら 400 日で 10,000 に達します。
- 15 番で、L1 のパーティションあたりのパーツの数を古さごとに見ます。
  古いパーティションの値と表全体のパーツの数（`table_parts`）を定期的に確かめます。
