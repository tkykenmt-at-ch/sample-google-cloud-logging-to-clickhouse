-- The INSERTs, OPTIMIZEs and MATERIALIZE statements here outlast the ~30 s the Query API waits and keep running on the
-- service. Run one statement at a time and wait until system.processes and system.mutations show it finished.
-- Indexes added afterwards to the one-day copy, then built for the rows already there (mutations, run in the background).
ALTER TABLE tune.logs_d ADD INDEX IF NOT EXISTS idx_insert_bf InsertId TYPE bloom_filter(0.01) GRANULARITY 1;
ALTER TABLE tune.logs_d ADD INDEX IF NOT EXISTS idx_sev_set SeverityText TYPE set(10) GRANULARITY 1;
ALTER TABLE tune.logs_d ADD PROJECTION IF NOT EXISTS p_insert (SELECT _part_offset ORDER BY InsertId);
ALTER TABLE tune.logs_d MATERIALIZE INDEX idx_insert_bf;
ALTER TABLE tune.logs_d MATERIALIZE INDEX idx_sev_set;
ALTER TABLE tune.logs_d MATERIALIZE PROJECTION p_insert;
