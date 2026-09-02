#!/usr/bin/env python3
"""Command-line driver for the Lean 4 specifications in this repository.

Subcommands:

    verify  <dir>... [--only NAME]      run every check of a project and summarize
    checks  <dir>...                    list the checks a project directory yields
    trace   <dir> --only NAME           run one check and print the full output
    run     <dir> [ARG...]              run the project's executable (scenario replay)
    lake    <dir> ARG...                pass ARG... straight to `lake` in the project

A model directory is a Lake project (`lakefile.toml` + `lean-toolchain`). The
checks derived from it:

    build     `lake build`: every definition type-checks and every theorem is
              proved. A proof that leans on `sorry` is reported by Lean as a
              warning; the check fails on it.
    axioms    `lake env lean Audit.lean`: `#print axioms` for the main theorems.
              Fails if `sorryAx` shows up, and lists the axioms that were used
              (at most the standard `propext` / `Classical.choice` / `Quot.sound`).
    run       `lake exe <exe>`: replays the scenario scripts and checks each line
              against its expected outcome (the same scripts are `#guard`ed at
              compile time; this check makes the traces visible).

Lean is managed by elan. `lake` is taken from `$PATH`, then `$ELAN_HOME/bin`,
then `~/.elan/bin`; otherwise elan is installed into `.tools/elan` with no
default toolchain. The toolchain pinned by the project's `lean-toolchain` file
is downloaded by elan on first use.
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
from pathlib import Path
from urllib.request import Request, urlopen

ELAN_INIT_URL = "https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh"
REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLS_DIR = Path(os.environ.get("LEAN_TOOLS_DIR", REPO_ROOT / ".tools"))
ELAN_PREFIX = TOOLS_DIR / "elan"

BUILT = re.compile(r"^✔ \[\d+/\d+\] Built (\S+)", re.M)
SORRY = re.compile(r"declaration uses 'sorry'|sorryAx")
AXIOMS = re.compile(r"depends on axioms: \[([^\]]*)\]")
AUDITED = re.compile(r"^'[^']+' (?:depends on axioms|does not depend on any axioms)", re.M)
SCENARIOS = re.compile(r"^(\d+)/(\d+) scenarios passed", re.M)
ALLOWED_AXIOMS = {"propext", "Classical.choice", "Quot.sound"}


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


# ---------------------------------------------------------------------------
# tools
# ---------------------------------------------------------------------------


def download(url: str, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(target.suffix + ".part")
    request = Request(url, headers={"User-Agent": "formalspec-cookbook/scripts/lean.py"})  # noqa: S310
    with urlopen(request) as response, tmp.open("wb") as out:  # noqa: S310
        shutil.copyfileobj(response, out)
    tmp.rename(target)


def lake_bin() -> str:
    """`lake` from $PATH, an existing elan home, or a fresh elan in .tools/elan."""
    on_path = shutil.which("lake")
    if on_path:
        return on_path
    homes = [Path(os.environ["ELAN_HOME"])] if os.environ.get("ELAN_HOME") else []
    homes += [Path.home() / ".elan", ELAN_PREFIX]
    for home in homes:
        lake = home / "bin" / "lake"
        if lake.exists():
            return str(lake)
    print(f"installing elan into {ELAN_PREFIX} ...", file=sys.stderr)
    with tempfile.TemporaryDirectory() as staging:
        script = Path(staging) / "elan-init.sh"
        download(ELAN_INIT_URL, script)
        env = dict(os.environ, ELAN_HOME=str(ELAN_PREFIX))
        result = subprocess.run(  # noqa: S603
            ["sh", str(script), "-y", "--no-modify-path", "--default-toolchain", "none"],
            env=env, check=False)
    if result.returncode != 0:
        fail("elan installation failed")
    return str(ELAN_PREFIX / "bin" / "lake")


def lake_env() -> dict[str, str]:
    """elan's proxies find their home through ELAN_HOME; point it at the elan owning `lake`."""
    lake = Path(lake_bin()).resolve()
    env = dict(os.environ)
    home = lake.parent.parent
    if (home / "toolchains").exists() or home == ELAN_PREFIX:
        env.setdefault("ELAN_HOME", str(home))
    env["PATH"] = str(lake.parent) + os.pathsep + env.get("PATH", "")
    return env


def lake(project: Path, args: list[str], **kwargs: object) -> subprocess.CompletedProcess:
    return subprocess.run([lake_bin(), *args], cwd=project, env=lake_env(), check=False, **kwargs)  # noqa: S603


# ---------------------------------------------------------------------------
# projects and checks
# ---------------------------------------------------------------------------


class Project:
    """A Lake project directory."""

    def __init__(self, directory: Path) -> None:
        self.dir = directory
        if not (directory / "lakefile.toml").exists() and not (directory / "lakefile.lean").exists():
            fail(f"{directory}: not a Lake project (no lakefile.toml)")
        if not (directory / "lean-toolchain").exists():
            fail(f"{directory}: no lean-toolchain file")
        self.audit = directory / "Audit.lean"
        self.exe = self._exe_name()

    def _exe_name(self) -> str | None:
        lakefile = self.dir / "lakefile.toml"
        if not lakefile.exists():
            return None
        text = lakefile.read_text(encoding="utf-8")
        match = re.search(r"\[\[lean_exe\]\]\s*\n\s*name\s*=\s*\"([^\"]+)\"", text)
        return match.group(1) if match else None

    @property
    def display(self) -> str:
        return str(self.dir)

    def checks(self, only: str | None = None) -> list[Check]:
        checks: list[Check] = [BuildCheck(self)]
        if self.audit.exists():
            checks.append(AxiomsCheck(self))
        if self.exe:
            checks.append(RunCheck(self))
        if only is not None:
            checks = [c for c in checks if c.name == only]
            if not checks:
                fail(f"{self.display}: no check named {only!r}")
        return checks


