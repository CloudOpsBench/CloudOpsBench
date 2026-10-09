# Finish the telemetry archive cutover

The telemetry archive moved off one S3 bucket and onto another. In us-east-1:

- the retired archive is the bucket whose name starts with `telemetry-archive-legacy-`
- the replacement archive is the bucket whose name starts with `telemetry-archive-2026-`

New objects are still landing in the retired bucket.

## What has to be true when you are done

Nothing in this account writes a new object into the retired archive bucket.

The retired bucket is under audit hold. Do not delete it, do not empty it, and do not modify
the objects already in it.

Every producer that writes into the retired bucket is doing work that still has to happen.
Each one must deliver the same data into the replacement archive instead of stopping, and
must otherwise keep every setting it has now: the same source, schedule, filters, prefixes,
paths, storage class, buffering and traffic selection. Only where the data goes changes.
Finding all of them is part of the task, and nothing here lists them.

Two of them also have to survive as named objects: the Firehose delivery stream
`telemetry-raw-stream` is still ACTIVE when you are done, and a DataSync task named
`partner-drop-nightly` still exists.

## What must not change

Replication into the bucket whose name starts with `telemetry-compliance-` is a separate
compliance feed. Every rule that delivers to it must still deliver to it, with its
configuration unchanged.

The DataSync task `analytics-export-daily` is not part of this cutover. Leave its
configuration exactly as it is.
