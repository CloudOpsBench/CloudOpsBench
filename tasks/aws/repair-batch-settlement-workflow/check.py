import json
import math
import random
import time
import uuid

import checkkit as ck


def _round2(x):
    return round(x + 0.0, 2)


def compute(payload):
    batch = payload["batch"]
    rules = payload["rules"]
    inventory = rules.get("inventory", {})
    sku_rebates = rules.get("skuRebates", {})
    discounts = rules.get("discounts", {})
    tax_rate = rules["taxRate"]
    ship_threshold = rules["shippingThreshold"]
    ship_fee = rules["shippingFee"]
    batch_credit = rules["batchCredit"]
    orders = batch.get("orders", [])

    used_qty, used_ext = {}, {}
    order_calcs = []
    global_audit = []
    for oi, o in enumerate(orders):
        infos = []
        for li, ln in enumerate(o.get("lines", [])):
            sku, qty, price = ln["sku"], ln["qty"], ln["unitPrice"]
            taxable = bool(ln.get("taxable", False))
            prior_qty = used_qty.get(sku, 0)
            avail = max(0, inventory.get(sku, 0) - prior_qty)
            fq = min(qty, avail)
            used_qty[sku] = prior_qty + qty
            ext = fq * price
            prior_ext = used_ext.get(sku, 0)
            reb = min(ext, max(0, sku_rebates.get(sku, 0) - prior_ext))
            used_ext[sku] = prior_ext + ext
            audit = round(ext * 100) - round(reb * 100) + fq * 17 + qty * 5 + (11 if taxable else 0)
            infos.append({"ext": ext, "reb": reb, "qty": qty, "fq": fq, "taxable": taxable, "audit": audit})
            global_audit.append({
                "key": f"{o['id']}#{li + 1}#{sku}",
                "orderIndex": oi + 1,
                "lineIndex": li + 1,
                "sku": sku,
                "priorRequestedQty": prior_qty,
                "fulfilledQty": fq,
                "backorderedQty": qty - fq,
                "extension": _round2(ext),
                "priorFulfilledExtension": _round2(prior_ext),
                "lineRebate": _round2(reb),
                "lineAudit": audit,
            })

        requested = sum(l["qty"] for l in infos)
        fulfilled = sum(l["fq"] for l in infos)
        subtotal = sum(l["ext"] for l in infos)
        sku_rebate = sum(l["reb"] for l in infos)
        tier_rate = discounts.get(o.get("tier"), 0)
        coupon_rate = 0.20 if o.get("coupon") == "SAVE20" else 0
        discount_rate = min(0.35, tier_rate + coupon_rate)
        discount = (subtotal - sku_rebate) * discount_rate
        net = subtotal - sku_rebate - discount
        taxable_sum = sum((l["ext"] - l["reb"]) for l in infos if l["taxable"])
        taxable_net = taxable_sum * (1 - discount_rate)
        order_calcs.append({
            "o": o, "line_count": len(infos), "line_totals": [_round2(l["ext"]) for l in infos],
            "line_audit": [
                l["audit"] for l in infos
            ],
            "requested": requested, "fulfilled": fulfilled,
            "back": requested - fulfilled, "subtotal": subtotal, "sku_rebate": sku_rebate,
            "discount_rate": discount_rate, "discount": discount, "net": net, "taxable_net": taxable_net,
        })

    credit_min_net = rules["creditMinNet"]
    eligible = [i for i, c in enumerate(order_calcs) if c["net"] >= credit_min_net]
    sum_elig = sum(order_calcs[i]["net"] for i in eligible)
    available_cents = round(min(batch_credit, sum_elig) * 100) if eligible else 0
    allocated = [0] * len(order_calcs)
    exact = {}
    floor_cents = [0] * len(order_calcs)
    remainder_scaled = [0] * len(order_calcs)
    if sum_elig > 0 and available_cents > 0:
        exact = {i: available_cents * order_calcs[i]["net"] / sum_elig for i in eligible}
        for i in eligible:
            floor_cents[i] = math.floor(exact[i])
            allocated[i] = floor_cents[i]
            remainder_scaled[i] = round((exact[i] - floor_cents[i]) * 1000000)
        remaining = available_cents - sum(allocated[i] for i in eligible)
        order_idx = sorted(eligible, key=lambda i: (-(exact[i] - math.floor(exact[i])), i))
        for k in range(remaining):
            allocated[order_idx[k]] += 1

    invoices = []
    credit_ledger = []
    for idx, c in enumerate(order_calcs):
        credit = allocated[idx] / 100
        net = c["net"]
        taxable_base = 0 if net == 0 else c["taxable_net"] * (net - credit) / net
        tax = taxable_base * tax_rate
        shipping = 0 if (net - credit) >= ship_threshold else ship_fee
        total = (net - credit) + tax + shipping
        fingerprint = (
            sum((j + 1) * v for j, v in enumerate(c["line_audit"]))
            + c["requested"] * 101 + c["fulfilled"] * 103 + c["back"] * 107
        )
        invoices.append({
            "id": c["o"]["id"], "tier": c["o"].get("tier"), "lineCount": c["line_count"],
            "lineTotals": c["line_totals"], "lineAudit": c["line_audit"],
            "requestedItemCount": c["requested"], "fulfilledItemCount": c["fulfilled"],
            "backorderedItemCount": c["back"], "subtotal": _round2(c["subtotal"]),
            "skuRebate": _round2(c["sku_rebate"]), "discountRate": c["discount_rate"],
            "discount": _round2(c["discount"]), "batchCredit": _round2(credit),
            "taxableBase": _round2(taxable_base), "tax": _round2(tax),
            "shipping": _round2(shipping), "total": _round2(total),
            "invoiceFingerprint": fingerprint,
        })
        eligible_flag = idx in eligible
        ratio_bps = 0 if net == 0 else round((net - credit) * 10000 / net)
        bonus_cent = allocated[idx] - floor_cents[idx]
        credit_code = (
            (idx + 1) * 97 + (89 if eligible_flag else 0)
            + round(net * 100) * 3 + floor_cents[idx] * 5 + bonus_cent * 7
            + allocated[idx] * 11 + round(taxable_base * 100) * 13
            + ratio_bps * 17 + remainder_scaled[idx]
        )
        credit_ledger.append({
            "orderId": c["o"]["id"],
            "inputIndex": idx + 1,
            "eligible": eligible_flag,
            "netBeforeCredit": _round2(net),
            "floorCreditCents": floor_cents[idx],
            "remainderMicros": remainder_scaled[idx],
            "receivedRemainderCent": bonus_cent,
            "creditCents": allocated[idx],
            "taxableProrationBps": ratio_bps,
            "creditCode": credit_code,
        })

    summary = {
        "invoiceCount": len(invoices),
        "requestedItemCount": sum(i["requestedItemCount"] for i in invoices),
        "fulfilledItemCount": sum(i["fulfilledItemCount"] for i in invoices),
        "backorderedItemCount": sum(i["backorderedItemCount"] for i in invoices),
        "subtotal": _round2(sum(i["subtotal"] for i in invoices)),
        "skuRebate": _round2(sum(i["skuRebate"] for i in invoices)),
        "discount": _round2(sum(i["discount"] for i in invoices)),
        "batchCredit": _round2(sum(i["batchCredit"] for i in invoices)),
        "tax": _round2(sum(i["tax"] for i in invoices)),
        "shipping": _round2(sum(i["shipping"] for i in invoices)),
        "grandTotal": _round2(sum(i["total"] for i in invoices)),
        "freeShippingCount": sum(1 for i in invoices if i["shipping"] == 0),
        "batchChecksum": sum((i + 1) * (inv["invoiceFingerprint"] + round(inv["total"] * 100))
                             for i, inv in enumerate(invoices)),
        "auditChecksum": sum((i + 1) * a["lineAudit"] + a["priorRequestedQty"] * 19
                             + round(a["priorFulfilledExtension"] * 100)
                             for i, a in enumerate(global_audit)),
    }
    sku_ledger = []
    for sku in sorted({a["sku"] for a in global_audit}):
        rows = [a for a in global_audit if a["sku"] == sku]
        requested = sum(r["fulfilledQty"] + r["backorderedQty"] for r in rows)
        fulfilled = sum(r["fulfilledQty"] for r in rows)
        gross = _round2(sum(r["extension"] for r in rows))
        rebate = _round2(sum(r["lineRebate"] for r in rows))
        taxable_gross = _round2(sum(r["extension"] for r in rows if any(
            o["id"] == r["key"].split("#")[0]
            and o.get("lines", [])[r["lineIndex"] - 1].get("taxable", False)
            for o in orders
        )))
        non_taxable_gross = _round2(gross - taxable_gross)
        remaining = _round2(max(0, sku_rebates.get(sku, 0) - rebate))
        code = (
            requested * 31 + fulfilled * 37 + (requested - fulfilled) * 41
            + round(gross * 100) + round(rebate * 100) * 3
            + round(remaining * 100) * 5
            + sum((i + 1) * r["lineAudit"] for i, r in enumerate(rows))
        )
        sku_ledger.append({
            "sku": sku,
            "occurrenceCount": len(rows),
            "requestedQty": requested,
            "fulfilledQty": fulfilled,
            "backorderedQty": requested - fulfilled,
            "grossExtension": gross,
            "rebateUsed": rebate,
            "rebateRemaining": remaining,
            "taxableFulfilledExtension": taxable_gross,
            "nonTaxableFulfilledExtension": non_taxable_gross,
            "firstOccurrenceKey": rows[0]["key"],
            "lastOccurrenceKey": rows[-1]["key"],
            "ledgerCode": code,
        })
    summary["skuLedgerChecksum"] = sum((i + 1) * row["ledgerCode"] for i, row in enumerate(sku_ledger))
    summary["creditLedgerChecksum"] = sum((i + 1) * row["creditCode"] for i, row in enumerate(credit_ledger))
    invoice_contract = [
        {k: invoice[k] for k in (
            "id", "tier", "lineCount", "lineTotals",
            "requestedItemCount", "fulfilledItemCount", "backorderedItemCount",
            "subtotal", "skuRebate", "discountRate", "discount", "batchCredit",
            "taxableBase", "tax", "shipping", "total"
        )}
        for invoice in invoices
    ]
    summary_contract = {k: summary[k] for k in (
        "invoiceCount", "requestedItemCount", "fulfilledItemCount",
        "backorderedItemCount", "subtotal", "skuRebate", "discount",
        "batchCredit", "tax", "shipping", "grandTotal", "freeShippingCount"
    )}
    return {"batchId": batch.get("batchId"),
            "invoices": invoice_contract, "summary": summary_contract}


