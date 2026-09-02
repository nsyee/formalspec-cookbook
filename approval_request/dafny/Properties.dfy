include "Approval.dfy"

// The properties of spec.md, proved for *every* directory, request and trace.
//
// The model checkers in this repository answer the same questions inside a
// finite scope ("up to 3 users, 2 departments, 8 steps"). Here each statement
// is a lemma quantified over all values of the types, so the guarantee has no
// scope: `TerminalRequestsAreFrozen` holds for traces of any length, over
// organisations of any size.
//
// A lemma that a reader might expect to see -- "a Draft cannot be approved" --
// is missing on purpose: `Approve` requires `CanDecide`, so such a call does
// not verify and there is nothing to prove about it. Only the dynamic entry
// point `Step` needs theorems.
module Properties {
  import opened Approval

  // === Traces ===

  datatype Event = Event(actor: UserId, command: Command)

  // Applying a whole trace: a denied command leaves the request untouched,
  // which is what the environment sees when a user is refused.
  function Run(dir: Directory, r: Request, events: seq<Event>): Request
    decreases |events|
  {
    if events == [] then r
    else
      var outcome := Step(dir, events[0].actor, r, events[0].command);
      Run(dir, if outcome.Success? then outcome.value else r, events[1..])
  }

  // === P1: contextual authority does not leak between departments ===

  // Every successful decision comes from a manager of the *target*
  // department, whatever roles the actor holds elsewhere.
  lemma OnlyTargetManagersDecide(dir: Directory, actor: UserId, r: Request, cmd: Command)
    requires cmd.ApproveCommand? || cmd.RejectCommand? || cmd.ReturnCommand?
    requires Step(dir, actor, r, cmd).Success?
    ensures r.status.Pending? && IsManagerOf(dir, actor, r.department)
  {
    // `Step` delegates to `Approve`/`Reject`/`Return`, all guarded by
    // `CanDecide`, which is the conjunction above.
  }

  // The concrete shape of P1: a user who manages `elsewhere` and is a plain
  // member of the target department is refused, even on a request they wrote
  // themselves.
  lemma NoAuthorityLeakAcrossDepartments(
    dir: Directory, actor: UserId, r: Request, elsewhere: DepartmentId, cmd: Command)
    requires cmd.ApproveCommand? || cmd.RejectCommand? || cmd.ReturnCommand?
    requires elsewhere != r.department
    requires IsManagerOf(dir, actor, elsewhere)
    requires IsAffiliated(dir, actor, r.department) && !IsManagerOf(dir, actor, r.department)
    ensures Step(dir, actor, r, cmd).Failure?
    ensures r.status.Pending? ==> Step(dir, actor, r, cmd) == Failure(NotManager)
  {
    if Step(dir, actor, r, cmd).Success? {
      OnlyTargetManagersDecide(dir, actor, r, cmd);
      assert false;
    }
  }

  // Self-approval (spec.md section 4.D) is the same rule seen from the other
  // side, so it must remain possible. The lemma exhibits a witness, which
  // also proves that P1 above is not vacuous.
  lemma SelfApprovalIsAllowed()
    ensures exists dir: Directory, actor: UserId, r: Request ::
              r.author == actor && Step(dir, actor, r, ApproveCommand).Success?
  {
    var assignment: Assignment := map[(SomeUser, SomeDepartment) := Manager];
    assert HasManager(assignment, SomeDepartment) by {
      assert (SomeUser, SomeDepartment) in assignment;
    }
    var dir: Directory := assignment;
    var r := Request(SomeUser, SomeDepartment, Content("laptop", 1500), Pending);
    assert Step(dir, SomeUser, r, ApproveCommand).Success?;
  }

  // === P2: terminal states are frozen ===

  lemma TerminalRequestsRejectEveryCommand(dir: Directory, actor: UserId, r: Request, cmd: Command)
    requires Terminal(r.status)
    ensures Step(dir, actor, r, cmd).Failure?
  {
  }

  // ... and therefore no trace, of any length, moves a decided request.
  lemma TerminalRequestsAreFrozen(dir: Directory, r: Request, events: seq<Event>)
    requires Terminal(r.status)
    ensures Run(dir, r, events) == r
    decreases |events|
  {
    if events != [] {
      TerminalRequestsRejectEveryCommand(dir, events[0].actor, r, events[0].command);
      TerminalRequestsAreFrozen(dir, r, events[1..]);
    }
  }

  // === P3: no orphan request ===

