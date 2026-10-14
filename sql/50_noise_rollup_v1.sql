-- Noise handling in the MV instead of the sink: high-volume, low-value entries are kept only as
-- per-minute counts. L0 still holds the raw rows for its TTL, so the decision can be reverted
-- (rebuild from L0) and the rate stays visible (a stopped heartbeat is itself a signal).
-- The rule lives here and in the WHERE of MV1 (sql/30): keep both in sync.
-- ProjectId uses the same rule as MV1 (resource.labels.project_id, else the project in logName). It is
-- last in ORDER BY and out of PRIMARY KEY, so that an existing table reaches the same definition with
-- ADD COLUMN AFTER Minute + MODIFY ORDER BY.
CREATE TABLE IF NOT EXISTS gcl.gcl_noise_1m_v1
(
    Minute      DateTime,
    ProjectId   LowCardinality(String),
    Rule        LowCardinality(String),
    ServiceName LowCardinality(String),
    Principal   LowCardinality(String),
    Cnt         SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(Minute)
PRIMARY KEY (Rule, ServiceName, Principal, Minute)
ORDER BY (Rule, ServiceName, Principal, Minute, ProjectId)
TTL Minute + INTERVAL {{LOGS_TTL_DAYS}} DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS gcl.gcl_noise_1m_v1_mv TO gcl.gcl_noise_1m_v1
DEFINER = {{MV_DEFINER}} SQL SECURITY DEFINER
AS
WITH
    JSONExtract(_raw_message, 'Tuple(timestamp String, logName String, resource Tuple(labels Map(String, String)),
        protoPayload Tuple(serviceName String, methodName String, authenticationInfo Tuple(principalEmail String)))') AS e,
    tupleElement(e, 'protoPayload') AS p,
    tupleElement(tupleElement(e, 'resource'), 'labels') AS res_labels,
    tupleElement(p, 'methodName') AS method,
    parseDateTime64BestEffortOrZero(tupleElement(e, 'timestamp'), 3, 'UTC') AS ts
SELECT
    toStartOfMinute(if(ts > toDateTime64('2000-01-01 00:00:00', 3, 'UTC'), ts, _publish_time)) AS Minute,
    if(res_labels['project_id'] != '', res_labels['project_id'], extract(tupleElement(e, 'logName'), '^projects/([^/]+)/')) AS ProjectId,
    'k8s-lease-update' AS Rule,
    tupleElement(p, 'serviceName') AS ServiceName,
    tupleElement(tupleElement(p, 'authenticationInfo'), 'principalEmail') AS Principal,
    count() AS Cnt
FROM gcl.gcl_landing_v1
WHERE method = 'io.k8s.coordination.v1.leases.update'
GROUP BY Minute, ProjectId, Rule, ServiceName, Principal;
