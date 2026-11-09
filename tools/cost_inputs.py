#!/usr/bin/env python3
"""Collect the inputs of the cost estimate (docs/files/cost_estimate.csv) for complete UTC days.

Reads, for each day of the period:
- Google Cloud Monitoring (PromQL API, Application Default Credentials): Pub/Sub publish and delivery bytes
  billed for the topic and every subscription that reads it, and the billable Cloud Logging volume.
- ClickHouse Cloud API (clickhousectl): compute, storage and backup cost per day (usageCost).
- ClickHouse Cloud Prometheus endpoint (API key): ClickPipes replica size and count.
- The service's system tables (clickhousectl service query): stored size per table, CPU time by kind of work,
  hourly CPU and memory use, and text index sizes.

Prints the daily values, then the value for each input cell of the CSV. Anything it cannot read is listed
with the reason; fill that cell by hand. Messages and output are plain text; nothing is written.

Usage:
  python3 tools/cost_inputs.py --project <gcp project> --topic <topic> --service <service id> [--days 7]
Credentials: `gcloud auth application-default login`; clickhousectl's stored credentials or
CLICKHOUSE_CLOUD_API_KEY / CLICKHOUSE_CLOUD_API_SECRET (the key needs to read billing for usageCost).
Run it from a directory without another ./.clickhouse/credentials.json (see tools/chq.py).
"""
import argparse, base64, datetime as dt, json, os, statistics, subprocess, sys, urllib.parse, urllib.request

GIB = 2**30
MONTH_DAYS = 30.42
missing = []


