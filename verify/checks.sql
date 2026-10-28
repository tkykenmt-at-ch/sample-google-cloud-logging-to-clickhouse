-- Periodic checks for the GCL -> Pub/Sub ClickPipes -> ClickHouse pipeline.
-- Run with tools/chq.py. Table names follow sql/ (v1); adjust after a Blue/Green switch.
-- L1 is partitioned and sorted by Timestamp, not PublishTime: checks that select by publish time also bound
-- Timestamp, so they read a few partitions instead of the whole retention. Entries published more than
-- 7 days after their timestamp fall outside those bounds.

-- 1. Ingest latency: Pub/Sub publish -> row inserted, and LogEntry timestamp -> inserted.
SELECT
    toStartOfMinute(PublishTime) AS minute,
    count() AS rows,
    round(quantile(0.5)(dateDiff('millisecond', PublishTime, InsertedAt)) / 1000, 1) AS p50_publish_to_ch_s,
    round(quantile(0.99)(dateDiff('millisecond', PublishTime, InsertedAt)) / 1000, 1) AS p99_publish_to_ch_s,
    round(quantile(0.99)(dateDiff('millisecond', Timestamp, InsertedAt)) / 1000, 1) AS p99_event_to_ch_s
FROM gcl.gcl_logs_v1
WHERE PublishTime > now() - INTERVAL 15 MINUTE AND Timestamp > now() - INTERVAL 7 DAY
GROUP BY minute
ORDER BY minute;

-- 2. Stuck batches: rows in L0 that never reached L1 (should be 0; see sql/runbooks/05_mv_failure.sql).
SELECT count() AS stuck_rows, min(_publish_time) AS oldest
FROM gcl.gcl_landing_v1
WHERE _publish_time BETWEEN now() - INTERVAL 1 DAY AND now() - INTERVAL 2 MINUTE
  -- Rows dropped on purpose by a noise rule (sql/30 WHERE, sql/50, runbook 07) are not stuck: keep in sync.
  AND JSONExtractString(_raw_message, 'protoPayload', 'methodName') != 'io.k8s.coordination.v1.leases.update'
  AND _message_id NOT IN (
      SELECT MessageId FROM gcl.gcl_logs_v1
      WHERE PublishTime BETWEEN now() - INTERVAL 1 DAY AND now() AND Timestamp > now() - INTERVAL 8 DAY);

-- 3. Duplicates: Pub/Sub redelivery (same MessageId) vs. the same LogEntry exported twice (the LogEntry
--    identity logName + insertId + timestamp, as in runbooks 06 and 10). Backfilled rows have no MessageId.
SELECT
    count() AS rows,
    countIf(MessageId != '') - uniqExactIf(MessageId, MessageId != '') AS dup_by_message_id,
    rows - uniqExact(LogName, InsertId, Timestamp) AS dup_by_insert_id
FROM gcl.gcl_logs_v1
WHERE PublishTime > now() - INTERVAL 1 DAY AND Timestamp > now() - INTERVAL 8 DAY;

-- 4. Late arrivals (LogEntry.timestamp behind publish time): sizes rebuild windows and partition churn.
SELECT
    multiIf(d < 0, '0: future', d < 60, '1: <1m', d < 600, '2: 1-10m', d < 3600, '3: 10-60m', d < 86400, '4: 1-24h', '5: >24h') AS bucket,
    count() AS rows
FROM (SELECT dateDiff('second', Timestamp, PublishTime) AS d FROM gcl.gcl_logs_v1
      WHERE PublishTime > now() - INTERVAL 1 DAY AND Timestamp > now() - INTERVAL 8 DAY)
GROUP BY bucket
ORDER BY bucket;

-- 5. Parser health: rows whose body was not valid JSON, and the active parser versions.
SELECT ParserVersion, countIf(NOT ParseOk) AS invalid_json, count() AS rows
FROM gcl.gcl_logs_v1
WHERE PublishTime > now() - INTERVAL 1 DAY AND Timestamp > now() - INTERVAL 8 DAY
GROUP BY ParserVersion;

