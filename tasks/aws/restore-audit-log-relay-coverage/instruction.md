This account relays application logs to a central audit pipeline: the Kinesis data stream
`audit-relay-stream-*`, which CloudWatch Logs writes to through the role `audit-relay-cwl-*`.

Application log groups are named `/svc/<service>-*`. Deployments create new ones continuously,
in the Standard log class.

Leave things in this state:

1. Every `/svc/` log group's events reach `audit-relay-stream-*`, all of them, not a filtered
   subset. A `/svc/` log group created after you finish is covered too, from the moment it
   exists, without being set up individually.
2. The one exception is the log group `/svc/vendor-callback-raw-*`. It carries third-party
   payloads and its events must never reach the audit relay.

Constraints:

- Every `/svc/` log group keeps the name and the retention setting it has now. Events already
  stored in them do not have to be preserved.
- `/svc/vendor-callback-raw-*` is otherwise left exactly as it is.
- Do not delete or replace `audit-relay-stream-*` or the role `audit-relay-cwl-*`.
