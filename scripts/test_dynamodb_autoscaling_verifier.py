"""Local identity-preservation tests for the DynamoDB autoscaling verifier."""
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


class VerificationFailure(AssertionError):
    pass


class FakeDynamoDB:
    def __init__(self, table_id):
        self.table_id = table_id

    def describe_table(self, **_kwargs):
        return {"Table": {
            "TableId": self.table_id,
            "BillingModeSummary": {"BillingMode": "PROVISIONED"},
        }}


class FakeApplicationAutoScaling:
    def __init__(self, state, policy_name, policy_arn):
        self.state = state
        self.policy_name = policy_name
        self.policy_arn = policy_arn

    def describe_scalable_targets(self, **_kwargs):
        return {"ScalableTargets": [{
            "ResourceId": self.state["resource_id"],
            "ScalableDimension": self.state["dimension"],
            "MinCapacity": 2,
            "MaxCapacity": 10,
        }]}

    def describe_scaling_policies(self, **_kwargs):
        return {"ScalingPolicies": [{
            "PolicyName": self.policy_name,
            "PolicyARN": self.policy_arn,
            "PolicyType": "TargetTrackingScaling",
        }]}


class FakeScheduler:
    def list_schedules(self, **_kwargs):
        return {"Schedules": []}


def run_verifier(
    *,
    table_id="table-original",
    policy_name="vera2-orders-wcu-track-test",
    policy_arn="arn:aws:autoscaling:us-east-1:123456789012:scalingPolicy:original",
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
        ),
        "scheduler": FakeScheduler(),
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
    exceptions.ClientError = type("ClientError", (Exception,), {})
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


if __name__ == "__main__":
    unittest.main()
