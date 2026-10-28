# Troubleshooting

English | [日本語](../ja/troubleshooting.md)

How to narrow down an ingest problem from the symptom to its cause and fix. Queries are referred to by their number in `verify/checks.sql` (run with `python3 tools/chq.py verify/checks.sql`). The routine checks and their thresholds are in "Daily checks" in [operations](operations.md).

| Symptom | Section |
|---|---|
| New logs do not show up, or show up late | "Ingest falls behind" |
| The pipe goes Degraded or Failed; rows do not reach L1 | "Detecting and recovering MV failures" in [operations](operations.md) |
| Inserts fail with `TOO_MANY_PARTITIONS` | "One insert spans too many partitions" |
| The part count looks too high | "Part counts" |
| The sink's export count and the rows in ClickHouse disagree | Loss on the path, in "Daily checks" in [operations](operations.md) |

## Ingest falls behind

### 1. Measure the delay

Check 16 shows, for the rows that reached L1 in the last 10 minutes, the delay from Pub/Sub publish. The pipe inserts at least every 5 seconds, so the delay is a few seconds when it keeps up. If you see minutes, or a value that keeps growing, go on.

Check 1 selects rows by publish time, so during a backlog it returns few rows. Fewer rows than usual in check 1 are also a sign of delay.

### 2. Confirm a backlog

In Cloud Monitoring, look at these metrics for the managed subscription `clickpipes-<pipe id>` ([Pub/Sub monitoring](https://cloud.google.com/pubsub/docs/monitoring)):

- `pubsub.googleapis.com/subscription/oldest_unacked_message_age_by_region` (age of the oldest unprocessed message)
- `pubsub.googleapis.com/subscription/num_unacked_messages_by_region` (number of unprocessed messages)

If both keep growing, the pipe is not keeping up with the rate.

From ClickHouse, use check 11. It counts the rows written to L0 in the last hour by publish date. L0 is partitioned by publish date, so only today's date appears when the pipe keeps up. Many rows under earlier dates mean the pipe is still working through messages published in the past.

### 3. Tell the pipe from the service

Check 12 shows the number and duration of pipe inserts per 10 minutes. Check 13 shows the rows each insert wrote to L0.

The pipe closes a batch and inserts it at 100,000 rows, at 32 MB per GB of replica memory, or after 5 seconds ([docs](https://clickhouse.com/docs/integrations/clickpipes/pubsub/overview)).

| Backlog | Interval and rows per insert | Insert duration | Reading |
|---|---|---|---|
| Yes | About every 5 s, well below the size limits | Much shorter than the interval (`busy_ratio` well below the number of pipe replicas) | The pipe's read rate is the limit: it cannot fill a batch in 5 s |
| Yes | Near the size limits, short intervals | Much shorter than the interval | The pipe writes as fast as it can: add or enlarge replicas |
| Yes | ― | Close to the interval, or failures (check 6) | The service is the limit |
| No | About every 5 s | Short | Normal. A 5 s interval is fine as long as nothing backs up |

### 4. Fix it

**When the pipe is the limit**

Choose the replica size and number from the ingest rate ("Estimating size" in [design](design.md)) and change them. Run two or more replicas.

- In the browser: open the pipe in the ClickHouse Cloud Console, Settings → Advanced Settings → Scaling
- Terraform: `pipe_replicas`, `pipe_replica_cpu_millicores`, `pipe_replica_memory_gb` ("Changing settings after creation" in [setup](setup.md))

With rate F, total throughput C and a delay of T, catching up takes T × F ÷ (C − F).

**When the service is the limit**

- Check that the autoscaling maximum is not below the vCPU needed for ingest and queries ("Estimating size" in [design](design.md)). A larger pipe also delivers more to the service while it works off a backlog.
- If check 6 shows failed inserts, follow "Detecting and recovering MV failures" in [operations](operations.md).

### 5. Confirm it caught up

- Check 11 shows only today's date.
- The delay in check 16 is back to a few seconds.
- Both Pub/Sub metrics fall and level off.

### When the backlog lasted long

- The managed subscription keeps messages 7 days ([docs](https://clickhouse.com/docs/integrations/clickpipes/pubsub/overview)). Messages not processed within 7 days are discarded, and without topic retention they cannot be recovered from Pub/Sub. If they are still in a Cloud Logging log bucket, load them with "Backfilling existing logs" in [operations](operations.md).
- Unprocessed messages older than one day incur storage charges ([storage costs](https://cloud.google.com/pubsub/pricing#storage_costs)).

## One insert spans too many partitions

L1 is partitioned by the date of `Timestamp`. By default one block of one insert can span at most 100 partitions; beyond that the insert fails ([max_partitions_per_insert_block](https://clickhouse.com/docs/reference/settings/session-settings/max-partitions)). The MV performs the insert into L1, so the failure is handled like an MV failure, and the pipe presumably keeps retrying the same batch (inferred from the behavior with another MV exception; not tested with this one).

Cloud Logging accepts entries with old timestamps through the API and routes them to sinks without storing them in log buckets ([Cloud Logging limits](https://cloud.google.com/logging/quotas)). The failure happens when the `Timestamp` values within one batch fall on more than 100 dates, regardless of the L1 retention (TTL).

- Check 14 shows how many L1 partitions one insert wrote.
- Check 4 (late arrivals) reads only `Timestamp` within the last 8 days, so it does not count older timestamps.
- If it happens, an option is to have the MV replace very old `Timestamp` values with the publish time or drop them (not tested).

## Part counts

Part limits are counted per table.

| Setting | Value on ClickHouse Cloud (checked 2026-10-28) | Scope |
|---|---|---|
| `parts_to_delay_insert` | 1,000 | Active parts in one partition; above it inserts are delayed |
| `parts_to_throw_insert` | 3,000 | Same scope; above it inserts fail |
| `max_parts_in_total` | 10,000 | Active parts across all partitions of one table |

- Check 8 shows partitions and parts per table.
- The service-wide part count includes system tables (`system.query_log` and others). When a system table's structure changes, the old one is kept under a numbered name (`query_log_11` and so on), so system tables can outnumber user tables. They do not count toward user tables' limits.
- For L1, which keeps daily partitions for 400 days, `max_parts_in_total` applies first. It assumes older partitions merge down to a few parts: 25 parts left in each partition reach 10,000 in 400 days.
- Check 15 shows L1 parts per partition by partition age. Check the older partitions and the table total (`table_parts`) regularly.
