"""Offline tests for the tighten-kinesis-resource-policy grader."""
import json
import unittest

import verifier_fakes as vf

TASK = "aws/tighten-kinesis-resource-policy"
REGION = "us-east-1"
ACCOUNT = "123456789012"
STREAM = "vera-events-stream-" + REGION
ROLES = {
    "producer": "vera-events-producer-",
    "consumer": "vera-analytics-consumer-",
    "outsider": "vera-outsider-",
}
READ = {"DescribeStream", "GetShardIterator", "GetRecords"}
WRITE = {"PutRecord", "PutRecords"}
COMMANDS = [
    ("put-record", "PutRecord", {"ShardId": "shardId-000000000000", "SequenceNumber": "1"}),
    ("put-records", "PutRecords", {"FailedRecordCount": 0, "Records": [{"SequenceNumber": "2"}]}),
    ("describe-stream", "DescribeStream", "shardId-000000000000\n"),
    ("get-shard-iterator", "GetShardIterator", "iterator-1\n"),
    ("get-records", "GetRecords", {"Records": []}),
]


def stream_policy(grants):
    """aws answers for a stream whose resource policy grants each role the given actions."""
    rules = [
        vf.aws_rule("sts", "get-caller-identity", stdout=json.dumps(ACCOUNT)),
        vf.aws_rule("kinesis", "describe-stream-summary", "--stream-name", STREAM,
                    stdout={"StreamDescriptionSummary": {"StreamStatus": "ACTIVE"}}),
    ]
    for role, prefix in ROLES.items():
        key = "AKIA" + role.upper()
        rules.append(vf.aws_rule(
            "sts", "assume-role", "--role-arn", "arn:aws:iam::%s:role/%s%s" % (ACCOUNT, prefix, REGION),
            stdout={"Credentials": {"AccessKeyId": key, "SecretAccessKey": "s", "SessionToken": "t"}}))
        env = {"AWS_ACCESS_KEY_ID": key}
        for command, action, stdout in COMMANDS:
            if action in grants.get(role, set()):
                rules.append(vf.aws_rule("kinesis", command, stdout=stdout, env=env))
            else:
                rules.append(vf.aws_error("kinesis", command, code="AccessDeniedException",
                                          operation=action, env=env))
    return rules


def grade(**grants):
    return vf.run_grader(TASK, seed={"region": REGION}, aws=stream_policy(grants), region=REGION)


class KinesisPolicyVerifierTests(unittest.TestCase):
    def test_verdicts(self):
        cases = [
            ("least privilege", dict(producer=WRITE, consumer=READ), vf.PASS, ""),
            ("producer limited to PutRecord", dict(producer={"PutRecord"}, consumer=READ), vf.PASS, ""),
            ("consumer can PutRecord", dict(producer=WRITE, consumer=READ | {"PutRecord"}), vf.FAIL,
             "vera-analytics-consumer can write"),
            ("consumer can PutRecords", dict(producer=WRITE, consumer=READ | {"PutRecords"}), vf.FAIL,
             "vera-analytics-consumer can write"),
            ("outsider can PutRecords", dict(producer=WRITE, consumer=READ, outsider={"PutRecords"}),
             vf.FAIL, "vera-outsider can still access"),
            ("seeded wide-open policy", dict(producer=READ | WRITE, consumer=READ | WRITE,
                                             outsider=READ | WRITE), vf.FAIL, "vera-outsider"),
            ("producer cannot write", dict(consumer=READ), vf.FAIL, "vera-events-producer denied"),
            ("consumer cannot read", dict(producer=WRITE), vf.FAIL, "vera-analytics-consumer denied"),
        ]
        for name, grants, verdict, message in cases:
            with self.subTest(name):
                result = grade(**grants)
                self.assertEqual(verdict, result.verdict, result.stderr)
                self.assertIn(message, result.stderr)

    def test_consumer_and_outsider_writes_use_both_apis(self):
        result = grade(producer=WRITE, consumer=READ)
        probed = {(c["env"].get("AWS_ACCESS_KEY_ID"), c["argv"][1])
                  for c in result.aws_calls if c["argv"][:1] == ["kinesis"]}
        for key in ("AKIACONSUMER", "AKIAOUTSIDER"):
            self.assertIn((key, "put-record"), probed)
            self.assertIn((key, "put-records"), probed)


if __name__ == "__main__":
    unittest.main()
