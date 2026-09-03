#!/usr/bin/env python3
"""Command-line driver for the Souther specifications in this repository.

Subcommands:

    verify   <dir>... [--only NAME]      run every check of a model and summarize
    checks   <dir>...                    list the checks a model directory yields
    trace    <dir> --only NAME           run one check and print the full output
    examples <dir>                       print the compiler's example/adequacy report
    run      <dir> BEHAVIOR JSON...      execute one behavior, one JSON value per
                                         parameter, and print the result as JSON
    souther  ARG...                      pass ARG... straight to the Souther CLI

A model directory holds one module file (`*.sou`, not `*.examples.sou`) and any
number of attached example files (`*.examples.sou`). The checks derived from it:

    format    `souther fmt --check`: every file is in canonical form.
    compile   `souther compile`: the module and its examples type-check and the
              JVM classes (behaviors, data, JSON codecs) are generated.
    examples  `souther examples --strict`: every `example` row holds, and the rows
              cover the model — every behavior, every declared outcome, every
              invariant boundary — so the report's adequacy verdict is `satisfied`.

`run` is what makes the specification executable from a shell: the behavior is
looked up in the compiled module, each argument is decoded with the generated
codecs (a sum type is written as `{"type": "<Case>", ...fields}`, a newtype as
its bare value), and the result is printed as JSON in the same encoding.

Souther is a single self-executing jar that needs Java 25. The CLI is taken from
`$SOUTHER_BIN`, then from `$PATH` if that `souther` is the pinned version
(`$SOUTHER_VERSION`, default 0.1.0), and otherwise downloaded into `.tools/souther`.
Java is taken from `$JAVA_HOME`, then `$PATH`, if that `java` is 25 or later;
otherwise a Temurin JDK 25 is downloaded into `.tools/jdk-25`.
"""

from __future__ import annotations

import argparse
import functools
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile
from pathlib import Path
from urllib.request import Request, urlopen

SOUTHER_VERSION = os.environ.get("SOUTHER_VERSION", "0.1.0")
SOUTHER_URL = f"https://github.com/souther-lang/souther/releases/download/v{SOUTHER_VERSION}/souther"
JAVA_MAJOR = 25
JDK_URL = "https://api.adoptium.net/v3/binary/latest/{major}/ga/{os}/{arch}/jdk/hotspot/normal/eclipse"
REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLS_DIR = Path(os.environ.get("SOUTHER_TOOLS_DIR", REPO_ROOT / ".tools"))
SOUTHER_PREFIX = TOOLS_DIR / "souther"
JDK_PREFIX = TOOLS_DIR / f"jdk-{JAVA_MAJOR}"

JAVA_VERSION = re.compile(r'version "(\d+)')
ADEQUACY = re.compile(r"^adequacy:\s*(\S+)", re.M)
BEHAVIORS = re.compile(r"^(\d+) behaviors: (\d+) implemented", re.M)
GAPS = re.compile(r"^(\d+) gap\(s\) marked", re.M)
EXAMPLE_FAILED = re.compile(r"^-- EXAMPLE\s+E\d+", re.M)
WROTE = re.compile(r"^wrote ", re.M)


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


# ---------------------------------------------------------------------------
# tools
# ---------------------------------------------------------------------------


def java_major(java: str) -> int:
    out = subprocess.run([java, "-version"], capture_output=True, text=True, check=False).stderr  # noqa: S603
    match = JAVA_VERSION.search(out)
    return int(match.group(1)) if match else 0


