# Planning

English | [日本語](../ja/02-planning.md)

What to decide for your environment, and how to size ClickPipes and the service, before deployment.
Cost is in [Estimating cost](03-cost.md).
The configuration and the reasons behind it are in [Design](01-design.md); deployment is in [Setup](04-setup.md).

> Limits were checked against the official documentation on 2026-10-05.
> Private Preview features may change in behavior and pricing before general availability (GA).
> The markers "(verified)", "(docs)" and "(PoC)" are explained at the top of [Design](01-design.md).

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
| L2 (typed tables) | None | Only for requirements that match "When to build an L2" in [Design](01-design.md) |
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

Size the ClickPipes replicas and the ClickHouse Cloud service from the same ingest rate. The estimate is a starting point based on the official guidelines; once the parallel run starts, confirm with the checks in [troubleshooting](08-troubleshooting.md) that nothing backs up.

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
- The default (one XS replica) handles about 7 MB/s: enough for a trial, possibly not for production. In production, set `pipe_replicas` and related variables in [setup](04-setup.md), and the size in [setup in the browser](05-setup-console.md), to this estimate.

**Service**

- For ingest, plan 1 vCPU per 10 MB/s of sustained (uncompressed) ingest. For queries, plan another 1 vCPU per 1 QPS per 10 MB/s of ingest ([ClickStack resource estimation](https://clickhouse.com/docs/clickstack/managing/estimating-resources)).
- A larger pipe also delivers more to the service; while it works off a backlog, up to the pipe's total throughput.
- Keep the autoscaling maximum at or above the vCPU needed for ingest and queries together.
