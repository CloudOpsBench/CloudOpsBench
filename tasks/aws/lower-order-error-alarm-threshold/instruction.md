Our order-processing service has a CloudWatch alarm (`vera2-high-order-errors-*`) that is supposed to page
on-call the moment order errors start spiking. Right now the alarm's threshold is set to 1000 errors in a
5-minute window, so it only fires after we've already dropped thousands of orders — on-call effectively never
gets paged in time.

Set the alarm's threshold to 100 so it pages while a spike is still small enough to act on.

Constraints:
- Keep the same alarm (same name); it must stay a "GreaterThanOrEqualToThreshold" alarm on the same
  namespace/metric (`vera2/orders` / `OrderErrors`).
- The threshold should be 100 (not so low that ordinary noise pages on-call constantly).