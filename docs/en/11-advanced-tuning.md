# Tuning in operation

English | [日本語](../ja/11-advanced-tuning.md)

This page helps you pick a fix from the symptom when searches or aggregations become slow after go-live, or when ingestion load grows.
Fixes that only need a different way of writing the query are in [query patterns](10-query-patterns.md).
This page covers how to find slow queries, and the fixes you can add later on the table or service side.
The figures come from synthetic logs ([test conditions](#test-conditions)).

## Summary

| Symptom | Section | Fix | Result in the test |
|---|---|---|---|
| You do not know which queries are heavy | [1](#1-find-the-slow-queries) | Rank `system.query_log` by data read | None |
| A search that only shows the latest few hundred rows is slow | [2](#2-sort-the-latest-n-rows-by-the-sort-key) | Make `ORDER BY` follow the sort key | 7.8 million rows → 49,152 rows |
| A dashboard with the same conditions is opened again and again | [3](#3-the-query-condition-cache-helps-queries-that-repeat-a-condition) | Query condition cache (on by default) | 150 million rows → 11,516 rows (from the second run) |
| Finding one row by a request ID or similar is slow | [4](#4-add-an-index-to-find-one-row-by-id) | Bloom filter index | 50 million rows → 459,000 rows |
| Aggregating or filtering on attributes (`LogAttributes`) is slow | [5](#5-copy-frequently-used-attributes-into-columns) | Column computed at insert time | 2.5 s → 0.07 s |
| After adding an index or column, filling the existing rows never finishes | [6](#6-fill-existing-rows-one-partition-at-a-time) | Run it per partition and watch `system.mutations` | None |
| Heavy queries from some users slow down everyone else's searches | [7](#7-set-limits-per-user) | Settings profile | None |
| Searches and ingestion compete for compute | [8](#8-separate-the-search-and-ingestion-services) | Add a read-only service | None |
| Compute stays busy even with no searches | [9](#9-look-at-ingestion-and-merge-load) | Look at merges per table in `system.part_log` | None |

Most of these fixes are added with `ALTER`, without rebuilding the table.
The [appendix](#appendix-what-each-change-takes) lists what each change takes.

## 1. Find the slow queries

Start by finding the heavy queries in `system.query_log`.
Group queries of the same shape by `normalized_query_hash` and rank them by data read.

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

| Column | How to read it |
|---|---|
| `read` | Data read. Compare fixes by this value rather than by time |
| `p95_s` | 95th percentile of the duration |
| `cpu_s` | Total CPU time. Queries that run often have a large value |
| `from_storage` | Data read from object storage (not in the cache) |
| `from_cache` | Data read from the local cache |

For a heavy query, `EXPLAIN indexes = 1` shows how far the primary key and the indexes cut the granules read.

```sql
EXPLAIN indexes = 1
SELECT count() FROM gcl.gcl_logs_v1
WHERE Timestamp >= '2026-11-23 00:00:00' AND Timestamp < '2026-11-24 00:00:00'
  AND hasAllTokens(lower(Body), 'timeout');
```

Durations change a lot with what is in the cache.
In the test, a query that searched a word over 3 days took 5.47 s on the first run (it read 187 MiB from object storage) and 0.57–0.60 s afterwards.
Do not judge from one run: use `from_storage` and `from_cache` to separate the effect of the cache before comparing.

## 2. Sort the latest N rows by the sort key

The sort key of L1 is `(toStartOfFiveMinutes(Timestamp), ServiceName, Timestamp)`.
`ORDER BY Timestamp DESC LIMIT 200` cannot use it: ClickHouse reads every row in the range and then sorts.
With `ORDER BY toStartOfFiveMinutes(Timestamp) DESC, Timestamp DESC`, which follows the sort key, ClickHouse reads from the newest end and stops once it has 200 rows.
When `ReadType` in `EXPLAIN actions = 1` shows `InReverseOrder`, the query reads this way.

```sql
-- Slow
SELECT Timestamp, SeverityText, Body FROM gcl.gcl_logs_v1
WHERE Timestamp >= '2026-11-23 00:00:00' AND Timestamp < '2026-11-24 00:00:00'
  AND ServiceName = 'k8s_container/app-a'
ORDER BY Timestamp DESC LIMIT 200;

-- Fast
SELECT Timestamp, SeverityText, Body FROM gcl.gcl_logs_v1
WHERE Timestamp >= '2026-11-23 00:00:00' AND Timestamp < '2026-11-24 00:00:00'
  AND ServiceName = 'k8s_container/app-a'
ORDER BY toStartOfFiveMinutes(Timestamp) DESC, Timestamp DESC LIMIT 200;
```

| Query (one service, one day, latest 200 rows) | Rows read | Data read | Time |
|---|---|---|---|
| `ORDER BY Timestamp DESC` | 7.8 million | 104 MiB | 0.13–0.65 s |
| `ORDER BY toStartOfFiveMinutes(Timestamp) DESC, Timestamp DESC` | 49,152 | 1.12 MiB | 0.01–0.02 s |
| `SELECT *` with `ORDER BY Timestamp DESC` | 7.8 million | 105 MiB | 0.14–1.56 s |
| `SELECT *` with the `ORDER BY` that follows the sort key | 49,152 | 1.63 MiB | 0.02 s |

In this test, `SELECT *` barely increased the data read.
The difference came from how `ORDER BY` was written, not from the columns selected.

The ClickStack search page builds `(toStartOfFiveMinutes(Timestamp), Timestamp) DESC` from the table's sort key, so it already uses this form (when Default Order By in the source settings is left empty).
Queries written by hand in the SQL console or Grafana need to follow the sort key themselves.

A query that filters on a word and then takes the latest rows also reads less when it follows the sort key.
When the word is rare, though, it still reads many granules before it has 200 rows, so the gain is smaller.
For the latest 200 rows containing `timeout` across all services over 3 days, the rows read fell from 51.7 million to 37.4 million (842 MiB → 611 MiB).

## 3. The query condition cache helps queries that repeat a condition

The query condition cache remembers granules with no row matching the `WHERE` condition, and the next query with the same condition skips them ([documentation](https://clickhouse.com/docs/concepts/features/performance/caches/query-condition-cache)).
It is on by default since 25.4 (`use_query_condition_cache = 1`).

| Query (3 days, 150 million rows, `Body LIKE '%request_id=…%'`) | Rows read | Data read | Time |
|---|---|---|---|
| First run | 150 million | 3.64 GiB | 15.9 s |
| Second and third runs | 11,516 | 730 KiB | 0.01 s |
| A different query with the same `WHERE`, counting per hour | 11,516 | 730 KiB | 0.01 s |
| The end of the time range moved by one minute | 150 million | 3.64 GiB | 6.5 s |

The cache is kept per condition, so a query with a different `SELECT` used it as long as the `WHERE` was the same.
The time range is part of the condition, though, so a different range did not use it.
It helps when an investigation filters the same time window again and again.
Expect little from it on dashboards whose range moves every time they open, such as "last 15 minutes".
It also does not help when matching rows appear in almost every granule, since there is nothing to skip.

The other measurements in this guide run with `use_query_condition_cache = 0` to remove its effect.
The query cache (`use_query_cache`), which stores whole results, is a different feature and is off by default.
Its results can be stale, so do not use it for log searches.

## 4. Add an index to find one row by ID

Finding one row by a column outside the sort key, such as a request ID or `InsertId`, reads that column across the whole range.
For a column with many distinct values where each value appears in only a few granules, a bloom filter index works.

```sql
ALTER TABLE gcl.gcl_logs_v1 ADD INDEX idx_insert_id InsertId TYPE bloom_filter(0.01) GRANULARITY 1;
-- Build the index for existing rows as well (per partition, as in 6)
ALTER TABLE gcl.gcl_logs_v1 MATERIALIZE INDEX idx_insert_id IN PARTITION '2026-11-23';
```

| Query (one day, 50 million rows, `InsertId = '…'`) | Rows read | Data read | Time | Index size |
|---|---|---|---|---|
| No index | 50 million | 906 MiB | 0.94–0.96 s | None |
| Bloom filter (`bloom_filter(0.01)`) | 459,000 | 8.5 MiB | 0.10–0.14 s | 58 MiB |
| Projection holding only `_part_offset` | 8,192 | 247 KiB | 0.03 s | 524 MiB |

When comparing, check both whether the rows read went down and whether the overall time went down.
An index adds storage and is built on every insert and merge.
Measure before deciding that it pays off.

- An index does not help with values that have few distinct values and appear in every granule. In the test, a `set` index on `SeverityText = 'ERROR'` left the rows read at 50 million, because ERROR rows were in almost every granule. Use an MV for such counts ([query patterns, 6](10-query-patterns.md#6-use-a-materialized-view-for-aggregations-you-run-repeatedly)).
- The documentation recommends text indexes first for string columns ([ClickStack - Performance tuning](https://clickhouse.com/docs/clickstack/managing/performance-tuning#when-to-add-skip-indexes)). L1 has a text index on `TraceId`. Building a text index takes a lot of memory, though. In the test, building a text index on `InsertId` afterwards for a 50-million-row part tried to use about 10 GiB and failed against the memory limit of the test service (6.76 GiB).
- The projection holding only `_part_offset` read the least. The documentation does not yet recommend it for ClickStack-style workloads ([ClickStack - Lightweight projections](https://clickhouse.com/docs/clickstack/managing/performance-tuning#lightweight-projections), beta). If you use one, check search times on production-like data first.

## 5. Copy frequently used attributes into columns

`LogAttributes` and `ResourceAttributes` are Maps.
Even a query that reads one key reads and unpacks the Map column itself.
Copying frequently used attributes into columns computed at insert time (`MATERIALIZED`) lets the query read only that column.
The documentation lists this as the first fix to consider when tuning ClickStack ([ClickStack - Materialize frequently queried attributes](https://clickhouse.com/docs/clickstack/managing/performance-tuning#materialize-frequently-queried-attributes)).

```sql
ALTER TABLE gcl.gcl_logs_v1
    ADD COLUMN HttpRoute LowCardinality(String) MATERIALIZED LogAttributes['http.route'],
    ADD COLUMN UserId String MATERIALIZED LogAttributes['user_id'];
-- Fill existing rows as well (per partition, as in 6)
ALTER TABLE gcl.gcl_logs_v1 MATERIALIZE COLUMN HttpRoute IN PARTITION '2026-11-23';
```

| Query (20 million rows, 12 attributes) | Map (`basic`) | Map (`with_buckets`) | Column computed at insert time |
|---|---|---|---|
| Count per `http.route` | 4.15 GiB, 2.45–2.82 s | 296 MiB, 2.68–3.05 s | 19 MiB, 0.07–0.08 s |
| Filter on `user_id` | 4.15 GiB, 2.45–2.58 s | 165 MiB, 2.35–3.11 s | 165 MiB, 0.31–0.35 s |

L1 stores the Maps of merged parts in the `with_buckets` format.
That format cut the data read sharply, but barely changed the time.
The column cut both.

- ClickStack detects columns copied out of a Map. When a user filters on the original attribute, such as `LogAttributes['http.route']`, ClickStack builds the query on the column, so saved searches and dashboards need no change.
- L1 also has a text index on `key=value` (`idx_log_attr_items`), which already skips granules for equality filters on attributes. Columns help most with aggregations by attribute (`GROUP BY`), filters with `LIKE` or ranges, and SQL written by hand.
- Choose which attributes to copy by counting them in real queries.

```sql
SELECT key, count() AS queries
FROM clusterAllReplicas('default', system.query_log)
ARRAY JOIN extractAll(query, 'LogAttributes\\[\'([^\']+)\'\\]') AS key
WHERE event_date >= today() - 7 AND type = 'QueryFinish' AND query_kind = 'Select'
GROUP BY key ORDER BY queries DESC LIMIT 20;
```

- Use `LowCardinality(String)` for attributes with few distinct values. Give numeric attributes a numeric type, such as `toUInt16OrZero(LogAttributes['http.status_code'])`, so that range filters and `minmax` indexes work.
- Each column adds ingestion CPU. In the test, three columns added about 0.46 CPU seconds per million rows ([query patterns, effect on ingestion](10-query-patterns.md#effect-on-ingestion)).

## 6. Fill existing rows one partition at a time

`MATERIALIZE INDEX`, `MATERIALIZE COLUMN` and `MATERIALIZE PROJECTION` run in the background as mutations that rewrite existing parts.
Run against the whole table at once, they hold compute and memory while large parts are rewritten.
A failed mutation is retried again and again, and the mutations issued after it on the same table do not move.
In the text index test in 4, the mutation failed against the memory limit, and the two mutations issued after it stopped too.

Split the work by daily partition and start with the newest day.

```sql
ALTER TABLE gcl.gcl_logs_v1 MATERIALIZE INDEX idx_insert_id IN PARTITION '2026-11-23';
```

Watch progress and failure reasons in `system.mutations`.

```sql
SELECT mutation_id, command, create_time, parts_to_do, latest_fail_time, latest_fail_reason
FROM clusterAllReplicas('default', system.mutations)
WHERE database = 'gcl' AND NOT is_done
ORDER BY create_time;
```

Stop a mutation that keeps failing with `KILL MUTATION`.
Then run it again on smaller partitions, or after making the service larger.

```sql
KILL MUTATION WHERE database = 'gcl' AND table = 'gcl_logs_v1' AND mutation_id = '<mutation_id>';
```

An added index or column applies to newly ingested rows from the moment it is added.
You can also limit the fill of existing rows to the period that searches use.

## 7. Set limits per user

When heavy queries from some users slow down other searches, set per-user limits with a settings profile ([CREATE SETTINGS PROFILE](https://clickhouse.com/docs/reference/statements/create/settings-profile)).
This works when each client, such as Grafana or a BI tool, can have its own user.

```sql
CREATE SETTINGS PROFILE IF NOT EXISTS dashboard SETTINGS
    max_execution_time = 60,          -- time limit per query (seconds)
    max_memory_usage = 8000000000,    -- memory limit per query (bytes)
    max_threads = 4;                  -- threads per query
CREATE USER IF NOT EXISTS grafana_viewer IDENTIFIED WITH sha256_password BY '<password>'
    SETTINGS PROFILE 'dashboard';
GRANT SELECT ON gcl.* TO grafana_viewer;
```

- A query that exceeds a limit stops with an error. Tell the users beforehand that they may see it.
- Choose the values after looking at the current durations and memory in `system.query_log` (section 1).
- For a read-only user, add `readonly = 1` to the profile.

## 8. Separate the search and ingestion services

Ingestion and merges use compute all the time, so a burst of searches competes with them.
ClickHouse Cloud lets you add a read-only service that shares the same data and send searches to it ([Warehouses](https://clickhouse.com/docs/products/cloud/features/infrastructure/warehouses), Scale and Enterprise plans).

- A read-only service does not run merges, so all of its compute serves queries.
- Each service has its own size, autoscaling and idling. The ingestion service can stay always on while the search service idles outside working hours.
- Storage is shared and not billed twice.
- ClickStack queries the service it was opened from in the Cloud console. Open ClickStack from the read-only service and searches run there. Dashboards, saved searches, alerts and sources belong to each service, though, so they have to be recreated ([Using ClickStack with read-only compute](https://clickhouse.com/docs/clickstack/self-configured/deployment/managed#additional-tasks)).

Separating services does not change how much one query reads.
Fix queries that do not skip data with sections 2–5 first.
The documentation says a single service usually absorbs both workloads below roughly 100 TB/month of stored data ([Isolating read and write workloads](https://clickhouse.com/docs/clickstack/self-configured/managing/isolating-read-write)).

## 9. Look at ingestion and merge load

Ingestion and merges use compute even when nobody is searching.
Each INSERT of the Pub/Sub pipe creates parts in L0, L1 and the aggregate tables, and these parts are merged in the background.
An aggregate table gets a part on every INSERT and is merged, however small it is.
Look at the load per table in `system.part_log`.

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

- `merge_s` is the total duration of merges. Merges run in parallel, so it is not CPU time; use it to compare tables.
- Every merge also builds the indexes of the new part. An index nobody uses only adds merge load and storage, and `ALTER TABLE … DROP INDEX` removes it. Before removing one, check that ClickStack searches and dashboards do not use it (the `Body` index serves full-text search and the attribute indexes serve attribute filters).
- When there are many parts per hour, see also [part counts](08-troubleshooting.md#part-counts) in troubleshooting.

Deletion by TTL also happens in merges.
L1 has daily partitions and `ttl_only_drop_parts = 1`, so the parts of an expired day are dropped whole, without rewriting parts to remove rows.
Deletion does not happen exactly at expiry: by default, merges for deletion run at least 4 hours apart (`merge_with_ttl_timeout`, [ClickStack - Managing TTL](https://clickhouse.com/docs/clickstack/managing/ttl)).
How to change the retention is in [operations](07-operations.md#changing-retention).

## Appendix: what each change takes

| Change | How | Table rebuild |
|---|---|---|
| Add a column computed at insert time | `ADD COLUMN … MATERIALIZED` and `MATERIALIZE COLUMN` | No |
| Add or drop an index | `ADD INDEX` and `MATERIALIZE INDEX`, `DROP INDEX` | No |
| Add a projection | `ADD PROJECTION` and `MATERIALIZE PROJECTION` | No |
| Add an aggregate table (MV) | [Operations, adding an L3](07-operations.md#adding-an-l3) | No |
| Change retention | `MODIFY TTL` ([operations](07-operations.md#changing-retention)) | No |
| Settings profile, read-only service | Sections 7 and 8 | No |
| Change the sort key, partitioning or column types | [Operations appendix A3](07-operations.md#a3-changing-types-order-by-partition-by-or-engine-bluegreen) (Blue/Green) | Yes |

## Test conditions

| Item | Value |
|---|---|
| ClickHouse Cloud | GCP asia-northeast1, 1 replica, autoscaling, 26.8.1 |
| Data for 2 and 3 | The same synthetic logs as [query patterns](10-query-patterns.md#test-conditions) (`tune.logs`, 150 million rows over 2026-11-22..24) |
| Data for 4 and 6 | A copy of one day (2026-11-23) of `tune.logs` (`tune.logs_d`, 50 million rows) |
| Data for 5 | 20 million synthetic rows with 12 attributes each, in two tables that differ only in the Map format (`tune.attrs_basic`, `tune.attrs_buckets`). Both merged into one part before measuring |
| Runs | 3 each. All except section 3 ran with `use_query_condition_cache = 0` |
| Data read and time | `read_rows`, `read_bytes` and `query_duration_ms` in `system.query_log` |

Synthetic logs have shorter strings than production logs, and the data was cached during the test, so the times come out shorter than in production.
Compare the data read and the before/after ratio.

The SQL is in `verify/advanced_tuning/` and the benchmark script is `verify/query_patterns/bench.py`.
Create `tune.logs` first with the [query patterns test](10-query-patterns.md#test-conditions).
INSERTs, `OPTIMIZE` and mutations take longer than the ~30 s that `tools/chq.py` waits and keep running on the service.
Run one statement at a time and check in `system.processes` and `system.mutations` that it finished before the next.

```bash
# After running the SQL in verify/advanced_tuning/ (10, 20, 30, 40) one statement at a time, as above
python3 verify/query_patterns/bench.py --service <id> t1_ t2_ t3_
```

When you are done, remove the data with `DROP DATABASE tune`.
