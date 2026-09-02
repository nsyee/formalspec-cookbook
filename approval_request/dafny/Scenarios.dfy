include "Workflow.dfy"

// Executable scenarios: the tables of spec.md, run by `dafny test`.
//
// The lemmas of Properties.dfy already hold for every value, so these tests
// are not there to raise confidence in the rules. They serve the two purposes
// a proof cannot: they show that the model *runs* (it is compiled to a real
// program, and `expect` fails at run time if the model changes meaning), and
// they pin the reading of the requirements to concrete users -- the sort of
// row a reviewer can check against spec.md by eye.
module Scenarios {
  import opened Approval
  import opened Workflow

  // alice: member of sales. bob: manager of sales.
  // carol: manager of eng *and* member of sales -- the joint appointment that
  // property P1 is about. dave: member of eng only.
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

  // Requirements A, C, F: Draft -> Pending -> Returned -> Pending -> Approved.
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
    // `history` is ghost, so it is asserted rather than expected: the trace
    // is checked by the verifier and costs nothing at run time.
    assert system.history ==
           [(id, "alice", SubmitCommand), (id, "bob", ReturnCommand),
            (id, "alice", SubmitCommand), (id, "bob", ApproveCommand)];
  }

  // Requirement A: the author must be affiliated with the target department,
  // and the content has to satisfy the invariants of its type.
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

  // Requirement D and its note: a manager of the target department may
  // approve a request they wrote themselves.
  method {:test} SelfApprovalIsAllowed() {
    var system := new System(DemoDirectory());

    var created := system.Create("bob", "sales", "laptop", 1500);
    expect created.Success?;
    var submitted := system.Execute("bob", created.value, SubmitCommand);
    expect submitted.Success?;

    var decided := system.Execute("bob", created.value, ApproveCommand);
    expect decided.Success? && decided.value.status == Approved("bob");
  }

  // Property P1: carol manages eng and is a plain member of sales, so her eng
  // authority buys her nothing on a sales request -- not even on her own.
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

    // The same commands from the manager of the target department succeed.
    var byBob := system.Execute("bob", id, ApproveCommand);
    expect byBob.Success? && byBob.value.status == Approved("bob");
  }

  // Requirements U1, U2, U3.
  method {:test} EditFollowsTheAuthorityTable() {
    var system := new System(DemoDirectory());
    var created := system.Create("alice", "sales", "laptop", 1500);
    expect created.Success?;
    var id := created.value;
    var edit := EditCommand(Content("monitor", 300));

    // U1: the author edits their own Draft.
    var byAuthor := system.Execute("alice", id, edit);
    expect byAuthor.Success? && byAuthor.value.content == Content("monitor", 300);

    // U2: another member of the same department cannot.
    var byColleague := system.Execute("carol", id, edit);
    expect byColleague == Failure(NotAuthor);

    // U3: the manager of the department can, and can still do so once the
    // request is Pending, where the author no longer can.
    var byManager := system.Execute("bob", id, edit);
    expect byManager.Success?;

    var submitted := system.Execute("alice", id, SubmitCommand);
    expect submitted.Success?;
    var authorOnPending := system.Execute("alice", id, edit);
    expect authorOnPending == Failure(NotManager);
    var managerOnPending := system.Execute("bob", id, edit);
    expect managerOnPending.Success? && managerOnPending.value.status == Pending;
  }

  // Property P2: once decided, every command is refused.
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

  // Requirements R1 and R2, from both sides: an eng-only user sees nothing of
  // a sales request, and every sales affiliate sees it.
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

  // A command against an identifier that does not exist is a denial like any
  // other, not a crash: the model is total.
  method {:test} UnknownRequestIsDenied() {
    var system := new System(DemoDirectory());
    var outcome := system.Execute("alice", 42, SubmitCommand);
    expect outcome == Failure(NoSuchRequest);
  }
}
