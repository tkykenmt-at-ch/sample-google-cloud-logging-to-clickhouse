-- Pattern 6: the same aggregations kept up to date at insert time.
CREATE MATERIALIZED VIEW IF NOT EXISTS tune.logs_1m_mv TO tune.logs_1m AS
SELECT toStartOfMinute(Timestamp) AS Timestamp, ServiceName, SeverityText, HttpStatus, count() AS count__ FROM tune.logs GROUP BY ALL;
CREATE MATERIALIZED VIEW IF NOT EXISTS tune.http_1h_mv TO tune.http_1h AS
SELECT toStartOfHour(Timestamp) AS Timestamp, domain(HttpUrl) AS Domain, splitByChar('/', path(HttpUrl))[2] AS Section, multiIf(positionCaseInsensitive(HttpUserAgent, 'gptbot') > 0, 'GPTBot', positionCaseInsensitive(HttpUserAgent, 'chatgpt-user') > 0, 'ChatGPT-User', positionCaseInsensitive(HttpUserAgent, 'claudebot') > 0, 'ClaudeBot', positionCaseInsensitive(HttpUserAgent, 'perplexitybot') > 0, 'PerplexityBot', positionCaseInsensitive(HttpUserAgent, 'googlebot') > 0, 'Googlebot', positionCaseInsensitive(HttpUserAgent, 'bingbot') > 0, 'bingbot', HttpUserAgent = '', '', 'other') AS Bot, HttpStatus, count() AS count__
FROM tune.logs WHERE ServiceName = 'http_load_balancer/web-frontend' GROUP BY ALL;
