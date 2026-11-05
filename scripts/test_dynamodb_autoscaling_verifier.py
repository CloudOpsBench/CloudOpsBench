"""Local tests for the DynamoDB autoscaling verifier."""
import json
import runpy
import sys
from pathlib import Path
import types
import unittest
from unittest.mock import patch


CHECKER = (
    Path(__file__).resolve().parents[1]
    / "tasks/aws/restore-dynamodb-write-autoscaling/tests/check.py"
)
REGISTER_ARN = "arn:aws:scheduler:::aws-sdk:applicationautoscaling:registerScalableTarget"


class VerificationFailure(AssertionError):
    pass


class FakeClientError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code}}


class FakeDynamoDB:
    def __init__(self, table_id):
        self.table_id = table_id

    def describe_table(self, **_kwargs):
        return {"Table": {
            "TableId": self.table_id,
            "BillingModeSummary": {"BillingMode": "PROVISIONED"},
        }}


class FakeApplicationAutoScaling:
    def __init__(self, state, policy_name, policy_arn, policy_config, suspended_state):
        self.state = state
        self.policy_name = policy_name
        self.policy_arn = policy_arn
        self.policy_config = policy_config
        self.suspended_state = suspended_state

    def describe_scalable_targets(self, **_kwargs):
        return {"ScalableTargets": [{
            "ResourceId": self.state["resource_id"],
            "ScalableDimension": self.state["dimension"],
            "MinCapacity": 2,
            "MaxCapacity": 10,
            "SuspendedState": self.suspended_state,
        }]}

    def describe_scaling_policies(self, **_kwargs):
        return {"ScalingPolicies": [{
            "PolicyName": self.policy_name,
            "PolicyARN": self.policy_arn,
            "PolicyType": "TargetTrackingScaling",
            "TargetTrackingScalingPolicyConfiguration": self.policy_config,
        }]}


class FakeScheduler:
    def __init__(self, schedules):
        self.schedules = dict(schedules)

    @staticmethod
    def group(item):
        return "default" if isinstance(item, str) else item.get("GroupName", "default")

    def list_schedules(self, **_kwargs):
        return {"Schedules": [
            {"Name": name, "GroupName": self.group(item)} for name, item in self.schedules.items()
        ]}

    def get_schedule(self, Name, GroupName="default", **_kwargs):
        item = self.schedules[Name]
        if isinstance(item, str):
            raise FakeClientError(item)
        if self.group(item) != GroupName:
            raise FakeClientError("ResourceNotFoundException")
        return dict(item, Name=Name)


def schedule(min_capacity=None, max_capacity=None, *, resource_id="table/vera2-orders-test",
             dimension="dynamodb:table:WriteCapacityUnits", state="ENABLED", group="default",
             suspended=None):
    payload = {
        "ServiceNamespace": "dynamodb",
        "ResourceId": resource_id,
        "ScalableDimension": dimension,
    }
    if min_capacity is not None:
        payload["MinCapacity"] = min_capacity
    if max_capacity is not None:
        payload["MaxCapacity"] = max_capacity
    if suspended is not None:
        payload["SuspendedState"] = suspended
    return {"GroupName": group, "State": state,
            "Target": {"Arn": REGISTER_ARN, "Input": json.dumps(payload)}}


def run_verifier(
    *,
    table_id="table-original",
    policy_name="vera2-orders-wcu-track-test",
    policy_arn="arn:aws:autoscaling:us-east-1:123456789012:scalingPolicy:original",
    policy_config=None,
    suspended_state=None,
    schedules=None,
):
    seed = {
        "table": "vera2-orders-test",
        "table_id": "table-original",
        "resource_id": "table/vera2-orders-test",
        "dimension": "dynamodb:table:WriteCapacityUnits",
        "policy": "vera2-orders-wcu-track-test",
        "policy_arn": "arn:aws:autoscaling:us-east-1:123456789012:scalingPolicy:original",
        "want_min": 2,
        "want_max": 10,
    }
    ok = {"message": None}
    clients = {
        "dynamodb": FakeDynamoDB(table_id),
        "application-autoscaling": FakeApplicationAutoScaling(
            seed,
            policy_name,
            policy_arn,
            policy_config or {"TargetValue": 70.0},
            suspended_state or {
                "DynamicScalingInSuspended": False,
                "DynamicScalingOutSuspended": False,
                "ScheduledScalingSuspended": False,
            },
        ),
        "scheduler": FakeScheduler(schedules or {}),
    }

    checkkit = types.ModuleType("checkkit")
    checkkit.client = lambda name: clients[name]
    checkkit.seed = lambda: seed

    def require(condition, message):
        if not condition:
            raise VerificationFailure(message)

    checkkit.require = require
    checkkit.ok = lambda message: ok.__setitem__("message", message)

    botocore = types.ModuleType("botocore")
    exceptions = types.ModuleType("botocore.exceptions")
    exceptions.ClientError = FakeClientError
    botocore.exceptions = exceptions

    modules = {
        "botocore": botocore,
        "botocore.exceptions": exceptions,
        "checkkit": checkkit,
    }
    with patch.dict(sys.modules, modules):
        runpy.run_path(str(CHECKER), run_name="__main__")
    return ok["message"]