def gcp_token():
    r = subprocess.run(["gcloud", "auth", "application-default", "print-access-token"], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError("no Application Default Credentials (run: gcloud auth application-default login)")
    return r.stdout.strip()


def http_json(url, headers):
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
        return json.load(r)


def promql(project, token, expr, at):
    url = (f"https://monitoring.googleapis.com/v1/projects/{project}/location/global/prometheus/api/v1/query?"
           + urllib.parse.urlencode({"query": expr, "time": at.strftime("%Y-%m-%dT%H:%M:%SZ")}))
    res = http_json(url, {"Authorization": f"Bearer {token}"})["data"]["result"]
    return sum(float(x["value"][1]) for x in res) if res else 0.0


def subscriptions(project, token, topic):
    url = f"https://pubsub.googleapis.com/v1/projects/{project}/topics/{topic}/subscriptions"
    return [s.rsplit("/", 1)[1] for s in http_json(url, {"Authorization": f"Bearer {token}"}).get("subscriptions", [])]


def ch(*cmd):
    r = subprocess.run(["clickhousectl", "cloud", *cmd, "--json"], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError((r.stdout + r.stderr).strip().splitlines()[0])
    return json.loads(r.stdout)


def sql(service, query):
    r = subprocess.run(["clickhousectl", "cloud", "service", "query", "--id", service, "-q",
                        query + "\nFORMAT JSONEachRow"], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError((r.stdout + r.stderr).strip().splitlines()[0])
    return [json.loads(l) for l in r.stdout.splitlines() if l.startswith("{")]


def api_key():
    k, s = os.environ.get("CLICKHOUSE_CLOUD_API_KEY"), os.environ.get("CLICKHOUSE_CLOUD_API_SECRET")
    if not (k and s):
        for path in (".clickhouse/credentials.json", os.path.expanduser("~/.clickhouse/credentials.json")):
            if os.path.exists(path):
                c = json.load(open(path))
                k, s = c.get("api_key"), c.get("api_secret")
                break
    if not (k and s):
        raise RuntimeError("no ClickHouse Cloud API key (set CLICKHOUSE_CLOUD_API_KEY and CLICKHOUSE_CLOUD_API_SECRET)")
    return base64.b64encode(f"{k}:{s}".encode()).decode()


def step(name, fn):
    try:
        return fn()
    except Exception as e:  # report and go on: one missing source should not hide the others
        missing.append(f"{name}: {e}")
        return None


def avg(xs):
    xs = [x for x in xs if x is not None]
    return statistics.mean(xs) if xs else None


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--project", required=True, help="Google Cloud project that holds the topic and the sink")
    p.add_argument("--topic", required=True, help="Pub/Sub topic the sink writes to")
    p.add_argument("--service", default=os.environ.get("CH_SERVICE_ID"), help="ClickHouse Cloud service ID")
    p.add_argument("--org", help="ClickHouse Cloud organization ID (detected when you have one)")
    p.add_argument("--database", default="gcl")
    p.add_argument("--l1", default="gcl_logs_v1")
    p.add_argument("--l0", default="gcl_landing_v1")
    p.add_argument("--days", type=int, default=7, help="complete UTC days ending yesterday (system logs keep about 7)")
    a = p.parse_args()
    if not a.service:
        sys.exit("--service or CH_SERVICE_ID is required")

    today = dt.datetime.now(dt.timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    days = [today - dt.timedelta(days=i) for i in range(a.days, 0, -1)]
    first, last = days[0].date(), days[-1].date()
    print(f"Period: {first} to {last} (UTC, {a.days} days)\n")

    # Google Cloud
    daily = {d.date(): {} for d in days}
    token = step("Google Cloud credentials", gcp_token)
    if token:
        subs = step("subscriptions of the topic", lambda: subscriptions(a.project, token, a.topic)) or []
        sub_re = "|".join(subs)
        for d in days:
            end = d + dt.timedelta(days=1)
            row = daily[d.date()]
            row["pubsub_publish_gib"] = step(f"topic/byte_cost {d.date()}", lambda: promql(
                a.project, token, f'sum(increase(pubsub_googleapis_com:topic_byte_cost{{topic_id="{a.topic}"}}[1d]))', end) / GIB)
            if subs:
                row["pubsub_delivery_gib"] = step(f"subscription/byte_cost {d.date()}", lambda: promql(
                    a.project, token,
                    f'sum(increase(pubsub_googleapis_com:subscription_byte_cost{{subscription_id=~"{sub_re}"}}[1d]))', end) / GIB)
            row["logging_billable_gib"] = step(f"billing/bytes_ingested {d.date()}", lambda: promql(
                a.project, token, "sum(increase(logging_googleapis_com:billing_bytes_ingested[1d]))", end) / GIB)
        print(f"Subscriptions reading {a.topic}: {', '.join(subs) or 'none found'}")

    # ClickHouse Cloud API
    org = a.org
    if not org:
        orgs = step("organization", lambda: ch("org", "list")) or []
        org = orgs[0]["id"] if len(orgs) == 1 else None
        if len(orgs) > 1:
            missing.append("organization: several found, pass --org")
    usage = step("usageCost", lambda: ch("org", "usage", "--org-id", org, "--from-date", str(first), "--to-date", str(last))) if org else None
    svc_name = None
    if usage:
        svc = [c for c in usage["costs"] if c["entityId"] == a.service]
        svc_name = svc[0]["entityName"] if svc else None
        wh = {c["dataWarehouseId"] for c in svc if c.get("dataWarehouseId")}
        for c in usage["costs"]:
            day = dt.date.fromisoformat(c["date"])
            if day not in daily:
                continue
            if c["entityId"] == a.service:
                daily[day]["compute_usd"] = c["metrics"].get("computeCHC", 0.0)
            elif c["entityType"] == "datawarehouse" and c["entityId"] in wh:
                daily[day]["storage_usd"] = c["metrics"].get("storageCHC", 0.0)
                daily[day]["backup_usd"] = c["metrics"].get("backupCHC", 0.0)

    units = None
    if org:
        def pipe_units():
            url = f"https://api.clickhouse.cloud/v1/organizations/{org}/services/{a.service}/prometheus?filtered_metrics=false"
            req = urllib.request.Request(url, headers={"Authorization": f"Basic {api_key()}"})
            text = urllib.request.urlopen(req, timeout=60).read().decode()
            mem = [float(l.rsplit(" ", 1)[1]) for l in text.splitlines() if l.startswith("ClickPipes_Replica_MemoryLimit{")]
            if not mem:
                raise RuntimeError("no ClickPipes_Replica_MemoryLimit series (is a pipe running?)")
            return sum(mem) / GIB / 8, len(mem)  # one ClickPipes compute unit per 8 GiB of replica memory
        units = step("ClickPipes replicas (Prometheus endpoint)", pipe_units)

    # System tables
    s = a.service
    db, l1, l0 = a.database, a.l1, a.l0
    parts = step("system.parts", lambda: sql(s, f"""
        SELECT table, partition AS day, sum(bytes_on_disk) / 1e9 AS on_disk_gb, sum(data_uncompressed_bytes) / 1e9 AS uncompressed_gb
        FROM system.parts WHERE database = '{db}' AND active AND table IN ('{l1}', '{l0}')
          AND toDate(partition) BETWEEN '{first}' AND '{last}'
        GROUP BY table, day""")) or []
    for r in parts:
        day = dt.date.fromisoformat(r["day"])
        key = "l1" if r["table"] == l1 else "l0"
        daily[day][f"{key}_on_disk_gb"] = r["on_disk_gb"]
        if key == "l0":
            daily[day]["l0_uncompressed_gb"] = r["uncompressed_gb"]
    cpu = step("system.query_log and system.part_log", lambda: sql(s, f"""
        SELECT kind, sum(cpu) / 3.6e9 / {a.days} AS cpu_hours_per_day FROM (
            SELECT multiIf(user LIKE 'clickpipe:%' AND query_kind = 'Insert', 'pipe inserts (parsing and MVs included)',
                           query_kind = 'Select', 'queries (SELECT)', 'other statements') AS kind,
                   ProfileEvents['OSCPUVirtualTimeMicroseconds'] AS cpu
            FROM clusterAllReplicas('default', system.query_log)
            WHERE type IN ('QueryFinish', 'ExceptionWhileProcessing') AND event_date BETWEEN '{first}' AND '{last}'
            UNION ALL
            SELECT if(database = '{db}', concat('merges ', table), 'merges of system tables'),
                   ProfileEvents['OSCPUVirtualTimeMicroseconds']
            FROM clusterAllReplicas('default', system.part_log)
            WHERE event_type = 'MergeParts' AND event_date BETWEEN '{first}' AND '{last}')
        GROUP BY kind ORDER BY cpu_hours_per_day DESC""")) or []
    use = step("system.metric_log", lambda: sql(s, f"""
        SELECT count(DISTINCT hostname) AS replicas,
               avg(ProfileEvent_OSCPUVirtualTimeMicroseconds) / 1e6 AS avg_cores,
               quantile(0.99)(ProfileEvent_OSCPUVirtualTimeMicroseconds) / 1e6 AS p99_cores,
               max(CurrentMetric_MemoryTracking) / pow(2, 30) AS max_mem_gib
        FROM clusterAllReplicas('default', system.metric_log)
        WHERE event_date BETWEEN '{first}' AND '{last}'""")) or []
    idx = step("system.data_skipping_indices", lambda: sql(s, f"""
        SELECT name, data_compressed_bytes / 1e9 AS gb,
               (SELECT sum(bytes_on_disk) FROM system.parts WHERE database = '{db}' AND table = '{l1}' AND active) / 1e9 AS table_gb
        FROM system.data_skipping_indices WHERE database = '{db}' AND table = '{l1}' ORDER BY gb DESC""")) or []

    # Daily values
    cols = [("pubsub_publish_gib", "PubSub publish GiB"), ("pubsub_delivery_gib", "PubSub delivery GiB"),
            ("logging_billable_gib", "Logging billable GiB"), ("l1_on_disk_gb", "L1 on disk GB"),
            ("l0_on_disk_gb", "L0 on disk GB"), ("l0_uncompressed_gb", "L0 raw GB"),
            ("compute_usd", "compute USD"), ("storage_usd", "storage USD"), ("backup_usd", "backups USD")]
    print("\nDaily values")
    print("day        " + "".join(f"{h:>22}" for _, h in cols))
    for day, row in daily.items():
        print(f"{day} " + "".join(f"{row[k]:>22.2f}" if row.get(k) is not None else f"{'-':>22}" for k, _ in cols))
    mean = {k: avg([r.get(k) for r in daily.values()]) for k, _ in cols}

    if svc_name:
        print(f"\nService: {svc_name}")
    if cpu:
        total = sum(r["cpu_hours_per_day"] for r in cpu)
        print("\nCPU hours per day, by kind of work (all replicas)")
        for r in cpu:
            print(f"  {r['kind']:<45}{r['cpu_hours_per_day']:>8.2f}  {r['cpu_hours_per_day'] / total:>5.0%}")
    if use:
        u = use[0]
        print(f"\nCPU and memory per replica ({u['replicas']} replicas): average {u['avg_cores']:.2f} cores, "
              f"p99 {u['p99_cores']:.2f} cores, peak memory {u['max_mem_gib']:.1f} GiB")
    if idx:
        print(f"\nIndexes in {l1} (whole table, {idx[0]['table_gb']:.1f} GB on disk): "
              + ", ".join(f"{r['name']} {r['gb']:.1f} GB" for r in idx))
    if units:
        print(f"\nClickPipes: {units[1]} replicas, {units[0]:g} compute units in total")

    # Cells of docs/files/cost_estimate.csv
    def cell(v, fmt="{:.2f}"):
        return fmt.format(v) if v is not None else "(not read; fill by hand)"
    print("\nInputs for docs/files/cost_estimate.csv")
    print(f"  B4  L1 on-disk size per day (GB):                  {cell(mean['l1_on_disk_gb'])}")
    print(f"  B5  L0 on-disk size per day (GB):                  {cell(mean['l0_on_disk_gb'])}")
    print(f"  B6  Bytes read by ClickPipes per day (GB):         {cell(mean['l0_uncompressed_gb'])}  (L0 uncompressed size; may differ slightly from what the pipe reports)")
    print(f"  B7  Pub/Sub publish bytes billed per day (GiB):    {cell(mean['pubsub_publish_gib'])}")
    print(f"  B8  Pub/Sub delivery bytes billed per day (GiB):   {cell(mean['pubsub_delivery_gib'])}")
    print(f"  B9  Billable Cloud Logging volume per month (GiB): {cell(mean['logging_billable_gib'] * MONTH_DAYS if mean['logging_billable_gib'] is not None else None)}  (current; before _Default stops storing)")
    print(f"  B10 Service compute per day (USD):                 {cell(mean['compute_usd'])}")
    print("  B11 Compute to add for search per day (unit-hours): 0 until the representative queries are measured (check 21)")
    print(f"  B12 Current storage per day (USD):                 {cell(mean['storage_usd'], '{:.3f}')}")
    print(f"  B13 Current backups per day (USD):                 {cell(mean['backup_usd'], '{:.3f}')}")
    print(f"  B17 Total ClickPipes replica units:                {cell(units[0] if units else None, '{:g}')}")
    print("  B14-B16, B18-B22: unit prices from the pricing pages (not read by this script)")
    if missing:
        print("\nNot read (fill these by hand):")
        for m in missing:
            print(f"  - {m}")


if __name__ == "__main__":
    main()
