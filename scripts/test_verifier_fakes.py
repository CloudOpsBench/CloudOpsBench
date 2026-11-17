"""Tests for the offline grader fakes in verifier_fakes.py."""
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import verifier_fakes as vf


class VerifierFakesTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tasks = Path(tmp.name)
        patcher = patch.object(vf, "TASKS", self.tasks)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, relative, source):
        path = self.tasks / "aws/demo" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)

    def grade(self, source, **kwargs):
        self.write("tests/check.py", source)
        return vf.run_grader("aws/demo", **kwargs)

    def test_exit_codes_map_like_the_runner(self):
        cases = [
            ("x = 1\n", vf.PASS),
            ("raise SystemExit(0)\n", vf.PASS),
            ("raise SystemExit(1)\n", vf.FAIL),
            ("raise SystemExit('setup did not run')\n", vf.FAIL),
            ("raise SystemExit(3)\n", vf.ERROR),
            ("raise RuntimeError('boom')\n", vf.ERROR),
        ]
        for source, verdict in cases:
            with self.subTest(source=source):
                self.assertEqual(verdict, self.grade(source).verdict)
        self.assertIn("setup did not run", self.grade(cases[3][0]).stderr)
        self.assertIsInstance(self.grade(cases[5][0]).error, RuntimeError)

    def test_checkkit_failure_cannot_be_swallowed(self):
        result = self.grade(
            "import checkkit as ck\n"
            "try:\n    ck.require(False, 'still public')\nexcept Exception:\n    pass\n"
            "ck.ok('done')\n")
        self.assertEqual(vf.FAIL, result.verdict)
        self.assertIn("still public", result.stderr)

    def test_undeclared_client_call_fails_even_if_swallowed(self):
        source = ("import checkkit as ck\n"
                  "try:\n    ck.client('s3').head_bucket(Bucket='b')\nexcept Exception:\n    pass\n")
        with self.assertRaisesRegex(AssertionError, r"s3\.head_bucket"):
            self.grade(source, clients={"s3": vf.StrictClient("s3")})
        with self.assertRaisesRegex(AssertionError, r"client\('sns'"):
            self.grade("import checkkit as ck\nck.client('sns')\n")

    def test_undeclared_aws_call_fails_even_if_ignored(self):
        source = ("import subprocess\n"
                  "r = subprocess.run(['aws', 's3api', 'head-bucket', '--bucket', 'b'],\n"
                  "                   capture_output=True)\n"
                  "print('gone' if r.returncode else 'present')\n")
        with self.assertRaisesRegex(AssertionError, "aws s3api head-bucket --bucket b"):
            self.grade(source)

    def test_clients_answer_by_region_with_errors_and_pages(self):
        west = vf.StrictClient(
            "s3", list_buckets={"Buckets": [{"Name": "west"}]},
            head_bucket=vf.client_error("404", "HeadBucket"),
            list_objects_v2=[{"Contents": [{"Key": "a"}]}, {"Contents": [{"Key": "b"}]}])
        result = self.grade(
            "import boto3, botocore\n"
            "s3 = boto3.client('s3', region_name='us-west-2')\n"
            "assert s3.list_buckets()['Buckets'] == [{'Name': 'west'}]\n"
            "try:\n    s3.head_bucket(Bucket='gone')\n"
            "except botocore.exceptions.ClientError as e:\n"
            "    assert e.response['Error']['Code'] == '404'\nelse:\n    raise SystemExit(1)\n"
            "pages = s3.get_paginator('list_objects_v2').paginate(Bucket='west')\n"
            "assert [p['Contents'][0]['Key'] for p in pages] == ['a', 'b']\n",
            clients={("s3", "us-west-2"): west, "s3": vf.StrictClient("s3")})
        self.assertEqual(vf.PASS, result.verdict, result.stderr)
        self.assertEqual(["list_buckets", "head_bucket", "list_objects_v2"],
                         [name for name, _ in west.calls])

    def test_aws_rules_match_arguments_and_environment(self):
        result = self.grade(
            "import json, os, subprocess\n"
            "def aws(*args, key=None):\n"
            "    env = dict(os.environ, **({'AWS_ACCESS_KEY_ID': key} if key else {}))\n"
            "    return subprocess.run(['aws', *args], capture_output=True, text=True, env=env)\n"
            "creds = json.loads(aws('sts', 'assume-role', '--role-arn', 'r1').stdout)\n"
            "assert creds['Credentials']['AccessKeyId'] == 'k1'\n"
            "assert aws('kinesis', 'put-record', key='k1').returncode == 0\n"
            "denied = aws('kinesis', 'put-record', key='k2')\n"
            "assert denied.returncode == 254 and 'AccessDenied' in denied.stderr\n",
            aws=[vf.aws_rule("sts", "assume-role", "--role-arn", "r1",
                             stdout={"Credentials": {"AccessKeyId": "k1"}}),
                 vf.aws_rule("kinesis", "put-record", env={"AWS_ACCESS_KEY_ID": "k1"}),
                 vf.aws_error("kinesis", "put-record", code="AccessDenied",
                              operation="PutRecord", env={"AWS_ACCESS_KEY_ID": "k2"})])
        self.assertEqual(vf.PASS, result.verdict, result.stderr)
        self.assertEqual([None, "k1", "k2"],
                         [c["env"].get("AWS_ACCESS_KEY_ID") for c in result.aws_calls])

    def test_outer_aws_environment_is_not_inherited(self):
        outer = {"AWS_PROFILE": "real", "AWS_ACCESS_KEY_ID": "AKIAREAL", "AWS_REGION": "eu-west-1"}
        with patch.dict(os.environ, outer):
            result = self.grade(
                "import os\n"
                "assert 'AWS_PROFILE' not in os.environ and 'AWS_ACCESS_KEY_ID' not in os.environ\n"
                "assert os.environ['AWS_REGION'] == 'us-east-1'\n")
        self.assertEqual(vf.PASS, result.verdict, result.stderr)

    def test_seed_files_and_workspace_placeholder(self):
        result = self.grade(
            "import checkkit as ck, json, os\n"
            "assert ck.seed() == {'prefix': 'p'}\n"
            "assert json.load(open('task_context.json')) == {'name': 'private'}\n"
            "assert os.environ['AGENT_WORKSPACE'] == os.path.join(os.getcwd(), 'workspace')\n"
            "assert ck.as_list('a') == ['a'] and ck.as_list(None) == []\n",
            seed={"prefix": "p"}, files={"task_context.json": {"name": "private"}},
            env={"AGENT_WORKSPACE": "{work}/workspace"})
        self.assertEqual(vf.PASS, result.verdict, result.stderr)

    def test_clock_is_virtual(self):
        started = time.perf_counter()
        result = self.grade(
            "import time\nt = time.time()\ntime.sleep(3600)\nassert time.time() - t >= 3600\n")
        self.assertEqual(vf.PASS, result.verdict, result.stderr)
        self.assertLess(time.perf_counter() - started, 5)

    def test_run_script_uses_fake_aws_and_instant_sleep(self):
        self.write("environment/lifecycle/setup.sh",
                   "set -euo pipefail\nsleep 600\n"
                   "aws sts get-caller-identity --query Account --output text > account.txt\n")
        started = time.perf_counter()
        result = vf.run_script("aws/demo", "environment/lifecycle/setup.sh",
                               aws=[vf.aws_rule("sts", "get-caller-identity", stdout="123456789012")])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("123456789012", result.files["account.txt"])
        self.assertLess(time.perf_counter() - started, 5)

    def test_run_script_rejects_undeclared_calls(self):
        self.write("environment/lifecycle/setup.sh", "aws sns delete-topic --topic-arn t || true\n")
        with self.assertRaisesRegex(AssertionError, "aws sns delete-topic"):
            vf.run_script("aws/demo", "environment/lifecycle/setup.sh")


if __name__ == "__main__":
    unittest.main()
