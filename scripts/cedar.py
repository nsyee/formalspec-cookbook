#!/usr/bin/env python3
"""Command-line driver for the Cedar policy models in this repository.

Subcommands:

    verify <dir>... [--only NAME]        run every check of a model and summarize
    checks <dir>...                      list the checks declared under a path
    trace  <dir> --only NAME             run one check and print the full output
    authorize <dir> PRINCIPAL ACTION RESOURCE
                                         evaluate one request against the fixture
    matrix <dir>                         decision table: every user x action x resource

A model directory holds `checks.json`:

    {
      "namespace": "Approval",
      "schema": "approval.cedarschema",
      "policies": "approval.cedar",
      "entities": "entities.json",
      "cases": "cases.json",
      "properties": [
        {"name": "P1-...", "kind": "allowed-only-if",
         "property": "properties/P1-....cedar",
         "actions": ["approve", "reject", "return"], "resource": "Request"},
        {"name": "D-...", "kind": "allowed-whenever", "property": "...",
         "actions": ["approve"], "resource": "Request", "expect": "violation"}
      ]
    }

The checks derived from it are:

    validate     `cedar validate --deny-warnings`: the policies type-check
                 against the schema.
    format       `cedar format --check`: the policies are canonically formatted.
    cases        `cedar run-tests`: the authorization requests in `cases.json`
                 produce the expected decision for the expected reasons. Each
                 case is {principal, action, resource, decision, reason?}; entity
                 UIDs are written without the namespace and share `entities.json`.
    <property>   `cedar symcc implies`: SymCC compiles both policy sets to SMT and
                 asks cvc5 whether one implies the other, for every request of
                 the given action, over *all* possible entity stores.
                   allowed-only-if   policies => property  (soundness: whatever the
                                     policies allow satisfies the property)
                   allowed-whenever  property => policies  (completeness: whatever
                                     the property describes is allowed)
                 `expect: violation` turns "a counterexample must exist" into a
                 check, which documents assumptions that the schema cannot state.

The Cedar CLI is taken from `$CEDAR_BIN`, then `$PATH`, and otherwise built with
cargo into `.tools/cedar` (feature `analyze`, which needs Rust 1.89+). cvc5 is
taken from `$CVC5`, then `$PATH`, and otherwise downloaded into `.tools/cvc5`.
"""

from __future__ import annotations

import argparse
import io
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
from urllib.request import urlopen

CEDAR_VERSION = os.environ.get("CEDAR_VERSION", "4.12.0")
CVC5_VERSION = os.environ.get("CVC5_VERSION", "1.3.4")
REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLS_DIR = Path(os.environ.get("CEDAR_TOOLS_DIR", REPO_ROOT / ".tools"))
CEDAR_PREFIX = TOOLS_DIR / "cedar"
CVC5_PREFIX = TOOLS_DIR / "cvc5"
MANIFEST = "checks.json"
SYMCC_KINDS = {"allowed-only-if": ("policies", "property"), "allowed-whenever": ("property", "policies")}

TEST_PASSED = re.compile(r"(\d+) passed")
TEST_FAILED = re.compile(r"(\d+) failed")
SYMCC_VERIFIED = re.compile(r"\bVERIFIED\b")
SYMCC_FAILED = re.compile(r"DOES NOT HOLD")


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


# ---------------------------------------------------------------------------
# tools
# ---------------------------------------------------------------------------


def rustc_minor() -> int | None:
    rustc = shutil.which("rustc")
    if rustc is None:
        return None
    out = subprocess.run([rustc, "--version"], capture_output=True, text=True, check=False).stdout  # noqa: S603
    match = re.search(r"rustc 1\.(\d+)", out)
    return int(match.group(1)) if match else None


def cedar_bin() -> str:
    """The Cedar CLI: from the environment, from $PATH, or built locally."""
    if os.environ.get("CEDAR_BIN"):
        return os.environ["CEDAR_BIN"]
    on_path = shutil.which("cedar")
    if on_path:
        return on_path
    local = CEDAR_PREFIX / "bin" / "cedar"
    if not local.exists():
        if shutil.which("cargo") is None or (rustc_minor() or 0) < 89:
            fail("Rust 1.89 or later (cargo) is required to build the Cedar CLI; "
                 "or set CEDAR_BIN to an existing `cedar` binary")
        print(f"building cedar-policy-cli {CEDAR_VERSION} into {CEDAR_PREFIX} (takes a few minutes) ...",
              file=sys.stderr)
        subprocess.run(  # noqa: S603
            ["cargo", "install", "cedar-policy-cli", "--version", CEDAR_VERSION, "--locked",
             "--features", "analyze", "--root", str(CEDAR_PREFIX)],
            check=True,
        )
    return str(local)