-- 6. Failed pipe inserts (the pipe state can stay Running while a batch is being retried).
--    query_log is per replica: read every replica of the service.
SELECT toStartOfMinute(event_time) AS minute, countIf(type = 'ExceptionWhileProcessing') AS failed, countIf(type = 'QueryFinish') AS ok
FROM clusterAllReplicas('default', system.query_log)
WHERE user LIKE 'clickpipe:%' AND query_kind = 'Insert' AND event_time > now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute;

-- 7. Text index use (expect idx_lower_body under Skip indexes).
-- ClickStack emits hasAllTokens (UI search) or hasToken (seen from the MCP search) on lower(Body).
-- With the ngrams(2) index, Cloud 26.6 used the index for both; clickhouse local 26.7 only for hasAllTokens.
-- Check both forms on the version you run.
EXPLAIN indexes = 1
SELECT count() FROM gcl.gcl_logs_v1
WHERE Timestamp >= now() - INTERVAL 1 HOUR AND hasAllTokens(lower(Body), 'timeout');

-- 8. Partitions, parts, compression per table (sizes L0 retention from measured bytes, not estimates).
SELECT
    table,
    uniqExact(partition) AS partitions,
    count() AS parts,
    sum(rows) AS rows,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio
FROM system.parts
WHERE database = 'gcl' AND active
GROUP BY table
ORDER BY table;

-- 9. Rows per publish hour in L0, to compare with the sink's exported entry count in Cloud Monitoring
--    (logging.googleapis.com/exports/log_entry_count, filtered by resource.label.name = <sink>).
--    Verified: the hourly difference stayed under 0.1% (entries near the hour boundary).
SELECT toStartOfHour(_publish_time) AS hour, count() AS rows_l0, uniqExact(_message_id) AS messages
FROM gcl.gcl_landing_v1
WHERE _publish_time >= now() - INTERVAL 6 HOUR AND _publish_time < toStartOfHour(now())
GROUP BY hour
ORDER BY hour;

-- 10. Records ClickPipes could not insert (the error table is created and managed by ClickPipes, kept 7 days).
--     L0 holds only the virtual columns of each message, so this normally stays empty. record_value holds
--     the whole message: the project (environment) comes from its logName.
--     https://clickhouse.com/docs/integrations/clickpipes (error table: whole invalid message, 7-day TTL).
SELECT toStartOfHour(error_timestamp) AS hour, error_type,
       -- same rule as MV1 (empty when record_value is not a LogEntry)
       if(startsWith(JSONExtractString(record_value, 'logName'), 'projects/'),
          extract(JSONExtractString(record_value, 'logName'), '^projects/([^/]+)/'),
          extract(JSONExtractString(record_value, 'logName'), '^([^/]+/[^/]+)/')) AS ProjectId,
       count() AS errors, any(error_msg) AS sample_error
FROM gcl.gcl_landing_v1_clickpipes_error
WHERE error_timestamp > now() - INTERVAL 7 DAY
GROUP BY hour, error_type, ProjectId
ORDER BY hour DESC;

-- 11. Backlog: rows written to L0 in the last hour, by publish date (L0 is partitioned by publish date).
--     Only today's date when the pipe keeps up; earlier dates mean it is still working through old messages.
SELECT partition AS publish_date, count() AS new_parts, sum(rows) AS rows
FROM clusterAllReplicas('default', system.part_log)
WHERE event_time > now() - INTERVAL 1 HOUR AND event_type = 'NewPart' AND database = 'gcl' AND table = 'gcl_landing_v1'
GROUP BY publish_date
ORDER BY publish_date;

-- 12. Pipe inserts per 10 minutes: how often, how long each took, and the share of time spent inserting.
--     With a backlog, inserts every ~5 s that finish well within the interval mean the pipe, not the service,
--     is the limit. busy_ratio can exceed 1 with several pipe replicas inserting at once.
SELECT
    user,
    toStartOfTenMinutes(event_time) AS ten_minutes,
    count() AS inserts,
    round(quantile(0.5)(query_duration_ms) / 1000, 2) AS p50_duration_s,
    round(max(query_duration_ms) / 1000, 2) AS max_duration_s,
    round(sum(query_duration_ms) / 1000 / 600, 2) AS busy_ratio
