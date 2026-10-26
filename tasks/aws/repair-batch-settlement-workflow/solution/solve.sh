#!/usr/bin/env bash
set -euo pipefail

SM_NAME="batch-settlement"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SM_ARN="$(aws stepfunctions list-state-machines \
  --query "stateMachines[?name=='${SM_NAME}'].stateMachineArn | [0]" --output text)"
[ -n "$SM_ARN" ] && [ "$SM_ARN" != "None" ] || { echo "state machine ${SM_NAME} not found" >&2; exit 1; }
ROLE_ARN="$(aws stepfunctions describe-state-machine --state-machine-arn "$SM_ARN" --query roleArn --output text)"

cat > "$WORK/expr.jsonata" <<'JSONATA'
(
  $rules := $states.input.rules;
  $orders := $states.input.batch.orders;
  $n := $count($orders);
  $sum0 := function($x){ $exists($x) ? $sum($x) : 0 };

  $occ := $n = 0 ? [] : $reduce([0..$n-1], function($acc, $oi){
    $append($acc, $map($orders[$oi].lines, function($ln, $li){
      {"oi": $oi, "li": $li, "sku": $ln.sku, "qty": $ln.qty, "unitPrice": $ln.unitPrice, "taxable": $ln.taxable}
    }))
  }, []);

  $ff := $reduce($occ, function($acc, $c){(
    $inv := $lookup($rules.inventory, $c.sku);
    $invN := $exists($inv) ? $inv : 0;
    $earlier := $lookup($acc.used, $c.sku);
    $earlierN := $exists($earlier) ? $earlier : 0;
    $fq := $min([$c.qty, $max([0, $invN - $earlierN])]);
    {
      "used": $merge([$acc.used, {$c.sku: $earlierN + $c.qty}]),
      "out": $append($acc.out, [$merge([$c, {"priorQty": $earlierN, "fq": $fq, "ext": $fq * $c.unitPrice}])])
    }
  )}, {"used": {}, "out": []});
  $occ2 := $ff.out;

  $rb := $reduce($occ2, function($acc, $c){(
    $pool := $lookup($rules.skuRebates, $c.sku);
    $poolN := $exists($pool) ? $pool : 0;
    $earlierE := $lookup($acc.usedE, $c.sku);
    $earlierEN := $exists($earlierE) ? $earlierE : 0;
    $reb := $min([$c.ext, $max([0, $poolN - $earlierEN])]);
    {
      "usedE": $merge([$acc.usedE, {$c.sku: $earlierEN + $c.ext}]),
      "out": $append($acc.out, [$merge([$c, {
        "priorExt": $earlierEN,
        "reb": $reb,
        "audit": $round($c.ext * 100, 0) - $round($reb * 100, 0) + ($c.fq * 17) + ($c.qty * 5) + ($c.taxable ? 11 : 0)
      }])])
    }
  )}, {"usedE": {}, "out": []});
  $occ3 := $rb.out;
  $auditTrail := $count($occ3) = 0 ? [] : [$map($occ3, function($x){
    {
      "key": $orders[$x.oi].id & "#" & ($x.li + 1) & "#" & $x.sku,
      "orderIndex": $x.oi + 1,
      "lineIndex": $x.li + 1,
      "sku": $x.sku,
      "priorRequestedQty": $x.priorQty,
      "fulfilledQty": $x.fq,
      "backorderedQty": $x.qty - $x.fq,
      "extension": $round($x.ext, 2),
      "priorFulfilledExtension": $round($x.priorExt, 2),
      "lineRebate": $round($x.reb, 2),
      "lineAudit": $x.audit
    }
  })];

  $orderCalcs := $n = 0 ? [] : $map([0..$n-1], function($oi){(
    $mine := $occ3[oi = $oi];
    $o := $orders[$oi];
    $subtotal := $sum0($mine.ext);
    $skuRebate := $sum0($mine.reb);
    $requested := $sum0($mine.qty);
    $fulfilled := $sum0($mine.fq);
    $tr := $lookup($rules.discounts, $o.tier);
    $tierRate := $exists($tr) ? $tr : 0;
    $couponRate := $o.coupon = "SAVE20" ? 0.20 : 0;
    $discountRate := $min([0.35, $tierRate + $couponRate]);
    $discount := ($subtotal - $skuRebate) * $discountRate;
    $net := $subtotal - $skuRebate - $discount;
    $taxableSum := $sum0($mine[taxable = true].(ext - reb));
    $taxableNet := $taxableSum * (1 - $discountRate);
    {
      "id": $o.id, "tier": $o.tier, "lineCount": $count($mine),
      "lineTotals": [$map($mine, function($x){ $round($x.ext, 2) })],
      "lineAudit": [$map($mine, function($x){ $x.audit })],
      "requested": $requested, "fulfilled": $fulfilled, "back": $requested - $fulfilled,
      "subtotal": $subtotal, "skuRebate": $skuRebate, "discountRate": $discountRate,
      "discount": $discount, "net": $net, "taxableNet": $taxableNet
    }
  )});

  $creditMin := $rules.creditMinNet;
  $sumElig := $sum0($orderCalcs[net >= $creditMin].net);
  $availCents := ($n = 0 or $sumElig <= 0) ? 0 : $round($min([$rules.batchCredit, $sumElig]) * 100, 0);

  $alloc0 := $n = 0 ? [] : $map([0..$n-1], function($i){(
    $isElig := $orderCalcs[$i].net >= $creditMin;
    $e := ($isElig and $sumElig > 0 and $availCents > 0) ? $availCents * $orderCalcs[$i].net / $sumElig : 0;
    $f := $floor($e);
    { "i": $i, "floor": $f, "frac": $isElig ? $e - $f : -1 }
  )});
  $remaining := $availCents - $sum0($alloc0.floor);
  $sorted := $sort($alloc0, function($a, $b){
    $a.frac < $b.frac or ($a.frac = $b.frac and $a.i > $b.i)
  });
  $topIdx := $remaining <= 0 ? [] : $sorted[[0..$remaining-1]].i;

  $invoices := $n = 0 ? [] : [$map([0..$n-1], function($i){(
    $c := $orderCalcs[$i];
    $creditCents := $alloc0[$i].floor + ($i in $topIdx ? 1 : 0);
    $credit := $creditCents / 100;
    $net := $c.net;
    $taxableBase := $net = 0 ? 0 : $c.taxableNet * ($net - $credit) / $net;
    $tax := $taxableBase * $rules.taxRate;
    $shipping := ($net - $credit) >= $rules.shippingThreshold ? 0 : $rules.shippingFee;
    $total := ($net - $credit) + $tax + $shipping;
    $fingerprint := $sum0($map([0..$count($c.lineAudit)-1], function($j){
      ($j + 1) * $c.lineAudit[$j]
    })) + ($c.requested * 101) + ($c.fulfilled * 103) + ($c.back * 107);
    {
      "id": $c.id, "tier": $c.tier, "lineCount": $c.lineCount,
      "lineTotals": $c.lineTotals,
      "requestedItemCount": $c.requested, "fulfilledItemCount": $c.fulfilled,
      "backorderedItemCount": $c.back,
      "subtotal": $round($c.subtotal, 2), "skuRebate": $round($c.skuRebate, 2),
      "discountRate": $c.discountRate, "discount": $round($c.discount, 2),
      "batchCredit": $round($credit, 2), "taxableBase": $round($taxableBase, 2),
      "tax": $round($tax, 2), "shipping": $round($shipping, 2), "total": $round($total, 2)
    }
  )})];
  $creditLedger := $n = 0 ? [] : [$map([0..$n-1], function($i){(
    $c := $orderCalcs[$i];
    $creditCents := $alloc0[$i].floor + ($i in $topIdx ? 1 : 0);
    $credit := $creditCents / 100;
    $net := $c.net;
    $taxableBase := $net = 0 ? 0 : $c.taxableNet * ($net - $credit) / $net;
    $eligible := $c.net >= $creditMin;
    $ratioBps := $net = 0 ? 0 : $round(($net - $credit) * 10000 / $net, 0);
    $bonusCent := $creditCents - $alloc0[$i].floor;
    $remainderMicros := $eligible and $sumElig > 0 and $availCents > 0 ? $round($alloc0[$i].frac * 1000000, 0) : 0;
    $creditCode := (($i + 1) * 97) + ($eligible ? 89 : 0)
      + ($round($net * 100, 0) * 3) + ($alloc0[$i].floor * 5) + ($bonusCent * 7)
      + ($creditCents * 11) + ($round($taxableBase * 100, 0) * 13)
      + ($ratioBps * 17) + $remainderMicros;
    {
      "orderId": $c.id,
      "inputIndex": $i + 1,
      "eligible": $eligible,
      "netBeforeCredit": $round($net, 2),
      "floorCreditCents": $alloc0[$i].floor,
      "remainderMicros": $remainderMicros,
      "receivedRemainderCent": $bonusCent,
      "creditCents": $creditCents,
      "taxableProrationBps": $ratioBps,
      "creditCode": $creditCode
    }
  )})];
  $batchChecksum := $n = 0 ? 0 : $sum0($map([0..$count($invoices)-1], function($i){
    ($i + 1) * ($invoices[$i].invoiceFingerprint + $round($invoices[$i].total * 100, 0))
  }));
  $auditChecksum := $count($auditTrail) = 0 ? 0 : $sum0($map([0..$count($auditTrail)-1], function($i){
    (($i + 1) * $auditTrail[$i].lineAudit) + ($auditTrail[$i].priorRequestedQty * 19) + $round($auditTrail[$i].priorFulfilledExtension * 100, 0)
  }));
  $skuList := $count($occ3) = 0 ? [] : [$sort($distinct($occ3.sku))];
  $skuLedger := $count($skuList) = 0 ? [] : [$map($skuList, function($sku){(
    $mine := $occ3[sku = $sku];
    $requested := $sum0($mine.qty);
    $fulfilled := $sum0($mine.fq);
    $gross := $round($sum0($mine.ext), 2);
    $rebate := $round($sum0($mine.reb), 2);
    $pool := $lookup($rules.skuRebates, $sku);
    $poolN := $exists($pool) ? $pool : 0;
    $remaining := $round($max([0, $poolN - $rebate]), 2);
    $taxableGross := $round($sum0($mine[taxable = true].ext), 2);
    $nonTaxableGross := $round($gross - $taxableGross, 2);
    $first := $mine[0];
    $last := $mine[$count($mine)-1];
    $lineCode := $sum0($map([0..$count($mine)-1], function($i){ ($i + 1) * $mine[$i].audit }));
    $ledgerCode := ($requested * 31) + ($fulfilled * 37) + (($requested - $fulfilled) * 41)
      + $round($gross * 100, 0) + ($round($rebate * 100, 0) * 3)
      + ($round($remaining * 100, 0) * 5) + $lineCode;
    {
      "sku": $sku,
      "occurrenceCount": $count($mine),
      "requestedQty": $requested,
      "fulfilledQty": $fulfilled,
      "backorderedQty": $requested - $fulfilled,
      "grossExtension": $gross,
      "rebateUsed": $rebate,
      "rebateRemaining": $remaining,
      "taxableFulfilledExtension": $taxableGross,
      "nonTaxableFulfilledExtension": $nonTaxableGross,
      "firstOccurrenceKey": $orders[$first.oi].id & "#" & ($first.li + 1) & "#" & $first.sku,
      "lastOccurrenceKey": $orders[$last.oi].id & "#" & ($last.li + 1) & "#" & $last.sku,
      "ledgerCode": $ledgerCode
    }
  )})];
  $skuLedgerChecksum := $count($skuLedger) = 0 ? 0 : $sum0($map([0..$count($skuLedger)-1], function($i){
    ($i + 1) * $skuLedger[$i].ledgerCode
  }));
  $creditLedgerChecksum := $count($creditLedger) = 0 ? 0 : $sum0($map([0..$count($creditLedger)-1], function($i){
    ($i + 1) * $creditLedger[$i].creditCode
  }));

  {
    "batchId": $states.input.batch.batchId,
    "invoices": $invoices,
    "summary": {
      "invoiceCount": $count($invoices),
      "requestedItemCount": $sum0($invoices.requestedItemCount),
      "fulfilledItemCount": $sum0($invoices.fulfilledItemCount),
      "backorderedItemCount": $sum0($invoices.backorderedItemCount),
      "subtotal": $round($sum0($invoices.subtotal), 2),
      "skuRebate": $round($sum0($invoices.skuRebate), 2),
      "discount": $round($sum0($invoices.discount), 2),
      "batchCredit": $round($sum0($invoices.batchCredit), 2),
      "tax": $round($sum0($invoices.tax), 2),
      "shipping": $round($sum0($invoices.shipping), 2),
      "grandTotal": $round($sum0($invoices.total), 2),
      "freeShippingCount": $count($invoices[shipping = 0])
    }
  }
)
JSONATA