def cvc5_bin() -> str:
    """The cvc5 SMT solver that SymCC drives: from the environment, $PATH, or downloaded."""
    if os.environ.get("CVC5"):
        return os.environ["CVC5"]
    on_path = shutil.which("cvc5")
    if on_path:
        return on_path
    local = CVC5_PREFIX / "cvc5"
    if not local.exists():
        system = {"Linux": "Linux", "Darwin": "macOS"}.get(platform.system())
        arch = {"x86_64": "x86_64", "AMD64": "x86_64", "arm64": "arm64", "aarch64": "arm64"}.get(platform.machine())
        if not system or not arch:
            fail("no cvc5 binary for this platform; install cvc5 and set CVC5 to its path")
        asset = f"cvc5-{system}-{arch}-static.zip"
        url = f"https://github.com/cvc5/cvc5/releases/download/cvc5-{CVC5_VERSION}/{asset}"
        print(f"downloading {url} into {CVC5_PREFIX} ...", file=sys.stderr)
        with urlopen(url) as response:  # noqa: S310
            archive = zipfile.ZipFile(io.BytesIO(response.read()))
        member = next(n for n in archive.namelist() if n.endswith("/bin/cvc5"))
        CVC5_PREFIX.mkdir(parents=True, exist_ok=True)
        local.write_bytes(archive.read(member))
        local.chmod(0o755)
    return str(local)


# ---------------------------------------------------------------------------
# model
# ---------------------------------------------------------------------------


class Model:
    """One directory with a schema, a policy set, a fixture and its checks."""

    def __init__(self, manifest: Path) -> None:
        self.dir = manifest.resolve().parent
        self.display = manifest.parent
        doc = json.loads(manifest.read_text(encoding="utf-8"))
        self.namespace = doc.get("namespace", "")
        self.schema = self.dir / doc["schema"]
        self.policies = self.dir / doc["policies"]
        self.entities = self.dir / doc["entities"]
        self.cases = self.dir / doc["cases"] if "cases" in doc else None
        self.properties = doc.get("properties", [])
        for path in [self.schema, self.policies, self.entities, self.cases]:
            if path is not None and not path.exists():
                fail(f"{manifest} refers to a missing file: {path}")
        for prop in self.properties:
            if prop.get("kind") not in SYMCC_KINDS:
                fail(f"{prop.get('name')}: unknown kind {prop.get('kind')!r}")
            if not (self.dir / prop["property"]).exists():
                fail(f"{prop['name']}: missing property file {prop['property']}")

    def qualify(self, uid: str) -> str:
        """`User::"alice"` -> `Approval::User::"alice"` unless already qualified."""
        if not self.namespace or uid.startswith(self.namespace + "::"):
            return uid
        return f"{self.namespace}::{uid}"

    def checks(self, only: str | None = None) -> list[Check]:
        checks: list[Check] = [ValidateCheck(self), FormatCheck(self)]
        if self.cases:
            checks.append(CasesCheck(self))
        checks += [PropertyCheck(self, prop) for prop in self.properties]
        selected = [c for c in checks if only in (None, c.name)]
        if not selected:
            fail(f"no check matched {only!r}")
        return selected

    def common_args(self) -> list[str]:
        return ["--schema", str(self.schema), "--policies", str(self.policies)]

    def load_entities(self) -> list[dict]:
        return json.loads(self.entities.read_text(encoding="utf-8"))

    def authorize(self, principal: str, action: str, resource: str, verbose: bool) -> tuple[str, int]:
        args = [cedar_bin(), "authorize", *self.common_args(), "--entities", str(self.entities),
                "--principal", self.qualify(principal), "--action", self.qualify(action),
                "--resource", self.qualify(resource)]
        if verbose:
            args.append("--verbose")
        result = subprocess.run(args, capture_output=True, text=True, check=False)  # noqa: S603
        return result.stdout + result.stderr, result.returncode


class Check:
    name: str
    expect = "ok"

    def __init__(self, model: Model) -> None:
        self.model = model

    @property
    def description(self) -> str:
        raise NotImplementedError

    def command(self) -> list[str]:
        raise NotImplementedError

    def env(self) -> dict[str, str]:
        return os.environ.copy()

    def run(self) -> tuple[str, int, float]:
        started = time.monotonic()
        result = subprocess.run(  # noqa: S603
            self.command(), cwd=self.model.dir, capture_output=True, text=True, check=False, env=self.env()
        )
        return result.stdout + result.stderr, result.returncode, time.monotonic() - started

    def outcome(self, output: str, returncode: int) -> str:
        return "ok" if returncode == 0 else "violation"

    def summary(self, output: str, returncode: int) -> str:
        return "passed" if returncode == 0 else "failed"


