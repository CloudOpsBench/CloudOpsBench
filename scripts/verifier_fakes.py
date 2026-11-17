"""Offline fakes for running task graders and lifecycle scripts in unit tests.

A grader runs in-process with fake checkkit, boto3 and botocore modules, a fake
aws executable first on PATH and a virtual clock. Scripts run under bash with the
same fake aws and an instant sleep. Every call a test did not declare fails the
test, even if the code under test swallows the error.
"""
import contextlib
import copy
import io
import json
import os
import runpy
import subprocess
import sys
import tempfile
import types
from dataclasses import dataclass, field
from pathlib import Path
from unittest.mock import patch

TASKS = Path(__file__).resolve().parents[1] / "tasks"
PASS, FAIL, ERROR = "PASS", "FAIL", "ERROR"


class UnexpectedCall(BaseException):
    """An undeclared call. A BaseException, so `except Exception` cannot hide it."""


class ClientError(Exception):
    def __init__(self, error_response, operation_name):
        self.response = error_response
        self.operation_name = operation_name
        error = error_response.get("Error", {})
        super().__init__("An error occurred (%s) when calling the %s operation: %s"
                         % (error.get("Code"), operation_name, error.get("Message", "")))


def client_error(code, operation="Operation", message=""):
    return ClientError({"Error": {"Code": code, "Message": message}}, operation)


class StrictClient:
    """A boto3 client that answers only the operations it was given.

    A response is a value to return, an exception to raise, or a callable that
    receives the call's keyword arguments. Paginators yield a list response as pages.
    """

    def __init__(self, service, responses=None, **operations):
        self._service = service
        self._responses = {**(responses or {}), **operations}
        self.calls = []
        self.unexpected = []

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        return lambda **kwargs: self._call(name, kwargs)

    def get_paginator(self, name):
        client = self

        class Paginator:
            def paginate(self, **kwargs):
                pages = client._call(name, kwargs)
                return iter(pages if isinstance(pages, list) else [pages])

        return Paginator()

    def _call(self, name, kwargs):
        self.calls.append((name, kwargs))
        if name not in self._responses:
            self.unexpected.append("%s.%s(%s)" % (self._service, name, kwargs))
            raise UnexpectedCall(self.unexpected[-1])
        response = self._responses[name]
        if callable(response):
            response = response(**kwargs)
        if isinstance(response, BaseException):
            raise response
        return copy.deepcopy(response)


def aws_rule(*argv, stdout="", stderr="", status=0, env=None):
    """Answer aws calls whose arguments start with argv and whose AWS_* env includes env."""
    return {"argv": list(argv), "env": env or {}, "stdout": stdout, "stderr": stderr,
            "status": status}


def aws_error(*argv, code, operation, env=None):
    message = "\nAn error occurred (%s) when calling the %s operation: denied\n" % (code, operation)
    return aws_rule(*argv, stderr=message, status=254, env=env)


@dataclass
class Result:
    verdict: str
    stdout: str
    stderr: str
    error: BaseException = None
    aws_calls: list = field(default_factory=list)


@dataclass
class ScriptResult:
    returncode: int
    stdout: str
    stderr: str
    files: dict
    aws_calls: list = field(default_factory=list)


_AWS = r'''
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
argv = sys.argv[1:]
env = {k: v for k, v in os.environ.items() if k.startswith("AWS_")}
record = {"argv": argv, "env": env, "matched": False}
try:
    with open(os.path.join(here, "rules.json")) as f:
        rule = next((r for r in json.load(f) if argv[:len(r["argv"])] == r["argv"]
                     and all(env.get(k) == v for k, v in r.get("env", {}).items())), None)
    record["matched"] = rule is not None
finally:
    with open(os.path.join(here, "calls.jsonl"), "a") as f:
        f.write(json.dumps(record) + "\n")
if rule is None:
    sys.stderr.write("unexpected aws call: %s\n" % " ".join(argv))
    sys.exit(255)
out = rule.get("stdout", "")
sys.stdout.write(out if isinstance(out, str) else json.dumps(out))
sys.stderr.write(rule.get("stderr", ""))
sys.exit(rule.get("status", 0))
'''


def _executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


@contextlib.contextmanager
def _sandbox(rules, env, files, seed, region):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        work, bin_dir = root / "work", root / "bin"
        work.mkdir()
        bin_dir.mkdir()
        _executable(bin_dir / "aws", "#!%s -S\n%s" % (sys.executable, _AWS))
        _executable(bin_dir / "sleep", "#!/bin/sh\nexit 0\n")
        (bin_dir / "rules.json").write_text(json.dumps(rules or []))
        if seed is not None:
            (work / "seed_state.json").write_text(json.dumps(seed))
        for name, content in (files or {}).items():
            path = work / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content if isinstance(content, str) else json.dumps(content))
        run_env = {k: v for k, v in os.environ.items() if not k.startswith("AWS_")}
        run_env.update(PATH=str(bin_dir) + os.pathsep + os.environ.get("PATH", ""),
                       AWS_REGION=region, AWS_DEFAULT_REGION=region)
        run_env.update({k: v.replace("{work}", str(work)) for k, v in (env or {}).items()})
        yield root, work, run_env


