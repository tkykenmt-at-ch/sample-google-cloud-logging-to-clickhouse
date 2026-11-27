-- Synthetic logs for the query-pattern measurements: 150,000,000 rows over 2026-11-22..24 (UTC), 70% load
-- balancer requests and 30% application logs. Run in chunks so each statement stays short, for example
--   for off in $(seq -f %.0f 0 5000000 145000000); do
--     python3 tools/chq.py --service <id> --var OFF=$off --var N=5000000 verify/query_patterns/10_gen_logs.sql; done
-- Row i is placed at 2026-11-22 00:00 UTC + i * 1.728 ms, so OFF/N choose the time window.
INSERT INTO tune.logs (Timestamp, ReceiveTimestamp, ServiceName, ResourceType, ProjectId, LogId, LogName, SeverityText, SeverityNumber, Body,
  HttpMethod, HttpStatus, HttpUrl, HttpUserAgent, HttpLatencySeconds, InsertId, ParseOk)
SELECT ts, ts, svc, rt, 'sample-project', lid, concat('projects/sample-project/logs/', lid), sev, sevn, body, meth, st, url, ua, lat, ins, true
FROM (
  SELECT {{OFF}} + number AS i,
    fromUnixTimestamp64Nano(toInt64(1795305600000000000 + i * 1728000)) AS ts,
    cityHash64(i, 1) % 100 AS r,
    r < 70 AS lb,
    if(lb, 'http_load_balancer/web-frontend', concat('k8s_container/app-', ['a','b','c','d','e'][1 + cityHash64(i, 2) % 5])) AS svc,
    if(lb, 'http_load_balancer', 'k8s_container') AS rt,
    if(lb, 'requests', 'stdout') AS lid,
    cityHash64(i, 3) % 1000 AS e,
    if(lb, if(e < 3, 'ERROR', 'INFO'), multiIf(e < 5, 'ERROR', e < 40, 'WARNING', 'INFO')) AS sev,
    multiIf(sev = 'ERROR', 17, sev = 'WARNING', 13, 9) AS sevn,
    if(lb, '', multiIf(e < 2, concat('外部 API の呼び出しでタイムアウトが発生しました request_id=', hex(cityHash64(i, 4))),
                       e < 5, concat('upstream request timeout after 30s request_id=', hex(cityHash64(i, 4))),
                       e < 40, concat('在庫の取得に時間がかかっています item=', toString(cityHash64(i, 5) % 50000), ' elapsed_ms=', toString(800 + cityHash64(i, 6) % 4000)),
                       concat('GET /api/v1/items/', toString(cityHash64(i, 5) % 50000), ' 200 user=', toString(cityHash64(i, 7) % 300000), ' elapsed_ms=', toString(cityHash64(i, 6) % 300)))) AS body,
    if(lb, if(cityHash64(i, 8) % 20 = 0, 'POST', 'GET'), '') AS meth,
    if(lb, multiIf(e < 3, 503, e < 30, 404, e < 120, 304, 200), 0) AS st,
    cityHash64(i, 9) % 100 AS b,
    if(lb, concat('https://', ['www.example.com', 'shop.example.com', 'api.example.com'][1 + cityHash64(i, 10) % 3], '/',
                  ['products', 'category', 'search', 'store', 'article', 'cart'][1 + cityHash64(i, 11) % 6], '/', toString(cityHash64(i, 12) % 20000),
                  multiIf(cityHash64(i, 13) % 10 = 0, concat('?page=', toString(1 + cityHash64(i, 14) % 20)), cityHash64(i, 13) % 10 = 1, concat('?q=', toString(cityHash64(i, 14) % 999)), '')), '') AS url,
    if(lb, multiIf(b < 6, 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
                   b < 8, 'Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)',
                   b < 10, concat('Mozilla/5.0 (compatible; ExampleCrawler/', toString(1 + cityHash64(i, 21) % 3), '.0; +https://crawler.example.com)'),
                   concat('Mozilla/5.0 (', ['Windows NT 10.0; Win64; x64', 'Macintosh; Intel Mac OS X 10_15_7', 'iPhone; CPU iPhone OS 18_1 like Mac OS X', 'Linux; Android 15; Pixel 9'][1 + cityHash64(i, 15) % 4], ') ',
                          [concat('AppleWebKit/537.36 (KHTML, like Gecko) Chrome/', toString(120 + cityHash64(i, 16) % 20), '.0.', toString(6000 + cityHash64(i, 17) % 400), '.', toString(cityHash64(i, 18) % 200), ' Safari/537.36'),
                           concat('AppleWebKit/605.1.15 (KHTML, like Gecko) Version/', toString(16 + cityHash64(i, 16) % 3), '.', toString(cityHash64(i, 17) % 6), ' Safari/605.1.15'),
                           concat('Gecko/20100101 Firefox/', toString(120 + cityHash64(i, 16) % 15), '.0'),
                           concat('AppleWebKit/537.36 (KHTML, like Gecko) Chrome/', toString(120 + cityHash64(i, 16) % 20), '.0.0.0 Safari/537.36 Edg/', toString(120 + cityHash64(i, 16) % 20), '.0.', toString(2000 + cityHash64(i, 17) % 400), '.', toString(cityHash64(i, 18) % 100))][1 + cityHash64(i, 22) % 4])), '') AS ua,
    if(lb, (cityHash64(i, 19) % 2000) / 1000.0, 0) AS lat,
    hex(cityHash64(i, 20)) AS ins
  FROM numbers({{N}})
)
SETTINGS max_insert_threads = 4;
