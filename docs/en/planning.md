# Planning

English | [日本語](../ja/planning.md)

What to decide for your environment, and how to estimate size and cost, before deployment and before and after the PoC.
The configuration and the reasons behind it are in [Design](design.md); deployment is in [Setup](setup.md).

> Prices and limits were checked against the official documentation on 2026-10-05.
> Private Preview features may change in behavior and pricing before general availability (GA).
> The markers "(verified)", "(docs)" and "(PoC)" are explained at the top of [Design](design.md).

## Decisions for your environment

| Setting | Value in this sample | How to decide |
|---|---|---|
| Sink scope | All logs of the project | An aggregated sink for multiple projects |
| Topic message retention | None | Enable briefly only when a pipe swap must seek back |
| Topic storage region | Not restricted (Terraform default) | Pin it to the region of the ClickHouse Cloud service (`topic_storage_regions`); crossing regions adds delivery egress charges |
| ClickPipes replicas | One (smallest size) | From the ingest rate in "Estimating size"; confirm there is no backlog during the parallel run |
| ClickPipes insert wait | 5 s (`streaming_max_insert_wait_ms` default) | In testing the pipe inserted 212 rows on average every 7.7 s, creating a part in four tables per insert. With little volume and too many parts, raise it (logs then take longer to appear; effect not tested) |
| L0 retention | 7 days | Ingest delay + switch and backfill + reconciliation and rollback, plus margin |
| L1 retention | 400 days | Retention requirements per log kind and privacy rules |
| Body full-text index | `ngrams(2)` | `splitByNonAlpha` if there are no Japanese logs |
| Attribute Map serialization | `with_buckets` for merged parts, default split threshold (32 keys on average) | Measure the average keys per row; lower the threshold only if it is well above 32 and single-key filters are common |
| L2 (typed tables) | None | Only for requirements that match "When to build an L2" in [Design](design.md) |
| L3 (aggregates) | Per-minute counts from L1 | Whether you need long-range trends or long-lived aggregates |
| Aggregate table partitions | Daily (`sql/40`, `sql/50`) | The aggregate tables are small (490 KB for 13 days in testing); monthly (`toYYYYMM`) means fewer partitions and parts, but expiry then drops whole months, so retention can run up to a month longer |
| Numeric and IP types | `HttpLatencySeconds` Float64, `HttpRemoteIp` String | Float32 and IPv6 are smaller (IPv6 turns empty or invalid values into `::`) |
| Noise rules | Kubernetes Lease updates, as an example | Find them among the top counts during the parallel run |
| Service replicas | 2 or more, no idle scaling to zero | Search load and availability requirements |
| Alert destinations | ― | L0 to L1 gap, failed inserts, gap against the sink's export count |

Before a PoC, decide the following in your environment.

- Number and layout of target projects (whether to use an aggregated sink)
- Log sources (GKE, Cloud Run, GCE, and so on) and the kinds and volumes of noise to expect
- Whether any logs contain Japanese messages
- Retention per log kind
- Handling of personal data and who can see which logs
- Whether to bring past logs
- Use of Error Reporting, log-based metrics, and log alerts
- Saved queries in Logs Explorer and how people search day to day
- Whether Pub/Sub is inside a VPC Service Controls perimeter
- The ClickHouse Cloud region

## Estimating size

Size the ClickPipes replicas and the ClickHouse Cloud service from the same ingest rate. The estimate is a starting point based on the official guidelines; once the parallel run starts, confirm with the checks in [troubleshooting](troubleshooting.md) that nothing backs up.

**Ingest rate**

| Step | How | Source |
|---|---|---|
| 1. Monthly volume | Billable Cloud Logging ingestion (`logging.googleapis.com/billing/bytes_ingested`, or Log Storage on the bill). During the parallel run, the sink's exported bytes (`logging.googleapis.com/exports/byte_count`) | Your environment |
| 2. Average rate | Monthly volume ÷ 2,592,000 seconds (30 days) | Arithmetic |
| 3. Bytes sent to Pub/Sub | The JSON a sink exports is larger than the billable volume. Once the parallel run starts, measure the ratio of exported to billable bytes and apply it | Your environment |
| 4. Logs routed to `_Required` | Add them if the sink exports them; the volume depends heavily on the log mix | Your environment |
| 5. Peak | Look at `bytes_ingested` per minute and multiply by the peak-to-average ratio | Your environment |