class ValidateCheck(Check):
    name = "validate"
    description = "cedar validate --deny-warnings"

    def command(self) -> list[str]:
        return [cedar_bin(), "validate", "--deny-warnings", *self.model.common_args()]

    def summary(self, output: str, returncode: int) -> str:
        return "policies type-check against the schema" if returncode == 0 else "validation failed"


class FormatCheck(Check):
    name = "format"
    description = "cedar format --check"

    def command(self) -> list[str]:
        return [cedar_bin(), "format", "--check", "--policies", str(self.model.policies)]

    def summary(self, output: str, returncode: int) -> str:
        return "canonically formatted" if returncode == 0 else "not formatted (run: cedar format --write)"


class CasesCheck(Check):
    """`cedar run-tests` over cases.json, expanded with the shared entity fixture."""

    name = "cases"
    description = "cedar run-tests (cases.json x entities.json)"

    def expanded_tests(self) -> list[dict]:
        entities = self.model.load_entities()
        tests = []
        for case in json.loads(self.model.cases.read_text(encoding="utf-8")):
            tests.append({
                "name": case.get("name", ""),
                "request": {
                    "principal": self.model.qualify(case["principal"]),
                    "action": self.model.qualify(case["action"]),
                    "resource": self.model.qualify(case["resource"]),
                    "context": case.get("context", {}),
                },
                "entities": entities,
                "decision": case["decision"],
                "reason": case.get("reason", []),
                "num_errors": case.get("num_errors", 0),
            })
        return tests

    def command(self) -> list[str]:
        tests = self.expanded_tests()
        handle = tempfile.NamedTemporaryFile("w", suffix=".tests.json", delete=False, encoding="utf-8")
        with handle:
            json.dump(tests, handle)
        self._tests_file = handle.name
        return [cedar_bin(), "run-tests", *self.model.common_args(), "--tests", handle.name]

    def run(self) -> tuple[str, int, float]:
        try:
            return super().run()
        finally:
            Path(self._tests_file).unlink(missing_ok=True)

    def summary(self, output: str, returncode: int) -> str:
        passed, failed = TEST_PASSED.search(output), TEST_FAILED.search(output)
        parts = [f"{passed.group(1)} passed"] if passed else []
        if failed and failed.group(1) != "0":
            parts.append(f"{failed.group(1)} failed")
        return ", ".join(parts) or ("passed" if returncode == 0 else "CEDAR FAILED")


class PropertyCheck(Check):
    """`cedar symcc implies`, once per action, between the policy set and a property."""

    def __init__(self, model: Model, prop: dict) -> None:
        super().__init__(model)
        self.prop = prop
        self.name = prop["name"]
        self.kind = prop["kind"]
        self.expect = prop.get("expect", "ok")
        self.actions = prop["actions"]
        self.resource = prop["resource"]
        self.property = model.dir / prop["property"]
        if self.expect not in ("ok", "violation"):
            fail(f"{self.name}: unknown expectation {self.expect!r}")

    @property
    def description(self) -> str:
        arrow = "policies => property" if self.kind == "allowed-only-if" else "property => policies"
        return f"symcc implies  {arrow}  {','.join(self.actions)}"

    def env(self) -> dict[str, str]:
        return {**os.environ, "CVC5": cvc5_bin()}

    def command_for(self, action: str) -> list[str]:
        files = {"policies": str(self.model.policies), "property": str(self.property)}
        first, second = SYMCC_KINDS[self.kind]
        return [cedar_bin(), "symcc", "--schema", str(self.model.schema),
                "--principal-type", self.model.qualify("User"),
                "--action", self.model.qualify(f'Action::"{action}"'),
                "--resource-type", self.model.qualify(self.resource),
                "implies", "--policies1", files[first], "--policies2", files[second]]

    def run(self) -> tuple[str, int, float]:
        started = time.monotonic()
        chunks, returncode = [], 0
        for action in self.actions:
            result = subprocess.run(  # noqa: S603
                self.command_for(action), cwd=self.model.dir, capture_output=True, text=True,
                check=False, env=self.env(),
            )
            chunks.append(f"--- action {action}\n{result.stdout}{result.stderr}")
            returncode = returncode or result.returncode
        return "\n".join(chunks), returncode, time.monotonic() - started

    def outcome(self, output: str, returncode: int) -> str:
        verified = len(SYMCC_VERIFIED.findall(output))
        if returncode != 0 or verified + len(SYMCC_FAILED.findall(output)) != len(self.actions):
            return "error"
        return "ok" if verified == len(self.actions) else "violation"

    def summary(self, output: str, returncode: int) -> str:
        verified = len(SYMCC_VERIFIED.findall(output))
        failed = len(SYMCC_FAILED.findall(output))
        if verified == len(self.actions):
            return f"verified for {verified} action(s)"
        if failed:
            return f"counterexample for {failed} of {len(self.actions)} action(s)"
        return "SYMCC FAILED"


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------


