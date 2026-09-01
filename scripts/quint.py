#!/usr/bin/env python3
"""Command-line driver for the Quint specifications in this repository.

Subcommands:

    verify <path>... [--only NAME]   run the checks of a model and summarize
    checks <path>...                 list the checks declared under a path
    trace  <path> --only NAME        run one check and print the full output
    typecheck <file.qnt>             typecheck a single specification

A "check" is one invocation of the Quint CLI (`quint test`, `quint run` or
`quint verify`) together with the outcome it is expected to produce. The checks
of a topic are declared in `<topic>/quint/checks.json`:

    {
      "spec": "models.qnt",
      "checks": [
        {"name": "tests", "kind": "test", "main": "scenarios"},
        {"name": "safety", "kind": "verify", "main": "smallModel",
         "backend": "tlc", "invariants": ["safety"]},
        {"name": "liveness-no-fairness", "kind": "verify", "main": "smallModel",
         "backend": "tlc", "temporal": ["pendingIsEventuallyDecided"],
         "expect": "violation"}
      ]
    }

`expect` defaults to "ok" and may be set to "violation" for checks that are
supposed to fail: this is how "the fairness assumption is really needed" is
turned into a CI gate. Checks of kind "run" may declare `witnesses`; the driver
also fails when a witness is never observed, which detects a simulation that no
longer reaches the interesting behaviours.

The Quint CLI is taken from `$PATH` when available and installed into `.tools/`
with npm otherwise. Apalache and TLC are downloaded by Quint itself on first use
(into `~/.quint`), so only Node.js 18+ and Java 17+ are needed.
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

QUINT_VERSION = os.environ.get("QUINT_VERSION", "0.32.0")
REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLS_DIR = Path(os.environ.get("QUINT_TOOLS_DIR", REPO_ROOT / ".tools"))
QUINT_PREFIX = TOOLS_DIR / "quint"
# The rust evaluator is fetched from the GitHub API on first use, which is not
# always reachable; the typescript one ships with the CLI itself.
DEFAULT_EVALUATOR = os.environ.get("QUINT_BACKEND", "typescript")
MANIFEST = "checks.json"

OK = re.compile(r"^\[ok\]", re.M)
VIOLATION = re.compile(r"^\[violation\]", re.M)
PASSING = re.compile(r"^\s*(\d+) passing", re.M)
FAILED = re.compile(r"^\s*(\d+) failed", re.M)
DURATION = re.compile(r"\((\d+)ms")
WITNESSED = re.compile(r"^(\S+) was witnessed in (\d+) trace", re.M)
TRACES = re.compile(r"out of (\d+) explored")
STATES = re.compile(r"([\d,]+) distinct states found")


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def quint_bin() -> str:
    """The Quint CLI: from the environment, from $PATH, or installed locally."""
    if os.environ.get("QUINT_BIN"):
        return os.environ["QUINT_BIN"]
    on_path = shutil.which("quint")
    if on_path:
        return on_path
    local = QUINT_PREFIX / "node_modules" / ".bin" / "quint"
    if not local.exists():
        if shutil.which("npm") is None:
            fail("node.js 18 or later (with npm) is required to run Quint")
        QUINT_PREFIX.mkdir(parents=True, exist_ok=True)
        print(f"installing quint {QUINT_VERSION} into {QUINT_PREFIX} ...", file=sys.stderr)
        subprocess.run(  # noqa: S603
            ["npm", "install", "--silent", "--no-audit", "--no-fund",
             "--prefix", str(QUINT_PREFIX), f"@informalsystems/quint@{QUINT_VERSION}"],
            check=True,
        )
    return str(local)


class Check:
    """One invocation of the Quint CLI plus its expected outcome."""

    KINDS = ("test", "run", "verify")

    def __init__(self, spec: Path, entry: dict) -> None:
        self.spec = spec
        self.name = entry.get("name") or fail(f"{spec}: a check needs a name")
        self.kind = entry.get("kind", "verify")
        self.expect = entry.get("expect", "ok")
        self.main = entry.get("main")
        self.entry = entry
        if self.kind not in self.KINDS:
            fail(f"{self.name}: unknown kind {self.kind!r}")
        if self.expect not in ("ok", "violation"):
            fail(f"{self.name}: unknown expectation {self.expect!r}")

    @property
    def witnesses(self) -> list[str]:
        return self.entry.get("witnesses", [])

    @property
    def description(self) -> str:
        target = self.entry.get("invariants") or self.entry.get("temporal") or ["--"]
        return f"{self.kind:<7} {self.main or '':<16} {','.join(target)}"

    def command(self) -> list[str]:
        entry, args = self.entry, [quint_bin(), self.kind, self.spec.name]
        if self.main:
            args += [f"--main={self.main}"]
        if self.kind == "verify":
            args += [f"--backend={entry.get('backend', 'apalache')}"]
        else:
            args += [f"--backend={entry.get('evaluator', DEFAULT_EVALUATOR)}"]
        for option in ("max-steps", "max-samples", "seed", "match", "init", "step"):
            value = entry.get(option.replace("-", "_"))
            if value is not None:
                args += [f"--{option}={value}"]
        if entry.get("invariants"):
            args += ["--invariants", *entry["invariants"]]
        if entry.get("temporal"):
            args += [f"--temporal={','.join(entry['temporal'])}"]
        if self.witnesses:
            args += ["--witnesses", *self.witnesses]
        return args + entry.get("args", [])

    def run(self, capture: bool) -> tuple[str, float]:
        started = time.monotonic()
        stream = subprocess.PIPE if capture else None
        result = subprocess.run(  # noqa: S603
            self.command(),
            cwd=self.spec.parent,
            input="y\n",  # answer the "experimental support" prompt of quint verify
            stdout=stream,
            stderr=subprocess.STDOUT if capture else None,
            text=True,
            check=False,
        )
        self.returncode = result.returncode
        return result.stdout or "", time.monotonic() - started

    def outcome(self, output: str) -> str:
        """Classify a run as "ok", "violation" or "error"."""
        if self.kind == "test":
            if PASSING.search(output) and not FAILED.search(output):
                return "ok"
            return "violation" if FAILED.search(output) else "error"
        if VIOLATION.search(output):
            return "violation"
        if OK.search(output) and self.returncode == 0:
            return "ok"
        return "error"

    def unwitnessed(self, output: str) -> list[str]:
        counts = {name: int(n) for name, n in WITNESSED.findall(output)}
        return [w for w in self.witnesses if counts.get(w, 0) == 0]

    def summary(self, output: str) -> str:
        if self.kind == "test":
            passing = PASSING.search(output)
            failed = FAILED.search(output)
            parts = [f"{passing.group(1)} passing"] if passing else []
            if failed:
                parts.append(f"{failed.group(1)} failed")
            return ", ".join(parts) or "no test"
        states = STATES.search(output)
        traces = TRACES.search(output)
        detail = VIOLATION.search(output) and "violation found" or "no violation"
        if states:
            detail += f", {states.group(1)} distinct states"
        elif traces:
            detail += f", {traces.group(1)} traces"
        return detail


def discover(paths: list[Path], only: str | None = None) -> list[Check]:
    checks: list[Check] = []
    for path in paths:
        manifest = path / MANIFEST if path.is_dir() else path
        if manifest.name != MANIFEST or not manifest.exists():
            fail(f"no {MANIFEST} found at {path}")
        document = json.loads(manifest.read_text())
        spec = manifest.parent / document.get("spec", "models.qnt")
        if not spec.exists():
            fail(f"{manifest} refers to a missing specification: {spec}")
        checks += [Check(spec, entry) for entry in document["checks"]]
    selected = [c for c in checks if only in (None, c.name)]
    if not selected:
        fail(f"no check matched {only!r}")
    return selected


def cmd_checks(args: argparse.Namespace) -> int:
    checks = discover(args.paths)
    width = max(len(c.name) for c in checks)
    for check in checks:
        print(f"{check.name:<{width}}  {check.description:<48} expect {check.expect}")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    checks = discover(args.paths, args.only)
    width = max(len(c.name) for c in checks)
    failures = []
    for check in checks:
        output, elapsed = check.run(capture=True)
        got = check.outcome(output)
        unwitnessed = check.unwitnessed(output) if got == "ok" else []
        ok = got == check.expect and not unwitnessed
        detail = check.summary(output) if got != "error" else "QUINT FAILED"
        if unwitnessed:
            detail += ", never witnessed: " + ", ".join(unwitnessed)
        print(f"{'ok  ' if ok else 'FAIL'} {check.name:<{width}}  {detail} ({elapsed:.0f}s)")
        if not ok:
            failures.append(check)
            if got == "error":
                print(output.strip()[-2000:], file=sys.stderr)
    print()
    print(f"{len(checks) - len(failures)}/{len(checks)} checks as expected")
    if failures:
        print("unexpected results: " + ", ".join(c.name for c in failures), file=sys.stderr)
        print(
            f"inspect one with: {sys.argv[0]} trace {failures[0].spec.parent} "
            f"--only {failures[0].name}",
            file=sys.stderr,
        )
        return 1
    return 0


def cmd_trace(args: argparse.Namespace) -> int:
    check = discover(args.paths, args.only)[0]
    check.run(capture=False)
    return 0 if check.expect == "violation" else check.returncode


def cmd_typecheck(args: argparse.Namespace) -> int:
    return subprocess.run(  # noqa: S603
        [quint_bin(), "typecheck", args.spec.name], cwd=args.spec.parent, check=False
    ).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="subcommand", required=True)

    verify = sub.add_parser("verify", help="run the checks and summarize the results")
    verify.add_argument("paths", type=Path, nargs="+")
    verify.add_argument("--only", help="name of the single check to run")
    verify.set_defaults(func=cmd_verify)

    checks = sub.add_parser("checks", help="list the checks declared under a path")
    checks.add_argument("paths", type=Path, nargs="+")
    checks.set_defaults(func=cmd_checks)

    trace = sub.add_parser("trace", help="run one check and show the full output")
    trace.add_argument("paths", type=Path, nargs=1)
    trace.add_argument("--only", required=True, help="name of the check to run")
    trace.set_defaults(func=cmd_trace)

    typecheck = sub.add_parser("typecheck", help="typecheck a single specification")
    typecheck.add_argument("spec", type=Path)
    typecheck.set_defaults(func=cmd_typecheck)

    args = parser.parse_args()
    for path in [*getattr(args, "paths", []), *filter(None, [getattr(args, "spec", None)])]:
        if not path.exists():
            fail(f"no such path: {path}")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
