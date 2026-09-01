#!/usr/bin/env python3
"""Command-line driver for the TLA+ specifications in this repository.

Subcommands:

    verify <path>... [--only NAME]   run the TLC models and print a summary
    models <path>...                 list the models found under a path
    trace  <model.cfg>               run one model and print the full TLC output
    parse  <module.tla>              parse/typecheck a module with SANY

A "model" is a TLC configuration file (`*.cfg`). Each configuration starts with
directives that say which module it belongs to and what the expected outcome is:

    \\* module: MCApproval
    \\* expect: ok             (default; TLC must not find any error)
    \\* expect: counterexample (TLC must report a violation)

`expect: counterexample` is how reachability ("this scenario can happen") is
checked: the negation of the scenario is given to TLC as an invariant, and the
counterexample it produces is the witnessing behaviour. `verify` therefore exits
non-zero both when a property is violated unexpectedly and when an expected
counterexample fails to show up, which makes it usable as a CI gate.

The TLA+ tools jar is downloaded on first use into `.tools/`.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

TLA_VERSION = os.environ.get("TLA_VERSION", "1.7.4")
TLA_URL = (
    "https://github.com/tlaplus/tlaplus/releases/download/"
    f"v{TLA_VERSION}/tla2tools.jar"
)
REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLS_DIR = Path(os.environ.get("TLA_TOOLS_DIR", REPO_ROOT / ".tools"))
TLA_JAR = TOOLS_DIR / f"tla2tools-{TLA_VERSION}.jar"

DIRECTIVE = re.compile(r"^\\\*\s*(module|expect|name)\s*:\s*(\S+)\s*$")
STATES = re.compile(r"^(\d+) states generated, (\d+) distinct states found", re.M)
VIOLATION = re.compile(
    r"^Error: (?:Invariant|Action property|Temporal properties|Property|Deadlock|"
    r"The behavior up to this point|Assumption).*$",
    re.M,
)
FATAL = ("Parsing or semantic analysis failed", "was interrupted", "TLC threw an unexpected exception")


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def tla_jar() -> Path:
    if TLA_JAR.exists():
        return TLA_JAR
    if shutil.which("java") is None:
        fail("java 11 or later is required to run TLC")
    TOOLS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"downloading the TLA+ tools {TLA_VERSION} ...", file=sys.stderr)
    tmp = TLA_JAR.with_suffix(".part")
    with urllib.request.urlopen(TLA_URL) as response, tmp.open("wb") as out:
        shutil.copyfileobj(response, out)
    tmp.rename(TLA_JAR)
    return TLA_JAR


class Model:
    """A TLC configuration file plus the directives written in its header."""

    def __init__(self, config: Path) -> None:
        self.config = config
        self.name = config.stem
        self.expect = "ok"
        module = None
        for line in config.read_text().splitlines():
            match = DIRECTIVE.match(line.strip())
            if not match:
                continue
            key, value = match.groups()
            if key == "module":
                module = value
            elif key == "expect":
                self.expect = value
            else:
                self.name = value
        if module is None:
            fail(f"{config} has no `\\* module: <name>` directive")
        self.module = module if module.endswith(".tla") else f"{module}.tla"
        if not (config.parent / self.module).exists():
            fail(f"{config} refers to a missing module: {self.module}")
        if self.expect not in ("ok", "counterexample"):
            fail(f"{config}: unknown expectation {self.expect!r}")

    def __str__(self) -> str:
        return f"{self.config.parent}/{self.name}"


def discover(paths: list[Path]) -> list[Model]:
    configs: list[Path] = []
    for path in paths:
        if path.is_dir():
            configs.extend(sorted(path.rglob("*.cfg")))
        elif path.suffix == ".cfg":
            configs.append(path)
        else:
            fail(f"not a TLC configuration or directory: {path}")
    return [Model(config) for config in configs]


def run_java(args: list[str], **kwargs: object) -> subprocess.CompletedProcess:
    java = ["java", "-XX:+UseParallelGC", "-cp", str(tla_jar())]
    return subprocess.run(java + args, check=False, **kwargs)  # noqa: S603


def run_tlc(model: Model, extra: list[str], **kwargs: object) -> subprocess.CompletedProcess:
    with tempfile.TemporaryDirectory() as metadir:
        return run_java(
            [
                "tlc2.TLC",
                "-workers",
                os.environ.get("TLC_WORKERS", "auto"),
                "-metadir",
                metadir,
                "-config",
                model.config.name,
                *extra,
                model.module,
            ],
            cwd=model.config.parent,
            **kwargs,
        )


def outcome(output: str, returncode: int) -> str:
    """Classify a TLC run as "ok", "counterexample" or "error"."""
    if any(marker in output for marker in FATAL):
        return "error"
    if returncode == 0 and "No error has been found" in output:
        return "ok"
    if VIOLATION.search(output):
        return "counterexample"
    return "error"


def summarize(output: str) -> str:
    violation = VIOLATION.search(output)
    if violation:
        return violation.group(0)[len("Error: ") :].rstrip(".")
    states = STATES.search(output)
    if states:
        return f"{int(states.group(2)):,} distinct states"
    return "no error"


def cmd_models(args: argparse.Namespace) -> int:
    models = discover(args.paths)
    if not models:
        fail(f"no TLC configuration found under {', '.join(map(str, args.paths))}")
    width = max(len(model.name) for model in models)
    for model in models:
        print(f"{model.name:<{width}}  {model.module:<16} expect {model.expect}")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    models = [m for m in discover(args.paths) if args.only in (None, m.name)]
    if not models:
        fail(f"no model matched {args.only!r} under {', '.join(map(str, args.paths))}")

    results = []
    width = max(len(model.name) for model in models)
    for model in models:
        started = time.monotonic()
        result = run_tlc(model, [], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        output = result.stdout or ""
        elapsed = time.monotonic() - started
        got = outcome(output, result.returncode)
        ok = got == model.expect
        results.append((model, ok, output))
        detail = summarize(output) if got != "error" else "TLC FAILED"
        print(f"{'ok  ' if ok else 'FAIL'} {model.name:<{width}}  {detail} ({elapsed:.0f}s)")
        if got == "error":
            print(output.strip()[-2000:], file=sys.stderr)

    failures = [model for model, ok, _ in results if not ok]
    print()
    print(f"{len(results) - len(failures)}/{len(results)} models as expected")
    if failures:
        print("unexpected results: " + ", ".join(m.name for m in failures), file=sys.stderr)
        print(
            f"inspect one with: {sys.argv[0]} trace {failures[0].config}",
            file=sys.stderr,
        )
        return 1
    return 0


def cmd_trace(args: argparse.Namespace) -> int:
    model = Model(args.config)
    result = run_tlc(model, args.tlc_args)
    if model.expect == "counterexample" and result.returncode != 0:
        return 0  # the counterexample is the expected output
    return result.returncode


def cmd_parse(args: argparse.Namespace) -> int:
    return run_java(["tla2sany.SANY", args.module.name], cwd=args.module.parent).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="subcommand", required=True)

    verify = sub.add_parser("verify", help="run the models and summarize the results")
    verify.add_argument("paths", type=Path, nargs="+")
    verify.add_argument("--only", help="name of the single model to run")
    verify.set_defaults(func=cmd_verify)

    models = sub.add_parser("models", help="list the models found under a path")
    models.add_argument("paths", type=Path, nargs="+")
    models.set_defaults(func=cmd_models)

    trace = sub.add_parser("trace", help="run one model and show the full TLC output")
    trace.add_argument("config", type=Path)
    trace.add_argument("tlc_args", nargs="*", help="extra arguments passed to TLC")
    trace.set_defaults(func=cmd_trace)

    parse = sub.add_parser("parse", help="parse a module with SANY")
    parse.add_argument("module", type=Path)
    parse.set_defaults(func=cmd_parse)

    args = parser.parse_args()
    for path in [*getattr(args, "paths", []), *filter(None, [getattr(args, "config", None), getattr(args, "module", None)])]:
        if not path.exists():
            fail(f"no such path: {path}")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
