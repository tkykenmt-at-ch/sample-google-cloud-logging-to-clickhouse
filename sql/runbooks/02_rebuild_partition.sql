-- Runbook 02: rebuild one settled day of L1 from L0 after a parser fix, then rebuild its rollup.
-- REPLACE PARTITION does NOT fire MVs on gcl_logs_v1: the rollup must be rebuilt explicitly.
-- Use only for days where late arrivals have settled (check verify/checks.sql: late-arrival distribution).
-- Variables: {{DAY}} = 2026-10-07, {{PART}} = 20261007, {{FROM}}/{{TO}} = publish-time window that holds every
--   entry of the day: {{FROM}} = DAY - 1 day (timestamps up to 24 h in the future), {{TO}} = now (late arrivals).
-- REPLACE PARTITION deletes every row of the day that the rebuild does not hold: rows that are not in L0
-- (L0 expired, runbook 06 rows, runbook 10 rows older than the L0 TTL) are lost. Step "Compare" must pass.
-- A per-month L3 (runbook 09, toYYYYMM) cannot be fixed by a one-day REPLACE: rebuild its month from L1.

CREATE TABLE gcl.gcl_logs_v1_rebuild AS gcl.gcl_logs_v1;

-- INSERT ... SELECT maps columns by POSITION, while an MV maps them by NAME.
-- Wrap the MV body in a subquery and select the target columns in table order
-- (SELECT arrayStringConcat(groupArray(name), ', ') FROM system.columns
--  WHERE database = 'gcl' AND table = 'gcl_logs_v1' ORDER BY position).
INSERT INTO gcl.gcl_logs_v1_rebuild
SELECT /* target columns in table order */ *
FROM
(
    -- body of the fixed MV (WITH ... SELECT ...), reading L0 through a deduplicating subquery:
    -- FROM (SELECT * FROM gcl.gcl_landing_v1
    --       WHERE _publish_time >= toDateTime64('{{FROM}}', 3, 'UTC') AND _publish_time < toDateTime64('{{TO}}', 3, 'UTC')
    --       LIMIT 1 BY if(_message_id != '', _message_id, concat(JSONExtractString(_raw_message, 'logName'), '|', JSONExtractString(_raw_message, 'insertId'), '|', JSONExtractString(_raw_message, 'timestamp'))))
    -- WHERE (/* the current WHERE of the MV: noise rules */)
    -- L0 keeps Pub/Sub redeliveries as separate rows; without LIMIT 1 BY they come back into L1
    -- (observed: 493 duplicates in an 8-minute window right after a pipe seek). Rows copied by runbook 10
    -- have no message ID: the LogEntry identity keeps them apart.
)
WHERE toDate(Timestamp) = '{{DAY}}';

-- Compare before replacing (by LogEntry identity, because the old partition may hold duplicates too).
SELECT uniqExact(LogName, InsertId, Timestamp) FROM gcl.gcl_logs_v1 WHERE toDate(Timestamp) = '{{DAY}}';
SELECT uniqExact(LogName, InsertId, Timestamp) FROM gcl.gcl_logs_v1_rebuild;
-- Entries the rebuild would delete: must be 0 (or exactly the rows a noise rule added since now drops).
-- Otherwise stop: widen FROM/TO, or the day holds rows that only exist in L1.
SELECT count() FROM gcl.gcl_logs_v1
WHERE toDate(Timestamp) = '{{DAY}}'
  AND (LogName, InsertId, Timestamp) NOT IN (SELECT LogName, InsertId, Timestamp FROM gcl.gcl_logs_v1_rebuild);

ALTER TABLE gcl.gcl_logs_v1 REPLACE PARTITION ID '{{PART}}' FROM gcl.gcl_logs_v1_rebuild;

-- Rebuild the matching rollup partition from the rebuilt rows.
CREATE TABLE gcl.gcl_logs_1m_v1_rebuild AS gcl.gcl_logs_1m_v1;
INSERT INTO gcl.gcl_logs_1m_v1_rebuild (Minute, ProjectId, ServiceName, SeverityText, HttpStatus, Cnt)
SELECT toStartOfMinute(Timestamp) AS Minute, ProjectId, ServiceName, SeverityText, HttpStatus, count() AS Cnt
FROM gcl.gcl_logs_v1_rebuild
GROUP BY Minute, ProjectId, ServiceName, SeverityText, HttpStatus;
ALTER TABLE gcl.gcl_logs_1m_v1 REPLACE PARTITION ID '{{PART}}' FROM gcl.gcl_logs_1m_v1_rebuild;

DROP TABLE gcl.gcl_logs_1m_v1_rebuild;
DROP TABLE gcl.gcl_logs_v1_rebuild;
