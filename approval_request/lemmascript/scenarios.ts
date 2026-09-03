// Executable scenarios: the tables of spec.md, *run* on the very TypeScript that was verified.
//
// The `//@ ensures` of approval.ts are proved by Dafny for all values, so these tests do not
// add confidence in the rules. They serve two purposes: showing that a LemmaScript program
// runs as-is under Node.js (without going through Dafny), and pinning the reading of the
// specification down to concrete users -- the kind of lines a reviewer can check against
// spec.md side by side.
//
//   $ node scenarios.ts      # Node 22.18+ / 24+ (built-in type stripping)
//
// This file is not handed to `lsc`: `assert` and `console.log` are outside the LemmaScript
// subset, and the goal here is execution, not verification.

import assert from "node:assert/strict";
import {
  type Content,
  type Directory,
  type Event,
  type Request,
  Workflow,
  departmentsHaveManagers,
  hasManager,
  run,
  step,
} from "./approval.ts";

// alice: Member of sales. bob: Manager of sales.
// carol: Manager of eng *and* Member of sales -- the dual affiliation property P1 is about.
// dave: affiliated with eng only.
const demoDirectory: Directory = {
  roles: new Map([
    ["alice", new Map([["sales", "Member"]])],
    ["bob", new Map([["sales", "Manager"]])],
    ["carol", new Map([["sales", "Member"], ["eng", "Manager"]])],
    ["dave", new Map([["eng", "Member"]])],
  ]),
};

const laptop: Content = { title: "laptop", amount: 1500 };