def download(url: str, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(target.suffix + ".part")
    request = Request(url, headers={"User-Agent": "formalspec-cookbook/scripts/souther.py"})  # noqa: S310
    with urlopen(request) as response, tmp.open("wb") as out:  # noqa: S310
        shutil.copyfileobj(response, out)
    tmp.rename(target)


def java_bin() -> str:
    """A `java` of major version 25 or later: from JAVA_HOME, from $PATH, or downloaded."""
    candidates = []
    if os.environ.get("JAVA_HOME"):
        candidates.append(str(Path(os.environ["JAVA_HOME"]) / "bin" / "java"))
    if shutil.which("java"):
        candidates.append(shutil.which("java"))
    local = JDK_PREFIX / "bin" / "java"
    candidates.append(str(local))
    for java in candidates:
        if Path(java).exists() and java_major(java) >= JAVA_MAJOR:
            return java
    system = {"Linux": "linux", "Darwin": "mac"}.get(platform.system())
    arch = {"x86_64": "x64", "AMD64": "x64", "arm64": "aarch64", "aarch64": "aarch64"}.get(platform.machine())
    if not system or not arch:
        fail(f"Java {JAVA_MAJOR} is required; install it and put it on PATH or set JAVA_HOME")
    url = JDK_URL.format(major=JAVA_MAJOR, os=system, arch=arch)
    print(f"downloading a Temurin JDK {JAVA_MAJOR} into {JDK_PREFIX} ...", file=sys.stderr)
    archive = TOOLS_DIR / f"jdk-{JAVA_MAJOR}.tar.gz"
    download(url, archive)
    with tempfile.TemporaryDirectory(dir=TOOLS_DIR) as staging:
        with tarfile.open(archive) as tar:
            if sys.version_info >= (3, 12):
                tar.extractall(staging, filter="data")
            else:
                tar.extractall(staging)  # noqa: S202
        (root,) = Path(staging).iterdir()
        home = root / "Contents" / "Home" if (root / "Contents" / "Home").exists() else root
        shutil.move(str(home), JDK_PREFIX)
    archive.unlink()
    return str(local)


def souther_version(binary: str) -> str:
    """The `Implementation-Version` of the jar's manifest, or "" if it cannot be read."""
    try:
        with zipfile.ZipFile(binary) as jar, jar.open("META-INF/MANIFEST.MF") as manifest:
            for line in manifest.read().decode("utf-8", "replace").splitlines():
                key, _, value = line.partition(":")
                if key.strip() == "Implementation-Version":
                    return value.strip()
    except (OSError, zipfile.BadZipFile, KeyError):
        pass
    return ""


@functools.cache
def souther_bin() -> str:
    """The Souther CLI (a self-executing jar) of the pinned version.

    `$SOUTHER_BIN` is used as given (with a warning if its version differs). A `souther` on
    `$PATH` is used only if it is the pinned version; otherwise it is skipped, since the models
    are written against that version's syntax. Anything else is downloaded into `.tools/souther`,
    re-downloading if the cached jar is of a different version.
    """
    if os.environ.get("SOUTHER_BIN"):
        explicit = os.environ["SOUTHER_BIN"]
        found = souther_version(explicit)
        if found != SOUTHER_VERSION:
            print(
                f"warning: SOUTHER_BIN={explicit} is souther {found or 'of unknown version'}, "
                f"the models target {SOUTHER_VERSION}",
                file=sys.stderr,
            )
        return explicit
    on_path = shutil.which("souther")
    if on_path:
        found = souther_version(on_path)
        if found == SOUTHER_VERSION:
            return on_path
        print(
            f"note: ignoring {on_path} (souther {found or 'of unknown version'}); "
            f"the models target {SOUTHER_VERSION}",
            file=sys.stderr,
        )
    local = SOUTHER_PREFIX / "souther"
    if not local.exists() or souther_version(str(local)) != SOUTHER_VERSION:
        print(f"downloading souther {SOUTHER_VERSION} into {SOUTHER_PREFIX} ...", file=sys.stderr)
        download(SOUTHER_URL, local)
        local.chmod(0o755)
    return str(local)


def souther_env() -> dict[str, str]:
    """The jar's launcher runs `java` from PATH, so the chosen JDK is put in front of it."""
    java = Path(java_bin())
    env = dict(os.environ)
    env["JAVA_HOME"] = str(java.parent.parent)
    env["PATH"] = str(java.parent) + os.pathsep + env.get("PATH", "")
    return env


def souther(args: list[str], **kwargs: object) -> subprocess.CompletedProcess:
    return subprocess.run([souther_bin(), *args], env=souther_env(), check=False, **kwargs)  # noqa: S603


# ---------------------------------------------------------------------------
# models and checks
# ---------------------------------------------------------------------------


class Model:
    """A module file and the example files attached to it."""

    def __init__(self, directory: Path) -> None:
        self.dir = directory
        sources = sorted(directory.glob("*.sou"))
        self.examples = [s for s in sources if s.name.endswith(".examples.sou")]
        modules = [s for s in sources if s not in self.examples]
        if len(modules) != 1:
            fail(f"{directory}: expected exactly one module file (*.sou), found {len(modules)}")
        self.module = modules[0]
        self.sources = [self.module, *self.examples]

    @property
    def display(self) -> str:
        return str(self.dir)

    def checks(self, only: str | None = None) -> list[Check]:
        checks: list[Check] = [FormatCheck(self), CompileCheck(self), ExamplesCheck(self)]
        if only is not None:
            checks = [c for c in checks if c.name == only]
            if not checks:
                fail(f"{self.display}: no check named {only!r}")
        return checks


class Check:
    name = ""
    description = ""

    def __init__(self, model: Model) -> None:
        self.model = model

    def command(self) -> list[str]:
        raise NotImplementedError

    def run(self) -> tuple[str, int, float]:
        started = time.monotonic()
        result = souther(self.command(), capture_output=True, text=True)
        return result.stdout + result.stderr, result.returncode, time.monotonic() - started

    def summary(self, output: str, returncode: int) -> str:
        return "passed" if returncode == 0 else "failed"


class FormatCheck(Check):
    name = "format"
    description = "souther fmt --check"

    def command(self) -> list[str]:
        return ["fmt", "--check", *map(str, self.model.sources)]

    def summary(self, output: str, returncode: int) -> str:
        return "canonically formatted" if returncode == 0 else "not formatted (run: souther fmt -w <files>)"


class CompileCheck(Check):
    name = "compile"
    description = "souther compile (module + examples)"

    def run(self) -> tuple[str, int, float]:
        started = time.monotonic()
        with tempfile.TemporaryDirectory() as out:
            result = souther(["compile", *map(str, self.model.sources), "-d", out], capture_output=True, text=True)
        return result.stdout + result.stderr, result.returncode, time.monotonic() - started

    def summary(self, output: str, returncode: int) -> str:
        if returncode != 0:
            return "compile error"
        return f"{len(WROTE.findall(output))} classes generated"


class ExamplesCheck(Check):
    name = "examples"
    description = "souther examples --strict (rows hold and cover the model)"

    def command(self) -> list[str]:
        return ["examples", "--strict", *map(str, self.model.sources)]

    def summary(self, output: str, returncode: int) -> str:
        failed = len(EXAMPLE_FAILED.findall(output))
        if failed:
            return f"{failed} example(s) do not hold"
        behaviors, adequacy, gaps = BEHAVIORS.search(output), ADEQUACY.search(output), GAPS.search(output)
        parts = []
        if behaviors:
            parts.append(f"{behaviors.group(2)}/{behaviors.group(1)} behaviors implemented")
        if adequacy:
            parts.append(f"adequacy {adequacy.group(1)}")
        if gaps:
            parts.append(f"{gaps.group(1)} coverage gap(s)")
        return ", ".join(parts) or ("passed" if returncode == 0 else "failed")


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
        ok = returncode == 0
        print(f"{'ok  ' if ok else 'FAIL'} {check.name:<{width}}  {check.summary(output, returncode)} ({elapsed:.1f}s)")
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
    return 0 if returncode == 0 else 1


def cmd_examples(args: argparse.Namespace) -> int:
    model = discover(args.paths)[0]
    return souther(["examples", *map(str, model.sources)]).returncode


def cmd_run(args: argparse.Namespace) -> int:
    """One JSON value per parameter; the CLI takes a bare value for one parameter and an array otherwise."""
    model = discover(args.paths)[0]
    values = []
    for text in args.inputs:
        try:
            values.append(json.loads(text))
        except json.JSONDecodeError as e:
            fail(f"argument is not JSON: {text!r} ({e})")
    payload = values[0] if len(values) == 1 else values
    return souther(["run", str(model.module), "--behavior", args.behavior, "--input", json.dumps(payload)]).returncode


def cmd_souther(args: argparse.Namespace) -> int:
    return souther(args.args).returncode


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

    examples = sub.add_parser("examples", help="print the example and adequacy report")
    examples.add_argument("paths", type=Path, nargs=1)
    examples.set_defaults(func=cmd_examples)

    run = sub.add_parser("run", help="execute one behavior on JSON arguments")
    run.add_argument("paths", type=Path, nargs=1)
    run.add_argument("behavior", help="e.g. decide")
    run.add_argument("inputs", nargs="+", help="one JSON value per parameter of the behavior")
    run.set_defaults(func=cmd_run)

    raw = sub.add_parser("souther", help="invoke the Souther CLI directly with the managed JDK")
    raw.add_argument("args", nargs=argparse.REMAINDER)
    raw.set_defaults(func=cmd_souther, paths=[])

    args = parser.parse_args()
    for path in args.paths:
        if not path.exists():
            fail(f"no such path: {path}")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