class DynamoDBAutoscalingVerifierTests(unittest.TestCase):
    def test_original_table_and_policy_pass(self):
        self.assertIn("auto-scale", run_verifier())

    def test_recreated_table_fails(self):
        with self.assertRaisesRegex(VerificationFailure, "table.*recreated"):
            run_verifier(table_id="table-replacement")

    def test_recreated_scaling_policy_fails(self):
        with self.assertRaisesRegex(VerificationFailure, "policy.*recreated"):
            run_verifier(
                policy_arn="arn:aws:autoscaling:us-east-1:123456789012:scalingPolicy:replacement",
            )

    def test_differently_named_scaling_policy_fails(self):
        with self.assertRaisesRegex(VerificationFailure, "policy.*replaced"):
            run_verifier(
                policy_name="replacement-policy",
                policy_arn="arn:aws:autoscaling:us-east-1:123456789012:scalingPolicy:replacement",
            )

    def test_policy_with_scale_in_disabled_fails(self):
        with self.assertRaisesRegex(VerificationFailure, "scale-in disabled"):
            run_verifier(policy_config={"TargetValue": 70.0, "DisableScaleIn": True})

    def test_suspended_dynamic_scaling_fails(self):
        with self.assertRaisesRegex(VerificationFailure, "dynamic scaling is suspended"):
            run_verifier(suspended_state={
                "DynamicScalingInSuspended": True,
                "DynamicScalingOutSuspended": False,
                "ScheduledScalingSuspended": False,
            })

    def test_suspended_scheduled_scaling_only_passes(self):
        self.assertIn("auto-scale", run_verifier(suspended_state={
            "DynamicScalingInSuspended": False,
            "DynamicScalingOutSuspended": False,
            "ScheduledScalingSuspended": True,
        }))

    def test_schedule_with_required_range_passes(self):
        self.assertIn("auto-scale", run_verifier(schedules={"pin": schedule(2, 10)}))

    def test_schedule_with_float_bounds_passes(self):
        self.assertIn("auto-scale", run_verifier(schedules={"pin": schedule(2.0, 10.0)}))

    def test_schedule_with_only_required_min_passes(self):
        self.assertIn("auto-scale", run_verifier(schedules={"pin": schedule(2)}))

    def test_schedule_with_only_required_max_passes(self):
        self.assertIn("auto-scale", run_verifier(schedules={"pin": schedule(None, 10)}))

    def test_schedule_that_raises_min_fails(self):
        with self.assertRaisesRegex(VerificationFailure, "MinCapacity=5/MaxCapacity=10"):
            run_verifier(schedules={"pin": schedule(5, 10)})

    def test_schedule_that_lowers_min_fails(self):
        with self.assertRaisesRegex(VerificationFailure, "MinCapacity=1/MaxCapacity=10"):
            run_verifier(schedules={"pin": schedule(1, 10)})

    def test_schedule_that_raises_max_fails(self):
        with self.assertRaisesRegex(VerificationFailure, "MinCapacity=2/MaxCapacity=11"):
            run_verifier(schedules={"pin": schedule(2, 11)})

    def test_schedule_with_one_wrong_bound_fails(self):
        with self.assertRaisesRegex(VerificationFailure, "MinCapacity=5/MaxCapacity=None"):
            run_verifier(schedules={"pin": schedule(5)})

    def test_schedule_that_suspends_dynamic_scaling_fails(self):
        pin = schedule(suspended={"DynamicScalingOutSuspended": True})
        with self.assertRaisesRegex(VerificationFailure, "dynamic scaling suspended"):
            run_verifier(schedules={"pin": pin})

    def test_schedule_for_read_capacity_is_ignored(self):
        read = schedule(2, 2, dimension="dynamodb:table:ReadCapacityUnits")
        self.assertIn("auto-scale", run_verifier(schedules={"read": read}))

    def test_schedule_with_escaped_resource_id_fails(self):
        pinned = schedule(2, 2)
        pinned["Target"]["Input"] = pinned["Target"]["Input"].replace("/", "\\/")
        with self.assertRaisesRegex(VerificationFailure, "MinCapacity=2/MaxCapacity=2"):
            run_verifier(schedules={"pin": pinned})

    def test_schedule_for_another_table_is_ignored(self):
        other = schedule(2, 2, resource_id="table/vera2-orders-test-copy")
        self.assertIn("auto-scale", run_verifier(schedules={"other": other}))

    def test_schedule_in_another_group_is_checked(self):
        with self.assertRaisesRegex(VerificationFailure, "MinCapacity=2/MaxCapacity=2"):
            run_verifier(schedules={"pin": schedule(2, 2, group="ops")})

    def test_disabled_schedule_is_ignored(self):
        self.assertIn("auto-scale", run_verifier(schedules={"pin": schedule(2, 2, state="DISABLED")}))

    def test_deleted_schedule_is_skipped(self):
        self.assertIn("auto-scale", run_verifier(schedules={"pin": "ResourceNotFoundException"}))

    def test_unreadable_schedule_fails(self):
        with self.assertRaisesRegex(VerificationFailure, "could not read schedules"):
            run_verifier(schedules={"pin": "AccessDeniedException"})


if __name__ == "__main__":
    unittest.main()
