# トラブルシューティング

[English](../en/08-troubleshooting.md) | 日本語

取り込みの不調を、症状から原因と対処まで切り分ける手順です。
クエリは `verify/checks.sql` の番号で示します（実行は `python3 tools/chq.py verify/checks.sql`）。
日常の確認の項目と目安、遅れの監視は [運用](07-operations.md) の「日常の確認」と「監視とアラート」にあります。

| 症状 | 見る節 |
|---|---|
| 新しいログが出てこない、遅れて出る | 「取り込みが遅れる」 |
| パイプが Degraded や Failed になる、L1 に届かない行がある | 「MV のエラーの検知と復旧」 |
| INSERT が `TOO_MANY_PARTITIONS` で失敗する | 「1 回の INSERT がまたぐパーティションが多すぎる」 |
| パーツが多すぎるように見える | 「パーツの数」 |
| シンクの送出件数と ClickHouse の行数が合わない | [運用](07-operations.md) の「日常の確認」の経路全体の欠損 |

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

[計画](02-planning.md) の「大きさの見積もり方」で流量からレプリカの大きさと数を決め、変更します。
レプリカは 2 つ以上にします。

- ブラウザ：ClickHouse Cloud Console でパイプを開き、Settings → Advanced Settings → Scaling
- Terraform：`pipe_replicas`、`pipe_replica_cpu_millicores`、`pipe_replica_memory_gb`（[導入](04-setup.md) の「作成後に設定を変える」）

追いつくまでの時間は、流量 F、合計の処理量 C、遅れ T のとき T × F ÷ (C − F) です。

**サービス側が遅い場合**

- 自動スケールの上限が、取り込みと検索に要る vCPU を下回っていないかを確かめます（[計画](02-planning.md) の「大きさの見積もり方」）。
  パイプを大きくすると、滞留を取り戻している間はサービスに届く量も増えます。
- 6 番で失敗した INSERT があれば、「MV のエラーの検知と復旧」に従います。
### 5. 追いついたことを確かめる

- 11 番で、今日の日付だけが出る。
- 16 番の遅れが数秒に戻る。
- Pub/Sub の 2 つの指標が下がり、横ばいになる。
### 滞留が長く続いた場合の注意

- 管理サブスクリプションの保持は 7 日です（[公式資料](https://clickhouse.com/docs/integrations/clickpipes/pubsub/overview)）。
  7 日を過ぎても処理されないメッセージは破棄され、トピックに保持がなければ Pub/Sub からは取り戻せません。
  Cloud Logging のログバケットに残っていれば、[運用](07-operations.md) の「既存ログのバックフィル」の手順で入れられます。
- 公開から 1 日を超えた未処理のメッセージには、保管料がかかります（[保管料](https://cloud.google.com/pubsub/pricing#storage_costs)）。

## MV のエラーの検知と復旧

MV が例外を出したときの挙動は、次のとおりでした。

1. 失敗したバッチは L0 には書かれ、L1 には届かない。
2. パイプは同じバッチを 10 秒、30 秒、70 秒、その後は 2 分ごとに再試行する。
3. ほかのバッチは並行して処理され、パイプの状態は短時間 Degraded になった後 Running に戻る。
   エラーテーブルには行が書き込まれない。
4. `MODIFY QUERY` で MV を直すと、次の再試行で L1 に届き、欠損も重複も出ない。

4 は、L0 でブロックの重複が排除されたうえで、下流の MV にはブロックがもう一度渡されるためです。
これは設定 `deduplicate_blocks_in_dependent_materialized_views` の既定値 1 によります（[設定の説明](https://clickhouse.com/docs/reference/settings/session-settings/other#deduplicate_blocks_in_dependent_materialized_views)）。

ただし検証では、最初の失敗から約 60 分たつと、パイプは Failed になって取り込みを止めました。
その場合も、MV を直してから `clickpipe start` で再開すれば欠損は出ませんでしたが、処理が停滞したバッチの一部が L1 に二重に入りました。
再開後は `verify/checks.sql` の 3 番で `MessageId` の重複を確かめ、検索側で除くか、該当範囲を [運用](07-operations.md) の付録 A2 で作り直します。

パイプの状態表示は、Failed になるまで処理の停滞を示さないので、監視は L0 と L1 の差と、`system.query_log` の失敗した INSERT で行います。
SQL は `sql/runbooks/05_mv_failure.sql` にあります。

MV は DROP して作り直さず、`MODIFY QUERY` で直します。
DROP と CREATE の間に INSERT されたブロックは、MV を通らずに L0 にだけ残ります。

## 1 回の INSERT がまたぐパーティションが多すぎる

L1 は `Timestamp` の日付でパーティションを分けます。
1 回の INSERT の 1 ブロックがまたげるパーティションは既定で 100 までで、超えると INSERT が失敗します（[max_partitions_per_insert_block](https://clickhouse.com/docs/reference/settings/session-settings/max-partitions)）。
L1 への INSERT は MV が行うので、失敗すると MV のほかの例外と同じくバッチが止まります。

Cloud Logging は、古いタイムスタンプのエントリーも API で受け付け、ログバケットには保存せずシンクへ送ります（[Cloud Logging の上限](https://cloud.google.com/logging/quotas)）。
範囲を絞らない場合、保持期間（L1 の TTL）の長さとは関係なく、1 回のバッチの中の `Timestamp` が 100 を超える日付にまたがると起こります。

パーサ v8 から、MV1 は LogEntry の timestamp を公開時刻の 30 日前から 1 日後までに限って使い、範囲の外は公開時刻にします。
1 回のバッチが書くパーティションは多くても 32 ほどに収まります。
ノイズの MV と L2 の例も同じ規則です。

- clickhouse local 26.7 で、150 の日付にまたがる 1 回の INSERT を試しました。
  v7 では `Too many partitions for single INSERT block` で失敗し、行は L0 に残って L1 には 1 行も届きませんでした。
  v8 では全行が L1 に届きました（`verify/local_e2e.sh` の 22 番と 23 番）。
  ClickHouse Cloud のパイプでは未検証です。
- timestamp を置き換えた行には、元の文字列が `entry.timestamp` 属性に残ります。
- 14 番で、1 回の INSERT が L1 のいくつのパーティションに書いたかを見ます。
- 4 番の遅延到着は直近 8 日分の `Timestamp` だけを読むので、それより古い `Timestamp` は数えません。

**パーサ v7 以前で作った環境**

`sql/30` と `sql/50` は `CREATE MATERIALIZED VIEW IF NOT EXISTS` なので、もう一度実行しても（`terraform apply` を含む）既存の MV は変わりません。
[運用](07-operations.md) の付録 A1 と同じく、`ALTER TABLE ... MODIFY QUERY` で新しい SELECT に入れ替えます。
対象は、`gcl.gcl_logs_v1_mv`（`sql/30_logs_v1_mv.sql`）、`gcl.gcl_noise_1m_v1_mv`（`sql/50_noise_rollup_v1.sql`）、L0 を読む L2 の MV です。
追加したノイズの除外条件は残します。
書き込んでいるパーサの版は 5 番で確かめます。

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
