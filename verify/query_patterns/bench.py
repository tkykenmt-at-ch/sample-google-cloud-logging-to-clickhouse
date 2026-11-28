#!/usr/bin/env python3
"""Run each benchmark query 3 times on the test service and print timings from system.query_log.

Usage: bench.py --service <id> [CASE_PREFIX ...]   (no prefix = all cases)
Run from the directory where `clickhousectl` finds its credentials.
Every run carries SETTINGS log_comment='qp:<case>:<run>', use_query_condition_cache=0.
"""
import json, os, subprocess, sys, time

CHQ = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "chq.py")
CLIENT = open(os.path.join(os.path.dirname(__file__), "client_expr.sql")).read().strip()

D1 = "Timestamp >= '2026-11-23 00:00:00' AND Timestamp < '2026-11-24 00:00:00' AND toStartOfFiveMinutes(Timestamp) >= '2026-11-23 00:00:00' AND toStartOfFiveMinutes(Timestamp) < '2026-11-24 00:00:00'"
D3 = "Timestamp >= '2026-11-22 00:00:00' AND Timestamp < '2026-11-25 00:00:00' AND toStartOfFiveMinutes(Timestamp) >= '2026-11-22 00:00:00' AND toStartOfFiveMinutes(Timestamp) < '2026-11-25 00:00:00'"
APP = "ServiceName = 'k8s_container/app-a'"
LOOKUP_ID = "7AFA42487929F0A1"   # an InsertId of the 2026-11-23 rows
LB = "ServiceName = 'http_load_balancer/web-frontend'"

CASES = {
    # 1. Full-text search on Body
    "p1a_like":        f"SELECT count() FROM tune.logs WHERE {D1} AND {APP} AND Body LIKE '%タイムアウト%'",
    "p1a_lowerlike":   f"SELECT count() FROM tune.logs WHERE {D1} AND {APP} AND lower(Body) LIKE '%タイムアウト%'",
    "p1a_token":       f"SELECT count() FROM tune.logs WHERE {D1} AND {APP} AND hasAllTokens(lower(Body), lower('タイムアウト'))",
    "p1b_like_all":    f"SELECT count() FROM tune.logs WHERE {D1} AND Body ILIKE '%timeout%'",
    "p1b_token_all":   f"SELECT count() FROM tune.logs WHERE {D1} AND hasAllTokens(lower(Body), 'timeout')",
    "p1d_token_like":  f"SELECT count() FROM tune.logs WHERE {D1} AND hasAllTokens(lower(Body), 'timeout') AND Body ILIKE '%timeout%'",
    "p1e_fp_token":    f"SELECT count() FROM tune.logs WHERE {D1} AND hasAllTokens(lower(Body), 'request timeout')",
    "p1e_fp_like":     f"SELECT count() FROM tune.logs WHERE {D1} AND Body ILIKE '%request timeout%'",
    "p1c_combined":    f"SELECT countIf(Body LIKE '%タイムアウト%') AS err, count() AS total FROM tune.logs WHERE {D1} AND {APP}",
    "p1c_split_total": f"SELECT count() FROM tune.logs WHERE {D1} AND {APP}",
    # 2. Filter on the ORDER BY key (ServiceName)
    "p2_noservice":    f"SELECT toStartOfHour(Timestamp) h, count() FROM tune.logs WHERE {D1} AND HttpUrl LIKE '%/search/%' GROUP BY h ORDER BY h",
    "p2_service":      f"SELECT toStartOfHour(Timestamp) h, count() FROM tune.logs WHERE {D1} AND {LB} AND HttpUrl LIKE '%/search/%' GROUP BY h ORDER BY h",
    # 3. Chart-style counts over 3 days
    "p3_countif":      f"SELECT toStartOfHour(Timestamp) h, countIf(SeverityText = 'ERROR') FROM tune.logs WHERE {D3} GROUP BY h ORDER BY h",
    "p3_where":        f"SELECT toStartOfHour(Timestamp) h, count() FROM tune.logs WHERE {D3} AND SeverityText = 'ERROR' GROUP BY h ORDER BY h",
    "p3_rollup":       "SELECT toStartOfHour(Timestamp) h, sum(count__) FROM tune.logs_1m WHERE Timestamp >= '2026-11-22 00:00:00' AND Timestamp < '2026-11-25 00:00:00' AND SeverityText = 'ERROR' GROUP BY h ORDER BY h",
    # 4. Client-type and page analysis on the load balancer logs (1 day)
    "p4_raw":          f"SELECT {CLIENT} AS client, path(HttpUrl) AS page, count() n, countIf(HttpStatus = 200) ok FROM tune.logs WHERE {D1} AND {LB} GROUP BY client, page ORDER BY n DESC LIMIT 20",
    "p4_matcol":       f"SELECT Client AS client, UrlPath AS page, count() n, countIf(HttpStatus = 200) ok FROM tune.logs WHERE {D1} AND {LB} GROUP BY client, page ORDER BY n DESC LIMIT 20",
    "p4s_raw":         f"SELECT {CLIENT} AS client, splitByChar('/', path(HttpUrl))[2] AS section, count() n FROM tune.logs WHERE {D1} AND {LB} GROUP BY client, section ORDER BY client, section",
    "p4s_rollup":      "SELECT Client AS client, Section AS section, sum(count__) n FROM tune.http_1h WHERE Timestamp >= '2026-11-23 00:00:00' AND Timestamp < '2026-11-24 00:00:00' GROUP BY client, section ORDER BY client, section",
    # 7. Latest N rows: ORDER BY that matches the sorting key reads in order
    "t1_ts_desc":      f"SELECT Timestamp, SeverityText, Body FROM tune.logs WHERE {D1} AND {APP} ORDER BY Timestamp DESC LIMIT 200",
    "t1_key_desc":     f"SELECT Timestamp, SeverityText, Body FROM tune.logs WHERE {D1} AND {APP} ORDER BY toStartOfFiveMinutes(Timestamp) DESC, Timestamp DESC LIMIT 200",
    "t1_tuple_desc":   f"SELECT Timestamp, SeverityText, Body FROM tune.logs WHERE {D1} AND {APP} ORDER BY (toStartOfFiveMinutes(Timestamp), Timestamp) DESC LIMIT 200",
    "t1_star_ts":      f"SELECT * FROM tune.logs WHERE {D1} AND {APP} ORDER BY Timestamp DESC LIMIT 200",
    "t1_star_key":     f"SELECT * FROM tune.logs WHERE {D1} AND {APP} ORDER BY toStartOfFiveMinutes(Timestamp) DESC, Timestamp DESC LIMIT 200",
    "t1_word_ts":      f"SELECT Timestamp, Body FROM tune.logs WHERE {D3} AND hasAllTokens(lower(Body), 'timeout') ORDER BY Timestamp DESC LIMIT 200",
    "t1_word_key":     f"SELECT Timestamp, Body FROM tune.logs WHERE {D3} AND hasAllTokens(lower(Body), 'timeout') ORDER BY toStartOfFiveMinutes(Timestamp) DESC, Timestamp DESC LIMIT 200",
    # 8. Point lookups and skip indexes on the one-day copy (verify/advanced_tuning/10_copy_day.sql, 30_indexes.sql)
    "t2_id_none":      f"SELECT Timestamp, Body FROM tune.logs_d WHERE InsertId = '{LOOKUP_ID}' SETTINGS ignore_data_skipping_indices = 'idx_insert_bf', optimize_use_projections = 0",
    "t2_id_bloom":     f"SELECT Timestamp, Body FROM tune.logs_d WHERE InsertId = '{LOOKUP_ID}' SETTINGS optimize_use_projections = 0",
    "t2_id_proj":      f"SELECT Timestamp, Body FROM tune.logs_d WHERE InsertId = '{LOOKUP_ID}' SETTINGS ignore_data_skipping_indices = 'idx_insert_bf'",
    "t2_sev_none":     "SELECT count() FROM tune.logs_d WHERE SeverityText = 'ERROR' SETTINGS ignore_data_skipping_indices = 'idx_sev_set'",
    "t2_sev_set":      "SELECT count() FROM tune.logs_d WHERE SeverityText = 'ERROR'",
    # 9. Map attributes versus a column filled at insert time (verify/advanced_tuning/20_attrs.sql, 40_attr_column.sql)
    "t3_map_basic":    "SELECT LogAttributes['http.route'] AS r, count() FROM tune.attrs_basic GROUP BY r ORDER BY r",
    "t3_map_buckets":  "SELECT LogAttributes['http.route'] AS r, count() FROM tune.attrs_buckets GROUP BY r ORDER BY r",
    "t3_column":       "SELECT HttpRoute AS r, count() FROM tune.attrs_buckets GROUP BY r ORDER BY r",
    "t3_filter_basic": "SELECT count() FROM tune.attrs_basic WHERE LogAttributes['user_id'] = '12345'",
    "t3_filter_buckets": "SELECT count() FROM tune.attrs_buckets WHERE LogAttributes['user_id'] = '12345'",
    "t3_filter_column": "SELECT count() FROM tune.attrs_buckets WHERE UserId = '12345'",
}


