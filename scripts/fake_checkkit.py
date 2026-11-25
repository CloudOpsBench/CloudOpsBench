"""Stand-in for the runner's `checkkit`, mirroring its semantics for grader unit tests.

`check` records and continues; `fail` and a failed `require` stop the grader; `ok` raises
if any check failed. A failing run raises VerificationFailure carrying every failure message.
"""
import types


class VerificationFailure(AssertionError):
    pass


def build(clients, seed):
    kit = types.ModuleType("checkkit")
    kit.failures, kit.ok_message = [], None

    def stop():
        raise VerificationFailure("; ".join(kit.failures))

    def check(condition, message):
        if not condition:
            kit.failures.append(str(message))
        return bool(condition)

    def fail(message):
        kit.failures.append(str(message))
        stop()

    def require(condition, message):
        if not condition:
            fail(message)

    def ok(message=""):
        if kit.failures:
            stop()
        kit.ok_message = message

    kit.client = lambda name: clients[name]
    kit.seed = lambda: seed
    kit.check, kit.fail, kit.require, kit.ok = check, fail, require, ok
    return kit
