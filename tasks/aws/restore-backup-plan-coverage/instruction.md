The AWS Backup plan vera-nightly-<id> in us-east-1 protects the vera fleet:
the resources whose names carry that same <id>. It selects them by the tag
backup=nightly and backs them up into the vault vera-vault-<id>. A resource
named vera-* with any other id is not part of this fleet and is out of scope.
A compliance sweep found the fleet has no recovery points at all.

You cannot start backup jobs in this environment - backup:StartBackupJob is
denied to you. The verification starts them itself after you finish.

Required end state:

1. Every fleet resource except the scratch bucket, whose Name tag is
   vera-scratch-<id>, is covered by a selection on vera-nightly-<id>, and a
   backup job for it into vera-vault-<id>, started with that selection's role,
   completes.
2. That scratch bucket is still not backed up by that plan when you are done.
3. vera-nightly-<id> and vera-vault-<id> stay in place, and the fleet
   resources that exist now stay in place. Do not delete or recreate any of them.