-- MV2 (optional): per-minute counts for dashboards.
-- NOTE: partition operations (REPLACE/MOVE PARTITION) on gcl_logs_v1 do not fire this MV.
-- Any backfill or rebuild of L1 must rebuild the matching rollup partitions too (see runbooks).
-- ProjectId keeps projects (environments) apart when one sink carries several. It is last in ORDER BY and
-- out of PRIMARY KEY, so that an existing table reaches the same definition with ADD COLUMN AFTER Minute
-- + MODIFY ORDER BY.
CREATE TABLE IF NOT EXISTS gcl.gcl_logs_1m_v1
(
    Minute       DateTime,
    ProjectId    LowCardinality(String),
    ServiceName  LowCardinality(String),
    SeverityText LowCardinality(String),
    HttpStatus   UInt16,
    Cnt          SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(Minute)
PRIMARY KEY (Minute, ServiceName, SeverityText, HttpStatus)
ORDER BY (Minute, ServiceName, SeverityText, HttpStatus, ProjectId)
TTL Minute + INTERVAL {{LOGS_TTL_DAYS}} DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS gcl.gcl_logs_1m_v1_mv TO gcl.gcl_logs_1m_v1
DEFINER = {{MV_DEFINER}} SQL SECURITY DEFINER
AS
SELECT
    toStartOfMinute(Timestamp) AS Minute,
    ProjectId,
    ServiceName,
    SeverityText,
    HttpStatus,
    count() AS Cnt
FROM gcl.gcl_logs_v1
GROUP BY Minute, ProjectId, ServiceName, SeverityText, HttpStatus;
