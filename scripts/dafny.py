#!/usr/bin/env python3
"""Command-line driver for the Dafny specifications in this repository.

Subcommands:

    verify <path>... [--only NAME]   run the checks of a model and summarize
    checks <path>...                 list the checks declared under a path
    trace  <path> --only NAME        run one check and print the full output
    run    <path> [ARG...]           execute the model's entry point on ARG...
    dafny  ARG...                    pass ARG... straight to the Dafny CLI

A "check" is one invocation of the Dafny CLI (`dafny format --check`,
`dafny verify`, `dafny test` or `dafny run`) together with the outcome it is
expected to produce. The checks of a topic are declared in
`<topic>/dafny/checks.json`:

    {
      "entry": "Demo.dfy",
      "checks": [
        {"name": "format", "kind": "format", "files": ["*.dfy", "negative/*.dfy"]},
        {"name": "verify", "kind": "verify", "files": ["Scenarios.dfy", "Demo.dfy"]},
        {"name": "tests", "kind": "test", "files": ["Scenarios.dfy"]},
        {"name": "negative-authority-leak", "kind": "verify",
         "files": ["negative/AuthorityLeak.dfy"], "expect": "violation"}
      ]
    }

`expect` defaults to "ok" and may be set to "violation" for checks that are
supposed to fail. That is how the negative checks under `negative/` become CI
gates: each states a property the model must *not* have (a manager of any
department deciding, a directory without a manager), so a rule that is widened
by accident stops failing there and the driver reports it.

`files` are relative to the model directory and may be globs. A `.dfy` file
pulls in the files it `include`s, so a check needs to name only the roots.

Compilation and execution use the Python backend (`--target=py`), which needs
nothing beyond the Python 3 that runs this script -- unlike the C# backend,
which would require the .NET SDK.

The Dafny CLI is taken from `$DAFNY_BIN`, then `$PATH`, and otherwise the
self-contained release (Dafny with its bundled Z3) is downloaded and unpacked
into `.tools/dafny-<version>`.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from urllib.request import Request, urlopen

DAFNY_VERSION = os.environ.get("DAFNY_VERSION", "4.11.0")
DAFNY_ASSETS = {
    ("Linux", "x86_64"): "x64-ubuntu-22.04",
    ("Darwin", "x86_64"): "x64-macos-13",
    ("Darwin", "arm64"): "arm64-macos-13",
    ("Windows", "AMD64"): "x64-windows-2022",
}
DAFNY_URL = "https://github.com/dafny-lang/dafny/releases/download/v{version}/dafny-{version}-{asset}.zip"
REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLS_DIR = Path(os.environ.get("DAFNY_TOOLS_DIR", REPO_ROOT / ".tools"))
DAFNY_PREFIX = TOOLS_DIR / f"dafny-{DAFNY_VERSION}"
MANIFEST = "checks.json"
TARGET = os.environ.get("DAFNY_TARGET", "py")

VERIFIED = re.compile(r"finished with (\d+) verified, (\d+) error", re.M)
TEST_RESULT = re.compile(r"^(\S+): (PASSED|FAILED)", re.M)
NEEDS_FORMAT = re.compile(r"^The file (.*) needs to be formatted", re.M)
FORMATTED = re.compile(r"^(\d+) files? (?:were|was) already formatted", re.M)


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


# ---------------------------------------------------------------------------
# tools
# ---------------------------------------------------------------------------


def download(url: str, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(target.suffix + ".part")
    request = Request(url, headers={"User-Agent": "formalspec-cookbook/scripts/dafny.py"})  # noqa: S310
    with urlopen(request) as response, tmp.open("wb") as out:  # noqa: S310
        shutil.copyfileobj(response, out)
    tmp.rename(target)


def dafny_bin() -> str:
    """The Dafny CLI: from the environment, from $PATH, or downloaded."""
    if os.environ.get("DAFNY_BIN"):
        return os.environ["DAFNY_BIN"]
    on_path = shutil.which("dafny")
    if on_path:
        return on_path
    executable = "dafny.exe" if platform.system() == "Windows" else "dafny"
    local = DAFNY_PREFIX / executable
    if local.exists():
        return str(local)
    asset = DAFNY_ASSETS.get((platform.system(), platform.machine()))
    if not asset:
        fail(f"no Dafny release for {platform.system()}/{platform.machine()}; "
             "install Dafny and put it on PATH or set DAFNY_BIN")
    url = DAFNY_URL.format(version=DAFNY_VERSION, asset=asset)
    print(f"downloading Dafny {DAFNY_VERSION} into {DAFNY_PREFIX} ...", file=sys.stderr)
    archive = TOOLS_DIR / f"dafny-{DAFNY_VERSION}.zip"
    download(url, archive)
    with tempfile.TemporaryDirectory(dir=TOOLS_DIR) as staging:
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(staging)  # noqa: S202
        shutil.move(str(Path(staging) / "dafny"), DAFNY_PREFIX)
    archive.unlink()
    # The zip does not preserve the executable bits.
    for path in DAFNY_PREFIX.rglob("*"):
        if path.is_file() and (path.suffix in {"", ".so", ".dylib"} or path.name.startswith("z3")):
            path.chmod(path.stat().st_mode | 0o111)
    return str(local)


def dafny(args: list[str], **kwargs: object) -> subprocess.CompletedProcess:
    return subprocess.run([dafny_bin(), *args], check=False, **kwargs)  # noqa: S603


# ---------------------------------------------------------------------------
# models and checks
# ---------------------------------------------------------------------------


class Model:
    """A model directory: the Dafny sources plus the checks declared on them."""

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
            files += [str(path) for path in matches]
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
        "format": "dafny format --check",
        "verify": "dafny verify",
        "test": f"dafny test --target={TARGET}",
        "run": f"dafny run --target={TARGET}",
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

    def command(self) -> list[str]:
        files = self.model.resolve(self.files)
        if self.kind == "format":
            return ["format", "--check", *files]
        if self.kind == "verify":
            return ["verify", *files]
        # `test` and `run` leave the generated Python next to the model; the
        # `*-py/` directories are ignored by git.
        return [self.kind, f"--target={TARGET}", *files]

    def run(self, extra: list[str] | None = None) -> tuple[str, int, float]:
        started = time.monotonic()
        result = dafny([*self.command(), *(extra or [])], capture_output=True, text=True)
        return result.stdout + result.stderr, result.returncode, time.monotonic() - started

    def passed(self, returncode: int) -> bool:
        return (returncode == 0) == (self.expect == "ok")

    def summary(self, output: str, returncode: int) -> str:
        expected = "" if self.expect == "ok" else "as expected, " if returncode != 0 else "unexpectedly "
        if self.kind == "format":
            unformatted = NEEDS_FORMAT.findall(output)
            if unformatted:
                names = ", ".join(Path(f).name for f in unformatted)
                return f"not formatted: {names} (run: dafny format <files>)"
            count = FORMATTED.search(output)
            return f"{count.group(1)} files canonically formatted" if count else "canonically formatted"
        verdict = VERIFIED.search(output)
        counts = ""
        if verdict:
            verified, errors = verdict.groups()
            counts = f"{verified} proof obligation group(s) verified"
            if int(errors):
                counts = f"{expected}{errors} verification error(s), {verified} verified"
        if self.kind == "test":
            results = TEST_RESULT.findall(output)
            failed = [name for name, verdict in results if verdict == "FAILED"]
            tests = f"{len(results) - len(failed)}/{len(results)} scenarios passed"
            return f"{tests}, {counts}" if counts else tests
        if self.kind == "run":
            lines = [line for line in output.splitlines() if line.strip()]
            return f"{counts}, {len(lines)} line(s) of output" if counts else "executed"
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
    """Execute the model: one command line per argument, as `<actor> <verb> ...`."""
    model = discover(args.paths)[0]
    if not model.entry:
        fail(f"{model.display}: {MANIFEST} declares no entry point")
    command = ["run", f"--target={TARGET}", *model.resolve([model.entry])]
    if args.inputs:
        command += ["--", *args.inputs]
    return dafny(command).returncode


def cmd_dafny(args: argparse.Namespace) -> int:
    """A leading `--` separates the driver's options from Dafny's own."""
    passthrough = args.args[1:] if args.args[:1] == ["--"] else args.args
    return dafny(passthrough).returncode


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

    run = sub.add_parser("run", help="execute the model on command lines")
    run.add_argument("paths", type=Path, nargs=1)
    run.add_argument("inputs", nargs="*", help="e.g. 'alice create sales laptop 1500'")
    run.set_defaults(func=cmd_run)

    raw = sub.add_parser("dafny", help="invoke the Dafny CLI directly")
    raw.add_argument("args", nargs=argparse.REMAINDER)
    raw.set_defaults(func=cmd_dafny, paths=[])

    args = parser.parse_args()
    for path in args.paths:
        if not path.exists():
            fail(f"no such path: {path}")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
