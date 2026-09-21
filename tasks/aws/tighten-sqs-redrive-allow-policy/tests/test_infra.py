"""Runs the state grader (check.py). Its verdict becomes 0/1; anything else is an
evaluation error, never a fabricated zero."""
import os
import runpy
import subprocess
import sys

ENDPOINT = "http://127.0.0.1:5003"


def main():
    try:
        if os.environ.get("AWS_ENDPOINT_URL") != ENDPOINT:
            raise RuntimeError("trusted emulator endpoint is missing or unexpected")
        # Explicit dummy identity: never fall back to metadata or local AWS profiles.
        os.environ.update(AWS_ACCESS_KEY_ID="test", AWS_SECRET_ACCESS_KEY="test",
                          AWS_EC2_METADATA_DISABLED="true", AWS_PAGER="")
        for name in ("AWS_SESSION_TOKEN", "AWS_PROFILE"):
            os.environ.pop(name, None)
        os.environ.setdefault("AWS_REGION", "us-east-1")
        # check.py reads an unreachable emulator as "nothing left"; rule that out first.
        subprocess.run(["aws", "sts", "get-caller-identity"], check=True,
                       capture_output=True, text=True, timeout=60)
        os.chdir("/tests")  # check.py resolves its ground truth relative to the CWD
        try:
            runpy.run_path("/tests/check.py", run_name="__main__")
            verdict = 0
        except SystemExit as done:
            verdict = done.code
    except Exception as error:
        print(f"EVALUATION ERROR: {error}", file=sys.stderr)
        return 2
    return 0 if verdict in (0, None) else 1


if __name__ == "__main__":
    sys.exit(main())
