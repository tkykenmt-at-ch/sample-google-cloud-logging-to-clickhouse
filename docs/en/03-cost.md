# Estimating cost

English | [日本語](../ja/03-cost.md)

The monthly cost after moving to ClickHouse: a rough estimate from volume before the PoC, and a figure from your own measurements after it.
Both are compared with keeping the logs in Cloud Logging for the same retention.
The size of the service and of ClickPipes comes from "Estimating size" in [Planning](02-planning.md).

> Prices and limits were checked against the official documentation on 2026-10-05.
> Private Preview features may change in behavior and pricing before general availability (GA).
> The markers "(verified)", "(docs)" and "(PoC)" are explained at the top of [Design](01-design.md).

## What changes in the bill

Cloud Logging ingestion and retention go down; Pub/Sub, ClickPipes and ClickHouse Cloud are added.

| Direction | Item | Proportional to | Price (docs) |
|---|---|---|---|
| Down | Cloud Logging ingestion | Logs no longer stored in `_Default` | $0.50/GiB, including the first 30 days of storage ([pricing](https://cloud.google.com/stackdriver/pricing)) |
| Down | Cloud Logging retention beyond 30 days | Volume kept and how long | $0.01/GiB-month (same) |
| Up | Pub/Sub publish | Bytes the sink exports | $40/TiB ([pricing](https://cloud.google.com/pubsub/pricing)) |
| Up | Pub/Sub delivery | Bytes the sink exports × number of subscriptions | $40/TiB (same) |
| Up | ClickPipes | Bytes read, and replica size × count × hours | Other streaming ClickPipes charge $0.04/GB plus a price per unit-hour ([pricing](https://clickhouse.com/docs/products/cloud/reference/billing/clickpipes/clickpipes-for-streaming-and-object-storage)). Pub/Sub is in Private Preview; ask ClickHouse for its pricing |
| Up | ClickHouse Cloud compute | Service size × hours | Per plan and region ([pricing](https://clickhouse.com/pricing)) |
| Up | ClickHouse Cloud storage and backups | Size on disk (compressed, indexes included) | Same |

- Free tiers: Cloud Logging gives 50 GiB per project per month, Pub/Sub 10 GiB per billing account per month.
- Cloud Logging costs drop only when you stop storing logs in the `_Default` bucket ("Key points" in [Design](01-design.md)).

## A rough estimate before the PoC

Before anything flows into ClickHouse, start from the billable Cloud Logging volume and fill the template (below, in "Estimating cost from PoC measurements") as follows.

1. **Billable Cloud Logging volume per month**: the usage of the "Log Storage cost" SKU in the billing report filtered to Cloud Logging. Put it in B9.
2. **Pub/Sub and ClickPipes volume**: the JSON the sink exports is larger than the billable volume. In our tests it was about 1.2 times for the log types Cloud Logging bills ("Bytes that drive Pub/Sub cost" in [Findings](09-findings.md)). Put the daily billable volume × 1.2 in B6 (GB) and in B7 and B8 (GiB). Add the logs routed to `_Required` if the sink exports them too.
3. **Stored size**: assume a compression ratio and put the daily volume ÷ that ratio in B4 and B5. The ClickHouse Cloud pricing calculator assumes 10:1. Measure the real ratio, and the text index on top of it, in the PoC.
4. **Compute and replicas**: from the size chosen in "Estimating size" in [Planning](02-planning.md), work out the compute cost per day and put it in B10. Put the ClickPipes replica units in B17.

A rough estimate can be far off depending on the log mix. Replace it with measurements once the parallel run starts.

## Estimating cost from PoC measurements

Once production volume is flowing, estimate the monthly cost from what you measure in your own environment: collect the inputs, fill the template, read the result.

### 1. Collect the inputs

`tools/cost_inputs.py` reads what the estimate needs from Cloud Monitoring, the ClickHouse Cloud API and the service's system tables, and prints which cell of the template each value goes in.

```bash
gcloud auth application-default login        # reads Cloud Monitoring and Pub/Sub
export CLICKHOUSE_CLOUD_API_KEY=<key id>      # or the API key stored by clickhousectl
export CLICKHOUSE_CLOUD_API_SECRET=<key secret>
python3 tools/cost_inputs.py --project <project> --topic <topic> --service <service id> --days 7
```

- The period is complete UTC days up to yesterday. Use one week with weekdays and weekends: log volume varies by day of the week, and a few days are biased.
- ClickHouse Cloud keeps the system logs (`query_log`, `part_log`, `metric_log`) about 7 days (verified). Run the script right after the week you use as the baseline.
- Do not use a period in which ingestion fell behind or caught up.
- Anything the script could not read is listed at the end with the reason. Get those values as described in "By hand" below.

**Permissions**

| Source | Permission |
|---|---|
| Cloud Monitoring, list of Pub/Sub subscriptions | Monitoring Viewer (`roles/monitoring.viewer`) and Pub/Sub Viewer (`roles/pubsub.viewer`) on the project |
| ClickHouse Cloud usage (usageCost) | An API key that can read the organization's billing |
| ClickHouse Cloud Prometheus endpoint | An API key that can read the service |
| System tables | Queries on the service (`clickhousectl cloud service query`) |

**Inputs**

| Cell | Value | What the script reads | By hand |
|---|---|---|---|
| B4, B5 | On-disk size per day of L1 and L0 (GB) | `bytes_on_disk` in `system.parts`, per daily partition | Average `on_disk_gb` from check 17 in `verify/checks.sql` |
| B6 | Bytes read by ClickPipes (GB/day) | Uncompressed size of L0 (`data_uncompressed_bytes` in `system.parts`); may differ slightly from what the pipe reports | The pipe's Metrics tab, or the daily increase of `ClickPipes_FetchedBytes_Total` from the Prometheus endpoint |
| B7 | Pub/Sub publish bytes billed (GiB/day) | Cloud Monitoring `pubsub.googleapis.com/topic/byte_cost` (PromQL API) | The same metric in Metrics Explorer, filtered to the topic and summed per day |
| B8 | Pub/Sub delivery bytes billed (GiB/day) | `pubsub.googleapis.com/subscription/byte_cost`, summed over every subscription that reads the topic | Same. After a month of parallel running, compare with the "Message Delivery Basic" SKU on the bill |
| B9 | Billable Cloud Logging volume (GiB/month) | `logging.googleapis.com/billing/bytes_ingested` (whole project) | Usage of the "Log Storage cost" SKU in the billing report |
| B10, B12, B13 | Service compute, storage, backups (USD/day, list price of the current plan) | ClickHouse Cloud usage API (`clickhousectl cloud org usage`) | Console → Settings → Usage breakdown ([tracking spending](https://clickhouse.com/docs/products/cloud/reference/billing/billing-overview#how-can-i-keep-track-of-my-spending)) |
| B17 | Total ClickPipes replica units | `ClickPipes_Replica_MemoryLimit` from the Prometheus endpoint (one unit per 8 GiB) | Size and count under the pipe's Settings → Advanced Settings → Scaling |

The daily values from the Cloud Monitoring PromQL API matched daily sums from the Monitoring v3 API (verified).
In our tests, delivery bytes billed were about 1.6 times the publish bytes, because acks and ack deadline extensions are counted too.

### 2. Fill the template

The template is [cost_estimate.en.csv](../files/cost_estimate.en.csv) (Japanese: [cost_estimate.csv](../files/cost_estimate.csv)). In Google Sheets, File → Import keeps the formulas working.

- Put the script's values in B4–B13 and B17.
- Take each price (B14–B16, B18–B22) from its pricing page with your cloud, region and plan selected. B14 is the compute price of the current plan, B15 that of the plan you will use in production.
- Leave B11 (compute to add for search) at 0 until the representative queries are measured ("Where the compute goes" below).

### 3. Read the result

| Row | Meaning |
|---|---|
| B31 | Monthly cost after moving to ClickHouse, once logs for the full retention have accumulated |
| B32 | Monthly cost of keeping the logs in Cloud Logging for the same retention |
| B33 | Difference |
| B34 | Average monthly cost in the first year, starting empty. Storage and backups grow until the full retention has accumulated, so with 400 days the first year is a little under half of the steady state |

- Compute (B26) covers what ran during the period. If search will be heavier than during the PoC, add it in B11.
- During the migration you also pay for keeping logs in both Cloud Logging and ClickHouse.
- Compare with Cloud Logging on the same billable volume.

## Where the compute goes

The service size depends on where the CPU goes: ingestion, merges or queries. Check with these numbers in `verify/checks.sql` (`python3 tools/chq.py verify/checks.sql`).

| Check | Shows | How to use it |
|---|---|---|
| 18 | CPU hours per day split into pipe inserts, queries and merges per table | If ingestion and merges dominate, there may be room to reduce them ("Part counts" in [Troubleshooting](08-troubleshooting.md), and the pipe's insert wait time in "Decisions for your environment" in [Planning](02-planning.md)) |
| 19 | CPU and memory per replica, hourly average and p99 | The larger the gap between average and p99, the more the size follows the peaks |
| 20 | Size of each index in L1 | How much of the storage the full-text index on the body takes |
| 21 | CPU seconds and bytes read per run of each representative query | Run each with `SETTINGS log_comment = 'rep:<name>'`. Put CPU seconds × runs per day ÷ 3,600 ÷ 2 in B11 (one unit is 2 vCPU) |

## Worked example

Made-up volumes, built up in the order of the template. The prices are placeholders, not actual prices.

| Input | Value |
|---|---|
| On-disk size of L1 / L0 (B4, B5) | 70 GB/day, 70 GB/day |
| Bytes read by ClickPipes (B6) | 1,000 GB/day |
| Pub/Sub publish and delivery (B7, B8) | 931.3 GiB/day each |
| Billable Cloud Logging volume (B9) | 25,000 GiB/month |
| Compute, storage, backups (B10, B12, B13) | $20.0/day, $1.0/day, $1.2/day |
| Compute price (B14 current, B15 production), storage price (B16) | $0.30, $0.40 per unit-hour, $25 per TB-month |
| ClickPipes units (B17) | 1 |

| Item | Formula | Monthly |
|---|---|---|
| Compute | $20.0 × 0.40 ÷ 0.30 × 30.42 | $811 |
| Storage | (70 × 400 + 70 × 7) ÷ 1,000 = 28.49 TB × $25 | $712 |
| Backups | $1.2 ÷ $1.0 × $712 | $855 |
| ClickPipes | 1 × $0.20 × 24 × 30.42 + 1,000 × 30.42 × $0.04 | $1,363 |
| Pub/Sub | (931.3 + 931.3) × 30.42 ÷ 1,024 × $40 | $2,213 |
| **Total after moving to ClickHouse** | | **$5,954** |
| Keeping the logs in Cloud Logging | 25,000 × $0.50 + 25,000 × (400 − 30) ÷ 30.42 × $0.01 | $15,541 |
| Difference | | $9,587 |
| Total after moving to ClickHouse (first-year average) | Storage and backups at 0.47 of the steady state | $5,117 |

## Points to watch

- Pub/Sub charges apply to logs Cloud Logging does not bill. Logs routed to `_Required` (Admin Activity audit logs and others) are free in Cloud Logging, but cost Pub/Sub when a sink exports them. For high-volume ones, consider "Noise rules" in [Operations](07-operations.md).
- On delivery, acks and ack deadline extensions were counted in `byte_cost` too. The pricing page lists publish and delivery as billable; check the bill to see whether acks and extensions are charged. (PoC)
- A stopped pipe's managed subscription keeps accumulating messages, and messages older than one day incur storage charges ([storage costs](https://cloud.google.com/pubsub/pricing#storage_costs)). Delete pipes you no longer use.