def discover(paths: list[Path]) -> list[Model]:
    models = []
    for path in paths:
        manifest = path / MANIFEST if path.is_dir() else path
        if manifest.name != MANIFEST or not manifest.exists():
            fail(f"no {MANIFEST} found at {path}")
        models.append(Model(manifest))
    return models


def all_checks(paths: list[Path], only: str | None = None) -> list[Check]:
    checks = [c for m in discover(paths) for c in m.checks(only)]
    return checks


def cmd_checks(args: argparse.Namespace) -> int:
    checks = all_checks(args.paths)
    width = max(len(c.name) for c in checks)
    for check in checks:
        print(f"{check.name:<{width}}  {check.description:<70} expect {check.expect}")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    checks = all_checks(args.paths, args.only)
    width = max(len(c.name) for c in checks)
    failures = []
    for check in checks:
        output, returncode, elapsed = check.run()
        got = check.outcome(output, returncode)
        ok = got == check.expect
        detail = check.summary(output, returncode) if got != "error" else "CEDAR FAILED"
        print(f"{'ok  ' if ok else 'FAIL'} {check.name:<{width}}  {detail} ({elapsed:.1f}s)")
        if not ok:
            failures.append(check)
            print(output.strip()[-3000:], file=sys.stderr)
    print()
    print(f"{len(checks) - len(failures)}/{len(checks)} checks as expected")
    if failures:
        print("unexpected results: " + ", ".join(c.name for c in failures), file=sys.stderr)
        print(f"inspect one with: {sys.argv[0]} trace {failures[0].model.display} --only {failures[0].name}",
              file=sys.stderr)
        return 1
    return 0


def cmd_trace(args: argparse.Namespace) -> int:
    check = all_checks(args.paths, args.only)[0]
    output, returncode, _ = check.run()
    print(output, end="")
    return 0 if check.outcome(output, returncode) == check.expect else 1


def cmd_authorize(args: argparse.Namespace) -> int:
    model = discover(args.paths)[0]
    output, returncode = model.authorize(args.principal, args.action, args.resource, verbose=True)
    print(output, end="")
    return returncode


def uid_of(entity: dict) -> tuple[str, str]:
    return entity["uid"]["type"], entity["uid"]["id"]


def cmd_matrix(args: argparse.Namespace) -> int:
    """Decision table over the fixture: rows are (resource, action), columns are users."""
    model = discover(args.paths)[0]
    entities = model.load_entities()
    ns = model.namespace + "::" if model.namespace else ""
    users = sorted(i for t, i in map(uid_of, entities) if t == f"{ns}User")
    schema = subprocess.run(  # noqa: S603
        [cedar_bin(), "translate-schema", "--direction", "cedar-to-json", "--schema", str(model.schema)],
        capture_output=True, text=True, check=True,
    ).stdout
    actions = json.loads(schema)[model.namespace]["actions"]
    rows = []
    for action, decl in sorted(actions.items()):
        applies = decl.get("appliesTo")
        if not applies:
            continue
        for rtype in applies["resourceTypes"]:
            for _, rid in sorted(e for e in map(uid_of, entities) if e[0] == f"{ns}{rtype}"):
                rows.append((f'{rtype}::"{rid}"', action))
    rows.sort()
    width = max(len(r) for r, _ in rows)
    print(f"{'resource':<{width}}  {'action':<8}  " + "  ".join(f"{u:<7}" for u in users))
    for resource, action in rows:
        cells = []
        for user in users:
            output, _ = model.authorize(f'User::"{user}"', f'Action::"{action}"', resource, verbose=False)
            cells.append("ALLOW" if "ALLOW" in output else "  .  ")
        print(f"{resource:<{width}}  {action:<8}  " + "  ".join(f"{c:<7}" for c in cells))
    return 0


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

    authorize = sub.add_parser("authorize", help="evaluate one request against the fixture")
    authorize.add_argument("paths", type=Path, nargs=1)
    authorize.add_argument("principal", help='e.g. User::"alice"')
    authorize.add_argument("action", help='e.g. Action::"approve"')
    authorize.add_argument("resource", help='e.g. Request::"dev/pending-by-alice"')
    authorize.set_defaults(func=cmd_authorize)

    matrix = sub.add_parser("matrix", help="print the decision table over the fixture")
    matrix.add_argument("paths", type=Path, nargs=1)
    matrix.set_defaults(func=cmd_matrix)

    args = parser.parse_args()
    for path in args.paths:
        if not path.exists():
            fail(f"no such path: {path}")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
