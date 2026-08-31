#!/usr/bin/env python3
"""Command-line driver for the Alloy 6 models in this repository.

Subcommands:

    verify   <model.als> [command-pattern]   run commands and print a summary
    commands <model.als>                     list the commands of a model
    trace    <model.als> <command>           print the instance/counterexample
    gui      [model.als]                     open the Alloy Analyzer GUI

`verify` exits non-zero when a `check` produced a counterexample or a `run`
turned out to be unsatisfiable (i.e. the scenario cannot happen), which makes it
usable as a CI gate.

The Alloy distribution jar is downloaded on first use into `.tools/`.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ALLOY_VERSION = os.environ.get("ALLOY_VERSION", "6.2.0")
ALLOY_URL = (
    "https://github.com/AlloyTools/org.alloytools.alloy/releases/download/"
    f"v{ALLOY_VERSION}/org.alloytools.alloy.dist.jar"
)
REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLS_DIR = Path(os.environ.get("ALLOY_TOOLS_DIR", REPO_ROOT / ".tools"))
ALLOY_JAR = TOOLS_DIR / f"org.alloytools.alloy.dist-{ALLOY_VERSION}.jar"


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def alloy_jar() -> Path:
    if ALLOY_JAR.exists():
        return ALLOY_JAR
    if shutil.which("java") is None:
        fail("java 17 or later is required to run Alloy")
    TOOLS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"downloading Alloy {ALLOY_VERSION} ...", file=sys.stderr)
    tmp = ALLOY_JAR.with_suffix(".part")
    with urllib.request.urlopen(ALLOY_URL) as response, tmp.open("wb") as out:
        shutil.copyfileobj(response, out)
    tmp.rename(ALLOY_JAR)
    return ALLOY_JAR


def run_alloy(args: list[str], **kwargs: object) -> subprocess.CompletedProcess:
    return subprocess.run(  # noqa: S603
        ["java", "-jar", str(alloy_jar()), *args], check=False, **kwargs
    )


def cmd_commands(args: argparse.Namespace) -> int:
    return run_alloy(["commands", str(args.model)]).returncode


def cmd_trace(args: argparse.Namespace) -> int:
    return run_alloy(
        [
            "exec",
            "--command",
            args.command,
            "--type",
            "text",
            "--output",
            "-",
            "--quiet",
            str(args.model),
        ]
    ).returncode


def cmd_gui(args: argparse.Namespace) -> int:
    argv = ["gui"] + ([str(args.model)] if args.model else [])
    return run_alloy(argv).returncode


def cmd_verify(args: argparse.Namespace) -> int:
    with tempfile.TemporaryDirectory() as workdir:
        receipt = Path(workdir) / "receipt.json"
        result = run_alloy(
            [
                "exec",
                "--force",
                "--command",
                args.pattern,
                "--type",
                "none",
                "--output",
                workdir,
                str(args.model),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        output = result.stdout or ""
        if not receipt.exists():
            sys.stdout.write(output)
            fail(f"alloy did not produce {receipt}")
        commands = json.loads(receipt.read_text())["commands"]

    if not commands:
        fail(f"no command of {args.model} matched {args.pattern!r}")

    width = max(len(name) for name in commands)
    failures = []
    for name, command in commands.items():
        found_instance = bool(command.get("solution"))
        is_check = command.get("type") == "check"
        ok = not found_instance if is_check else found_instance
        if is_check:
            verdict = "no counterexample" if ok else "COUNTEREXAMPLE"
        else:
            verdict = "instance found" if ok else "UNSATISFIABLE"
        if not ok:
            failures.append(name)
        print(f"{'ok  ' if ok else 'FAIL'} {name:<{width}}  {command['type']:<5} {verdict}")

    print()
    print(f"{len(commands) - len(failures)}/{len(commands)} commands as expected")
    if failures:
        print("unexpected results: " + ", ".join(failures), file=sys.stderr)
        print(
            f"inspect one with: {sys.argv[0]} trace {args.model} {failures[0]}",
            file=sys.stderr,
        )
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="subcommand", required=True)

    verify = sub.add_parser("verify", help="run commands and summarize the results")
    verify.add_argument("model", type=Path)
    verify.add_argument("pattern", nargs="?", default="*", help="command name or glob")
    verify.set_defaults(func=cmd_verify)

    commands = sub.add_parser("commands", help="list the commands of a model")
    commands.add_argument("model", type=Path)
    commands.set_defaults(func=cmd_commands)

    trace = sub.add_parser("trace", help="print the instance found for one command")
    trace.add_argument("model", type=Path)
    trace.add_argument("command")
    trace.set_defaults(func=cmd_trace)

    gui = sub.add_parser("gui", help="open the Alloy Analyzer GUI")
    gui.add_argument("model", type=Path, nargs="?")
    gui.set_defaults(func=cmd_gui)

    args = parser.parse_args()
    if getattr(args, "model", None) and not args.model.exists():
        fail(f"no such model: {args.model}")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
