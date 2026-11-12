# Troubleshooting

English | [日本語](../ja/08-troubleshooting.md)

How to narrow down an ingest problem from the symptom to its cause and fix. Queries are referred to by their number in `verify/checks.sql` (run with `python3 tools/chq.py verify/checks.sql`). The routine checks and their thresholds are in "Daily checks" and "Monitoring and alerts" in [operations](07-operations.md).

| Symptom | Section |
|---|---|
| New logs do not show up, or show up late | "Ingest falls behind" |
| The pipe goes Degraded or Failed; rows do not reach L1 | "Detecting and recovering MV failures" |
| Inserts fail with `TOO_MANY_PARTITIONS` | "One insert spans too many partitions" |
| The part count looks too high | "Part counts" |
| The sink's export count and the rows in ClickHouse disagree | Loss on the path, in "Daily checks" in [operations](07-operations.md) |

## Ingest falls behind
### 1. Measure the delay

The quickest way is the "Latency (s)" chart on the pipe's Metrics tab in the ClickHouse Cloud Console. The same value is available as `ClickPipes_Latency` on the Prometheus endpoint ([ClickPipes monitoring](https://clickhouse.com/docs/integrations/clickpipes/monitoring)).

From ClickHouse, check 16 shows, for the rows that reached L1 in the last 10 minutes, the delay from Pub/Sub publish. The pipe inserts at least every 5 seconds, so the delay is a few seconds when it keeps up. If you see minutes, or a value that keeps growing, go on.

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

Choose the replica size and number from the ingest rate ("Estimating size" in [planning](02-planning.md)) and change them. Run two or more replicas.

- In the browser: open the pipe in the ClickHouse Cloud Console, Settings → Advanced Settings → Scaling
- Terraform: `pipe_replicas`, `pipe_replica_cpu_millicores`, `pipe_replica_memory_gb` ("Changing settings after creation" in [setup](04-setup.md))

With rate F, total throughput C and a delay of T, catching up takes T × F ÷ (C − F).

**When the service is the limit**

- Check that the autoscaling maximum is not below the vCPU needed for ingest and queries ("Estimating size" in [planning](02-planning.md)). A larger pipe also delivers more to the service while it works off a backlog.
- If check 6 shows failed inserts, follow "Detecting and recovering MV failures".
### 5. Confirm it caught up

- Check 11 shows only today's date.
- The delay in check 16 is back to a few seconds.
- Both Pub/Sub metrics fall and level off.
### When the backlog lasted long

- The managed subscription keeps messages 7 days ([docs](https://clickhouse.com/docs/integrations/clickpipes/pubsub/overview)). Messages not processed within 7 days are discarded, and without topic retention they cannot be recovered from Pub/Sub. If they are still in a Cloud Logging log bucket, load them with "Backfilling existing logs" in [operations](07-operations.md).
- Unprocessed messages older than one day incur storage charges ([storage costs](https://cloud.google.com/pubsub/pricing#storage_costs)).

## Detecting and recovering MV failures

When an MV threw an exception, the behavior was:

1. The failing batch was written to L0 but never reached L1.
2. The pipe retried the same batch after 10 s, 30 s, 70 s, then every 2 minutes.
3. Other batches kept flowing; the pipe state was Degraded briefly and then back to Running. The error table stayed empty.
4. After fixing the MV with `MODIFY QUERY`, the next retry delivered the batch to L1 with no loss and no duplicates.

Point 4 holds because the block is deduplicated in L0 and still passed again to the dependent MVs.
This comes from the default value 1 of the setting `deduplicate_blocks_in_dependent_materialized_views` ([setting](https://clickhouse.com/docs/reference/settings/session-settings/other#deduplicate_blocks_in_dependent_materialized_views)).

In testing, however, the pipe went Failed and stopped ingesting about 60 minutes after the first failure.
Fixing the MV and restarting with `clickpipe start` lost nothing, but part of the stuck batch was written to L1 twice.
After a restart, check `MessageId` duplicates with check 3 in `verify/checks.sql`, and deduplicate in queries or rebuild the range with appendix A2 in [operations](07-operations.md).

The pipe state does not show a stuck batch until Failed, so monitor the L0 to L1 gap and failed inserts in `system.query_log`.
The SQL is in `sql/runbooks/05_mv_failure.sql`.

Fix MVs with `MODIFY QUERY`; never drop and recreate them.
Blocks inserted between DROP and CREATE skip the MV and stay only in L0.

## One insert spans too many partitions

L1 is partitioned by the date of `Timestamp`. By default one block of one insert can span at most 100 partitions; beyond that the insert fails ([max_partitions_per_insert_block](https://clickhouse.com/docs/reference/settings/session-settings/max-partitions)). The MV performs the insert into L1, so the failure blocks the batch like any other MV exception.

Cloud Logging accepts entries with old timestamps through the API and routes them to sinks without storing them in log buckets ([Cloud Logging limits](https://cloud.google.com/logging/quotas)). Without a bound, the failure happens when the `Timestamp` values within one batch fall on more than 100 dates, regardless of the L1 retention (TTL).

From parser version 8, MV1 uses the LogEntry timestamp only between 30 days before and 1 day after the publish time, and the publish time otherwise. One pipe batch then touches about 32 partitions at most. The noise MV and the L2 examples apply the same rule.

- On clickhouse local 26.7, one insert with timestamps on 150 dates failed with `Too many partitions for single INSERT block` under parser version 7 (rows in L0, none in L1) and reached L1 in full under version 8 (`verify/local_e2e.sh`, checks 22 and 23). Not tested with a pipe on ClickHouse Cloud.
- Rows whose timestamp was replaced have the `entry.timestamp` attribute with the original text.
- Check 14 shows how many L1 partitions one insert wrote.
- Check 4 (late arrivals) reads only `Timestamp` within the last 8 days, so it does not count older timestamps.

**Deployments created with parser version 7 or earlier.** `sql/30` and `sql/50` use `CREATE MATERIALIZED VIEW IF NOT EXISTS`, so running them again (including `terraform apply`) does not change an existing MV. Apply the new SELECT with `ALTER TABLE ... MODIFY QUERY` as in appendix A1 of [operations](07-operations.md): `gcl.gcl_logs_v1_mv` from `sql/30_logs_v1_mv.sql`, `gcl.gcl_noise_1m_v1_mv` from `sql/50_noise_rollup_v1.sql`, and any L2 MV that reads L0. Keep the noise rules you added. Check 5 shows which parser versions are writing.

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