def cmp(exp, act, path, tol):
    if isinstance(exp, bool) or isinstance(act, bool):
        ck.require(exp == act, f"{path}: expected {exp!r}, got {act!r}")
        return
    if isinstance(exp, int) and not isinstance(exp, bool):
        ck.require(isinstance(act, (int, float)) and act == exp, f"{path}: expected {exp}, got {act!r}")
        return
    if isinstance(exp, float):
        ck.require(isinstance(act, (int, float)) and abs(act - exp) <= tol,
                   f"{path}: expected {exp} (+/-{tol}), got {act!r}")
        return
    if isinstance(exp, list):
        ck.require(isinstance(act, list) and len(act) == len(exp),
                   f"{path}: expected list len {len(exp)}, got {act!r}")
        for i, (e, a) in enumerate(zip(exp, act)):
            cmp(e, a, f"{path}[{i}]", tol)
        return
    if isinstance(exp, dict):
        ck.require(isinstance(act, dict) and set(act.keys()) == set(exp.keys()),
                   f"{path}: keys mismatch, expected {sorted(exp.keys())}, got {sorted(act.keys()) if isinstance(act, dict) else act!r}")
        for k in exp:
            cmp(exp[k], act[k], f"{path}.{k}", tol)
        return
    ck.require(exp == act, f"{path}: expected {exp!r}, got {act!r}")


