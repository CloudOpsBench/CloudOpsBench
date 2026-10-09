The `adt-` data pipeline in AWS account <account-id> has been deprecated and is still accruing cost. Shut it down completely — remove every resource that was provisioned for it (they all carry the `adt-` prefix in their names) so nothing of `adt-` survives. Do not modify or delete anything that isn't part of `adt-`.

`<account-id>` is the ID of the AWS account you are working in.
