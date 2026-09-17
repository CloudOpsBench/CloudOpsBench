#!/usr/bin/env python3
"""Dependency-free scaffold checks, not a Harbor schema validator or runner."""

import ast
from pathlib import Path
import re
import tomllib
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    "instruction.md", "task.toml", "environment/Dockerfile",
    "solution/solve.sh", "tests/test.sh",
)


def main():
    errors = []
    configs = sorted((ROOT / "tasks").rglob("task.toml"))
    if not configs:
        errors.append("No task configurations found")
    ids = set()
    for config in configs:
        task = config.parent
        for name in REQUIRED:
            if not (task / name).is_file():
                errors.append(f"{task.relative_to(ROOT)}: missing {name}")
        try:
            data = tomllib.loads(config.read_text())
            task_id = data.get("metadata", {}).get("id")
            if task_id != task.relative_to(ROOT / "tasks").as_posix():
                errors.append(f"{config.relative_to(ROOT)}: ID/path mismatch")
            if task_id in ids:
                errors.append(f"Duplicate task ID: {task_id}")
            ids.add(task_id)
        except (ValueError, TypeError) as error:
            errors.append(f"{config.relative_to(ROOT)}: {error}")

    for path in ROOT.rglob("*.py"):
        if ".git" in path.parts or ".venv" in path.parts:
            continue
        try:
            ast.parse(path.read_text(), filename=str(path))
        except SyntaxError as error:
            errors.append(str(error))

    # Inline Markdown file links only; remote URLs and heading anchors excluded.
    for path in ROOT.rglob("*.md"):
        if ".git" in path.parts or ".venv" in path.parts:
            continue
        for target in re.findall(r"\[[^\]]*\]\(([^\s)]+)\)", path.read_text()):
            link = urlsplit(target)
            if link.scheme or link.netloc or not link.path:
                continue
            if not (path.parent / unquote(link.path)).exists():
                errors.append(f"{path.relative_to(ROOT)}: broken file link {target}")

    if errors:
        print("\n".join(errors))
        return 1
    print(f"Static checks passed ({len(configs)} task scaffold).")
    print("Not checked: Harbor schema/runtime, Docker build, Terraform, emulator, Markdown anchors.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