Example (illustrative numbers): 10 TiB billable per month averages 10 × 1,099,511,627,776 ÷ 2,592,000 ≈ 4.2 MB/s. If the sink exports 1.2 times the billable bytes, about 5.1 MB/s goes to Pub/Sub.

**ClickPipes replicas**

| Size | vCPU, memory | Expected throughput |
|---|---|---|
| XS (default) | 0.125, 512 MiB | 7 MB/s |
| S | 0.25, 1 GiB | 15 MB/s |
| M | 0.5, 2 GiB | 31 MB/s |
| L | 1, 4 GiB | 63 MB/s |
| XL | 2, 8 GiB | 126 MB/s |

- Sizes, vCPU and memory are from the docs ([replica sizes](https://clickhouse.com/docs/products/cloud/reference/billing/clickpipes/clickpipes-for-streaming-and-object-storage)).
- The only published throughput is for Kafka ClickPipes: L at 63 MB/s for JSON (1.6 KB messages, an informal benchmark with ClickHouse not the bottleneck) ([benchmarks](https://clickhouse.com/docs/integrations/clickpipes/kafka/best-practices)). The other sizes scale it by vCPU and round down. No throughput is published for Pub/Sub ClickPipes.
- Pick a size above the peak rate and run two or more replicas. Two or more give an availability-zone-distributed setup ([docs](https://clickhouse.com/docs/integrations/clickpipes/pubsub/overview#scaling)); ClickPipes spreads the managed subscription's messages across the replicas.
- Total throughput also sets how fast the pipe catches up after a stop: with rate F, total throughput C and a stop of T hours, catching up takes T × F ÷ (C − F) hours. The managed subscription keeps messages 7 days, so leave room to catch up well within that.
- The default (one XS replica) handles about 7 MB/s: enough for a trial, possibly not for production. In production, set `pipe_replicas` and related variables in [setup](setup.md), and the size in [setup in the browser](setup-console.md), to this estimate.

**Service**

- For ingest, plan 1 vCPU per 10 MB/s of sustained (uncompressed) ingest. For queries, plan another 1 vCPU per 1 QPS per 10 MB/s of ingest ([ClickStack resource estimation](https://clickhouse.com/docs/clickstack/managing/estimating-resources)).
- A larger pipe also delivers more to the service; while it works off a backlog, up to the pipe's total throughput.
- Keep the autoscaling maximum at or above the vCPU needed for ingest and queries together.

## Estimating cost

**Cost items**

| Item | Price (docs) | Volume |
|---|---|---|
| Cloud Logging ingestion (the side that goes down) | $0.50/GiB ([pricing](https://cloud.google.com/stackdriver/pricing); first 50 GiB per project per month free) | Logs no longer stored in `_Default` |
| Pub/Sub publish | $40/TiB ([pricing](https://cloud.google.com/pubsub/pricing)) | Bytes exported by the sink |
| Pub/Sub delivery | $40/TiB (per subscription) | Bytes exported × number of subscriptions |
| ClickPipes (Pub/Sub) | Private Preview ([ClickPipes connectors](https://clickhouse.com/docs/integrations/clickpipes)). Pricing during the preview and after GA is not on the public price list; ask ClickHouse. Other streaming ClickPipes charge $0.04/GB ingested plus replica hours ([pricing](https://clickhouse.com/docs/products/cloud/reference/billing/clickpipes/clickpipes-for-streaming-and-object-storage)) | Ingested volume, number and size of replicas |
| ClickHouse Cloud | Compute and storage on the pricing page | Service size, stored volume (compressed) |

The Pub/Sub free tier is 10 GiB per billing account per month, shared by publish and delivery.

**What to measure while running in parallel**

| Volume | Cloud Monitoring metric |
|---|---|
| Billable Cloud Logging ingestion | `logging.googleapis.com/billing/bytes_ingested` |
| Bytes exported by the sink | `logging.googleapis.com/exports/byte_count` (filter by sink) |
| Pub/Sub publish bytes billed | `pubsub.googleapis.com/topic/byte_cost` |
| Pub/Sub delivery bytes billed | `pubsub.googleapis.com/subscription/byte_cost` |

**Points to watch**

- Pub/Sub charges apply to logs Cloud Logging does not bill. Logs routed to `_Required` (Admin Activity audit logs and others) are free in Cloud Logging, but cost Pub/Sub when a sink exports them. For high-volume ones, consider the noise handling below.
- The JSON a sink exports is larger than the billable Cloud Logging volume. In testing it was about 1.2 times for the log types Cloud Logging bills. Pub/Sub (publish plus delivery) then costs about 20% of Cloud Logging ingestion (1.2 × $40/TiB × 2 ÷ $0.50/GiB).
- The ratio depends heavily on your log mix, so estimate from the metrics above after starting the parallel run.
- On the delivery side, acks and ack deadline extensions were also counted in `byte_cost`. The price list names publish and delivery as billable; check your bill for whether acks and extensions are charged. (PoC)
- A stopped pipe's managed subscription keeps accumulating messages. (verified)
  Messages older than one day incur storage charges. (docs: [storage costs](https://cloud.google.com/pubsub/pricing#storage_costs))
  Delete pipes you no longer use.

## Estimating cost from PoC measurements

Once production volume is flowing, estimate the monthly cost from what you measure in your own environment. Every input comes from your Cloud Logging, Pub/Sub and ClickHouse Cloud. A spreadsheet template is in `verify/cost_estimate.en.csv` (Japanese: `verify/cost_estimate.csv`; in Google Sheets, File → Import keeps the formulas working).

**Baseline period**

- Average the per-day volumes of one week that includes weekdays and weekends. Log volume changes by day of week, so a few days are biased.
- Do not average by insert time over a period when ingestion was behind or catching up. L1 is partitioned by log timestamp and L0 by publish date, so rows that arrived late still count on their own day.
- Leave out today: it is partial and its parts are not merged yet.

**What to measure**

| Volume | How |
|---|---|
| Stored size per day and compression ratio | Check 17 in `verify/checks.sql` (per table and day). Storage is billed on `on_disk_gb`, which includes skip indexes (in L1 the text index on Body is a large share); `compressed_gb` and `ratio` cover column data only |
| Bytes read by ClickPipes | The pipe's Metrics tab, or `ClickPipes_FetchedBytes_Total` from the Prometheus endpoint ([ClickPipes monitoring](https://clickhouse.com/docs/integrations/clickpipes/monitoring)) |
| Pub/Sub publish and delivery bytes billed | `topic/byte_cost` and `subscription/byte_cost` from "What to measure while running in parallel" above. For delivery, add up every subscription that reads the topic (each pipe has its own managed subscription). After a month of parallel running, compare with the "Message Delivery Basic" SKU on the bill |
| Service compute, storage and backups | ClickHouse Cloud console, Settings → Usage breakdown (per day, at list price, downloadable as CSV; [tracking spend](https://clickhouse.com/docs/products/cloud/reference/billing/billing-overview#how-can-i-keep-track-of-my-spending)) |
| Billable Cloud Logging volume | The usage of the "Log Storage cost" SKU in the billing report filtered to Cloud Logging, or `logging.googleapis.com/billing/bytes_ingested` |

**Putting it together**

| Item | Formula |
|---|---|
| Storage | (L1 on-disk size per day × L1 retention days + L0 on-disk size per day × L0 retention days) × storage price. Add L2 and aggregate tables the same way if you build them |
| Backups | current backups ÷ current storage × the storage above |
| Service compute | compute per day from Usage breakdown × days. If production uses a plan with a different price, multiply by the price ratio |
| ClickPipes | total replica units × compute price × hours + bytes read × ingested-data price |
| Pub/Sub | (publish bytes billed + delivery bytes billed) × $40/TiB |
| Keeping the logs in Cloud Logging instead | billable volume × $0.50/GiB + billable volume × (retention days − 30) ÷ 30.42 × $0.01/GiB (retention beyond 30 days, [pricing](https://cloud.google.com/stackdriver/pricing)). The free 50 GiB per project per month is not included |

- Take each price from its pricing page with your cloud, region and plan selected ([ClickHouse Cloud](https://clickhouse.com/pricing), [ClickPipes](https://clickhouse.com/docs/products/cloud/reference/billing/clickpipes/clickpipes-for-streaming-and-object-storage), [Pub/Sub](https://cloud.google.com/pubsub/pricing)). For Pub/Sub ClickPipes pricing, ask ClickHouse as noted in "Cost items" above.
- Compute measured during the PoC covers ingestion only. Add search once the representative queries are measured ("Service" under "Estimating size" above).
- Storage is the steady state once logs for the full retention have accumulated. During the migration, add the cost of keeping logs in both Cloud Logging and ClickHouse.
- Compare with Cloud Logging on the same billable volume. Pub/Sub and ClickPipes volumes are the size of the JSON the sink exports, which is larger than the billable Cloud Logging volume ("Points to watch" above).
