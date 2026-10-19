# Cut the vendor's sessions off from the pricing table

This account shares live data with Meridian, an external analytics vendor. Two DynamoDB
tables in us-east-1 hold the shared data: `dataex-catalog` and `dataex-pricing`.

Meridian's integrations run inside this account. None of them holds standing table
permissions: each one assumes the shared IAM role `dataex-access-role`, and the only thing
narrowing a session down from the role's full grant is the scoping document the integration
passes when it assumes the role.

A compliance review reclassified `dataex-pricing` as internal only. Meridian must no longer
be able to read it.

## What has to be true when you are done

No session produced by a Meridian integration's stored configuration can read anything from
`dataex-pricing` — not GetItem, BatchGetItem, Query, or Scan.

Every Meridian integration keeps the read access to `dataex-catalog` it has today, through
the same path it uses today. Do not delete an integration, disable one, or remove its way
of obtaining credentials. Scope it.

## What must not change

`dataex-access-role` is also used by an internal reconciliation job through
`dataex-recon-role`. Reconciliation reads both tables and must keep doing so: the role's
own permissions stay as broad as they are now, and whatever can assume the role today must
still be able to.

The two tables, their configuration and their data stay as they are. Do not attach resource
policies to them; the narrowing happens on the credential paths.

Meridian deploys its own integration code. Scope an integration through its configuration,
not by editing what it runs.