python3 - "$WORK/expr.jsonata" "$WORK/definition.json" <<'PY'
import json, sys
expr = open(sys.argv[1]).read().strip()
definition = {
    "Comment": "Turn an order batch into reconciled invoices and a batch summary.",
    "QueryLanguage": "JSONata",
    "StartAt": "Compute",
    "States": {
        "Compute": {
            "Type": "Pass",
            "Assign": {"result": "{% " + expr + " %}"},
            "Next": "Emit",
        },
        "Emit": {
            "Type": "Pass",
            "Output": {
                "batchId": "{% $result.batchId %}",
                "invoices": "{% $result.invoices %}",
                "summary": "{% $result.summary %}",
            },
            "End": True,
        },
    },
}
json.dump(definition, open(sys.argv[2], "w"), indent=2)
PY

aws stepfunctions update-state-machine \
  --state-machine-arn "$SM_ARN" \
  --definition "file://$WORK/definition.json" \
  --role-arn "$ROLE_ARN" >/dev/null

sleep 3
LIVE_VER="$(aws stepfunctions publish-state-machine-version \
  --state-machine-arn "$SM_ARN" \
  --query stateMachineVersionArn --output text)"
[ -n "$LIVE_VER" ] && [ "$LIVE_VER" != "None" ] || { echo "failed to publish live repaired version" >&2; exit 1; }

