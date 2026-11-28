-- The INSERTs, OPTIMIZEs and MATERIALIZE statements here outlast the ~30 s the Query API waits and keep running on the
-- service. Run one statement at a time and wait until system.processes and system.mutations show it finished.
-- Synthetic application logs whose attributes live in a Map, in two copies that differ only in how the Map
-- is stored: 'basic' (one stream for all keys) and 'with_buckets' (keys hashed into buckets).
-- 20,000,000 rows on 2026-11-23 (UTC), 12 attribute keys per row.
CREATE TABLE IF NOT EXISTS tune.attrs_basic
(
    Timestamp DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    ServiceName LowCardinality(String) CODEC(ZSTD(1)),
    SeverityText LowCardinality(String) CODEC(ZSTD(1)),
    Body String CODEC(ZSTD(1)),
    LogAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1))
)
ENGINE = MergeTree
PARTITION BY toDate(Timestamp)
ORDER BY (toStartOfFiveMinutes(Timestamp), ServiceName, Timestamp)
SETTINGS map_serialization_version = 'basic';

CREATE TABLE IF NOT EXISTS tune.attrs_buckets AS tune.attrs_basic
SETTINGS map_serialization_version = 'with_buckets', map_serialization_version_for_zero_level_parts = 'with_buckets';

INSERT INTO tune.attrs_basic
SELECT
    fromUnixTimestamp64Nano(toInt64(1795392000000000000 + number * 4320000)) AS ts,
    concat('k8s_container/app-', ['a','b','c','d','e'][1 + cityHash64(number, 2) % 5]) AS svc,
    if(cityHash64(number, 3) % 100 < 2, 'ERROR', 'INFO') AS sev,
    concat('handled request elapsed_ms=', toString(cityHash64(number, 6) % 3000)) AS body,
    map('k8s-pod/app', svc,
        'k8s-pod/pod-template-hash', hex(cityHash64(number % 40, 30)),
        'compute.googleapis.com/resource_name', concat('node-', toString(cityHash64(number, 31) % 60)),
        'http.route', ['/api/v1/items', '/api/v1/cart', '/api/v1/search', '/api/v1/stores', '/api/v1/orders', '/healthz'][1 + cityHash64(number, 32) % 6],
        'http.status_code', toString([200, 200, 200, 200, 304, 404, 500][1 + cityHash64(number, 33) % 7]),
        'user_id', toString(cityHash64(number, 7) % 300000),
        'request_id', hex(cityHash64(number, 4)),
        'session_id', hex(cityHash64(number, 34) % 2000000),
        'client.version', concat('5.', toString(cityHash64(number, 35) % 20)),
        'feature_flags', concat('ff_', toString(cityHash64(number, 36) % 8), ',ff_', toString(cityHash64(number, 37) % 8)),
        'region', ['tokyo', 'osaka', 'nagoya', 'fukuoka'][1 + cityHash64(number, 38) % 4],
        'elapsed_ms', toString(cityHash64(number, 6) % 3000)) AS attrs
FROM numbers(20000000)
SETTINGS max_insert_threads = 4;

INSERT INTO tune.attrs_buckets SELECT * FROM tune.attrs_basic SETTINGS max_insert_threads = 4;

-- Merge each table into one part so that both are measured in their merged form.
OPTIMIZE TABLE tune.attrs_basic FINAL;
OPTIMIZE TABLE tune.attrs_buckets FINAL;