class Check:
    name = ""
    description = ""

    def __init__(self, project: Project) -> None:
        self.project = project

    def command(self) -> list[str]:
        raise NotImplementedError

    def run(self) -> tuple[str, int, float]:
        started = time.monotonic()
        result = lake(self.project.dir, self.command(), capture_output=True, text=True)
        output = result.stdout + result.stderr
        returncode = result.returncode or self.extra_failure(output)
        return output, returncode, time.monotonic() - started

    def extra_failure(self, output: str) -> int:
        return 0

    def summary(self, output: str, returncode: int) -> str:
        return "passed" if returncode == 0 else "failed"


class BuildCheck(Check):
    name = "build"
    description = "lake build (definitions type-check, theorems are proved, no sorry)"

    def command(self) -> list[str]:
        return ["build"]

    def extra_failure(self, output: str) -> int:
        return 1 if SORRY.search(output) else 0

    def summary(self, output: str, returncode: int) -> str:
        if SORRY.search(output):
            return "incomplete proof (sorry)"
        if returncode != 0:
            return "build error"
        modules = [m for m in BUILT.findall(output) if not m.endswith((":c.o", ":exe"))]
        return f"{len(modules)} modules checked, no sorry" if modules else "up to date, no sorry"


class AxiomsCheck(Check):
    name = "axioms"
    description = "lake env lean Audit.lean (#print axioms: no sorryAx, standard axioms only)"

    def command(self) -> list[str]:
        return ["env", "lean", self.project.audit.name]

    def used(self, output: str) -> set[str]:
        return {a.strip() for group in AXIOMS.findall(output) for a in group.split(",") if a.strip()}

    def extra_failure(self, output: str) -> int:
        return 1 if self.used(output) - ALLOWED_AXIOMS else 0

    def summary(self, output: str, returncode: int) -> str:
        used = self.used(output)
        if "sorryAx" in used:
            return "incomplete proof (sorryAx)"
        if used - ALLOWED_AXIOMS:
            return "non-standard axioms: " + ", ".join(sorted(used - ALLOWED_AXIOMS))
        if returncode != 0:
            return "audit failed"
        audited = len(AUDITED.findall(output))
        axioms = ", ".join(sorted(used)) or "none"
        return f"{audited} theorems audited, axioms used: {axioms}"


class RunCheck(Check):
    name = "run"
    description = "lake exe (replay the scenario scripts against their expected outcomes)"

    def command(self) -> list[str]:
        return ["exe", self.project.exe or ""]

    def summary(self, output: str, returncode: int) -> str:
        match = SCENARIOS.search(output)
        if match:
            return f"{match.group(1)}/{match.group(2)} scenarios passed"
        return "passed" if returncode == 0 else "failed"


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------


def discover(paths: list[Path]) -> list[Project]:
    return [Project(path if path.is_dir() else path.parent) for path in paths]


def all_checks(paths: list[Path], only: str | None = None) -> list[Check]:
    return [c for p in discover(paths) for c in p.checks(only)]


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
        ok = returncode == 0
        print(f"{'ok  ' if ok else 'FAIL'} {check.name:<{width}}  {check.summary(output, returncode)} ({elapsed:.1f}s)")
        if not ok:
            failures.append(check)
            print(output.strip()[-3000:], file=sys.stderr)
    print()
    print(f"{len(checks) - len(failures)}/{len(checks)} checks passed")
    if failures:
        print("failed: " + ", ".join(c.name for c in failures), file=sys.stderr)
        print(f"inspect one with: {sys.argv[0]} trace {failures[0].project.display} --only {failures[0].name}",
              file=sys.stderr)
        return 1
    return 0


def cmd_trace(args: argparse.Namespace) -> int:
    check = all_checks(args.paths, args.only)[0]
    output, returncode, _ = check.run()
    print(output, end="")
    return 0 if returncode == 0 else 1


def cmd_run(args: argparse.Namespace) -> int:
    project = discover(args.paths)[0]
    if not project.exe:
        fail(f"{project.display}: the lakefile declares no executable")
    return lake(project.dir, ["exe", project.exe, *args.args]).returncode


def cmd_lake(args: argparse.Namespace) -> int:
    project = discover(args.paths)[0]
    return lake(project.dir, args.args).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="subcommand", required=True)

    verify = sub.add_parser("verify", help="run the checks and summarize the results")
    verify.add_argument("paths", type=Path, nargs="+")
    verify.add_argument("--only", help="name of the single check to run")
    verify.set_defaults(func=cmd_verify)

    checks = sub.add_parser("checks", help="list the checks of a project directory")
    checks.add_argument("paths", type=Path, nargs="+")
    checks.set_defaults(func=cmd_checks)

    trace = sub.add_parser("trace", help="run one check and show the full output")
    trace.add_argument("paths", type=Path, nargs=1)
    trace.add_argument("--only", required=True, help="name of the check to run")
    trace.set_defaults(func=cmd_trace)

    run = sub.add_parser("run", help="run the project's executable (e.g. replay named scenarios)")
    run.add_argument("paths", type=Path, nargs=1)
    run.add_argument("args", nargs=argparse.REMAINDER)
    run.set_defaults(func=cmd_run)

    raw = sub.add_parser("lake", help="invoke lake in the project directory with the managed toolchain")
    raw.add_argument("paths", type=Path, nargs=1)
    raw.add_argument("args", nargs=argparse.REMAINDER)
    raw.set_defaults(func=cmd_lake)

    args = parser.parse_args()
    for path in args.paths:
        if not path.exists():
            fail(f"no such path: {path}")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
