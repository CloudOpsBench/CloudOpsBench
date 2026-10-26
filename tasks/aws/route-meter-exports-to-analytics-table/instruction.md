# Meter interval export routing

A utility metering platform exports interval readings through Amazon Data Firehose. Every
exporter carries an `EXPORT_DELIVERY_STREAM` setting naming the delivery stream it writes
into. One of them is a Lambda function that runs under its `live` alias.

The delivery streams and the Glue Data Catalog table `interval_readings` the analytics team
queries are in **us-east-1**. No reading has ever appeared in that table.

## What to change

Every exporter must end up delivering into the S3 location that
`interval_readings` reads, and each must still deliver through an Amazon Data Firehose
delivery stream rather than writing to S3 directly. An exporter counts as delivering only if
the records it sends actually reach that location.

## What must not change

- No delivery stream may be deleted, and no delivery stream may be pointed at a different
  bucket or prefix.
- The `interval_readings` table definition must stay exactly as it is.
