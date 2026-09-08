#!/usr/bin/env python3
"""Command-line driver for the Markdown with Gherkin (MDG) specifications in this repository.

Subcommands:

    verify   <path>... [--only NAME]   run the checks of a model and summarize
    checks   <path>...                 list the checks declared under a path
    trace    <path> --only NAME        run one check and print the full output
    run      <path> [--tags EXPR] [--model FILE] [ARG...]
                                       execute the scenarios and print every step
    report   <path> [--out FILE]       write a self-contained HTML report of a run
    cucumber <path> [ARG...]           pass ARG... straight to cucumber-js in the model directory
    tsc      <path> [ARG...]           pass ARG... straight to the TypeScript compiler

An MDG model is a `*.feature.md` document — GitHub Flavored Markdown whose
headers (`# Feature` / `## Rule` / `### Scenario`) and list items (`* Given`
...) are Gherkin, everything else being prose — plus the step definitions that
make it executable with Cucumber. The model directory is a small npm project
(`package.json`, `cucumber.json`); `npm ci` is run into its `node_modules/` on
first use. The checks of a topic are declared in `<topic>/mdg/checks.json`:

    {
      "checks": [
        {"name": "typecheck", "kind": "tsc"},
        {"name": "dry-run", "kind": "dry-run"},
        {"name": "scenarios", "kind": "run"},
        {"name": "negative-authority-leak", "kind": "run", "tags": "@P1",
         "model": "negative/authority-leak.ts", "expect": "violation"}
      ]
    }

The kinds are:

    tsc      `tsc -p .`: the model, step definitions and mutants type-check.
    dry-run  `cucumber-js --dry-run`: the Markdown parses as Gherkin and every
             step of every scenario has exactly one matching step definition.
    run      `cucumber-js`: execute the scenarios. `tags` restricts the run to
             a Cucumber tag expression; `model` points the step definitions at
             another implementation (the mutants under `negative/`) through the
             MDG_MODEL environment variable.

`expect` defaults to "ok" and may be set to "violation" for checks that are
supposed to fail.

Tools: Node.js >= 22.18 (which strips TypeScript type annotations natively) and
npm must be on PATH; cucumber-js and the TypeScript compiler are installed by
`npm ci` from the model's `package-lock.json` into `<model>/node_modules/`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

MANIFEST = "checks.json"
NODE_MIN = (22, 18)

SCENARIOS = re.compile(r"^(\d+) scenarios? \(([^)]*)\)", re.M)
STEPS = re.compile(r"^(\d+) steps? \(([^)]*)\)", re.M)
PARSE_ERROR = re.compile(r"^Parse error in .*$", re.M)
TSC_ERRORS = re.compile(r"error TS\d+", re.M)


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


# ---------------------------------------------------------------------------
# tools
# ---------------------------------------------------------------------------


def node_bin() -> str:
    node = shutil.which("node")
    if not node:
        fail("node not found; install Node.js >= %d.%d (https://nodejs.org/)" % NODE_MIN)
    version = subprocess.run([node, "--version"], capture_output=True, text=True, check=True).stdout.strip()  # noqa: S603
    parts = tuple(int(p) for p in version.lstrip("v").split(".")[:2])
    if parts < NODE_MIN:
        fail(f"Node.js {version} is too old; >= {NODE_MIN[0]}.{NODE_MIN[1]} is required to run TypeScript directly")
    return node


def npm_bin() -> str:
    npm = shutil.which("npm")
    if not npm:
        fail("npm not found; install Node.js >= %d.%d (https://nodejs.org/)" % NODE_MIN)
    return npm


class Model:
    """A model directory: the `.feature.md` documents, the npm project around them, and the checks."""

    def __init__(self, directory: Path) -> None:
        self.dir = directory
        manifest = directory / MANIFEST
        if not manifest.exists():
            fail(f"{directory}: no {MANIFEST}")
        self.manifest = json.loads(manifest.read_text())

    @property
    def display(self) -> str:
        return str(self.dir)

    def ensure_installed(self) -> None:
        """`npm ci` unless node_modules is at least as new as package-lock.json."""
        lock = self.dir / "package-lock.json"
        stamp = self.dir / "node_modules" / ".package-lock.json"
        if stamp.exists() and lock.exists() and stamp.stat().st_mtime >= lock.stat().st_mtime:
            return
        print(f"installing the npm dependencies of {self.display} ...", file=sys.stderr)
        subprocess.run([npm_bin(), "ci", "--no-audit", "--no-fund"], cwd=self.dir, check=True)  # noqa: S603

    def bin(self, name: str) -> str:
        self.ensure_installed()
        executable = f"{name}.cmd" if os.name == "nt" else name
        path = (self.dir / "node_modules" / ".bin" / executable).resolve()
        if not path.exists():
            fail(f"{self.display}: {name} is not installed (expected {path})")
        return str(path)

    def cucumber(self, args: list[str], model: str | None = None, **kwargs: object) -> subprocess.CompletedProcess:
        node_bin()
        env = dict(os.environ)
        if model:
            env["MDG_MODEL"] = model
        env.setdefault("FORCE_COLOR", "0")
        return subprocess.run([self.bin("cucumber-js"), *args], cwd=self.dir, env=env, check=False, **kwargs)  # noqa: S603

    def tsc(self, args: list[str], **kwargs: object) -> subprocess.CompletedProcess:
        return subprocess.run([self.bin("tsc"), *args], cwd=self.dir, check=False, **kwargs)  # noqa: S603

    def checks(self, only: str | None = None) -> list[Check]:
        checks = [Check(self, spec) for spec in self.manifest["checks"]]
        if only is not None:
            checks = [c for c in checks if c.name == only]
            if not checks:
                fail(f"{self.display}: no check named {only!r}")
        return checks


class Check:
    KINDS = {
        "tsc": "tsc -p .",
        "dry-run": "cucumber-js --dry-run",
        "run": "cucumber-js",
    }

    def __init__(self, model: Model, spec: dict) -> None:
        self.model = model
        self.name = spec["name"]
        self.kind = spec["kind"]
        self.expect = spec.get("expect", "ok")
        self.tags = spec.get("tags")
        self.impl = spec.get("model")
        self.note = spec.get("description", "")
        if self.kind not in Check.KINDS:
            fail(f"{model.display}: unknown check kind {self.kind!r}")

    @property
    def description(self) -> str:
        parts = [Check.KINDS[self.kind]]
        if self.tags:
            parts.append(f"--tags {self.tags!r}")
        if self.impl:
            parts.append(f"MDG_MODEL={self.impl}")
        if self.expect != "ok":
            parts.append(f"[expected: {self.expect}]")
        return "  ".join(parts)

    def run(self) -> tuple[str, int, float]:
        started = time.monotonic()
        if self.kind == "tsc":
            result = self.model.tsc(["-p", "."], capture_output=True, text=True)
        else:
            args = ["--format", "summary"]
            if self.kind == "dry-run":
                args.append("--dry-run")
            if self.tags:
                args += ["--tags", self.tags]
            result = self.model.cucumber(args, model=self.impl, capture_output=True, text=True)
        return result.stdout + result.stderr, result.returncode, time.monotonic() - started

    def passed(self, returncode: int) -> bool:
        return (returncode == 0) == (self.expect == "ok")

    def summary(self, output: str, returncode: int) -> str:
        if self.kind == "tsc":
            errors = len(TSC_ERRORS.findall(output))
            return "no type errors" if returncode == 0 else f"{errors} type error(s)"
        if PARSE_ERROR.search(output):
            return PARSE_ERROR.search(output).group(0)  # type: ignore[union-attr]
        scenarios, steps = SCENARIOS.search(output), STEPS.search(output)
        if not scenarios:
            return "passed" if self.passed(returncode) else "failed"
        detail = scenarios.group(2)
        if self.kind == "dry-run":
            return f"{scenarios.group(1)} scenarios / {steps.group(1) if steps else '?'} steps, every step defined"
        prefix = "" if self.expect == "ok" else "as expected, " if returncode != 0 else "unexpectedly "
        return f"{prefix}{scenarios.group(1)} scenarios ({detail})"


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------


def discover(paths: list[Path]) -> list[Model]:
    return [Model(path if path.is_dir() else path.parent) for path in paths]


def all_checks(paths: list[Path], only: str | None = None) -> list[Check]:
    return [c for m in discover(paths) for c in m.checks(only)]


def cmd_checks(args: argparse.Namespace) -> int:
    checks = all_checks(args.paths)
    width = max(len(c.name) for c in checks)
    for check in checks:
        print(f"{check.name:<{width}}  {check.description}")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    checks = all_checks(args.paths, args.only)
    width = max(len(c.name) for c in checks)
    failures = []
    for check in checks:
        output, returncode, elapsed = check.run()
        ok = check.passed(returncode)
        print(f"{'ok  ' if ok else 'FAIL'} {check.name:<{width}}  "
              f"{check.summary(output, returncode)} ({elapsed:.1f}s)")
        if not ok:
            failures.append(check)
            print(output.strip()[-3000:], file=sys.stderr)
    print()
    print(f"{len(checks) - len(failures)}/{len(checks)} checks passed")
    if failures:
        print("failed: " + ", ".join(c.name for c in failures), file=sys.stderr)
        print(f"inspect one with: {sys.argv[0]} trace {failures[0].model.display} --only {failures[0].name}",
              file=sys.stderr)
        return 1
    return 0


def cmd_trace(args: argparse.Namespace) -> int:
    check = all_checks(args.paths, args.only)[0]
    if check.kind == "tsc":
        output, returncode, _ = check.run()
        print(output, end="")
        return 0 if check.passed(returncode) else 1
    cucumber_args = ["--format", "progress", "--format", "summary"]
    if check.kind == "dry-run":
        cucumber_args.append("--dry-run")
    if check.tags:
        cucumber_args += ["--tags", check.tags]
    returncode = check.model.cucumber(cucumber_args, model=check.impl).returncode
    return 0 if check.passed(returncode) else 1


def passthrough(args: argparse.Namespace) -> list[str]:
    """A leading `--` separates the driver's options from the tool's own."""
    return args.args[1:] if args.args[:1] == ["--"] else args.args


def cmd_run(args: argparse.Namespace) -> int:
    """Execute the scenarios, printing each step as it runs."""
    model = discover(args.paths)[0]
    cucumber_args = ["--format", "pretty"]
    if args.tags:
        cucumber_args += ["--tags", args.tags]
    return model.cucumber(cucumber_args + passthrough(args), model=args.model).returncode


def cmd_report(args: argparse.Namespace) -> int:
    """Run the scenarios and write an HTML report that renders the Markdown with results."""
    model = discover(args.paths)[0]
    out = Path(args.out) if args.out else model.dir / "report" / "approval.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    result = model.cucumber(["--format", "summary", "--format", f"html:{out.resolve()}"])
    print(f"report written to {out}")
    return result.returncode


def cmd_cucumber(args: argparse.Namespace) -> int:
    return discover(args.paths)[0].cucumber(passthrough(args)).returncode


def cmd_tsc(args: argparse.Namespace) -> int:
    return discover(args.paths)[0].tsc(passthrough(args) or ["-p", "."]).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="subcommand", required=True)

    verify = sub.add_parser("verify", help="run the checks and summarize the results")
    verify.add_argument("paths", type=Path, nargs="+")
    verify.add_argument("--only", help="name of the single check to run")
    verify.set_defaults(func=cmd_verify)

    checks = sub.add_parser("checks", help="list the checks of a model directory")
    checks.add_argument("paths", type=Path, nargs="+")
    checks.set_defaults(func=cmd_checks)

    trace = sub.add_parser("trace", help="run one check and show the full output")
    trace.add_argument("paths", type=Path, nargs=1)
    trace.add_argument("--only", required=True, help="name of the check to run")
    trace.set_defaults(func=cmd_trace)

    run = sub.add_parser("run", help="execute the scenarios, printing every step")
    run.add_argument("paths", type=Path, nargs=1)
    run.add_argument("--tags", help="Cucumber tag expression, e.g. '@P1 or @P2'")
    run.add_argument("--model", help="alternative model module, e.g. negative/authority-leak.ts")
    run.add_argument("args", nargs=argparse.REMAINDER, help="extra cucumber-js arguments")
    run.set_defaults(func=cmd_run)

    report = sub.add_parser("report", help="write a self-contained HTML report of a run")
    report.add_argument("paths", type=Path, nargs=1)
    report.add_argument("--out", help="output file (default: <model>/report/approval.html)")
    report.set_defaults(func=cmd_report)

    cucumber = sub.add_parser("cucumber", help="invoke cucumber-js directly in the model directory")
    cucumber.add_argument("paths", type=Path, nargs=1)
    cucumber.add_argument("args", nargs=argparse.REMAINDER)
    cucumber.set_defaults(func=cmd_cucumber)

    tsc = sub.add_parser("tsc", help="invoke the TypeScript compiler directly in the model directory")
    tsc.add_argument("paths", type=Path, nargs=1)
    tsc.add_argument("args", nargs=argparse.REMAINDER)
    tsc.set_defaults(func=cmd_tsc)

    args = parser.parse_args()
    for path in args.paths:
        if not path.exists():
            fail(f"no such path: {path}")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
