Repair the seeded Lambda deployment guardrail in place. Preserve the function,
published versions, `live` alias, CodeDeploy application, deployment group,
roles, and ownership tags. Keep the seeded alarm name and live-alias scope.

Restore `live` to the stable version with no traffic split. The existing group
must use the 10-percent/five-minute Lambda canary, watch the seeded Errors
alarm scoped to `live` through Lambda's `Resource` dimension, and roll back on
deployment failure or alarm breach. The alarm uses a one-minute Sum, fires on
one error, and treats missing data as healthy.

Keep the CodeDeploy role usable and least-privilege: it may manage only the
seeded `live` alias and read alarms. Preserve the seeded identities and function
code/configuration. Add `SecurityProfile=secure-canary-rollback-v1` to the
function and CodeDeploy role.

Equivalent secure policy grouping, statement order, and Sid values are valid.