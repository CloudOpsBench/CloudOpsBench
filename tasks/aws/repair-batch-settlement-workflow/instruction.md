Repair the existing `batch-settlement` Step Functions workflow in place. Keep
its role, JSONata two-state design, and existing response contract; do not add
outside compute. Publish two repaired versions with the same settlement behavior
and route `live` and `audit` to different repaired versions.

Settlement is chronological across the whole batch, not restarted per order.
For a repeated SKU, each line's available inventory is reduced by all quantity
previously requested for that SKU, including quantity that could not be filled.
Its rebate budget is reduced only by the fulfilled merchandise value previously
seen for that SKU.

Apply the tier discount plus 20% for coupon `SAVE20`, capped at 35%. SKU rebate
reduces the taxable base before discount, and the same discount also reduces
taxable merchandise. Orders qualify for batch credit when their unrounded net is
at least `creditMinNet`; available credit is capped at the eligible net total.
Apportion that credit in whole cents by largest remainder, using original order
for ties. Prorate each eligible invoice's taxable value by the fraction of net
left after credit. Free shipping is based on net after batch credit.

Preserve the existing `batchId`, `invoices`, and `summary` response shape.
Invoice line totals reflect fulfilled merchandise. Round money only when
emitted, except for whole-cent credit allocation. Empty batches produce no
invoices and zero summary totals.