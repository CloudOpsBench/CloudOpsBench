"""Run with python3 -m unittest discover -s scripts -p 'test_lifecycle_validator.py'."""
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import validate


class LifecycleValidationTests(unittest.TestCase):
    def validate_task(self, *, missing_check=False, wrapper=False, metadata=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            task = root / "tasks/aws/demo"
            files = {
                "task.toml": '[task]\nname = "demo"\n' + metadata,
                "instruction.md": "Fix the resource.",
                "solution/solve.sh": "#!/bin/bash\n",
                "environment/lifecycle/setup.sh": "#!/bin/bash\n",
            }
            if not missing_check:
                files["tests/check.py"] = "raise SystemExit(0)\n"
            if wrapper:
                files["tests/test.sh"] = "#!/bin/bash\n"
            for name, content in files.items():
                path = task / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            with patch.object(validate, "ROOT", root), contextlib.redirect_stdout(io.StringIO()):
                return validate.main()

    def test_canonical_export_needs_no_test_rewrite_or_metadata_id(self):
        self.assertEqual(self.validate_task(), 0)

    def test_missing_grader_rejected(self):
        self.assertEqual(self.validate_task(missing_check=True), 1)

    def test_conflicting_wrapper_rejected(self):
        self.assertEqual(self.validate_task(wrapper=True), 1)

    def test_explicit_wrong_id_rejected(self):
        self.assertEqual(self.validate_task(metadata='[metadata]\nid = "wrong"\n'), 1)


if __name__ == "__main__":
    unittest.main()
