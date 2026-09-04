#!/usr/bin/env python3
"""Command-line driver for the LemmaScript specifications in this repository.

Subcommands:

    verify <path>... [--only NAME]   run the checks of a model and summarize
    checks <path>...                 list the checks declared under a path
    trace  <path> --only NAME        run one check and print the full output
    run    <path>                    execute the model's scenarios under Node.js
    lsc    ARG...                    pass ARG... straight to the LemmaScript CLI
    dafny  ARG...                    pass ARG... straight to the Dafny CLI

A LemmaScript model is annotated TypeScript (`foo.ts`) that `lsc` compiles to
Dafny: `foo.dfy.gen` is regenerated from the TypeScript on every run and must
not be edited, `foo.dfy` is its proof-owned copy to which helper lemmas and
loop invariants are *added* (never modified), and `lsc check` verifies the
latter after confirming the diff between the two is additions-only. The checks
of a topic are declared in `<topic>/lemmascript/checks.json`:

    {
      "entry": "scenarios.ts",
      "checks": [
        {"name": "check", "kind": "check", "files": ["approval.ts"]},
        {"name": "scenarios", "kind": "run", "files": ["scenarios.ts"]},
        {"name": "negative-authority-leak", "kind": "verify",
         "files": ["negative/AuthorityLeak.dfy"], "expect": "violation"}
      ]
    }

The kinds are:

    check    `lsc check --backend=dafny` on each TypeScript file: regenerate
             `.dfy.gen`, confirm `.dfy` is additions-only, run `dafny verify`
             on it. The check also fails if the committed `.dfy.gen` was stale,
             so a `.ts` edited without `lsc regen` cannot pass CI.
    verify   `dafny verify` on hand-written Dafny files that `include` the
             generated model — used for the negative checks under `negative/`.
    run      execute a TypeScript file with Node.js (>= 22.18, which strips type
             annotations natively). The same functions that were verified run.

`expect` defaults to "ok" and may be set to "violation" for checks that are
supposed to fail.

Tools: the LemmaScript CLI comes from $LSC_BIN, else `lsc` on PATH if it is the
pinned version, else an `npm install` of the pinned version into
`.tools/lemmascript/` (Node.js and npm are the only prerequisites). Dafny is
resolved exactly as by scripts/dafny.py (downloaded into `.tools/` on demand),
and its directory is prepended to PATH for `lsc`.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

LSC_VERSION = os.environ.get("LSC_VERSION", "0.6.1")
REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLS_DIR = Path(os.environ.get("LSC_TOOLS_DIR", REPO_ROOT / ".tools"))
LSC_PREFIX = TOOLS_DIR / "lemmascript"
MANIFEST = "checks.json"

VERIFIED = re.compile(r"finished with (\d+) verified, (\d+) error", re.M)
SCENARIOS = re.compile(r"^(\d+)/(\d+) scenarios passed", re.M)
GENERATED = re.compile(r"^Generated: (.*)$", re.M)


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


# ---------------------------------------------------------------------------
# tools
# ---------------------------------------------------------------------------


def load_dafny_driver():
    spec = importlib.util.spec_from_file_location("dafny_driver", Path(__file__).with_name("dafny.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


DAFNY = load_dafny_driver()


def lsc_version(binary: str) -> str | None:
    try:
        result = subprocess.run([binary, "version"], capture_output=True, text=True, check=False)  # noqa: S603
    except OSError:
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def lsc_bin() -> str:
    """The LemmaScript CLI: from the environment, from $PATH, or installed with npm."""
    if os.environ.get("LSC_BIN"):
        return os.environ["LSC_BIN"]
    on_path = shutil.which("lsc")
    if on_path and lsc_version(on_path) == LSC_VERSION:
        return on_path
    executable = "lsc.cmd" if os.name == "nt" else "lsc"
    local = LSC_PREFIX / "node_modules" / ".bin" / executable
    if local.exists() and lsc_version(str(local)) == LSC_VERSION:
        return str(local)
    npm = shutil.which("npm")
    if not npm:
        fail("npm not found; install Node.js >= 22.18 (https://nodejs.org/) or set LSC_BIN")
    print(f"installing lemmascript {LSC_VERSION} into {LSC_PREFIX} ...", file=sys.stderr)
    LSC_PREFIX.mkdir(parents=True, exist_ok=True)
    (LSC_PREFIX / "package.json").write_text(json.dumps({"name": "formalspec-cookbook-lemmascript", "private": True}))
    subprocess.run(  # noqa: S603
        [npm, "install", "--no-audit", "--no-fund", "--no-package-lock", f"lemmascript@{LSC_VERSION}"],
        cwd=LSC_PREFIX, check=True)
    return str(local)


def node_bin() -> str:
    node = shutil.which("node")
    if not node:
        fail("node not found; install Node.js >= 22.18 (https://nodejs.org/)")
    return node


def tool_env() -> dict[str, str]:
    env = dict(os.environ)
    env["PATH"] = str(Path(DAFNY.dafny_bin()).parent) + os.pathsep + env.get("PATH", "")
    return env


def run_tool(command: list[str], **kwargs: object) -> subprocess.CompletedProcess:
    return subprocess.run(command, check=False, env=tool_env(), **kwargs)  # noqa: S603


# ---------------------------------------------------------------------------
# models and checks
# ---------------------------------------------------------------------------


class Model:
    """A model directory: the LemmaScript sources plus the checks declared on them."""

    def __init__(self, directory: Path) -> None:
        self.dir = directory
        manifest = directory / MANIFEST
        if not manifest.exists():
            fail(f"{directory}: no {MANIFEST}")
        self.manifest = json.loads(manifest.read_text())
        self.entry = self.manifest.get("entry")

    @property
    def display(self) -> str:
        return str(self.dir)

    def resolve(self, patterns: list[str]) -> list[str]:
        files: list[str] = []
        for pattern in patterns:
            matches = sorted(self.dir.glob(pattern))
            if not matches:
                fail(f"{self.display}: no file matches {pattern!r}")
            files += [str(path.resolve()) for path in matches]
        return files

    def checks(self, only: str | None = None) -> list[Check]:
        checks = [Check(self, spec) for spec in self.manifest["checks"]]
        if only is not None:
            checks = [c for c in checks if c.name == only]
            if not checks:
                fail(f"{self.display}: no check named {only!r}")
        return checks


class Check:
    KINDS = {
        "check": "lsc check --backend=dafny",
        "verify": "dafny verify",
        "run": "node",
    }

    def __init__(self, model: Model, spec: dict) -> None:
        self.model = model
        self.name = spec["name"]
        self.kind = spec["kind"]
        self.expect = spec.get("expect", "ok")
        self.files = spec.get("files") or ([model.entry] if model.entry else [])
        self.note = spec.get("description", "")
        if self.kind not in Check.KINDS:
            fail(f"{model.display}: unknown check kind {self.kind!r}")

    @property
    def description(self) -> str:
        parts = [Check.KINDS[self.kind], " ".join(self.files)]
        if self.expect != "ok":
            parts.append(f"[expected: {self.expect}]")
        return "  ".join(p for p in parts if p)

    def run(self) -> tuple[str, int, float]:
        started = time.monotonic()
        output, returncode = "", 0
        for file in self.model.resolve(self.files):
            if self.kind == "check":
                out, code = self.run_lsc_check(Path(file))
            elif self.kind == "verify":
                result = DAFNY.dafny(["verify", file], capture_output=True, text=True)
                out, code = result.stdout + result.stderr, result.returncode
            else:
                result = run_tool([node_bin(), file], capture_output=True, text=True)
                out, code = result.stdout + result.stderr, result.returncode
            output += out
            returncode = returncode or code
        return output, returncode, time.monotonic() - started

    def run_lsc_check(self, source: Path) -> tuple[str, int]:
        """`lsc check`, plus a staleness test of the committed `.dfy.gen`."""
        generated = source.with_suffix(".dfy.gen")
        before = generated.read_text() if generated.exists() else None
        result = run_tool([lsc_bin(), "check", "--backend=dafny", str(source)], capture_output=True, text=True)
        output = result.stdout + result.stderr
        if result.returncode == 0 and before is not None and generated.read_text() != before:
            output += (f"\n{generated.name} was stale: {source.name} changed but the generated Dafny was not "
                       f"regenerated. Run `lsc regen --backend=dafny {source.name}` and commit the result.\n")
            return output, 1
        return output, result.returncode

    def passed(self, returncode: int) -> bool:
        return (returncode == 0) == (self.expect == "ok")

    def summary(self, output: str, returncode: int) -> str:
        expected = "" if self.expect == "ok" else "as expected, " if returncode != 0 else "unexpectedly "
        if "was stale" in output:
            return "generated Dafny is stale (run: lsc regen --backend=dafny <file.ts>)"
        if "not additions-only" in output:
            return "proof file modifies generated lines (must be additions-only)"
        verdict = VERIFIED.search(output)
        counts = ""
        if verdict:
            verified, errors = verdict.groups()
            counts = f"{verified} proof obligation group(s) verified"
            if int(errors):
                counts = f"{expected}{errors} verification error(s), {verified} verified"
        if self.kind == "check":
            generated = [Path(p).name for p in GENERATED.findall(output)]
            regen = f"{', '.join(generated)} regenerated, " if generated else ""
            return f"{regen}{counts}" if counts else regen + ("passed" if self.passed(returncode) else "failed")
        if self.kind == "run":
            scenarios = SCENARIOS.search(output)
            if scenarios:
                return f"{scenarios.group(1)}/{scenarios.group(2)} scenarios passed"
            return "executed" if returncode == 0 else "exited with an error"
        return counts or ("passed" if self.passed(returncode) else "failed")


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
    output, returncode, _ = check.run()
    print(output, end="")
    return 0 if check.passed(returncode) else 1


def cmd_run(args: argparse.Namespace) -> int:
    """Execute the model's entry point (its scenarios) with Node.js."""
    model = discover(args.paths)[0]
    if not model.entry:
        fail(f"{model.display}: {MANIFEST} declares no entry point")
    return run_tool([node_bin(), *model.resolve([model.entry])]).returncode


def passthrough(args: argparse.Namespace) -> list[str]:
    """A leading `--` separates the driver's options from the tool's own."""
    return args.args[1:] if args.args[:1] == ["--"] else args.args


def cmd_lsc(args: argparse.Namespace) -> int:
    return run_tool([lsc_bin(), *passthrough(args)]).returncode


def cmd_dafny(args: argparse.Namespace) -> int:
    return DAFNY.dafny(passthrough(args)).returncode


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

    run = sub.add_parser("run", help="execute the model's scenarios with Node.js")
    run.add_argument("paths", type=Path, nargs=1)
    run.set_defaults(func=cmd_run)

    lsc = sub.add_parser("lsc", help="invoke the LemmaScript CLI directly")
    lsc.add_argument("args", nargs=argparse.REMAINDER)
    lsc.set_defaults(func=cmd_lsc, paths=[])

    dafny = sub.add_parser("dafny", help="invoke the Dafny CLI directly")
    dafny.add_argument("args", nargs=argparse.REMAINDER)
    dafny.set_defaults(func=cmd_dafny, paths=[])

    args = parser.parse_args()
    for path in args.paths:
        if not path.exists():
            fail(f"no such path: {path}")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
