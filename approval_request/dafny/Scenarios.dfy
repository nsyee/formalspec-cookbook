include "Workflow.dfy"

// 実行可能なシナリオ: spec.md の表を、`dafny test` で実行する。
//
// Properties.dfy の補題はすでにすべての値について成り立つので、ここのテストは規則への
// 確信度を上げるためのものではない。証明にはできない 2 つの役割を果たす: モデルが
// *動く* ことを示すこと（実際のプログラムにコンパイルされ、モデルの意味が変われば
// `expect` が実行時に失敗する）と、仕様の読みを具体的なユーザーで固定すること
// ——レビュアーが spec.md と見比べで突き合わせられる種類の行である。
module Scenarios {
  import opened Approval
  import opened Workflow

  // alice: sales の一般メンバー。bob: sales の上長。
  // carol: eng の上長 *かつ* sales の一般メンバー——性質 P1 が対象とする兼務。
  // dave: eng にしか所属していない。
  function DemoDirectory(): Directory {
    var assignment: Assignment :=
      map[("alice", "sales") := Member,
          ("bob", "sales") := Manager,
          ("carol", "sales") := Member,
          ("carol", "eng") := Manager,
          ("dave", "eng") := Member];
    assert HasManager(assignment, "sales") by {
      assert ("bob", "sales") in assignment && assignment[("bob", "sales")] == Manager;
    }
    assert HasManager(assignment, "eng") by {
      assert ("carol", "eng") in assignment && assignment[("carol", "eng")] == Manager;
    }
    assignment
  }

  function SomeContent(): Content {
    Content("laptop", 1500)
  }

  // アクション A, C, F: Draft → Pending → Returned → Pending → Approved。
  method {:test} RoundTripEndsApproved() {
    var system := new System(DemoDirectory());

    var created := system.Create("alice", "sales", "laptop", 1500);
    expect created.Success?;
    var id := created.value;

    var submitted := system.Execute("alice", id, SubmitCommand);
    expect submitted == Success(Request("alice", "sales", SomeContent(), Pending));

    var returned := system.Execute("bob", id, ReturnCommand);
    expect returned.Success? && returned.value.status == Returned("bob");

    var resubmitted := system.Execute("alice", id, SubmitCommand);
    expect resubmitted.Success? && resubmitted.value.status == Pending;

    var approved := system.Execute("bob", id, ApproveCommand);
    expect approved.Success? && approved.value.status == Approved("bob");
    // `history` は ghost なので、expect ではなく assert する。トレースは検証器が検査し、
    // 実行時のコストはゼロである。
    assert system.history ==
           [(id, "alice", SubmitCommand), (id, "bob", ReturnCommand),
            (id, "alice", SubmitCommand), (id, "bob", ApproveCommand)];
  }

  // アクション A: 作成者は申請先部署に所属していなければならず、内容はその型の
  // 不変条件を満たさなければならない。
  method {:test} CreateIsRefusedOutsideTheDepartment() {
    var system := new System(DemoDirectory());

    var outsider := system.Create("dave", "sales", "laptop", 1500);
    expect outsider == Failure(NotAffiliated);

    var noTitle := system.Create("alice", "sales", "", 1500);
    expect noTitle == Failure(InvalidContent);

    var negative := system.Create("alice", "sales", "laptop", -1);
    expect negative == Failure(InvalidContent);

    var accepted := system.Create("alice", "sales", "laptop", 0);
    expect accepted.Success?;
  }

  // アクション D とその注: 申請先部署の上長は、自分が作成した申請を承認できる。
  method {:test} SelfApprovalIsAllowed() {
    var system := new System(DemoDirectory());

    var created := system.Create("bob", "sales", "laptop", 1500);
    expect created.Success?;
    var submitted := system.Execute("bob", created.value, SubmitCommand);
    expect submitted.Success?;

    var decided := system.Execute("bob", created.value, ApproveCommand);
    expect decided.Success? && decided.value.status == Approved("bob");
  }