def _aws_calls(root):
    log = root / "bin" / "calls.jsonl"
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


def _require_declared(aws_calls, unexpected):
    missed = unexpected + ["aws " + " ".join(c["argv"]) for c in aws_calls if not c["matched"]]
    if missed:
        raise AssertionError("undeclared calls:\n  " + "\n  ".join(missed))


class _Clock:
    def __init__(self):
        self.now = 1_700_000_000.0

    def sleep(self, seconds):
        self.now += max(0.0, float(seconds))

    def time(self):
        return self.now


def _modules(clients, unexpected, region, account):
    def client(service, region_name=None, **_kwargs):
        for key in ((service, region_name), service):
            if key in clients:
                return clients[key]
        unexpected.append("client(%r, region_name=%r)" % (service, region_name))
        raise UnexpectedCall(unexpected[-1])

    def fail(message=""):
        print(message, file=sys.stderr)
        raise SystemExit(1)

    def resource(*args, **kwargs):
        unexpected.append("resource(%r, %r)" % (args, kwargs))
        raise UnexpectedCall(unexpected[-1])

    ck = types.ModuleType("checkkit")
    ck.seed = lambda: json.loads(Path("seed_state.json").read_text())
    ck.client, ck.resource, ck.fail = client, resource, fail
    ck.region, ck.account_id = (lambda: region), (lambda: account)
    ck.as_list = lambda v: [] if v is None else list(v) if isinstance(v, (list, tuple)) else [v]
    ck.require = lambda condition, message="": None if condition else fail(message)
    ck.ok = lambda message="": print(message)

    boto3 = types.ModuleType("boto3")
    boto3.client = client
    exceptions = types.ModuleType("botocore.exceptions")
    exceptions.ClientError = ClientError
    config = types.ModuleType("botocore.config")
    config.Config = lambda **kwargs: types.SimpleNamespace(**kwargs)
    botocore = types.ModuleType("botocore")
    botocore.exceptions, botocore.config = exceptions, config
    return {"checkkit": ck, "boto3": boto3, "botocore": botocore,
            "botocore.exceptions": exceptions, "botocore.config": config}


def _execute(path):
    try:
        runpy.run_path(str(path), run_name="__main__")
    except SystemExit as exc:
        code = exc.code
        if code is not None and not isinstance(code, int):
            print(code, file=sys.stderr)
            code = 1
        verdict = {0: PASS, 1: FAIL}.get(code or 0, ERROR)
        return verdict, exc if verdict == ERROR else None
    except Exception as exc:
        return ERROR, exc
    return PASS, None


def run_grader(task, *, seed=None, files=None, clients=None, aws=None, env=None,
               region="us-east-1", account="123456789012"):
    """Run tasks/<task>/tests/check.py and map its exit like the runner: 0 PASS, 1 FAIL, else ERROR."""
    check = TASKS / task / "tests" / "check.py"
    clients = clients or {}
    unexpected = []
    out, err = io.StringIO(), io.StringIO()
    clock = _Clock()
    with _sandbox(aws, env, files, seed, region) as (root, work, run_env):
        cwd = os.getcwd()
        os.chdir(work)
        try:
            with patch.dict(sys.modules, _modules(clients, unexpected, region, account)), \
                    patch.dict(os.environ, run_env, clear=True), \
                    patch.object(sys, "argv", [str(check)]), \
                    patch("time.sleep", clock.sleep), patch("time.time", clock.time), \
                    patch("time.monotonic", clock.time), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    verdict, error = _execute(check)
                except UnexpectedCall:
                    verdict, error = None, None
        finally:
            os.chdir(cwd)
        aws_calls = _aws_calls(root)
    for c in clients.values():
        unexpected += [u for u in getattr(c, "unexpected", []) if u not in unexpected]
    _require_declared(aws_calls, unexpected)
    return Result(verdict, out.getvalue(), err.getvalue(), error, aws_calls)


def run_script(task, script, *, seed=None, files=None, aws=None, env=None,
               region="us-east-1", timeout=60):
    """Run tasks/<task>/<script> with bash in a scratch directory and return its files."""
    path = TASKS / task / script
    with _sandbox(aws, env, files, seed, region) as (root, work, run_env):
        proc = subprocess.run(["bash", str(path)], cwd=work, env=run_env,
                              capture_output=True, text=True, timeout=timeout)
        produced = {p.relative_to(work).as_posix(): p.read_text(errors="replace")
                    for p in sorted(work.rglob("*")) if p.is_file()}
        aws_calls = _aws_calls(root)
    _require_declared(aws_calls, [])
    return ScriptResult(proc.returncode, proc.stdout, proc.stderr, produced, aws_calls)