const scenarios: Record<string, () => void> = {
  // spec.md §1: every department has a manager. Runs the loop side of the `//@ pure` functions.
  directoryIsWellFormed() {
    assert.equal(hasManager(demoDirectory, "sales"), true);
    assert.equal(hasManager(demoDirectory, "eng"), true);
    assert.equal(hasManager(demoDirectory, "legal"), false);
    assert.equal(departmentsHaveManagers(demoDirectory), true);
    const orphaned: Directory = { roles: new Map([["dave", new Map([["eng", "Member"]])]]) };
    assert.equal(departmentsHaveManagers(orphaned), false);
  },

  // Actions A, C, F: Draft -> Pending -> Returned -> Pending -> Approved.
  roundTripEndsApproved() {
    const system = new Workflow(demoDirectory);
    const created = system.open("alice", "sales", laptop);
    assert.equal(created.kind, "Success");
    const id = system.nextId - 1;

    assert.deepEqual(system.apply("alice", id, { kind: "Submit" }), {
      kind: "Success",
      value: { author: "alice", department: "sales", content: laptop, status: { kind: "Pending" } },
    });
    const returned = system.apply("bob", id, { kind: "Return" });
    assert.equal(returned.kind, "Success");
    assert.deepEqual(returned.kind === "Success" && returned.value.status, { kind: "Returned", returnedBy: "bob" });
    assert.equal(system.apply("alice", id, { kind: "Submit" }).kind, "Success");
    const approved = system.apply("bob", id, { kind: "Approve" });
    assert.deepEqual(approved.kind === "Success" && approved.value.status, { kind: "Approved", approvedBy: "bob" });
  },

  // P1: carol manages eng but cannot decide a sales request (she is a Member in sales).
  managerOfAnotherDepartmentCannotDecide() {
    const pending: Request = { author: "alice", department: "sales", content: laptop, status: { kind: "Pending" } };
    assert.deepEqual(step(demoDirectory, "carol", pending, { kind: "Approve" }), { kind: "Failure", denial: "NotManager" });
    assert.deepEqual(step(demoDirectory, "carol", pending, { kind: "Reject" }), { kind: "Failure", denial: "NotManager" });
    assert.deepEqual(step(demoDirectory, "carol", pending, { kind: "Return" }), { kind: "Failure", denial: "NotManager" });
    // R1/R2: dave, not affiliated with sales, is not even told the request exists.
    assert.deepEqual(step(demoDirectory, "dave", pending, { kind: "Approve" }), { kind: "Failure", denial: "NotAffiliated" });
  },

  // Note in spec.md §4 D: a manager approving their own request is not forbidden.
  selfApprovalByManagerIsPermitted() {
    const own: Request = { author: "bob", department: "sales", content: laptop, status: { kind: "Pending" } };
    const outcome = step(demoDirectory, "bob", own, { kind: "Approve" });
    assert.equal(outcome.kind, "Success");
  },

  // U1/U3: only managers edit a Pending request; the author edits a Returned one.
  onlyManagersEditPendingRequests() {
    const pending: Request = { author: "alice", department: "sales", content: laptop, status: { kind: "Pending" } };
    const cheaper: Content = { title: "laptop", amount: 900 };
    assert.deepEqual(step(demoDirectory, "alice", pending, { kind: "Edit", content: cheaper }), { kind: "Failure", denial: "NotManager" });
    const edited = step(demoDirectory, "bob", pending, { kind: "Edit", content: cheaper });
    assert.deepEqual(edited, { kind: "Success", value: { ...pending, content: cheaper } });
    const returned: Request = { ...pending, status: { kind: "Returned", returnedBy: "bob" } };
    assert.equal(step(demoDirectory, "alice", returned, { kind: "Edit", content: cheaper }).kind, "Success");
  },

  // P2: nothing happens to a decided request whoever tries whatever -- the postcondition of `run`.
  terminalRequestsAreFrozen() {
    const approved: Request = { author: "alice", department: "sales", content: laptop, status: { kind: "Approved", approvedBy: "bob" } };
    const attempts: Event[] = [
      { actor: "alice", command: { kind: "Edit", content: { title: "laptop", amount: 1 } } },
      { actor: "alice", command: { kind: "Submit" } },
      { actor: "bob", command: { kind: "Reject" } },
      { actor: "bob", command: { kind: "Return" } },
      { actor: "carol", command: { kind: "Approve" } },
    ];
    assert.deepEqual(run(demoDirectory, approved, attempts), approved);
    assert.deepEqual(step(demoDirectory, "bob", approved, { kind: "Reject" }), { kind: "Failure", denial: "TerminalRequest" });
  },

  // Denials of action A: no request in a department one is not affiliated with, and no invalid content.
  createIsGuarded() {
    const system = new Workflow(demoDirectory);
    assert.deepEqual(system.open("dave", "sales", laptop), { kind: "Failure", denial: "NotAffiliated" });
    assert.deepEqual(system.open("alice", "sales", { title: "", amount: 1 }), { kind: "Failure", denial: "InvalidContent" });
    assert.deepEqual(system.open("alice", "sales", { title: "chair", amount: -1 }), { kind: "Failure", denial: "InvalidContent" });
    assert.equal(system.requests.size, 0);
    assert.deepEqual(system.apply("alice", 0, { kind: "Submit" }), { kind: "Failure", denial: "NoSuchRequest" });
  },

  // Deciding a Draft yields WrongState; submitting someone else's Draft yields NotAuthor.
  wrongStateAndWrongActorAreToldApart() {
    const draft: Request = { author: "alice", department: "sales", content: laptop, status: { kind: "Draft" } };
    assert.deepEqual(step(demoDirectory, "bob", draft, { kind: "Approve" }), { kind: "Failure", denial: "WrongState" });
    assert.deepEqual(step(demoDirectory, "bob", draft, { kind: "Submit" }), { kind: "Failure", denial: "NotAuthor" });
    assert.deepEqual(step(demoDirectory, "carol", draft, { kind: "Edit", content: laptop }), { kind: "Failure", denial: "NotAuthor" });
  },
};

let failed = 0;
for (const [name, scenario] of Object.entries(scenarios)) {
  try {
    scenario();
    console.log(`${name}: PASSED`);
  } catch (error) {
    failed += 1;
    console.log(`${name}: FAILED`);
    console.log(error instanceof Error ? error.message : String(error));
  }
}
console.log(`\n${Object.keys(scenarios).length - failed}/${Object.keys(scenarios).length} scenarios passed`);
if (failed > 0) process.exit(1);
