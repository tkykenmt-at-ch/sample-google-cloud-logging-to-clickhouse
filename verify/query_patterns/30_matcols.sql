-- Pattern 5: columns computed at insert time, then filled for the rows already in the table.
ALTER TABLE tune.logs ADD COLUMN IF NOT EXISTS Bot LowCardinality(String) MATERIALIZED multiIf(positionCaseInsensitive(HttpUserAgent, 'gptbot') > 0, 'GPTBot', positionCaseInsensitive(HttpUserAgent, 'chatgpt-user') > 0, 'ChatGPT-User', positionCaseInsensitive(HttpUserAgent, 'claudebot') > 0, 'ClaudeBot', positionCaseInsensitive(HttpUserAgent, 'perplexitybot') > 0, 'PerplexityBot', positionCaseInsensitive(HttpUserAgent, 'googlebot') > 0, 'Googlebot', positionCaseInsensitive(HttpUserAgent, 'bingbot') > 0, 'bingbot', HttpUserAgent = '', '', 'other'), ADD COLUMN IF NOT EXISTS UrlPath String MATERIALIZED path(HttpUrl), ADD COLUMN IF NOT EXISTS UrlDomain LowCardinality(String) MATERIALIZED domain(HttpUrl);
ALTER TABLE tune.logs MATERIALIZE COLUMN Bot;
ALTER TABLE tune.logs MATERIALIZE COLUMN UrlPath;
ALTER TABLE tune.logs MATERIALIZE COLUMN UrlDomain;
