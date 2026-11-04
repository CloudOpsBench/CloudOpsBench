"""Local identity-preservation tests for the urgent-order alert verifier."""
import os
import runpy
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
import types
import unittest
from unittest.mock import patch


CHECKER = (
    Path(__file__).resolve().parents[1]
    / "tasks/aws/repair-urgent-order-alert-delivery/tests/check.py"
)
SETUP = (
    Path(__file__).resolve().parents[1]
    / "tasks/aws/repair-urgent-order-alert-delivery/environment/lifecycle/setup.sh"
)


class VerificationFailure(AssertionError):
    pass


class FakeSNS:
    def __init__(self, state, subscription_arn):
        self.state = state
        self.subscription_arn = subscription_arn

    def get_topic_attributes(self, **_kwargs):
        return {"Attributes": {}}

    def list_subscriptions_by_topic(self, **_kwargs):
        return {"Subscriptions": [{
            "SubscriptionArn": self.subscription_arn,
            "Protocol": "sqs",
            "Endpoint": self.state["seed"]["queue_arn"],
        }]}

    def publish(self, **kwargs):
        self.state["last_body"] = kwargs["Message"]
        return {"MessageId": "probe"}


class FakeSQS:
    def __init__(self, state, created_timestamp):
        self.state = state
        self.created_timestamp = created_timestamp

    def get_queue_attributes(self, **_kwargs):
        return {"Attributes": {
            "QueueArn": self.state["seed"]["queue_arn"],
            "CreatedTimestamp": self.created_timestamp,
        }}

    def receive_message(self, **_kwargs):
        body = self.state.pop("last_body", None)
        if body is None:
            return {}
        return {"Messages": [{"Body": body, "ReceiptHandle": "receipt"}]}

    def delete_message(self, **_kwargs):
        return {}


def run_verifier(*, queue_created_timestamp="1000", subscription_arn="sub-original"):
    seed = {
        "topic_arn": "arn:aws:sns:us-east-1:123456789012:fulfillment-alerts-topic-test",
        "queue_url": "https://sqs.us-east-1.amazonaws.com/123456789012/oncall-escalation-queue-test",
        "queue_arn": "arn:aws:sqs:us-east-1:123456789012:oncall-escalation-queue-test",
        "queue_created_timestamp": "1000",
        "subscription_arn": "sub-original",
    }
    state = {"seed": seed, "ok": None}

    sns = FakeSNS(state, subscription_arn)
    sqs = FakeSQS(state, queue_created_timestamp)
    checkkit = types.ModuleType("checkkit")
    checkkit.client = lambda name: {"sns": sns, "sqs": sqs}[name]
    checkkit.seed = lambda: seed

    def fail(message):
        raise VerificationFailure(message)

    def require(condition, message):
        if not condition:
            raise VerificationFailure(message)

    checkkit.fail = fail
    checkkit.require = require
    checkkit.ok = lambda message: state.__setitem__("ok", message)

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
    return state["ok"]


class UrgentOrderAlertVerifierTests(unittest.TestCase):
    def test_setup_rejects_none_queue_identity_attributes(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake_bin = Path(tmp) / "bin"
            fake_bin.mkdir()
            fake_aws = fake_bin / "aws"
            fake_aws.write_text("""#!/usr/bin/env bash
case "$*" in
  "sts get-caller-identity --query Account --output text") echo 123456789012 ;;
  "sns create-topic"*) echo arn:aws:sns:us-east-1:123456789012:test-topic ;;
  "sqs create-queue"*) echo https://sqs.us-east-1.amazonaws.com/123456789012/test-queue ;;
  "sqs get-queue-attributes"*) printf 'None\\tNone\\n' ;;
  *) echo "unexpected aws call: $*" >&2; exit 1 ;;
esac
""")
            fake_aws.chmod(fake_aws.stat().st_mode | stat.S_IXUSR)
            env = os.environ.copy()
            env["PATH"] = str(fake_bin) + os.pathsep + env["PATH"]

            result = subprocess.run(
                ["bash", str(SETUP)],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
            )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("queue identity attributes were not returned", result.stderr)
        self.assertNotIn("unexpected aws call", result.stderr)

    def test_original_resources_pass(self):
        self.assertIn("fully repaired", run_verifier())

    def test_recreated_queue_fails(self):
        with self.assertRaisesRegex(VerificationFailure, "deleted and recreated"):
            run_verifier(queue_created_timestamp="2000")

    def test_recreated_topic_or_subscription_fails(self):
        with self.assertRaisesRegex(VerificationFailure, "subscription was deleted"):
            run_verifier(subscription_arn="sub-replacement")


if __name__ == "__main__":
    unittest.main()
