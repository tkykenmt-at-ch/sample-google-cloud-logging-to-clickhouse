-- The INSERTs, OPTIMIZEs and MATERIALIZE statements here outlast the ~30 s the Query API waits and keep running on the
-- service. Run one statement at a time and wait until system.processes and system.mutations show it finished.
-- Copy two frequently used attributes out of the Map into columns filled at insert time, then fill the existing rows.
ALTER TABLE tune.attrs_buckets
    ADD COLUMN IF NOT EXISTS HttpRoute LowCardinality(String) MATERIALIZED LogAttributes['http.route'],
    ADD COLUMN IF NOT EXISTS UserId String MATERIALIZED LogAttributes['user_id'];
ALTER TABLE tune.attrs_buckets MATERIALIZE COLUMN HttpRoute;
ALTER TABLE tune.attrs_buckets MATERIALIZE COLUMN UserId;