python3 - "$WORK/definition.json" <<'PY'
import json, sys
path = sys.argv[1]
definition = json.load(open(path))
definition["Comment"] = "Audit-isolated copy of the repaired order batch settlement workflow."
json.dump(definition, open(path, "w"), indent=2)
PY

aws stepfunctions update-state-machine \
  --state-machine-arn "$SM_ARN" \
  --definition "file://$WORK/definition.json" \
  --role-arn "$ROLE_ARN" >/dev/null

sleep 3
AUDIT_VER="$(aws stepfunctions publish-state-machine-version \
  --state-machine-arn "$SM_ARN" \
  --query stateMachineVersionArn --output text)"
[ -n "$AUDIT_VER" ] && [ "$AUDIT_VER" != "None" ] || { echo "failed to publish audit repaired version" >&2; exit 1; }
[ "$AUDIT_VER" != "$LIVE_VER" ] || { echo "live and audit repaired versions must be distinct" >&2; exit 1; }

LIVE_ALIAS_ARN="$(aws stepfunctions list-state-machine-aliases \
  --state-machine-arn "$SM_ARN" \
  --query "stateMachineAliases[?contains(stateMachineAliasArn, ':live')].stateMachineAliasArn | [0]" \
  --output text)"
[ -n "$LIVE_ALIAS_ARN" ] && [ "$LIVE_ALIAS_ARN" != "None" ] || { echo "live alias not found" >&2; exit 1; }

AUDIT_ALIAS_ARN="$(aws stepfunctions list-state-machine-aliases \
  --state-machine-arn "$SM_ARN" \
  --query "stateMachineAliases[?contains(stateMachineAliasArn, ':audit')].stateMachineAliasArn | [0]" \
  --output text)"
[ -n "$AUDIT_ALIAS_ARN" ] && [ "$AUDIT_ALIAS_ARN" != "None" ] || { echo "audit alias not found" >&2; exit 1; }

aws stepfunctions update-state-machine-alias \
  --state-machine-alias-arn "$LIVE_ALIAS_ARN" \
  --routing-configuration "[{\"stateMachineVersionArn\":\"$LIVE_VER\",\"weight\":100}]" >/dev/null

aws stepfunctions update-state-machine-alias \
  --state-machine-alias-arn "$AUDIT_ALIAS_ARN" \
  --routing-configuration "[{\"stateMachineVersionArn\":\"$AUDIT_VER\",\"weight\":100}]" >/dev/null

echo "repaired batch-settlement transforms and repointed live to $LIVE_VER and audit to $AUDIT_VER"
