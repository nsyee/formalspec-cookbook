// 実行可能なシナリオ: spec.md の表を、検証したものと同じ TypeScript で *実行* する。
//
// approval.ts の `//@ ensures` は Dafny によってすべての値について証明済みなので、
// ここのテストは規則への確信度を上げるためのものではない。役割は 2 つ: LemmaScript の
// プログラムが（Dafny へのコンパイルを経ずに）Node.js でそのまま動くことを示すことと、
// 仕様の読みを具体的なユーザーで固定すること——レビュアーが spec.md と並べて
// 突き合わせられる種類の行である。
//
//   $ node scenarios.ts      # Node 22.18+ / 24+（型注釈の除去が組み込み）
//
// このファイルは `lsc` には渡さない。`assert` と `console.log` は LemmaScript の
// サブセットの外にあり、ここでは検証ではなく実行だけが目的だからである。

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

// alice: sales の一般メンバー。bob: sales の上長。
// carol: eng の上長 *かつ* sales の一般メンバー——性質 P1 が対象とする兼務。
// dave: eng にしか所属していない。
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
  // spec.md §1: すべての部署に上長がいる。`//@ pure` な関数のループ側を実行している。
  directoryIsWellFormed() {
    assert.equal(hasManager(demoDirectory, "sales"), true);
    assert.equal(hasManager(demoDirectory, "eng"), true);
    assert.equal(hasManager(demoDirectory, "legal"), false);
    assert.equal(departmentsHaveManagers(demoDirectory), true);
    const orphaned: Directory = { roles: new Map([["dave", new Map([["eng", "Member"]])]]) };
    assert.equal(departmentsHaveManagers(orphaned), false);
  },

  // アクション A, C, F: Draft → Pending → Returned → Pending → Approved。
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

  // P1: carol は eng の上長だが、sales の申請は決裁できない（sales では一般メンバー）。
  managerOfAnotherDepartmentCannotDecide() {
    const pending: Request = { author: "alice", department: "sales", content: laptop, status: { kind: "Pending" } };
    assert.deepEqual(step(demoDirectory, "carol", pending, { kind: "Approve" }), { kind: "Failure", denial: "NotManager" });
    assert.deepEqual(step(demoDirectory, "carol", pending, { kind: "Reject" }), { kind: "Failure", denial: "NotManager" });
    assert.deepEqual(step(demoDirectory, "carol", pending, { kind: "Return" }), { kind: "Failure", denial: "NotManager" });
    // R1/R2: sales に所属しない dave は、申請の存在すら知らされない。
    assert.deepEqual(step(demoDirectory, "dave", pending, { kind: "Approve" }), { kind: "Failure", denial: "NotAffiliated" });
  },

  // spec.md §4 D の注記: 上長が自分の申請を自分で承認することは禁止されていない。
  selfApprovalByManagerIsPermitted() {
    const own: Request = { author: "bob", department: "sales", content: laptop, status: { kind: "Pending" } };
    const outcome = step(demoDirectory, "bob", own, { kind: "Approve" });
    assert.equal(outcome.kind, "Success");
  },

  // U1/U3: Pending の申請は上長だけが編集でき、Returned の申請は申請者が編集できる。
  onlyManagersEditPendingRequests() {
    const pending: Request = { author: "alice", department: "sales", content: laptop, status: { kind: "Pending" } };
    const cheaper: Content = { title: "laptop", amount: 900 };
    assert.deepEqual(step(demoDirectory, "alice", pending, { kind: "Edit", content: cheaper }), { kind: "Failure", denial: "NotManager" });
    const edited = step(demoDirectory, "bob", pending, { kind: "Edit", content: cheaper });
    assert.deepEqual(edited, { kind: "Success", value: { ...pending, content: cheaper } });
    const returned: Request = { ...pending, status: { kind: "Returned", returnedBy: "bob" } };
    assert.equal(step(demoDirectory, "alice", returned, { kind: "Edit", content: cheaper }).kind, "Success");
  },

  // P2: 決裁済みの申請には、誰が何を試みても何も起きない——`run` の事後条件そのもの。
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

  // アクション A の拒否: 所属していない部署には申請を作れず、不正な内容も受け付けない。
  createIsGuarded() {
    const system = new Workflow(demoDirectory);
    assert.deepEqual(system.open("dave", "sales", laptop), { kind: "Failure", denial: "NotAffiliated" });
    assert.deepEqual(system.open("alice", "sales", { title: "", amount: 1 }), { kind: "Failure", denial: "InvalidContent" });
    assert.deepEqual(system.open("alice", "sales", { title: "chair", amount: -1 }), { kind: "Failure", denial: "InvalidContent" });
    assert.equal(system.requests.size, 0);
    assert.deepEqual(system.apply("alice", 0, { kind: "Submit" }), { kind: "Failure", denial: "NoSuchRequest" });
  },

  // Draft のまま決裁しようとすると WrongState、他人の Draft を提出しようとすると NotAuthor。
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
