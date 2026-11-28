-- The INSERTs, OPTIMIZEs and MATERIALIZE statements here outlast the ~30 s the Query API waits and keep running on the
-- service. Run one statement at a time and wait until system.processes and system.mutations show it finished.
-- One-day copy of tune.logs for the index and projection measurements (50,000,000 rows).
-- Run 00_setup.sql and 10_gen_logs.sql of verify/query_patterns first. Long: use the native client.
CREATE TABLE IF NOT EXISTS tune.logs_d AS tune.logs;
INSERT INTO tune.logs_d SELECT * FROM tune.logs
WHERE Timestamp >= '2026-11-23 00:00:00' AND Timestamp < '2026-11-24 00:00:00'
SETTINGS max_insert_threads = 4;