seed = ck.seed()
seed_version_arn = seed["seed_version_arn"]
sfn = ck.client("stepfunctions")
alias_arns = {
    "live": seed["alias_arn"],
    "audit": seed["audit_alias_arn"],
}

def alias_target(alias_to_check, alias_name):
    alias = sfn.describe_state_machine_alias(stateMachineAliasArn=alias_to_check)
    routing = alias.get("routingConfiguration", [])
    ck.require(len(routing) >= 1, f"the {alias_name} alias must have a routing configuration")
    ck.require(
        len(routing) == 1 and routing[0].get("weight") == 100,
        f"the {alias_name} alias must route 100% of traffic to exactly one repaired version",
    )
    target = routing[0]["stateMachineVersionArn"]
    ck.require(
        target != seed_version_arn,
        f"the {alias_name} alias must be repointed away from the seeded buggy version to the repaired one",
    )
    return target


targets = {name: alias_target(arn, name) for name, arn in alias_arns.items()}
target_version = targets["live"]
ck.require(
    targets["audit"] != target_version,
    "the live and audit aliases must route to two distinct repaired version ARNs",
)

desc = sfn.describe_state_machine(stateMachineArn=target_version)
audit_desc = sfn.describe_state_machine(stateMachineArn=targets["audit"])
ck.require(
    desc.get("roleArn") == seed["role_arn"],
    "the live repaired version must keep the original batch-settlement execution role",
)
ck.require(
    audit_desc.get("roleArn") == seed["role_arn"],
    "the audit repaired version must keep the original batch-settlement execution role",
)
definition = json.loads(desc["definition"])
audit_definition = json.loads(audit_desc["definition"])
ck.require(
    definition.get("QueryLanguage") == "JSONata",
    "the live repaired state machine must keep the JSONata query language",
)
ck.require(
    audit_definition.get("QueryLanguage") == "JSONata",
    "the audit repaired state machine must keep the JSONata query language",
)
for label, current_definition in (("live", definition), ("audit", audit_definition)):
    states = current_definition.get("States", {})
    ck.require(
        isinstance(states, dict) and len(states) == 2,
        f"{label}: the repaired workflow must preserve the two-state design",
    )
    start_at = current_definition.get("StartAt")
    start_state = states.get(start_at, {})
    terminal_states = [state for state in states.values() if state.get("End") is True]
    ck.require(
        start_at in states
        and start_state.get("Type") == "Pass"
        and isinstance(start_state.get("Assign"), dict)
        and "result" in start_state.get("Assign", {})
        and start_state.get("Next") in states,
        f"{label}: the first Pass state must assign result and transition to the terminal state",
    )
    ck.require(
        len(terminal_states) == 1
        and terminal_states[0].get("Type") == "Pass"
        and isinstance(terminal_states[0].get("Output"), dict),
        f"{label}: the second Pass state must emit the final Output object",
    )
