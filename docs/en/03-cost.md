# Estimating cost

English | [日本語](../ja/03-cost.md)

The monthly cost after moving to ClickHouse: a rough estimate from volume before the PoC, and a figure from your own measurements after it.
Both are compared with keeping the logs in Cloud Logging for the same retention.
The size of the service and of ClickPipes comes from "Estimating size" in [Planning](02-planning.md).

> Prices and limits were checked against the official documentation on 2026-10-05.
> Private Preview features may change in behavior and pricing before general availability (GA).
> The markers "(verified)", "(docs)" and "(PoC)" are explained at the top of [Design](01-design.md).

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

Once production volume is flowing, estimate the monthly cost from what you measure in your own environment. Every input comes from your Cloud Logging, Pub/Sub and ClickHouse Cloud. A spreadsheet template is [cost_estimate.en.csv](../files/cost_estimate.en.csv) (Japanese: [cost_estimate.csv](../files/cost_estimate.csv); in Google Sheets, File → Import keeps the formulas working).

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
- Compute measured during the PoC covers ingestion only. Add search once the representative queries are measured ("Service" under "Estimating size" in [Planning](02-planning.md)).
- Storage is the steady state once logs for the full retention have accumulated. During the migration, add the cost of keeping logs in both Cloud Logging and ClickHouse.
- Compare with Cloud Logging on the same billable volume. Pub/Sub and ClickPipes volumes are the size of the JSON the sink exports, which is larger than the billable Cloud Logging volume ("Points to watch" above).
