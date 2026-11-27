-- Pattern 5: columns computed at insert time, then filled for the rows already in the table.
ALTER TABLE tune.logs ADD COLUMN IF NOT EXISTS Client LowCardinality(String) MATERIALIZED multiIf(HttpUserAgent = '', '', match(HttpUserAgent, '(?i)bot|crawler|spider'), 'crawler', position(HttpUserAgent, 'Edg/') > 0, 'Edge', position(HttpUserAgent, 'Firefox/') > 0, 'Firefox', position(HttpUserAgent, 'Chrome/') > 0, 'Chrome', position(HttpUserAgent, 'Safari/') > 0, 'Safari', 'other'), ADD COLUMN IF NOT EXISTS UrlPath String MATERIALIZED path(HttpUrl), ADD COLUMN IF NOT EXISTS UrlDomain LowCardinality(String) MATERIALIZED domain(HttpUrl);
ALTER TABLE tune.logs MATERIALIZE COLUMN Client;
ALTER TABLE tune.logs MATERIALIZE COLUMN UrlPath;
ALTER TABLE tune.logs MATERIALIZE COLUMN UrlDomain;