for label, current_definition in (("live", definition), ("audit", audit_definition)):
    for state_name, state in current_definition.get("States", {}).items():
        ck.require("Resource" not in state, f"{label}.{state_name}: the repaired workflow must not invoke Lambda or other compute")


def run_execution(payload, label, alias_to_use, alias_name):
    resp = sfn.start_execution(
        stateMachineArn=alias_to_use, name=f"grader-{uuid.uuid4().hex[:8]}", input=json.dumps(payload)
    )
    arn = resp["executionArn"]
    for _ in range(30):
        d = sfn.describe_execution(executionArn=arn)
        if d["status"] == "SUCCEEDED":
            return json.loads(d["output"])
        if d["status"] in ("FAILED", "TIMED_OUT", "ABORTED"):
            ck.fail(f"{label} via {alias_name}: execution failed with status {d['status']}: {d.get('error', '')} {d.get('cause', '')}")
        time.sleep(2)
    ck.fail(f"{label} via {alias_name}: execution did not complete in time")


def check_case(payload, label, alias_to_use, alias_name):
    out = run_execution(payload, label, alias_to_use, alias_name)
    exp = compute(payload)
    label = f"{label} via {alias_name}"
    ck.require(set(out.keys()) == set(exp.keys()),
               f"{label}: top-level keys mismatch, expected {sorted(exp.keys())}, got {sorted(out.keys())}")
    ck.require(out.get("batchId") == exp["batchId"], f"{label}: batchId mismatch")
    ck.require(isinstance(out.get("invoices"), list) and len(out["invoices"]) == len(exp["invoices"]),
              f"{label}: invoices must be a list of length {len(exp['invoices'])}")
    for i, (e, a) in enumerate(zip(exp["invoices"], out["invoices"])):
        cmp(e, a, f"{label}.invoices[{i}]", 0.004)
    cmp(exp["summary"], out.get("summary"), f"{label}.summary", 0.004)


