# Query patterns

English | [日本語](../ja/10-query-patterns.md)

This page sets typical log search and aggregation queries side by side with a faster way to write them.
It separates the patterns a rewrite of the query fixes from those that need a change on the table side (columns computed at insert time, or a materialized view (MV)).
The figures come from synthetic logs ([test conditions](#test-conditions)).

## Summary

| Pattern | Slow | Fast | Where to fix | Data read in the test |
|---|---|---|---|---|
| [1. Searching for a word](#1-search-with-the-full-text-index-not-like) | `Body LIKE '%word%'` | `hasAllTokens(lower(Body), lower('word'))` | Query | 1.24 GiB → 148 MiB |
| [2. Total and conditional count](#2-count-the-total-and-the-matches-separately) | `countIf(Body LIKE …)` and `count()` in one query | The total, and a full-text-filtered count, separately | Query | 236 MiB → 45 MiB + 71 MiB |
| [3. Narrowing the range](#3-filter-on-the-sort-key) | Time only | Time and `ServiceName` | Query | Depends on the share of other services |
| [4. Chart counts](#4-put-chart-conditions-in-the-filter-not-in-the-series) | `countIf(condition)` per series | `WHERE condition` with `count()`, then an MV | Query and MV | 150 million rows → 82 thousand (MV) |
| [5. String processing](#5-compute-repeated-string-processing-at-insert-time) | Extracting `path(HttpUrl)` and classifying the user agent on every query | Columns computed at insert time | Table | 5.29 GiB → 961 MiB |
| [6. Repeated aggregations](#6-use-a-materialized-view-for-aggregations-you-run-repeatedly) | Aggregating the raw logs every time | An MV's aggregate table | Table | 5.22 GiB → 118 KiB |

## 1. Search with the full-text index, not LIKE

The L1 table `gcl_logs_v1` has a two-character text index on `lower(Body)` (`idx_lower_body`).
`LIKE '%word%'`, `ILIKE` and `lower(Body) LIKE` do not use it, and read `Body` for every row in the range.
Written with `hasAllTokens` or `hasToken`, the query skips the granules that do not contain the word.

```sql
-- Slow
SELECT count() FROM gcl.gcl_logs_v1
WHERE Timestamp >= '2026-11-23 00:00:00' AND Timestamp < '2026-11-24 00:00:00'
  AND Body ILIKE '%timeout%';

-- Fast
SELECT count() FROM gcl.gcl_logs_v1
WHERE Timestamp >= '2026-11-23 00:00:00' AND Timestamp < '2026-11-24 00:00:00'
  AND hasAllTokens(lower(Body), 'timeout');
```

| Condition (one day) | Rows read | Data read | Time | Count |
|---|---|---|---|---|
| All services, `Body ILIKE '%timeout%'` | 50 million | 1.24 GiB | 0.54–0.57 s | 44,789 |
| All services, `hasAllTokens(lower(Body), 'timeout')` | 17.2 million | 148 MiB | 0.09–0.37 s | 44,789 |
| One service, `Body LIKE '%タイムアウト%'` | 7.80 million | 318 MiB | 0.18–0.44 s | 5,929 |
| One service, `lower(Body) LIKE '%タイムアウト%'` | 7.49 million | 375 MiB | 0.19–0.60 s | 5,929 |
| One service, `hasAllTokens(lower(Body), lower('タイムアウト'))` | 7.49 million | 71 MiB | 0.06 s | 5,929 |

With `EXPLAIN indexes = 1`, `idx_lower_body` cut the granules to read from 6,105 to 2,102.
When the word appears in nearly every granule (タイムアウト, "timeout", in one service), the rows read did not drop, but the data read fell from 375 MiB to 71 MiB, apparently because the index answered the condition without reading the `Body` column.

ClickStack turns a word typed in the search box into `hasAllTokens(lower(Body), lower('word'))` ([findings](09-findings.md#japanese-full-text-search)).
Rewrite queries in the SQL console, and conditions typed into ClickStack charts, with `hasAllTokens` yourself.

### LIKE and hasAllTokens match differently

`LIKE` looks for the word as part of the string.
With a two-character index, `hasAllTokens` treats a row as a match when it contains every two-character piece of the word, in any order.
It can therefore match more rows than `LIKE`.

| `Body` | `hasAllTokens(lower(Body), 'timeout')` | `Body ILIKE '%timeout%'` |
|---|---|---|
| `upstream timeout` | Match | Match |
| `video time out` | Match | No match |

When the count must equal the `LIKE` count, narrow with the index first and add `LIKE` on top.
Over one day of all services this read 982 MiB in 0.35–0.42 s, against 1.24 GiB in 0.54–0.57 s for `ILIKE` alone.

```sql
WHERE hasAllTokens(lower(Body), 'timeout') AND Body ILIKE '%timeout%'
```

### Where it does not apply

- `hasAllTokens` uses the index's tokenizer (two characters) only in the `WHERE` clause. In the `SELECT` list, as in `countIf(hasAllTokens(...))`, it falls back to the default tokenizer, and a Japanese word counted 0 rows (29,905 in `WHERE`). Count conditional matches with separate queries as in [pattern 2](#2-count-the-total-and-the-matches-separately).
- A one-character word cannot be searched with a two-character index.
- The index is on `lower(Body)`, so lower-case the search word with `lower()` too.
- `HttpUrl`, `HttpUserAgent` and the values of `LogAttributes` have no text index. Aggregations that search them with `LIKE` are handled by the columns computed at insert time in [pattern 5](#5-compute-repeated-string-processing-at-insert-time).

## 2. Count the total and the matches separately

Counting the errors and the total in one query reads `Body` for every row in the range.
The total needs only `Timestamp`, so with two queries each one reads only the columns it needs.

```sql
-- Slow
SELECT countIf(Body LIKE '%タイムアウト%') AS err, count() AS total FROM gcl.gcl_logs_v1 WHERE …;

-- Fast
SELECT count() FROM gcl.gcl_logs_v1 WHERE …;
SELECT count() FROM gcl.gcl_logs_v1 WHERE … AND hasAllTokens(lower(Body), lower('タイムアウト'));
```

| Query (one service, one day) | Data read | Time |
|---|---|---|
| `countIf` and `count()` in one query | 236 MiB | 0.16 s |
| Total only | 45 MiB | 0.05–0.06 s |
| Full-text-filtered count only | 71 MiB | 0.06 s |

## 3. Filter on the sort key

L1 is sorted by `(toStartOfFiveMinutes(Timestamp), ServiceName, Timestamp)`.
Filtering on `ServiceName` as well as the time range skips the rows of other services.
How much it skips depends on the share of the services the filter excludes.

In the test, load balancer logs were 70% of all rows.
Adding `ServiceName` therefore reduced the data read only from 1.75 GiB to 1.66 GiB (rows read from 50 million to 37.4 million).
Where load balancer logs are a small part of the total, the difference is larger.
Check whether the filter takes effect by looking at the number of granules in `EXPLAIN indexes = 1`.

`LogId` and `PayloadType` are not in the sort key, so filtering on them alone skips nothing.
When you look for logs of a known service, such as audit logs, add `ServiceName` to the condition.

## 4. Put chart conditions in the filter, not in the series

A ClickStack chart with a condition on each series issues a query of the form `countIf(condition)`.
That form reads every row in the range, and cannot use ClickStack materialized views ([pattern 6](#6-use-a-materialized-view-for-aggregations-you-run-repeatedly)).
For a chart with a single series, setting the condition in the chart's filter gives `WHERE condition` with `count()`.

| Query (three days, errors per hour) | Rows read | Data read | Time |
|---|---|---|---|
| `countIf(SeverityText = 'ERROR')` | 150 million | 1.26 GiB | 1.01–1.26 s |
| `WHERE SeverityText = 'ERROR'` with `count()` | 150 million | 1.26 GiB | 0.64–0.78 s |
| From an MV of per-minute counts | 82,079 | 1.02 MiB | 0.01 s |

`SeverityText` is not in the sort key, so putting it in the `WHERE` clause does not reduce the rows read.
Switching to the MV reduces the data read a great deal.

## 5. Compute repeated string processing at insert time

Aggregations that classify the client from `HttpUserAgent` (browser family or crawler), or compute `path(HttpUrl)` or `domain(HttpUrl)`, read and process the long strings in the range every time.
Even when the primary key narrows the range well, a rewrite of the query cannot remove that work.
With columns computed at insert time (`MATERIALIZED`), the query reads short columns instead.

```sql
ALTER TABLE gcl.gcl_logs_v1
    ADD COLUMN Client LowCardinality(String) MATERIALIZED multiIf(
        HttpUserAgent = '', '',
        match(HttpUserAgent, '(?i)bot|crawler|spider'), 'crawler',
        position(HttpUserAgent, 'Edg/') > 0, 'Edge',
        position(HttpUserAgent, 'Firefox/') > 0, 'Firefox',
        position(HttpUserAgent, 'Chrome/') > 0, 'Chrome',
        position(HttpUserAgent, 'Safari/') > 0, 'Safari',
        'other'),
    ADD COLUMN UrlPath String MATERIALIZED path(HttpUrl);
-- Fill the existing rows too (runs in the background as a mutation)
ALTER TABLE gcl.gcl_logs_v1 MATERIALIZE COLUMN Client;
ALTER TABLE gcl.gcl_logs_v1 MATERIALIZE COLUMN UrlPath;
```

| Query (one day of load balancer logs, 37.4 million rows) | Data read | Time |
|---|---|---|
| Client type and path computed in the query | 5.29 GiB | 6.58–8.85 s |
| Columns computed at insert time | 961 MiB | 1.95–3.10 s |

When the classification rules change, change the column with `MODIFY COLUMN`, and rerun `MATERIALIZE COLUMN` if past rows need the new values.
Adding and rebuilding a derived column is covered in [operations](07-operations.md#a1-adding-a-derived-column).

## 6. Use a materialized view for aggregations you run repeatedly

For aggregations you look at again and again, such as a dashboard, an MV that aggregates at insert time saves reading the raw logs.

| Aggregation (one day of load balancer logs) | Rows read | Data read | Time |
|---|---|---|---|
| From the raw logs, client type × first path segment | 37.4 million | 5.22 GiB | 5.63–9.53 s |
| From an hourly MV | 8,640 | 118 KiB | 0.04 s or less |

Whether an MV is small depends on how many distinct values its grouping columns have.
In the test, grouping by 5 minutes × full path × client type × status gave 34.0 million rows for one day of 35.0 million load balancer rows.
Such an MV is barely smaller than the raw logs.
Do not group an MV by high-cardinality columns such as the full path or the user agent; handle those with the columns of [pattern 5](#5-compute-repeated-string-processing-at-insert-time).

ClickStack uses MVs registered with a source in charts, search histograms and alerts automatically (beta).
Registration is described in [ClickStack - materialized views](https://clickhouse.com/docs/clickstack/managing/materialized-views).

### MV constraints

ClickStack ignores an MV and reads the source table when any of the following applies ([Limitations in the official documentation](https://clickhouse.com/docs/clickstack/managing/materialized-views#limitations)):

- The chart's time range starts before the MV's earliest timestamp. An MV holds only data inserted after it was created, so earlier data needs a backfill.
- The chart's granularity is not a whole multiple of the MV's. Use 1 minute or 1 hour, not 10 minutes (ClickStack charts offer 15 minutes).
- The chart uses an aggregate function the MV does not store.
- The chart asks for a conditional count such as `count(if(...))` ([pattern 4](#4-put-chart-conditions-in-the-filter-not-in-the-series)).
- The chart filters on a column the MV does not have.

When you design and operate MVs:

- Register 20 or fewer MVs per source; around 10 is the usual target (an official recommendation; ClickStack does not enforce a limit). Every time it renders a chart, ClickStack runs `EXPLAIN ESTIMATE` for each registered MV and picks the one that reads the fewest rows.
- Estimate the ingestion load separately from the registered count. In one INSERT of a Pub/Sub pipe, every chained MV runs inside the same INSERT: L0 to L1, then L1 to the aggregate tables. With this guide's standard set, MV1, the noise counts and L3 run, plus any L2 you add.
- A Cloud Storage pipe writes into a staging table and then moves the partitions, so an added MV or a `MODIFY QUERY` takes effect only after the pipe is stopped and resumed, with no error. After the restart the MVs ran through to the aggregate tables beyond L1 (test service, 26.8).
- Naming aggregate columns `<function>__<source column>` (`count__` for counts) lets ClickStack set the column mapping on the registration screen automatically. Map other columns by hand. This guide's `gcl_logs_1m_v1` (L3) names its columns `Minute` and `Cnt`, so it needs the manual mapping; left to inference, `Cnt` is taken as a sum, not a count.
- `REPLACE PARTITION` and `MOVE PARTITION` do not fire MVs. When you rebuild L1, rebuild the same partitions of the MV's aggregate table too ([operations](07-operations.md)).
- When an MV throws, the batch does not reach L1 either, and the pipe stops after about 60 minutes if the MV is not fixed ([findings](09-findings.md#when-an-mv-throws)). Try a new MV definition locally or on a test service before adding it.

### Effect on ingestion

The table shows the CPU time of a 5-million-row `INSERT ... SELECT` (including generating the synthetic logs).

| Table | CPU time (median) |
|---|---|
| No computed columns, no MVs | 10.5 s (10.2–11.0 s) |
| Three computed columns | 12.8 s (12.6–13.0 s) |
| Three computed columns and two MVs | 14.8 s (14.5–15.0 s) |

Per million rows, the computed columns added about 0.46 CPU seconds and the two MVs about 0.40.
Multiply these by the rows per second (in millions) for the vCPUs they add at production volume.

## Test conditions

| Item | Value |
|---|---|
| ClickHouse Cloud | GCP asia-northeast1, one replica, autoscaling, 26.8.1 |
| Data | 150 million synthetic rows from `numbers()`, three days (2026-11-22 to 24): 70% load balancer requests, 30% application logs |
| Table | Same definition as `gcl_logs_v1` (`CREATE TABLE … AS`) |
| Runs | Each query three times, with `use_query_condition_cache = 0`. Inserts three times each, alternating with a table that has nothing added |
| Rows, data and time | `read_rows`, `read_bytes`, `query_duration_ms` and `ProfileEvents['OSCPUVirtualTimeMicroseconds']` in `system.query_log` |

Every rewrite returned the same counts as the original.
The synthetic strings are shorter than real logs and the data stayed in cache, so the times are shorter than in production.
Times also vary with the autoscaling state, so compare the data read and the before/after ratios.

The SQL and scripts are in `verify/query_patterns/`.
Run them from a directory where `clickhousectl` finds its credentials.

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

Drop the data with `DROP DATABASE tune` when you are done.
