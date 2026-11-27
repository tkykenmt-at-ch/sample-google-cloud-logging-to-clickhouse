# よくあるクエリと速い書き方

[English](../en/10-query-patterns.md) | 日本語

ClickStack と SQL コンソールでよく書かれるクエリを、パターンごとに遅い書き方と速い書き方で並べます。
クエリの書き方を変えれば済むものと、テーブル側（取り込み時に計算する列や MV）の手当てが要るものを分けています。
数値は合成ログで計測した結果です（[計測の条件](#計測の条件)）。

## 早見表

| パターン | 遅い書き方 | 速い書き方 | 手当ての場所 | 計測で読んだ量 |
|---|---|---|---|---|
| [1. 語を探す](#1-語を探すときは-like-ではなく全文検索を使う) | `Body LIKE '%語%'` | `hasAllTokens(lower(Body), lower('語'))` | クエリ | 1.24 GiB → 148 MiB |
| [2. 総数と条件付きの件数](#2-総数と条件付きの件数は分けて数える) | `countIf(Body LIKE …)` と `count()` を 1 本で | 総数と、全文検索で絞った件数を別々に | クエリ | 243 MiB → 45 MiB ＋ 71 MiB |
| [3. 範囲を絞る](#3-並び順の列で絞る) | 時刻だけで絞る | 時刻と `ServiceName` で絞る | クエリ | ほかのサービスの割合しだい |
| [4. グラフの件数](#4-グラフの条件は系列ではなく全体のフィルタに置く) | 系列ごとの `countIf(条件)` | `WHERE 条件` と `count()`、さらに MV | クエリと MV | 1 億 5,000 万行 → 8 万行（MV） |
| [5. 文字列の加工](#5-毎回の文字列の加工は取り込み時の列にする) | 毎回 `path(HttpUrl)` や UA の判定 | 取り込み時に計算する列 | テーブル | 5.55 GiB → 961 MiB |
| [6. 繰り返し見る集計](#6-繰り返し見る集計は-mv-にする) | 生のログを毎回集計 | MV の集計テーブル | テーブル | 5.48 GiB → 164 KiB |

## 1. 語を探すときは LIKE ではなく全文検索を使う

L1 の `gcl_logs_v1` には、`lower(Body)` に 2 文字ずつのテキストインデックス（`idx_lower_body`）があります。
`LIKE '%語%'`、`ILIKE`、`lower(Body) LIKE` はこのインデックスを使わず、範囲内のすべての行の `Body` を読みます。
`hasAllTokens` か `hasToken` で書くと、語を含まないグラニュールを読み飛ばせます。

```sql
-- 遅い
SELECT count() FROM gcl.gcl_logs_v1
WHERE Timestamp >= '2026-11-23 00:00:00' AND Timestamp < '2026-11-24 00:00:00'
  AND Body ILIKE '%timeout%';

-- 速い
SELECT count() FROM gcl.gcl_logs_v1
WHERE Timestamp >= '2026-11-23 00:00:00' AND Timestamp < '2026-11-24 00:00:00'
  AND hasAllTokens(lower(Body), 'timeout');
```

| 条件（1 日分） | 読んだ行 | 読んだ量 | 時間 | 件数 |
|---|---|---|---|---|
| 全サービス、`Body ILIKE '%timeout%'` | 5,000 万 | 1.24 GiB | 0.55〜0.58 秒 | 44,789 |
| 全サービス、`hasAllTokens(lower(Body), 'timeout')` | 1,720 万 | 148 MiB | 0.09〜0.24 秒 | 44,789 |
| 1 サービス、`Body LIKE '%タイムアウト%'` | 776 万 | 316 MiB | 0.18〜0.35 秒 | 5,929 |
| 1 サービス、`lower(Body) LIKE '%タイムアウト%'` | 746 万 | 374 MiB | 0.19〜0.40 秒 | 5,929 |
| 1 サービス、`hasAllTokens(lower(Body), lower('タイムアウト'))` | 746 万 | 71 MiB | 0.06〜0.07 秒 | 5,929 |

`EXPLAIN indexes = 1` では、`idx_lower_body` が読むグラニュールを 6,106 から 2,102 に減らしていました。
語がほぼすべてのグラニュールに現れる場合（1 サービスの「タイムアウト」）は、読む行は減りませんでしたが、読んだ量は 374 MiB から 71 MiB に減りました。`Body` の列を読まず、インデックスだけで判定したとみられます。

ClickStack の検索窓に入れた語は、ClickStack が `hasAllTokens(lower(Body), lower('語'))` に変換します（[検証記録](09-findings.md#日本語の全文検索)）。
SQL コンソールで書くクエリと、ClickStack のグラフに手で書く条件は、このように書き換えます。

### 一致の定義の違い

`LIKE` は文字列の一部として一致を調べます。
2 文字ずつのインデックスでの `hasAllTokens` は、語を 2 文字ずつに分けた組がすべて含まれていれば一致とみなし、組の並び順は見ません。
そのため、`LIKE` より多く数えることがあります。

| `Body` | `hasAllTokens(lower(Body), 'timeout')` | `Body ILIKE '%timeout%'` |
|---|---|---|
| `upstream timeout` | 一致 | 一致 |
| `video time out` | 一致 | 一致しない |

件数を `LIKE` と同じにする必要があるときは、インデックスで絞ったうえで `LIKE` を重ねます。
全サービス 1 日分の計測では、`ILIKE` だけの 1.24 GiB、0.55〜0.58 秒に対して、981 MiB、0.37〜0.39 秒でした。

```sql
WHERE hasAllTokens(lower(Body), 'timeout') AND Body ILIKE '%timeout%'
```

### 使えない場面

- `hasAllTokens` は `WHERE` に書いたときだけインデックスの区切り方（2 文字ずつ）で判定されます。`countIf(hasAllTokens(...))` のように `SELECT` 句に書くと既定の区切り方になり、日本語の語は 0 件になりました（`WHERE` では 29,905 件）。条件付きの件数は [2](#2-総数と条件付きの件数は分けて数える) のようにクエリを分けて数えます。
- 1 文字の語は 2 文字ずつのインデックスでは探せません。
- インデックスは `lower(Body)` に作っています。語も `lower()` で小文字にそろえます。
- `HttpUrl`、`HttpUserAgent`、`LogAttributes` の値にはテキストインデックスがありません。これらを `LIKE` で探す集計は、[5](#5-毎回の文字列の加工は取り込み時の列にする) の取り込み時の列で手当てします。

## 2. 総数と条件付きの件数は分けて数える

エラーの件数と総数を 1 本で数えると、範囲内のすべての行の `Body` を読みます。
総数は `Timestamp` だけで数えられるので、2 本に分けると、それぞれが必要な列だけを読みます。

```sql
-- 遅い
SELECT countIf(Body LIKE '%タイムアウト%') AS err, count() AS total FROM gcl.gcl_logs_v1 WHERE …;

-- 速い
SELECT count() FROM gcl.gcl_logs_v1 WHERE …;
SELECT count() FROM gcl.gcl_logs_v1 WHERE … AND hasAllTokens(lower(Body), lower('タイムアウト'));
```

| 書き方（1 サービス 1 日分） | 読んだ量 | 時間 |
|---|---|---|
| 1 本で `countIf` と `count()` | 243 MiB | 0.16〜0.18 秒 |
| 総数だけ | 45 MiB | 0.06 秒 |
| 全文検索で絞った件数だけ | 71 MiB | 0.06〜0.07 秒 |

## 3. 並び順の列で絞る

L1 の並び順は `(toStartOfFiveMinutes(Timestamp), ServiceName, Timestamp)` です。
時刻の範囲に加えて `ServiceName` で絞ると、ほかのサービスの行を読み飛ばせます。
読み飛ばせる量は、絞り込みで外れるサービスが全体に占める割合で決まります。

計測では、ロードバランサのログが全体の 7 割を占めていたので、`ServiceName` を足しても読んだ量は 1.76 GiB から 1.67 GiB にしか減りませんでした（読んだ行は 5,000 万から 3,738 万）。
ロードバランサのログが全体の一部にすぎない環境では、差はもっと大きくなります。
効いているかどうかは、`EXPLAIN indexes = 1` で読むグラニュールの数を見て確かめます。

`LogId` や `PayloadType` は並び順に入っていないので、これらだけで絞っても読み飛ばせません。
監査ログのように決まったサービスのログを探すときは、`ServiceName` も条件に入れます。

## 4. グラフの条件は系列ではなく全体のフィルタに置く

ClickStack のグラフで系列ごとに条件を付けると、`countIf(条件)` の形のクエリになります。
この形は範囲内のすべての行を数えるうえ、ClickStack の MV（[6](#6-繰り返し見る集計は-mv-にする)）を使えません。
1 本の系列しかないグラフでは、条件をグラフ全体のフィルタに置くと `WHERE 条件` と `count()` になります。

| 書き方（3 日分、1 時間ごとのエラーの件数） | 読んだ行 | 読んだ量 | 時間 |
|---|---|---|---|
| `countIf(SeverityText = 'ERROR')` | 1 億 5,000 万 | 1.26 GiB | 0.88〜0.94 秒 |
| `WHERE SeverityText = 'ERROR'` と `count()` | 1 億 5,000 万 | 1.26 GiB | 0.64〜0.71 秒 |
| 1 分ごとの件数の MV から | 82,079 | 1.02 MiB | 0.01 秒 |

`SeverityText` は並び順に入っていないので、`WHERE` に置いても読む行は減りません。
大きく変わるのは MV に置き換えたときです。

## 5. 毎回の文字列の加工は取り込み時の列にする

ボットの判定（`HttpUserAgent` に `positionCaseInsensitive` を重ねる）、`path(HttpUrl)`、`domain(HttpUrl)` を毎回計算する集計は、主キーで範囲を十分に絞れていても、範囲内の長い文字列を毎回読んで加工します。
この重さはクエリの書き方では減らせません。
取り込み時に計算する列（`MATERIALIZED`）にすると、短い列だけを読みます。

```sql
ALTER TABLE gcl.gcl_logs_v1
    ADD COLUMN Bot LowCardinality(String) MATERIALIZED multiIf(
        positionCaseInsensitive(HttpUserAgent, 'gptbot') > 0, 'GPTBot',
        positionCaseInsensitive(HttpUserAgent, 'claudebot') > 0, 'ClaudeBot',
        positionCaseInsensitive(HttpUserAgent, 'googlebot') > 0, 'Googlebot',
        HttpUserAgent = '', '', 'other'),
    ADD COLUMN UrlPath String MATERIALIZED path(HttpUrl);
-- 既存の行にも値を入れる（ミューテーションとして裏で実行される）
ALTER TABLE gcl.gcl_logs_v1 MATERIALIZE COLUMN Bot;
ALTER TABLE gcl.gcl_logs_v1 MATERIALIZE COLUMN UrlPath;
```

| 書き方（ロードバランサのログ 1 日分、3,738 万行） | 読んだ量 | 時間 |
|---|---|---|
| ボットとパスを毎回計算して集計 | 5.55 GiB | 4.72〜5.60 秒 |
| 取り込み時の列で集計 | 961 MiB | 1.65〜1.91 秒 |

ボットの判定の条件を変えたときは、列の定義を `MODIFY COLUMN` で変え、過去の行が必要なら `MATERIALIZE COLUMN` をやり直します。
列の追加と作り直しの手順は[運用](07-operations.md#a1-派生列の追加)にあります。

## 6. 繰り返し見る集計は MV にする

ダッシュボードのように同じ集計を繰り返し見る場合は、MV で取り込み時に集計しておくと、生のログを読まずに済みます。

| 集計（ロードバランサのログ 1 日分） | 読んだ行 | 読んだ量 | 時間 |
|---|---|---|---|
| 生のログから、ボット × パスの第 1 階層 | 3,738 万 | 5.48 GiB | 4.18〜4.23 秒 |
| 1 時間ごとの MV から | 12,009 | 164 KiB | 0.03 秒以下 |

MV が小さくなるかどうかは、MV で分ける列の値の種類の数で決まります。
計測では、5 分ごと × パスそのもの × ボット × ステータスで分けた MV が、3 日分のロードバランサのログ 1 億 500 万行に対して 9,588 万行になり、ほとんど小さくなりませんでした。
パスや UA そのもののように種類の多い列は MV で分けず、[5](#5-毎回の文字列の加工は取り込み時の列にする) の取り込み時の列で手当てします。

ClickStack は、ソースに登録した MV を、グラフ、検索画面のヒストグラム、アラートで自動的に使います（ベータ）。
登録の手順は [ClickStack - materialized views](https://clickhouse.com/docs/clickstack/managing/materialized-views) にあります。

### MV の制約

ClickStack が MV を使わず、元のテーブルを読む条件です（[公式ドキュメントの Limitations](https://clickhouse.com/docs/clickstack/managing/materialized-views#limitations)）。

- グラフの時間範囲の始まりが、MV の最も古い時刻より前にある。MV は作成後のデータだけを持つので、過去の分はバックフィルが要る。
- グラフの粒度が MV の粒度のちょうど倍数でない。粒度は 1 分か 1 時間にし、10 分にはしない（ClickStack のグラフには 15 分があるため）。
- MV にない集計関数を求めている。
- `count(if(...))` のような条件付きの件数を求めている（[4](#4-グラフの条件は系列ではなく全体のフィルタに置く)）。
- MV にない列で絞り込んでいる。

MV の設計と運用での注意です。

- 1 つのソースに登録する MV は 20 本以下、目安は 10 本前後にする（公式の推奨で、ClickStack が本数を制限してはいない）。ClickStack はグラフを描くたびに、登録されたすべての MV について `EXPLAIN ESTIMATE` を流して、読む行の最も少ないものを選ぶ。
- 取り込みの負荷は、登録の本数とは別に見積もる。Pub/Sub のパイプの 1 回の INSERT では、L0 から L1、L1 から集計テーブル、とつながった MV がすべて同じ INSERT の中で動く。このガイドの標準の構成では、MV1、ノイズの件数、L3 の 3 本が動き、L2 を足すとその分が増える。
- Cloud Storage のパイプは一時テーブルに書いてからパーティションを移すので、MV の追加や `MODIFY QUERY` は、パイプを止めて開始し直すまで反映されない（エラーは出ない）。開始し直したあとは、L1 の先の集計テーブルまで連鎖した（検証環境、26.8）。
- 集計列の名前を `<関数>__<元の列>` にすると（件数は `count__`）、ClickStack が登録の画面で列の対応を自動で埋める。名前が規則に合わない列は、画面で手動で対応づける。このガイドの `gcl_logs_1m_v1`（L3）は `Minute` と `Cnt` なので手動になり、自動に任せると `Cnt` は件数ではなく合計と推定される。
- `REPLACE PARTITION` や `MOVE PARTITION` では MV が動きません。L1 を作り直したときは、MV の集計テーブルの同じパーティションも作り直します（[運用](07-operations.md)）。
- MV が例外を出すと、そのバッチは L1 にも届きません。直さないまま約 60 分たつとパイプが止まります（[検証記録](09-findings.md#mv-が例外を出したとき)）。MV を足す前に、ローカルや検証環境で同じ定義を流しておきます。

### 取り込みへの影響

500 万行の `INSERT ... SELECT`（合成ログの生成を含む）の CPU 時間です。

| テーブル | CPU 時間 |
|---|---|
| 取り込み時の列も MV もなし | 9.6〜9.8 秒 |
| 取り込み時の列を 3 本 | 11.3 秒 |
| 取り込み時の列を 3 本と MV を 2 本 | 13.2〜13.4 秒 |

取り込み時の列で 100 万行あたり約 0.3 CPU 秒、MV 2 本で約 0.4 CPU 秒が加わりました。
本番の流量でどれだけ増えるかは、この値に 1 秒あたりの行数を掛けて見積もります。

## 計測の条件

| 項目 | 値 |
|---|---|
| ClickHouse Cloud | GCP asia-northeast1、1 レプリカ、自動スケール（計測を終えた時点で 4 vCPU）、26.8.1 |
| データ | `numbers()` から作った合成ログ 1 億 5,000 万行（2026-11-22〜24 の 3 日分）。ロードバランサのリクエストが 7 割、アプリのログが 3 割 |
| テーブル | `gcl_logs_v1` と同じ定義（`CREATE TABLE … AS`） |
| 回数 | 各クエリを 3 回。`use_query_condition_cache = 0` |
| 読んだ量と時間 | `system.query_log` の `read_rows`、`read_bytes`、`query_duration_ms` |

書き換えの前後で、どのクエリも件数が一致しました。
合成ログは本番のログより文字列が短く、計測中はキャッシュに載っていたので、時間は本番より短く出ます。
比べるときは、読んだ量と、書き換えの前後の比を見てください。

計測に使った SQL とスクリプトは `verify/query_patterns/` にあります。

```bash
python3 tools/chq.py --service <id> verify/query_patterns/00_setup.sql
for off in $(seq -f %.0f 0 5000000 145000000); do
  python3 tools/chq.py --service <id> --var OFF=$off --var N=5000000 verify/query_patterns/10_gen_logs.sql
done
for d in 2026-11-22 2026-11-23 2026-11-24; do
  python3 tools/chq.py --service <id> --var D=$d verify/query_patterns/20_rollups.sql
done
python3 tools/chq.py --service <id> verify/query_patterns/30_matcols.sql
python3 verify/query_patterns/bench.py --service <id>
```

計測が終わったら `DROP DATABASE tune` で消します。