CRAFTED = [
    ("single order, multi-line within-order reservation + rebate + coupon", {
        "batch": {"batchId": "S1", "orders": [
            {"id": "O1", "tier": "gold", "coupon": "SAVE20",
             "lines": [{"sku": "A", "qty": 5, "unitPrice": 10.0, "taxable": True},
                       {"sku": "A", "qty": 4, "unitPrice": 10.0, "taxable": False}]},
        ]},
        "rules": {"inventory": {"A": 6}, "skuRebates": {"A": 45.0}, "discounts": {"gold": 0.1},
                  "taxRate": 0.08, "shippingThreshold": 50, "shippingFee": 7.5, "batchCredit": 5.0,
                  "creditMinNet": 0}}),
    ("empty batch", {"batch": {"batchId": "E0", "orders": []},
                     "rules": {"inventory": {"A": 5}, "skuRebates": {"A": 10}, "discounts": {"gold": 0.1},
                               "taxRate": 0.08, "shippingThreshold": 50, "shippingFee": 5, "batchCredit": 10,
                               "creditMinNet": 0}}),
    ("fully backordered order still pays shipping + credit ineligible", {
        "batch": {"batchId": "BK1", "orders": [
            {"id": "O1", "tier": "gold", "coupon": "NONE",
             "lines": [{"sku": "A", "qty": 3, "unitPrice": 20.0, "taxable": True}]},
            {"id": "O2", "tier": "silver", "coupon": "NONE",
             "lines": [{"sku": "A", "qty": 4, "unitPrice": 20.0, "taxable": True}]},
        ]},
        "rules": {"inventory": {"A": 3}, "skuRebates": {"A": 10.0}, "discounts": {"gold": 0.1, "silver": 0.15},
                  "taxRate": 0.08, "shippingThreshold": 50, "shippingFee": 6.0, "batchCredit": 5.0,
                  "creditMinNet": 10}}),
    ("cross-order reservation + cumulative rebate + additive discount + eligible credit", {
        "batch": {"batchId": "R1", "orders": [
            {"id": "O1", "tier": "silver", "coupon": "NONE",
             "lines": [{"sku": "A", "qty": 6, "unitPrice": 10.0, "taxable": True},
                       {"sku": "B", "qty": 2, "unitPrice": 20.0, "taxable": False}]},
            {"id": "O2", "tier": "bronze", "coupon": "SAVE20",
             "lines": [{"sku": "A", "qty": 5, "unitPrice": 10.0, "taxable": True},
                       {"sku": "C", "qty": 3, "unitPrice": 8.0, "taxable": True}]},
            {"id": "O3", "tier": "gold", "coupon": "NONE",
             "lines": [{"sku": "A", "qty": 4, "unitPrice": 10.0, "taxable": True}]},
        ]},
        "rules": {"inventory": {"A": 8, "B": 10, "C": 2}, "skuRebates": {"A": 55.0, "C": 100.0},
                  "discounts": {"gold": 0.1, "silver": 0.15, "bronze": 0.05},
                  "taxRate": 0.0725, "shippingThreshold": 60, "shippingFee": 7.5, "batchCredit": 12.34,
                  "creditMinNet": 20}}),
    ("additive discount cap + absent sku + unknown tier", {
        "batch": {"batchId": "A1", "orders": [
            {"id": "O1", "tier": "gold", "coupon": "SAVE20",
             "lines": [{"sku": "Z", "qty": 3, "unitPrice": 15.0, "taxable": True},
                       {"sku": "A", "qty": 2, "unitPrice": 9.5, "taxable": False}]},
            {"id": "O2", "tier": "plat", "coupon": "SAVE20",
             "lines": [{"sku": "A", "qty": 4, "unitPrice": 30.0, "taxable": True}]},
        ]},
        "rules": {"inventory": {"A": 10}, "skuRebates": {"A": 4.0}, "discounts": {"gold": 0.1, "plat": 0.25},
                  "taxRate": 0.05, "shippingThreshold": 100, "shippingFee": 9.99, "batchCredit": 3.0,
                  "creditMinNet": 0}}),
]

for idx, (label, payload) in enumerate(CRAFTED):
    alias_name = "audit" if idx % 2 else "live"
    alias_to_use = alias_arns[alias_name]
    check_case(payload, label, alias_to_use, alias_name)

random.seed(1337)
SKUS = ["A", "B", "C", "D", "Z"]
TIERS = ["gold", "silver", "bronze", "plat", "ghost"]
for t in range(6):
    inventory = {s: random.randint(0, 20) for s in SKUS if random.random() < 0.85}
    sku_rebates = {s: round(random.uniform(0, 60), 2) for s in SKUS if random.random() < 0.6}
    discounts = {tr: random.choice([0, 0.05, 0.1, 0.15, 0.25]) for tr in TIERS if random.random() < 0.8}
    orders = []
    for i in range(1 if t == 0 else random.randint(1, 4)):
        lines = [{"sku": random.choice(SKUS), "qty": random.randint(1, 8),
                  "unitPrice": round(random.uniform(1, 90), 2), "taxable": random.random() < 0.6}
                 for _ in range(random.randint(1, 3))]
        orders.append({"id": f"O{i + 1}", "tier": random.choice(TIERS),
                       "coupon": "SAVE20" if random.random() < 0.4 else "NONE", "lines": lines})
    payload = {
        "batch": {"batchId": f"B{random.randint(1, 999)}", "orders": orders},
        "rules": {"inventory": inventory, "skuRebates": sku_rebates, "discounts": discounts,
                  "taxRate": random.choice([0.05, 0.0725, 0.08, 0.095]),
                  "shippingThreshold": random.choice([50, 75, 100]),
                  "shippingFee": random.choice([5, 7.5, 9.99]),
                  "batchCredit": round(random.uniform(0, 40), 2),
                  "creditMinNet": random.choice([0, 20, 40, 60])},
    }
    alias_name = "audit" if t % 2 else "live"
    alias_to_use = alias_arns[alias_name]
    check_case(payload, f"random batch #{t + 1}", alias_to_use, alias_name)

ck.ok("batch-settlement produces correct reconciled invoices and summary across crafted and randomized batches")
