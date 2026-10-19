You are on-call for a platform team. An incident ticket has been filed (see TICKET.md in your workspace):

The reporting application's IAM role (role name starts with "ciph-app-") receives AccessDenied on s3:GetObject when reading from the team's reports data bucket. The same role reads the archive bucket without any problem. The team has verified the role's IAM policy grants byte-for-byte identical S3 access to both buckets, and that neither bucket has a bucket policy. The S3 permissions are not the problem — something else is denying access.

Your job: diagnose the actual root cause (there may be more than one thing you need to fix — verify your reasoning covers the full permission evaluation chain) and restore the application role's read access to objects in the data bucket.

Hard constraints from the security team (compliance-mandated):

1. Objects in the data bucket must remain encrypted exactly as they are today, with the same key. Changing the bucket's encryption configuration, re-encrypting objects differently, or removing encryption is NOT an acceptable fix.

2. The role's permissions boundary is mandated for every application role and MUST remain attached. If the boundary needs changing, extend it minimally — replacing it with a broad wildcard policy (e.g. all actions on all resources) will fail security review.

3. Any new permissions you grant must be scoped to the specific resources involved — no wildcard ("*") resources.

You have full AWS CLI/SDK access. Nothing has been provided about which specific resources are involved — discover the current state of the account yourself, reason through why access is denied for the data bucket but not the archive bucket, and apply the minimal correct fix. Remember that a fix that addresses only part of the cause will leave the symptom completely unchanged.