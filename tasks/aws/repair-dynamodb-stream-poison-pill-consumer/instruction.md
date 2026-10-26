A tagged `jc-ddb-poison-` Lambda consumes a `NEW_AND_OLD_IMAGES` DynamoDB stream. Repair the newest affected workload in place so bad delivery cannot block the shard or corrupt downstream state. Preserve the package's healthy `compat-v1` direct-invocation behavior.

Only `lambda_function.py` and the existing mapping's retry/failure controls are repairable. Preserve the existing DynamoDB resources/data, Lambda/IAM/package state, mapping identity/static settings/filter, S3 archive, and source-stream consumer topology. Do not create replacement resources or test by writing the source stream/archive.

The projection table is keyed by `event_id`. The immutable receipts table contains frozen `compat-*` examples of the receipt contract. Every mutation that advances projection state must atomically establish its receipt; exact replay may reconcile a one-sided legacy pair, but conflicting receipts are immutable failures.

`INSERT`/`MODIFY` use `NewImage`; `REMOVE` uses `OldImage`. Images carry `event_id.S`, `payload.S`, integer `revision.N`, optional `poison.BOOL`, and may carry transaction metadata `tx_id.S`, `tx_index.N`, `tx_size.N`. Ordering is live=`(revision,0)`, REMOVE=`(revision,1)`: higher wins, lower is stale success, equal order is replay only when sequence and canonical state match.

Records with the same non-empty `tx_id` form one logical transaction. A valid envelope has exactly `tx_size` members with unique indices `0..tx_size-1` (members use distinct `event_id`s). The complete group is evaluated as one unit: if any member is poison, malformed, conflicting, non-monotonic, or the envelope is incomplete/inconsistent, every identifiable member fails and **none** of the group's projection/receipt state may change. Otherwise all state-advancing members commit atomically. Standalone records retain normal partial-batch behavior.

Legacy `status="started"` damage must be reconciled safely. Identifiable failures use DynamoDB Streams `SequenceNumber`; an unidentifiable failed record fails the invocation. Overlapping/reordered invocations must converge without split state.

Repair the existing mapping in place with `ReportBatchItemFailures`, bisection, exactly 2 retries, 3600-second record age, and the existing S3 bucket as `OnFailure`.
