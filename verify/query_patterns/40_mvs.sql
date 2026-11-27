-- Pattern 6: the same aggregations kept up to date at insert time.
CREATE MATERIALIZED VIEW IF NOT EXISTS tune.logs_1m_mv TO tune.logs_1m AS
SELECT toStartOfMinute(Timestamp) AS Timestamp, ServiceName, SeverityText, HttpStatus, count() AS count__ FROM tune.logs GROUP BY ALL;
CREATE MATERIALIZED VIEW IF NOT EXISTS tune.http_1h_mv TO tune.http_1h AS
SELECT toStartOfHour(Timestamp) AS Timestamp, domain(HttpUrl) AS Domain, splitByChar('/', path(HttpUrl))[2] AS Section, multiIf(HttpUserAgent = '', '', match(HttpUserAgent, '(?i)bot|crawler|spider'), 'crawler', position(HttpUserAgent, 'Edg/') > 0, 'Edge', position(HttpUserAgent, 'Firefox/') > 0, 'Firefox', position(HttpUserAgent, 'Chrome/') > 0, 'Chrome', position(HttpUserAgent, 'Safari/') > 0, 'Safari', 'other') AS Client, HttpStatus, count() AS count__
FROM tune.logs WHERE ServiceName = 'http_load_balancer/web-frontend' GROUP BY ALL;