  // 性質 P1: carol は eng の上長で sales では一般メンバーなので、eng での権限は sales 宛ての
  // 申請に対して何の役にも立たない——自分が作成した申請でさえも。
  method {:test} JointAppointmentDoesNotLeakAuthority() {
    var system := new System(DemoDirectory());

    var created := system.Create("carol", "sales", "laptop", 1500);
    expect created.Success?;
    var id := created.value;
    var submitted := system.Execute("carol", id, SubmitCommand);
    expect submitted.Success?;

    var byCarol := system.Execute("carol", id, ApproveCommand);
    expect byCarol == Failure(NotManager);
    var rejectByCarol := system.Execute("carol", id, RejectCommand);
    expect rejectByCarol == Failure(NotManager);
    var returnByCarol := system.Execute("carol", id, ReturnCommand);
    expect returnByCarol == Failure(NotManager);

    // 同じコマンドを申請先部署の上長が出せば成功する。
    var byBob := system.Execute("bob", id, ApproveCommand);
    expect byBob.Success? && byBob.value.status == Approved("bob");
  }

  // アクション U1, U2, U3。
  method {:test} EditFollowsTheAuthorityTable() {
    var system := new System(DemoDirectory());
    var created := system.Create("alice", "sales", "laptop", 1500);
    expect created.Success?;
    var id := created.value;
    var edit := EditCommand(Content("monitor", 300));

    // U1: 作成者が自分の Draft を編集する。
    var byAuthor := system.Execute("alice", id, edit);
    expect byAuthor.Success? && byAuthor.value.content == Content("monitor", 300);

    // U2: 同じ部署の別の一般メンバーにはできない。
    var byColleague := system.Execute("carol", id, edit);
    expect byColleague == Failure(NotAuthor);

    // U3: その部署の上長にはでき、作成者にはもうできなくなる Pending の後でも引き続きできる。
    var byManager := system.Execute("bob", id, edit);
    expect byManager.Success?;

    var submitted := system.Execute("alice", id, SubmitCommand);
    expect submitted.Success?;
    var authorOnPending := system.Execute("alice", id, edit);
    expect authorOnPending == Failure(NotManager);
    var managerOnPending := system.Execute("bob", id, edit);
    expect managerOnPending.Success? && managerOnPending.value.status == Pending;
  }

  // 性質 P2: 一度決裁されたら、どのコマンドも拒否される。
  method {:test} TerminalRequestsAreFrozen() {
    var system := new System(DemoDirectory());
    var created := system.Create("alice", "sales", "laptop", 1500);
    expect created.Success?;
    var id := created.value;
    var submitted := system.Execute("alice", id, SubmitCommand);
    expect submitted.Success?;
    var rejected := system.Execute("bob", id, RejectCommand);
    expect rejected.Success? && rejected.value.status == Rejected("bob");

    var commands := [EditCommand(SomeContent()), SubmitCommand, ApproveCommand,
                     RejectCommand, ReturnCommand];
    for i := 0 to |commands|
      invariant system.Valid()
      invariant id in system.requests && system.requests[id] == rejected.value
    {
      var attempt := system.Execute("bob", id, commands[i]);
      expect attempt == Failure(TerminalRequest);
      var byAuthor := system.Execute("alice", id, commands[i]);
      expect byAuthor == Failure(TerminalRequest);
    }
    expect system.requests[id] == rejected.value;
  }

  // アクション R1 と R2 を両方向から: eng にしか所属しないユーザーには sales 宛ての申請が
  // 一切見えない一方で、sales に所属するユーザーには全員見える。
  method {:test} ReadingIsConfinedToAffiliations() {
    var system := new System(DemoDirectory());
    var created := system.Create("alice", "sales", "laptop", 1500);
    expect created.Success?;
    var id := created.value;

    var outsider := system.Execute("dave", id, SubmitCommand);
    expect outsider == Failure(NotAffiliated);

    var visibleToDave := system.Readable("dave");
    expect visibleToDave == {};
    var visibleToCarol := system.Readable("carol");
    expect visibleToCarol == {id};
    var visibleToBob := system.Readable("bob");
    expect visibleToBob == {id};
  }

  // 存在しない識別子へのコマンドも、クラッシュではなく他と同じ拒否になる: このモデルは
  // 全域的である。
  method {:test} UnknownRequestIsDenied() {
    var system := new System(DemoDirectory());
    var outcome := system.Execute("alice", 42, SubmitCommand);
    expect outcome == Failure(NoSuchRequest);
  }
}