def q(sql):
    out = subprocess.run(["python3", CHQ, "--service", SVC, "-q", sql], capture_output=True, text=True)
    return "\n".join(l for l in out.stdout.splitlines() if not l.startswith("-- ")) + out.stderr


def main():
    global SVC
    args = sys.argv[1:]
    if len(args) < 2 or args[0] != "--service":
        sys.exit(__doc__)
    SVC, pref = args[1], args[2:]
    cases = {k: v for k, v in CASES.items() if not pref or any(k.startswith(p) for p in pref)}
    tag = time.strftime("%H%M%S")
    first = {}
    for run in (1, 2, 3):
        for k, sql in cases.items():
            extra = f"log_comment = 'qp:{tag}:{k}:{run}', use_query_condition_cache = 0"
            r = q(f"{sql}, {extra}" if " SETTINGS " in sql else f"{sql} SETTINGS {extra}")
            if run == 1:
                first[k] = r.strip().splitlines()[1:3]
    time.sleep(10)
    stats = q(f"""SELECT splitByChar(':', log_comment)[3] k, groupArray(round(query_duration_ms / 1000, 2)) s,
        any(read_rows) rr, formatReadableSize(any(read_bytes)) rb, any(exception_code) ec
        FROM clusterAllReplicas('default', system.query_log)
        WHERE event_time > now() - INTERVAL 1 HOUR AND type IN ('QueryFinish', 'ExceptionWhileProcessing') AND log_comment LIKE 'qp:{tag}:%'
        GROUP BY k ORDER BY k FORMAT TSV""")
    print(stats)
    for k, v in first.items():
        print(k, "|", " / ".join(v)[:160])


if __name__ == "__main__":
    main()
