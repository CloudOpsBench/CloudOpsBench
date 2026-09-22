"""Local verifier unit tests; requires boto3, never contacts a cloud endpoint."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

from botocore.exceptions import ClientError

path = Path(__file__).resolve().parents[1] / 'tasks/aws/create-secure-s3-bucket/tests/test_infra.py'
spec = importlib.util.spec_from_file_location('secure_verifier', path)
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


def client():
    s3 = Mock()
    s3.list_buckets.return_value = {'Buckets': [{'Name': v.BUCKET}]}
    s3.get_bucket_versioning.return_value = {'Status': 'Enabled'}
    s3.get_public_access_block.return_value = {'PublicAccessBlockConfiguration': {k: True for k in v.PUBLIC_ACCESS_FLAGS}}
    s3.get_bucket_encryption.return_value = {'ServerSideEncryptionConfiguration': {'Rules': [
        {'ApplyServerSideEncryptionByDefault': {'SSEAlgorithm': 'AES256'}}]}}
    s3.get_bucket_tagging.return_value = {'TagSet': [{'Key': 'Environment', 'Value': 'production'}]}
    return s3


class VerifierTests(unittest.TestCase):
    def test_complete_state_passes(self):
        v.verify_bucket(client())

    def test_each_public_access_flag_is_required(self):
        for flag in v.PUBLIC_ACCESS_FLAGS:
            with self.subTest(flag=flag):
                s3 = client()
                s3.get_public_access_block.return_value['PublicAccessBlockConfiguration'][flag] = False
                with self.assertRaises(AssertionError):
                    v.verify_bucket(s3)

    def test_missing_bucket_versioning_tag_and_encryption_fail(self):
        for operation, response in [
            ('list_buckets', {'Buckets': []}),
            ('get_bucket_versioning', {'Status': 'Suspended'}),
            ('get_bucket_tagging', {'TagSet': [{'Key': 'Environment', 'Value': 'development'}]}),
            ('get_bucket_encryption', {'ServerSideEncryptionConfiguration': {'Rules': []}}),
        ]:
            with self.subTest(operation=operation):
                s3 = client()
                getattr(s3, operation).return_value = response
                with self.assertRaises(AssertionError):
                    v.verify_bucket(s3)

    def test_sdk_errors_are_classified_not_blanket_failures(self):
        for code, expected in [('NoSuchTagSet', 1), ('AccessDenied', 2), ('InternalError', 2), ('NotImplemented', 2)]:
            s3 = client()
            s3.get_bucket_tagging.side_effect = ClientError({'Error': {'Code': code}}, 'GetBucketTagging')
            with patch.object(v, 'connect_s3', return_value=s3), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(v.main(), expected)

    def test_refuse_non_emulator_endpoint_before_sdk_creation(self):
        with patch.dict(os.environ, {'AWS_ENDPOINT_URL': 'https://s3.amazonaws.com'}), patch.object(v.boto3, 'client') as create:
            with self.assertRaises(v.IntegrationError):
                v.connect_s3()
            create.assert_not_called()

    def test_explicit_dummy_credentials_and_endpoint(self):
        with patch.dict(os.environ, {'AWS_ENDPOINT_URL': 'http://127.0.0.1:5003'}), patch.object(v.boto3, 'client') as create:
            v.connect_s3()
            kwargs = create.call_args.kwargs
            self.assertEqual(kwargs['aws_access_key_id'], 'test')
            self.assertEqual(kwargs['aws_secret_access_key'], 'test')
            self.assertEqual(kwargs['endpoint_url'], 'http://127.0.0.1:5003')


if __name__ == '__main__':
    unittest.main()
