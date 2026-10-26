#!/usr/bin/env bash
# Creates the batch-settlement Step Functions state machine with a faulty JSONata
# transform, publishes it as a version, and points the `live` and `audit` aliases
# at that version. Records the ARNs in seed_state.json.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
SM_NAME="batch-settlement"
ROLE_NAME="batch-settlement-sfn-role"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/trust.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Principal": {"Service": "states.amazonaws.com"}, "Action": "sts:AssumeRole"}
  ]
}
JSON
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document "file://$WORK/trust.json" \
  --tags Key=Project,Value=starter-demo >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"

cat > "$WORK/expr.jsonata" <<'JSONATA'
(
  $rules := $states.input.rules;
  $orders := $states.input.batch.orders;
  $n := $count($orders);
  $sum0 := function($x){ $exists($x) ? $sum($x) : 0 };

  $calc := $n = 0 ? [] : [$map([0..$n-1], function($oi){(
    $o := $orders[$oi];
    $lines := $o.lines;
    $exts := $lines.(qty * unitPrice);
    $subtotal := $sum0($exts);
    $skuRebate := $sum0($lines.($min([qty * unitPrice, $lookup($rules.skuRebates, sku)])));
    $tr := $lookup($rules.discounts, $o.tier);
    $discountRate := $exists($tr) ? $tr : 0;
    $discount := ($subtotal - $skuRebate) * $discountRate;
    $net := $subtotal - $skuRebate - $discount;
    {
      "id": $o.id, "tier": $o.tier, "lineCount": $count($lines),
      "requested": $sum0($lines.qty), "fulfilled": $sum0($lines.qty),
      "subtotal": $subtotal, "skuRebate": $skuRebate, "discountRate": $discountRate,
      "discount": $discount, "net": $net,
      "taxableNet": $sum0($lines[taxable = true].(qty * unitPrice))
    }
  )})];

  $sumNets := $sum0($calc.net);
  $invoices := $n = 0 ? [] : [$map([0..$n-1], function($i){(
    $c := $calc[$i];
    $credit := $sumNets > 0 ? $round($rules.batchCredit * $c.net / $sumNets, 2) : 0;
    $tax := $c.taxableNet * $rules.taxRate;
    $shipping := $c.net >= $rules.shippingThreshold ? 0 : $rules.shippingFee;
    $total := $c.net - $credit + $tax + $shipping;
    {
      "id": $c.id, "tier": $c.tier, "lineCount": $c.lineCount,
      "lineTotals": $orders[$i].lines.($round(qty * unitPrice, 2)),
      "requestedItemCount": $c.requested, "fulfilledItemCount": $c.fulfilled,
      "backorderedItemCount": $c.requested - $c.fulfilled,
      "subtotal": $round($c.subtotal, 2), "skuRebate": $round($c.skuRebate, 2),
      "discountRate": $c.discountRate, "discount": $round($c.discount, 2),
      "batchCredit": $round($credit, 2), "taxableBase": $round($c.taxableNet, 2),
      "tax": $round($tax, 2), "shipping": $round($shipping, 2), "total": $round($total, 2)
    }
  )})];

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

SM_ARN=""
for attempt in $(seq 1 25); do
  if SM_ARN="$(aws stepfunctions create-state-machine \
        --name "$SM_NAME" \
        --definition "file://$WORK/definition.json" \
        --role-arn "$ROLE_ARN" \
        --type STANDARD \
        --tags key=Project,value=starter-demo \
        --query stateMachineArn --output text 2>"$WORK/smerr")"; then
    break
  fi
  if grep -qiE "AccessDenied|not authorized|cannot be assumed|invalid|role" "$WORK/smerr" && [ "$attempt" -lt 25 ]; then
    sleep 6; continue
  fi
  cat "$WORK/smerr" >&2; exit 1
done
[ -n "$SM_ARN" ] && [ "$SM_ARN" != "None" ] || { echo "failed to create state machine" >&2; exit 1; }

V1_ARN=""
for attempt in $(seq 1 20); do
  if V1_ARN="$(aws stepfunctions publish-state-machine-version \
        --state-machine-arn "$SM_ARN" \
        --query stateMachineVersionArn --output text 2>"$WORK/verr")"; then
    break
  fi
  [ "$attempt" -lt 20 ] && { sleep 4; continue; }
  cat "$WORK/verr" >&2; exit 1
done
[ -n "$V1_ARN" ] && [ "$V1_ARN" != "None" ] || { echo "failed to publish version" >&2; exit 1; }

LIVE_ALIAS_ARN=""
for attempt in $(seq 1 20); do
  if LIVE_ALIAS_ARN="$(aws stepfunctions create-state-machine-alias \
        --name live \
        --routing-configuration "[{\"stateMachineVersionArn\":\"$V1_ARN\",\"weight\":100}]" \
        --query stateMachineAliasArn --output text 2>"$WORK/aerr")"; then
    break
  fi
  [ "$attempt" -lt 20 ] && { sleep 4; continue; }
  cat "$WORK/aerr" >&2; exit 1
done
[ -n "$LIVE_ALIAS_ARN" ] && [ "$LIVE_ALIAS_ARN" != "None" ] || { echo "failed to create live alias" >&2; exit 1; }

AUDIT_ALIAS_ARN=""
for attempt in $(seq 1 20); do
  if AUDIT_ALIAS_ARN="$(aws stepfunctions create-state-machine-alias \
        --name audit \
        --routing-configuration "[{\"stateMachineVersionArn\":\"$V1_ARN\",\"weight\":100}]" \
        --query stateMachineAliasArn --output text 2>"$WORK/auditerr")"; then
    break
  fi
  [ "$attempt" -lt 20 ] && { sleep 4; continue; }
  cat "$WORK/auditerr" >&2; exit 1
done
[ -n "$AUDIT_ALIAS_ARN" ] && [ "$AUDIT_ALIAS_ARN" != "None" ] || { echo "failed to create audit alias" >&2; exit 1; }

python3 - "$SM_ARN" "$SM_NAME" "$ROLE_ARN" "$ROLE_NAME" "$LIVE_ALIAS_ARN" "$AUDIT_ALIAS_ARN" "$V1_ARN" <<'PY'
import json, sys
arn, name, role_arn, role_name, alias_arn, audit_alias_arn, v1_arn = sys.argv[1:8]
json.dump({"state_machine_arn": arn, "state_machine_name": name,
           "role_arn": role_arn, "role_name": role_name,
           "alias_arn": alias_arn, "audit_alias_arn": audit_alias_arn,
           "seed_version_arn": v1_arn},
          open("seed_state.json", "w"), indent=2)
PY
echo "seeded: $SM_ARN with aliases live,audit -> $V1_ARN (buggy JSONata transforms)"
