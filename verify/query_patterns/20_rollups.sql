-- Aggregate tables for patterns 4 and 6, filled from tune.logs one day at a time ({{D}} = YYYY-MM-DD).
CREATE TABLE IF NOT EXISTS tune.logs_1m
(
    Timestamp    DateTime,
    ServiceName  LowCardinality(String),
    SeverityText LowCardinality(String),
    HttpStatus   UInt16,
    count__      SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(Timestamp)
ORDER BY (Timestamp, ServiceName, SeverityText, HttpStatus);

CREATE TABLE IF NOT EXISTS tune.http_1h
(
    Timestamp   DateTime,
    Domain      LowCardinality(String),
    Section     LowCardinality(String),
    Client      LowCardinality(String),
    HttpStatus  UInt16,
    count__     SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(Timestamp)
ORDER BY (Timestamp, Domain, Section, Client, HttpStatus);

INSERT INTO tune.logs_1m SELECT toStartOfMinute(Timestamp), ServiceName, SeverityText, HttpStatus, count() FROM tune.logs WHERE toDate(Timestamp) = '{{D}}' GROUP BY ALL;
INSERT INTO tune.http_1h SELECT toStartOfHour(Timestamp), domain(HttpUrl), splitByChar('/', path(HttpUrl))[2], multiIf(HttpUserAgent = '', '', match(HttpUserAgent, '(?i)bot|crawler|spider'), 'crawler', position(HttpUserAgent, 'Edg/') > 0, 'Edge', position(HttpUserAgent, 'Firefox/') > 0, 'Firefox', position(HttpUserAgent, 'Chrome/') > 0, 'Chrome', position(HttpUserAgent, 'Safari/') > 0, 'Safari', 'other'), HttpStatus, count() FROM tune.logs WHERE toDate(Timestamp) = '{{D}}' AND ServiceName = 'http_load_balancer/web-frontend' GROUP BY ALL;