FROM clusterAllReplicas('default', system.query_log)
WHERE user LIKE 'clickpipe:%' AND query_kind = 'Insert' AND type = 'QueryFinish'
  AND event_time >= toStartOfTenMinutes(now()) - INTERVAL 1 HOUR AND event_time < toStartOfTenMinutes(now())
GROUP BY user, ten_minutes
ORDER BY user, ten_minutes;

-- 13. Rows per pipe insert into L0. A batch closes at 100,000 rows, 32 MB per GB of replica memory, or 5 s
--     (https://clickhouse.com/docs/integrations/clickpipes/pubsub/overview). Far below the size limits with a
--     backlog: the pipe cannot fill a batch in 5 s.
SELECT
    toStartOfTenMinutes(t) AS ten_minutes,
    count() AS inserts,
    round(avg(rows)) AS avg_rows_per_insert,
    max(rows) AS max_rows_per_insert,
    formatReadableSize(avg(bytes)) AS avg_uncompressed_per_insert
FROM (
    SELECT query_id, min(event_time) AS t, sum(rows) AS rows, sum(bytes_uncompressed) AS bytes
    FROM clusterAllReplicas('default', system.part_log)
    WHERE event_time >= toStartOfTenMinutes(now()) - INTERVAL 1 HOUR AND event_time < toStartOfTenMinutes(now())
      AND event_type = 'NewPart' AND database = 'gcl' AND table = 'gcl_landing_v1'
    GROUP BY query_id)
GROUP BY ten_minutes
ORDER BY ten_minutes;

-- 14. L1 partitions written by one insert. Above 100 the insert fails (max_partitions_per_insert_block).
--     Cloud Logging routes entries with old timestamps to sinks, so this depends on the spread of Timestamp
--     within a batch, not on the L1 TTL.
SELECT count() AS inserts, max(partitions) AS max_partitions, round(avg(partitions), 1) AS avg_partitions
FROM (
    SELECT query_id, uniqExact(partition_id) AS partitions
    FROM clusterAllReplicas('default', system.part_log)
    WHERE event_time > now() - INTERVAL 1 DAY AND event_type = 'NewPart' AND database = 'gcl' AND table = 'gcl_logs_v1'
    GROUP BY query_id);

-- 15. L1 parts per partition by partition age. max_parts_in_total (10,000 on Cloud) counts every active part of
--     the table, so with daily partitions kept 400 days the older partitions have to merge down to a few parts.
SELECT
    multiIf(age_days <= 1, '1: today, yesterday', age_days <= 7, '2: 2-7 days', '3: older') AS age,
    count() AS partitions,
    sum(n) AS parts,
    round(avg(n), 1) AS avg_parts_per_partition,
    max(n) AS max_parts_per_partition,
    (SELECT count() FROM system.parts WHERE active AND database = 'gcl' AND table = 'gcl_logs_v1') AS table_parts
FROM (
    SELECT partition, dateDiff('day', toDate(partition), today()) AS age_days, count() AS n
    FROM system.parts
    WHERE active AND database = 'gcl' AND table = 'gcl_logs_v1'
    GROUP BY partition)
GROUP BY age
ORDER BY age;

-- 16. Delay of the rows inserted in the last 10 minutes. Check 1 selects by publish time, so during a backlog it
--     returns few rows; this one selects by insert time and shows how far behind the pipe is. It reads 8 days of
--     L1 to catch rows published long ago, so it can take tens of seconds.
SELECT
    toStartOfMinute(InsertedAt) AS minute,
    count() AS rows,
    formatReadableTimeDelta(quantile(0.5)(dateDiff('second', PublishTime, InsertedAt))) AS p50_delay,
    formatReadableTimeDelta(max(dateDiff('second', PublishTime, InsertedAt))) AS max_delay
FROM gcl.gcl_logs_v1
WHERE Timestamp > now() - INTERVAL 8 DAY AND InsertedAt > now() - INTERVAL 10 MINUTE
GROUP BY minute
ORDER BY minute;
