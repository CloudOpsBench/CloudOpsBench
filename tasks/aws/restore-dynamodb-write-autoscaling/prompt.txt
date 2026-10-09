Our `vera2-orders-*` DynamoDB table can't handle write bursts — its write capacity is stuck at 2 and never
scales up under load, even though we set up target-tracking auto scaling for it. During last night's sale the
table throttled writes the whole time while sitting at 2 WCU.

Fix it so the table's write capacity actually auto-scales up to 10 when it's busy (and back down to 2 when
idle) based on utilization, going forward.

Constraints:
- Keep the table and its target-tracking scaling policy; don't delete the table or switch it to on-demand
  billing.
- The scalable range for write capacity must be min 2, max 10.