  // Because `Directory` is a subset type, "every department has a manager" is
  // available from the mere fact that `dir` has that type; the proof only has
  // to name the manager the constraint promises.
  lemma EveryPendingRequestHasADecider(dir: Directory, r: Request)
    requires WellFormed(dir, r) && r.status.Pending?
    ensures exists decider: UserId :: CanDecide(dir, decider, r)
  {
    assert (r.author, r.department) in dir.Keys;
    assert HasManager(dir, r.department);
    var decider: UserId :| (decider, r.department) in dir
                           && dir[(decider, r.department)] == Manager;
    assert CanDecide(dir, decider, r);
  }

  // The reachability counterpart, which the model checkers get from a
  // liveness property under fairness: a pending request is one event away
  // from a terminal state.
  lemma PendingRequestsCanBeDecided(dir: Directory, r: Request)
    requires WellFormed(dir, r) && r.status.Pending?
    ensures exists e: Event :: Terminal(Run(dir, r, [e]).status)
  {
    EveryPendingRequestHasADecider(dir, r);
    var decider: UserId :| CanDecide(dir, decider, r);
    var e := Event(decider, ApproveCommand);
    calc {
      Run(dir, r, [e]);
      Run(dir, Approve(dir, decider, r), []);
      Approve(dir, decider, r);
    }
    assert Terminal(Run(dir, r, [e]).status);
  }

  // === Access control (spec.md section 3) ===

  // R1 and R2 together: readability is exactly affiliation with the target
  // department. `<==>` states both directions in one lemma.
  lemma ReadIsExactlyAffiliation(dir: Directory, actor: UserId, r: Request)
    ensures CanRead(dir, actor, r) <==> IsAffiliated(dir, actor, r.department)
  {
  }

  // U2: a colleague of the same department who is not the author and not a
  // manager there cannot edit, in any state.
  lemma OtherMembersCannotEdit(dir: Directory, actor: UserId, r: Request)
    requires actor != r.author
    requires !IsManagerOf(dir, actor, r.department)
    ensures !CanEdit(dir, actor, r)
    ensures Step(dir, actor, r, EditCommand(r.content)).Failure?
  {
  }

  // U1 and U3: editing is confined to the states listed in spec.md, and
  // succeeds for the two roles listed there.
  lemma EditFollowsTheStateTable(dir: Directory, actor: UserId, r: Request, content: Content)
    ensures CanEdit(dir, actor, r) ==> !Terminal(r.status)
    ensures actor == r.author && (r.status.Draft? || r.status.Returned?) ==> CanEdit(dir, actor, r)
    ensures IsManagerOf(dir, actor, r.department) && r.status.Pending? ==> CanEdit(dir, actor, r)
    ensures CanEdit(dir, actor, r) ==> Edit(dir, actor, r, content).status == r.status
  {
  }

  // C: submission is the author's alone.
  lemma OnlyTheAuthorSubmits(dir: Directory, actor: UserId, r: Request)
    requires Step(dir, actor, r, SubmitCommand).Success?
    ensures actor == r.author && (r.status.Draft? || r.status.Returned?)
    ensures Step(dir, actor, r, SubmitCommand).value.status.Pending?
  {
  }

  // === Invariants along a trace ===

  // The author and the target department are fixed at creation time. Proving
  // it for `Run` rather than for `Step` is what makes it an invariant of the
  // system instead of a property of one transition.
  lemma IdentityIsImmutable(dir: Directory, r: Request, events: seq<Event>)
    ensures Run(dir, r, events).author == r.author
    ensures Run(dir, r, events).department == r.department
    decreases |events|
  {
    if events != [] {
      var outcome := Step(dir, events[0].actor, r, events[0].command);
      IdentityIsImmutable(dir, if outcome.Success? then outcome.value else r, events[1..]);
    }
  }

  // Consequently a well-formed request stays well-formed: its author remains
  // affiliated with its target department, so P3 keeps applying to it.
  lemma WellFormednessIsPreserved(dir: Directory, r: Request, events: seq<Event>)
    requires WellFormed(dir, r)
    ensures WellFormed(dir, Run(dir, r, events))
  {
    IdentityIsImmutable(dir, r, events);
  }

  // The state machine of spec.md section 2 has no other edges: a single step
  // either keeps the status or follows one of the arrows in the diagram.
  lemma StatusFollowsTheStateMachine(dir: Directory, actor: UserId, r: Request, cmd: Command)
    requires Step(dir, actor, r, cmd).Success?
    ensures var next := Step(dir, actor, r, cmd).value.status;
            || next == r.status // edit
            || (r.status.Draft? && next.Pending?) // submit
            || (r.status.Returned? && next.Pending?) // resubmit
            || (r.status.Pending? && (next.Approved? || next.Rejected? || next.Returned?))
  {
  }
}
