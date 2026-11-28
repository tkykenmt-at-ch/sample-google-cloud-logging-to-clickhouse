# 運用中のチューニング

[English](../en/11-advanced-tuning.md) | 日本語

運用を始めたあとで検索や集計が遅くなったときや、取り込みの負荷が増えたときに、症状から手当てを選ぶための頁です。
クエリの書き方で直せるものは[よくあるクエリと速い書き方](10-query-patterns.md)にあります。
この頁では、遅いクエリの見つけ方と、テーブルやサービスの側で後から足せる手当てを扱います。
数値は合成ログで計測した結果です（[計測の条件](#計測の条件)）。

## 早見表

| 症状 | 節 | 手当て | 計測の結果 |
|---|---|---|---|
| どのクエリが重いか分からない | [1](#1-遅いクエリを見つける) | `system.query_log` で読み出し量の多い順に並べる | なし |
| 最新の数百件を出すだけの検索が遅い | [2](#2-最新の-n-件は並び順に合わせて並べる) | `ORDER BY` を並び順の列に合わせる | 780 万行 → 4.9 万行 |
| 同じ条件のダッシュボードを何度も開く | [3](#3-同じ条件を繰り返すクエリにはクエリ条件キャッシュが効く) | クエリ条件キャッシュ（既定で有効） | 1 億 5,000 万行 → 1.2 万行（2 回目以降） |
| リクエスト ID などで 1 件を探すのが遅い | [4](#4-1-件を-id-で探すときは索引を足す) | ブルームフィルタの索引 | 5,000 万行 → 46 万行 |
| 属性（`LogAttributes`）での集計や絞り込みが遅い | [5](#5-よく使う属性は列に取り出す) | 取り込み時に計算する列 | 2.5 秒 → 0.07 秒 |
| 索引や列を足したあと、過去の行への反映が終わらない | [6](#6-過去の行への反映はパーティションごとに流す) | パーティションごとに流し、`system.mutations` を見る | なし |
| 一部の利用者の重いクエリがほかの検索を遅くする | [7](#7-利用者ごとに上限を決める) | 設定プロファイル | なし |
| 検索と取り込みが計算資源を取り合う | [8](#8-検索と取り込みでサービスを分ける) | 読み取り専用のサービスを分ける | なし |
| 検索がなくても計算資源を使い続ける | [9](#9-取り込みとマージの負荷を見る) | `system.part_log` でテーブルごとのマージを見る | なし |

後から足す手当ての多くは、テーブルを作り直さずに `ALTER` で足せます。
変更ごとの手間は[付録](#付録変更の手間)にまとめています。

## 1. 遅いクエリを見つける

まず、どのクエリが重いかを `system.query_log` で確かめます。
同じ形のクエリは `normalized_query_hash` でまとめ、読んだ量の多い順に並べます。

```sql
SELECT
    normalized_query_hash,
    substring(any(query), 1, 200) AS sample,
    count() AS runs,
    formatReadableSize(sum(read_bytes)) AS read,
    round(quantile(0.95)(query_duration_ms) / 1000, 2) AS p95_s,
    round(sum(ProfileEvents['OSCPUVirtualTimeMicroseconds']) / 1e6) AS cpu_s,
    formatReadableSize(sum(ProfileEvents['CachedReadBufferReadFromSourceBytes'])) AS from_storage,
    formatReadableSize(sum(ProfileEvents['CachedReadBufferReadFromCacheBytes'])) AS from_cache
FROM clusterAllReplicas('default', system.query_log)
WHERE event_time >= now() - INTERVAL 1 DAY
  AND type = 'QueryFinish' AND query_kind = 'Select' AND is_initial_query
  AND has(databases, 'gcl')
GROUP BY normalized_query_hash
ORDER BY sum(read_bytes) DESC
LIMIT 20;
```

| 列 | 読み方 |
|---|---|
| `read` | 読んだ量。手当ての効果は、時間よりこの値で比べる |
| `p95_s` | 95 パーセンタイルの時間 |
| `cpu_s` | 使った CPU 時間の合計。回数の多いクエリはこの値が大きくなる |
| `from_storage` | オブジェクトストレージから読んだ量（キャッシュになかった分） |
| `from_cache` | ローカルのキャッシュから読んだ量 |

重いクエリが見つかったら、`EXPLAIN indexes = 1` で、主キーと索引によって読むグラニュールがどれだけ減ったかを見ます。

```sql
EXPLAIN indexes = 1
SELECT count() FROM gcl.gcl_logs_v1
WHERE Timestamp >= '2026-11-23 00:00:00' AND Timestamp < '2026-11-24 00:00:00'
  AND hasAllTokens(lower(Body), 'timeout');
```

時間は、キャッシュに載っているかどうかで大きく変わります。
計測では、3 日分から語を探すクエリが、1 回目は 5.47 秒（オブジェクトストレージから 187 MiB を読んだ）、2 回目以降は 0.57〜0.60 秒でした。
1 回だけの時間で判断せず、`from_storage` と `from_cache` を見て、キャッシュの影響を分けてから比べます。

## 2. 最新の N 件は並び順に合わせて並べる

L1 の並び順は `(toStartOfFiveMinutes(Timestamp), ServiceName, Timestamp)` です。
`ORDER BY Timestamp DESC LIMIT 200` と書くと、この並び順を使えず、範囲内の行をすべて読んでから並べ替えます。
`ORDER BY toStartOfFiveMinutes(Timestamp) DESC, Timestamp DESC` と並び順の列に合わせると、新しい側から読み、200 件そろった時点で読むのをやめます。
`EXPLAIN actions = 1` の `ReadType` が `InReverseOrder` になっていれば、この読み方になっています。

```sql
-- 遅い
SELECT Timestamp, SeverityText, Body FROM gcl.gcl_logs_v1
WHERE Timestamp >= '2026-11-23 00:00:00' AND Timestamp < '2026-11-24 00:00:00'
  AND ServiceName = 'k8s_container/app-a'
ORDER BY Timestamp DESC LIMIT 200;

-- 速い
SELECT Timestamp, SeverityText, Body FROM gcl.gcl_logs_v1
WHERE Timestamp >= '2026-11-23 00:00:00' AND Timestamp < '2026-11-24 00:00:00'
  AND ServiceName = 'k8s_container/app-a'
ORDER BY toStartOfFiveMinutes(Timestamp) DESC, Timestamp DESC LIMIT 200;
```

| 書き方（1 サービス 1 日分、最新 200 件） | 読んだ行 | 読んだ量 | 時間 |
|---|---|---|---|
| `ORDER BY Timestamp DESC` | 780 万 | 104 MiB | 0.13〜0.65 秒 |
| `ORDER BY toStartOfFiveMinutes(Timestamp) DESC, Timestamp DESC` | 49,152 | 1.12 MiB | 0.01〜0.02 秒 |
| `SELECT *` と `ORDER BY Timestamp DESC` | 780 万 | 105 MiB | 0.14〜1.56 秒 |
| `SELECT *` と並び順に合わせた `ORDER BY` | 49,152 | 1.63 MiB | 0.02 秒 |

この計測では、`SELECT *` にしても読んだ量はほとんど増えませんでした。
差を生んだのは、選ぶ列ではなく `ORDER BY` の書き方です。

ClickStack の検索画面は、テーブルの並び順から `(toStartOfFiveMinutes(Timestamp), Timestamp) DESC` を組み立てるので、この形になっています（ソースの設定の Default Order By を空にした場合）。
SQL コンソールや Grafana で手で書くクエリは、自分で並び順に合わせます。

語で絞り込んだうえで最新の件数を出すクエリでも、並び順に合わせると読む量は減ります。
ただし、語が少ないと 200 件そろうまでに多くのグラニュールを読むので、差は小さくなります。
全サービス 3 日分から `timeout` を含む最新 200 件を出すクエリでは、5,172 万行が 3,745 万行に減りました（842 MiB → 611 MiB）。

## 3. 同じ条件を繰り返すクエリにはクエリ条件キャッシュが効く

クエリ条件キャッシュは、`WHERE` の条件に合う行がないグラニュールを覚えておき、同じ条件の次のクエリでそのグラニュールを読み飛ばします（[公式ドキュメント](https://clickhouse.com/docs/concepts/features/performance/caches/query-condition-cache)）。
25.4 から既定で有効です（`use_query_condition_cache = 1`）。

| クエリ（3 日分、1 億 5,000 万行、`Body LIKE '%request_id=…%'`） | 読んだ行 | 読んだ量 | 時間 |
|---|---|---|---|
| 1 回目 | 1 億 5,000 万 | 3.64 GiB | 15.9 秒 |
| 2 回目、3 回目 | 11,516 | 730 KiB | 0.01 秒 |
| 同じ `WHERE` で 1 時間ごとに集計する別のクエリ | 11,516 | 730 KiB | 0.01 秒 |
| 時間の範囲の終わりを 1 分ずらしたクエリ | 1 億 5,000 万 | 3.64 GiB | 6.5 秒 |

キャッシュは条件ごとに持つので、`SELECT` の中身が違うクエリでも、`WHERE` が同じなら使われました。
一方、時間の範囲も条件の一部なので、範囲が変わると使われませんでした。
障害の調査で同じ時間帯を何度も絞り込み直すような使い方には効きます。
「直近 15 分」のように開くたびに範囲が動くダッシュボードには効きにくいと考えてください。
条件に合う行が多く、ほぼすべてのグラニュールに含まれる場合も、読み飛ばせるグラニュールがないので効きません。

このガイドのほかの計測は、キャッシュの影響を除くために `use_query_condition_cache = 0` で行っています。
結果そのものを覚えるクエリキャッシュ（`use_query_cache`）は別の仕組みで、既定では無効です。
クエリキャッシュは結果が古くなることがあるので、ログの検索には使いません。

## 4. 1 件を ID で探すときは索引を足す

リクエスト ID や `InsertId` のように並び順に入っていない列で 1 件を探すと、範囲内のその列をすべて読みます。
値の種類が多く、1 つの値がごく一部のグラニュールにしか現れない列には、ブルームフィルタの索引が効きます。

```sql
ALTER TABLE gcl.gcl_logs_v1 ADD INDEX idx_insert_id InsertId TYPE bloom_filter(0.01) GRANULARITY 1;
-- 過去の行にも索引を作る（6 のとおりパーティションごとに）
ALTER TABLE gcl.gcl_logs_v1 MATERIALIZE INDEX idx_insert_id IN PARTITION '2026-11-23';
```

| 書き方（1 日分、5,000 万行、`InsertId = '…'`） | 読んだ行 | 読んだ量 | 時間 | 索引の大きさ |
|---|---|---|---|---|
| 索引なし | 5,000 万 | 906 MiB | 0.94〜0.96 秒 | なし |
| ブルームフィルタ（`bloom_filter(0.01)`） | 45.9 万 | 8.5 MiB | 0.10〜0.14 秒 | 58 MiB |
| `_part_offset` だけを持つ Projection | 8,192 | 247 KiB | 0.03 秒 | 524 MiB |

比べるときは、読む行が減ったかどうかと、全体の時間が縮んだかどうかを両方見ます。
索引は保存量を増やし、取り込みとマージのたびに作られます。
効果が見合うかは、計測してから決めます。

- 値の種類が少なく、どのグラニュールにも現れる値には効きません。計測では、`SeverityText = 'ERROR'` に `set` の索引を足しても、読む行は 5,000 万行のまま減りませんでした。ERROR がほぼすべてのグラニュールに含まれていたためです。こうした集計は MV で手当てします（[よくあるクエリの 6](10-query-patterns.md#6-繰り返し見る集計は-mv-にする)）。
- 公式ドキュメントは、文字列の列にはテキストインデックスを第一に勧めています（[ClickStack - Performance tuning](https://clickhouse.com/docs/clickstack/managing/performance-tuning#when-to-add-skip-indexes)）。L1 の `TraceId` にはテキストインデックスがあります。ただし、テキストインデックスは作るときに多くのメモリを使います。計測では、5,000 万行のパーツに後から `InsertId` のテキストインデックスを作ろうとすると、約 10 GiB を使おうとして、検証環境のメモリの上限（6.76 GiB）を超えて失敗しました。
- `_part_offset` だけを持つ Projection は、読む量が最も少なくなりました。ただし、公式ドキュメントは ClickStack のような使い方にはまだ勧めていません（[ClickStack - Lightweight projections](https://clickhouse.com/docs/clickstack/managing/performance-tuning#lightweight-projections)、ベータ）。使う場合は、本番に近いデータで検索の時間を確かめてからにします。

## 5. よく使う属性は列に取り出す

`LogAttributes` と `ResourceAttributes` は Map 型です。
Map の 1 つのキーだけを読むクエリでも、Map の列そのものを読んで展開します。
よく使う属性を取り込み時に計算する列（`MATERIALIZED`）にすると、その列だけを読めば済みます。
公式ドキュメントでも、ClickStack のチューニングで最初に検討する手当てとされています（[ClickStack - Materialize frequently queried attributes](https://clickhouse.com/docs/clickstack/managing/performance-tuning#materialize-frequently-queried-attributes)）。

```sql
ALTER TABLE gcl.gcl_logs_v1
    ADD COLUMN HttpRoute LowCardinality(String) MATERIALIZED LogAttributes['http.route'],
    ADD COLUMN UserId String MATERIALIZED LogAttributes['user_id'];
-- 過去の行にも値を入れる（6 のとおりパーティションごとに）
ALTER TABLE gcl.gcl_logs_v1 MATERIALIZE COLUMN HttpRoute IN PARTITION '2026-11-23';
```

| クエリ（2,000 万行、属性 12 個） | Map（`basic`） | Map（`with_buckets`） | 取り込み時に計算する列 |
|---|---|---|---|
| `http.route` ごとの件数 | 4.15 GiB、2.45〜2.82 秒 | 296 MiB、2.68〜3.05 秒 | 19 MiB、0.07〜0.08 秒 |
| `user_id` での絞り込み | 4.15 GiB、2.45〜2.58 秒 | 165 MiB、2.35〜3.11 秒 | 165 MiB、0.31〜0.35 秒 |

L1 はマージ後のパーツの Map を `with_buckets` の形式で保存します。
この形式では読む量は大きく減りましたが、時間はほとんど縮みませんでした。
列に取り出すと、読む量も時間も減りました。

- ClickStack は、Map から取り出した列を自動で見つけます。利用者が `LogAttributes['http.route']` のように元の属性で絞り込んでも、その列を使ってクエリを組み立てます。保存済みの検索やダッシュボードは直さずに済みます。
- L1 には `key=value` のテキストインデックス（`idx_log_attr_items`）もあり、属性が等しいかどうかの絞り込みはこの索引で読み飛ばせます。列に取り出すと特に効くのは、属性ごとの集計（`GROUP BY`）、`LIKE` や範囲での絞り込み、SQL を手で書くクエリです。
- どの属性を取り出すかは、実際のクエリで数えて決めます。

```sql
SELECT key, count() AS queries
FROM clusterAllReplicas('default', system.query_log)
ARRAY JOIN extractAll(query, 'LogAttributes\\[\'([^\']+)\'\\]') AS key
WHERE event_date >= today() - 7 AND type = 'QueryFinish' AND query_kind = 'Select'
GROUP BY key ORDER BY queries DESC LIMIT 20;
```

- 値の種類が少ない属性は `LowCardinality(String)` にします。数値の属性は `toUInt16OrZero(LogAttributes['http.status_code'])` のように数値の型にすると、範囲での絞り込みや `minmax` の索引を使えます。
- 列を足すと、取り込みの CPU が増えます。計測では、列 3 本で 100 万行あたり約 0.46 CPU 秒でした（[よくあるクエリの「取り込みへの影響」](10-query-patterns.md#取り込みへの影響)）。

## 6. 過去の行への反映はパーティションごとに流す

`MATERIALIZE INDEX`、`MATERIALIZE COLUMN`、`MATERIALIZE PROJECTION` は、既存のパーツを書き直すミューテーションとして裏で動きます。
テーブル全体に一度に流すと、大きなパーツを書き直すあいだ、計算資源とメモリを使い続けます。
失敗すると同じミューテーションを繰り返し、同じテーブルのあとに出したミューテーションも進みません。
4 のテキストインデックスの計測では、メモリの上限を超えて失敗し、そのあとに出した 2 本のミューテーションも止まりました。

日ごとのパーティションに分けて、新しい日から順に流します。

```sql
ALTER TABLE gcl.gcl_logs_v1 MATERIALIZE INDEX idx_insert_id IN PARTITION '2026-11-23';
```

進み具合と失敗の理由は `system.mutations` で見ます。

```sql
SELECT mutation_id, command, create_time, parts_to_do, latest_fail_time, latest_fail_reason
FROM clusterAllReplicas('default', system.mutations)
WHERE database = 'gcl' AND NOT is_done
ORDER BY create_time;
```

失敗を繰り返しているミューテーションは、`KILL MUTATION` で止めます。
止めたあと、パーティションを小さく分けるか、サービスを大きくしてから流し直します。

```sql
KILL MUTATION WHERE database = 'gcl' AND table = 'gcl_logs_v1' AND mutation_id = '<mutation_id>';
```

索引や列を足すだけなら、新しく取り込む行には足した時点から反映されます。
過去の行への反映は、検索で使う期間だけに絞ることもできます。

## 7. 利用者ごとに上限を決める

一部の利用者が重いクエリを流して、ほかの検索が遅くなる場合は、設定プロファイルで利用者ごとに上限を決めます（[CREATE SETTINGS PROFILE](https://clickhouse.com/docs/reference/statements/create/settings-profile)）。
Grafana や BI ツールのように、つなぎ先ごとに専用のユーザーを作れる場合に使えます。

```sql
CREATE SETTINGS PROFILE IF NOT EXISTS dashboard SETTINGS
    max_execution_time = 60,          -- 1 本のクエリの時間の上限（秒）
    max_memory_usage = 8000000000,    -- 1 本のクエリのメモリの上限（バイト）
    max_threads = 4;                  -- 1 本のクエリが使うスレッドの数
CREATE USER IF NOT EXISTS grafana_viewer IDENTIFIED WITH sha256_password BY '<password>'
    SETTINGS PROFILE 'dashboard';
GRANT SELECT ON gcl.* TO grafana_viewer;
```

- 上限を超えたクエリは、エラーで止まります。利用者にエラーが返ることを先に伝えておきます。
- 値は、1 の `system.query_log` で今のクエリの時間とメモリを見てから決めます。
- 読み取りだけのユーザーにするなら、プロファイルに `readonly = 1` も入れます。

## 8. 検索と取り込みでサービスを分ける

取り込みとマージは常に計算資源を使うので、検索が集中すると互いに取り合います。
ClickHouse Cloud では、同じデータを共有する読み取り専用のサービスを足して、検索をそちらに向けられます（[Warehouses](https://clickhouse.com/docs/products/cloud/features/infrastructure/warehouses)、Scale と Enterprise のプラン）。

- 読み取り専用のサービスはマージをしないので、検索だけに計算資源を使います。
- サービスごとに大きさ、自動スケール、アイドル時の停止を決められます。取り込み側は常に動かし、検索側は業務時間外に止める、といった使い分けができます。
- ストレージは共有なので、二重には課金されません。
- ClickStack は、Cloud の画面で開いたサービスに対してクエリを流します。読み取り専用のサービスから ClickStack を開けば、検索はそのサービスで動きます。ただし、ダッシュボード、保存済みの検索、アラート、ソースはサービスごとに持つので、作り直しが要ります（[Using ClickStack with read-only compute](https://clickhouse.com/docs/clickstack/self-configured/deployment/managed#additional-tasks)）。

サービスを分けても、1 本のクエリが読む量は変わりません。
読み飛ばせていないクエリは、2〜5 で先に直します。
公式ドキュメントは、保存量が月 100 TB 程度より小さければ、1 つのサービスで足りることが多いとしています（[Isolating read and write workloads](https://clickhouse.com/docs/clickstack/self-configured/managing/isolating-read-write)）。

## 9. 取り込みとマージの負荷を見る

検索がない時間帯にも、取り込みとマージは計算資源を使います。
Pub/Sub のパイプの 1 回の INSERT は、L0、L1、集計テーブルのそれぞれにパーツを作り、これらのパーツは裏でマージされます。
集計テーブルは小さくても、INSERT のたびにパーツができてマージがかかります。
テーブルごとの負荷は `system.part_log` で見ます。

```sql
SELECT
    table,
    countIf(event_type = 'NewPart') AS new_parts,
    countIf(event_type = 'MergeParts') AS merges,
    round(sumIf(duration_ms, event_type = 'MergeParts') / 1000) AS merge_s,
    formatReadableSize(sumIf(read_bytes, event_type = 'MergeParts')) AS merge_read
FROM clusterAllReplicas('default', system.part_log)
WHERE event_time >= now() - INTERVAL 1 HOUR AND database = 'gcl'
GROUP BY table
ORDER BY merge_s DESC;
```

- `merge_s` は、マージにかかった時間の合計です。複数のマージが同時に動くので、CPU 時間とは一致しません。テーブルどうしの比較に使います。
- マージのたびに、新しいパーツの索引も作られます。使っていない索引は、マージの負荷と保存量を増やすだけなので、`ALTER TABLE … DROP INDEX` で外せます。外す前に、ClickStack の検索やダッシュボードがその索引を使っていないかを確かめます（`Body` の索引は全文検索に、属性の索引は属性での絞り込みに使われます）。
- 1 時間あたりのパーツの数が多いときは、[トラブルシューティングの「パーツの数」](08-troubleshooting.md#パーツの数)も見ます。

保持期限（TTL）での削除もマージの中で行われます。
L1 は日ごとのパーティションと `ttl_only_drop_parts = 1` なので、期限を過ぎた日のパーツはまとめて消え、行を消すための書き直しは起きません。
削除は期限ちょうどには行われません。削除のためのマージは、既定では 4 時間以上の間隔をあけて行われます（`merge_with_ttl_timeout`、[ClickStack - Managing TTL](https://clickhouse.com/docs/clickstack/managing/ttl)）。
保持期間の変え方は[運用](07-operations.md#保持期間を変える)にあります。

## 付録：変更の手間

| 変更 | 方法 | テーブルの作り直し |
|---|---|---|
| 取り込み時に計算する列の追加 | `ADD COLUMN … MATERIALIZED` と `MATERIALIZE COLUMN` | 不要 |
| 索引の追加と削除 | `ADD INDEX` と `MATERIALIZE INDEX`、`DROP INDEX` | 不要 |
| Projection の追加 | `ADD PROJECTION` と `MATERIALIZE PROJECTION` | 不要 |
| 集計テーブル（MV）の追加 | [運用の「L3 の追加」](07-operations.md#l3-の追加) | 不要 |
| 保持期間の変更 | `MODIFY TTL`（[運用](07-operations.md#保持期間を変える)） | 不要 |
| 設定プロファイル、読み取り専用のサービス | 7、8 | 不要 |
| 並び順、パーティション、列の型の変更 | [運用の付録 A3](07-operations.md#a3-型order-bypartition-byエンジンの変更bluegreen)（Blue/Green） | 必要 |

## 計測の条件

| 項目 | 値 |
|---|---|
| ClickHouse Cloud | GCP asia-northeast1、1 レプリカ、自動スケール、26.8.1 |
| 2、3 のデータ | [よくあるクエリ](10-query-patterns.md#計測の条件)と同じ合成ログ（`tune.logs`、2026-11-22〜24 の 1 億 5,000 万行） |
| 4、6 のデータ | `tune.logs` の 2026-11-23 の 1 日分を写したテーブル（`tune.logs_d`、5,000 万行） |
| 5 のデータ | 属性を 12 個持つ合成ログ 2,000 万行を、Map の保存形式だけを変えた 2 つのテーブルに入れたもの（`tune.attrs_basic`、`tune.attrs_buckets`）。どちらも 1 つのパーツにマージしてから計測 |
| 回数 | 3 回ずつ。3 以外は `use_query_condition_cache = 0` |
| 読んだ量と時間 | `system.query_log` の `read_rows`、`read_bytes`、`query_duration_ms` |

合成ログは本番のログより文字列が短く、計測中はキャッシュに載っていたので、時間は本番より短く出ます。
比べるときは、読んだ量と、手当ての前後の比を見てください。

計測に使った SQL は `verify/advanced_tuning/` に、計測のスクリプトは `verify/query_patterns/bench.py` にあります。
[よくあるクエリの計測](10-query-patterns.md#計測の条件)で `tune.logs` を作ってから実行します。
INSERT、`OPTIMIZE`、ミューテーションは `tools/chq.py` の待ち時間（約 30 秒）より長くかかり、そのままサービスで動き続けます。
1 文ずつ実行し、`system.processes` と `system.mutations` で終わったことを確かめてから次に進みます。

```bash
# verify/advanced_tuning/ の 10、20、30、40 の SQL を、上の注意のとおり 1 文ずつ実行してから
python3 verify/query_patterns/bench.py --service <id> t1_ t2_ t3_
```

計測が終わったら `DROP DATABASE tune` で消します。
