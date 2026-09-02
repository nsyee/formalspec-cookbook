// Approval Request workflow in Dafny: the data model, the authority
// predicates and the transitions.
//
// The other models in this repository explore a bounded state space (Alloy,
// TLA+, Quint) or a request/policy pair (Cedar). Dafny instead *proves*
// statements about every value of a type, so the modeling weight moves to the
// types and to the pre/postconditions of the functions:
//
//   - Well-formedness lives in subset types (`Directory`, `Title`, `Amount`).
//     A value of type `Directory` cannot violate "every department has a
//     manager", so that requirement is not restated in any precondition.
//   - Each transition is a *total function with a precondition*: `Approve`
//     requires the request to be Pending and the actor to be a manager of the
//     target department, and its postcondition pins down the next status. The
//     precondition is discharged by the verifier at every call site, so
//     "approving a Draft" is not a runtime denial but an unprovable program.
//   - `Step` is the one entry point that accepts an arbitrary (request,
//     command) pair from the outside world. It answers with a failure-
//     compatible `Outcome`, which lets callers use `:-` to propagate denials.
//
// Properties.dfy proves P1-P3 and the access-control rules of spec.md against
// these definitions; Workflow.dfy runs them as a mutable system.
module Approval {

  // === Identifiers, roles and the directory ===

  type UserId = s: string | s != "" witness "u"
  type DepartmentId = s: string | s != "" witness "d"

  datatype Role = Member | Manager

  // Roles are contextual: the key is the (user, department) pair, never the
  // user alone. A map keyed by the pair makes "one role per affiliation"
  // structural, so unlike the relational models there is no extra invariant
  // for it.
  type Assignment = map<(UserId, DepartmentId), Role>

  ghost predicate HasManager(a: Assignment, dep: DepartmentId) {
    exists u: UserId :: (u, dep) in a && a[(u, dep)] == Manager
  }

  ghost predicate DepartmentsHaveManagers(a: Assignment) {
    forall k <- a.Keys :: HasManager(a, k.1)
  }

  // The organisation chart, carrying the invariant of spec.md section 1
  // ("each department has at least one Manager") in its type. The witness is
  // the smallest chart there is: one manager of one department. Dafny checks
  // that the witness satisfies the constraint, so the type is inhabited.
  const SomeUser: UserId := "u"
  const SomeDepartment: DepartmentId := "d"

  type Directory = a: Assignment | DepartmentsHaveManagers(a)
    witness map[(SomeUser, SomeDepartment) := Manager]

  predicate IsAffiliated(dir: Directory, user: UserId, dep: DepartmentId) {
    (user, dep) in dir
  }

  predicate IsManagerOf(dir: Directory, user: UserId, dep: DepartmentId) {
    (user, dep) in dir && dir[(user, dep)] == Manager
  }

  // === Requests ===

  type Title = s: string | s != "" witness "t"
  type Amount = n: int | 0 <= n witness 0

  datatype Content = Content(title: Title, amount: Amount)

  // Raw input is turned into a constrained value by a function with the
  // constraint as its precondition; the caller has to establish it, and the
  // value carries it from then on.
  function AsTitle(s: string): Title
    requires s != ""
  {
    s
  }

  function AsAmount(n: int): Amount
    requires 0 <= n
  {
    n
  }

  // One case per state of spec.md section 2. A state carries exactly the
  // fields that exist in it: who decided is recorded by the case that records
  // the decision, so "a Draft with an approver" is not writable.
  datatype Status =
    | Draft
    | Pending
    | Returned(returnedBy: UserId)
    | Approved(approvedBy: UserId)
    | Rejected(rejectedBy: UserId)

  predicate Terminal(s: Status) {
    s.Approved? || s.Rejected?
  }

  datatype Request = Request(
    author: UserId,
    department: DepartmentId,
    content: Content,
    status: Status)

  // The author must be affiliated with the target department (spec.md
  // section 1). This is a relation between a request and a directory rather
  // than a property of the request alone, so it stays a predicate.
  ghost predicate WellFormed(dir: Directory, r: Request) {
    IsAffiliated(dir, r.author, r.department)
  }

  // === Access control (spec.md section 3) ===

  predicate CanRead(dir: Directory, actor: UserId, r: Request) {
    IsAffiliated(dir, actor, r.department) // R1, R2
  }

  predicate CanEdit(dir: Directory, actor: UserId, r: Request) {
    || (actor == r.author && (r.status.Draft? || r.status.Returned?)) // U1
    || (IsManagerOf(dir, actor, r.department) && !Terminal(r.status)) // U3
    // U2 is the absence of a third disjunct.
  }

  predicate CanSubmit(actor: UserId, r: Request) {
    actor == r.author && (r.status.Draft? || r.status.Returned?) // C
  }

  // D, E and F share one authority rule, which mentions only the actor's role
  // *in the target department*. P1 (no authority leak between departments)
  // and the self-approval note of spec.md section 4.D are both consequences
  // of this single predicate.
  predicate CanDecide(dir: Directory, actor: UserId, r: Request) {
    r.status.Pending? && IsManagerOf(dir, actor, r.department)
  }

  // === Transitions (spec.md section 4) ===

  // `create` is the only transition that builds content out of raw input, so
  // it is the only one that can be given values its type forbids; hence the
  // Outcome. The postcondition is the postcondition of requirement A.
  function Create(
    dir: Directory,
    author: UserId,
    dep: DepartmentId,
    title: string,
    amount: int): Outcome<Request>
    ensures Create(dir, author, dep, title, amount).Success?
            ==> var r := Create(dir, author, dep, title, amount).value;
                r.author == author && r.department == dep && r.status.Draft?
                && WellFormed(dir, r)
  {
    if !IsAffiliated(dir, author, dep) then Failure(NotAffiliated)
    else if title == "" || amount < 0 then Failure(InvalidContent)
    else Success(Request(author, dep, Content(AsTitle(title), AsAmount(amount)), Draft))
  }

  // Editing keeps the status and the author, and only replaces the content
  // (requirement B). Writing that as a postcondition means the callers of
  // `Edit` -- including `Step` -- get it for free.
  function Edit(dir: Directory, actor: UserId, r: Request, content: Content): Request
    requires CanEdit(dir, actor, r)
    ensures Edit(dir, actor, r, content) == r.(content := content)
    ensures Edit(dir, actor, r, content).status == r.status
  {
    r.(content := content)
  }

  function Submit(actor: UserId, r: Request): Request
    requires CanSubmit(actor, r)
    ensures Submit(actor, r).status.Pending?
  {
    r.(status := Pending)
  }

  function Approve(dir: Directory, actor: UserId, r: Request): Request
    requires CanDecide(dir, actor, r)
    ensures Approve(dir, actor, r).status == Approved(actor)
  {
    r.(status := Approved(actor))
  }

  function Reject(dir: Directory, actor: UserId, r: Request): Request
    requires CanDecide(dir, actor, r)
    ensures Reject(dir, actor, r).status == Rejected(actor)
  {
    r.(status := Rejected(actor))
  }

  function Return(dir: Directory, actor: UserId, r: Request): Request
    requires CanDecide(dir, actor, r)
    ensures Return(dir, actor, r).status == Returned(actor)
  {
    r.(status := Returned(actor))
  }

  // === Commands and denials ===

  datatype Command =
    | EditCommand(content: Content)
    | SubmitCommand
    | ApproveCommand
    | RejectCommand
    | ReturnCommand

  datatype Denial =
    | NotAffiliated
    | NotAuthor
    | NotManager
    | TerminalRequest
    | WrongState
    | InvalidContent
    | NoSuchRequest

  // A failure-compatible result type: `IsFailure`/`PropagateFailure`/`Extract`
  // are what Dafny looks for to enable `var x :- expr;`, so callers of the
  // model (Workflow.dfy, Scenarios.dfy) propagate denials without a `match`.
  datatype Outcome<T> = Success(value: T) | Failure(denial: Denial)
  {
    predicate IsFailure() {
      Failure?
    }

    function PropagateFailure<U>(): Outcome<U>
      requires IsFailure()
    {
      Failure(denial)
    }

    function Extract(): T
      requires !IsFailure()
    {
      value
    }
  }

  // === The dynamic entry point ===

  // The transitions above cannot be misapplied: their preconditions are
  // proved at every call site. A command arriving from outside, however, is
  // an arbitrary pair of a request and a command, so `Step` classifies the
  // pair and delegates. It is total: every (status, command) cell answers,
  // either with the next request or with a denial.
  //
  // An actor who may not even read the request learns nothing about its
  // state: the affiliation check comes first, and terminal requests are
  // answered before the command is looked at (P2).
  function Step(dir: Directory, actor: UserId, r: Request, cmd: Command): Outcome<Request>
    ensures Step(dir, actor, r, cmd).Success? ==> CanRead(dir, actor, r)
    ensures Step(dir, actor, r, cmd).Success? ==> !Terminal(r.status)
    ensures Step(dir, actor, r, cmd).Success?
            ==> var next := Step(dir, actor, r, cmd).value;
                next.author == r.author && next.department == r.department
  {
    if !CanRead(dir, actor, r) then Failure(NotAffiliated)
    else if Terminal(r.status) then Failure(TerminalRequest)
    else match cmd
         case EditCommand(content) =>
           if CanEdit(dir, actor, r) then Success(Edit(dir, actor, r, content))
           else if r.status.Pending? then Failure(NotManager)
           else Failure(NotAuthor)
         case SubmitCommand =>
           if CanSubmit(actor, r) then Success(Submit(actor, r))
           else if r.status.Pending? then Failure(WrongState)
           else Failure(NotAuthor)
         case ApproveCommand =>
           if CanDecide(dir, actor, r) then Success(Approve(dir, actor, r))
           else if r.status.Pending? then Failure(NotManager)
           else Failure(WrongState)
         case RejectCommand =>
           if CanDecide(dir, actor, r) then Success(Reject(dir, actor, r))
           else if r.status.Pending? then Failure(NotManager)
           else Failure(WrongState)
         case ReturnCommand =>
           if CanDecide(dir, actor, r) then Success(Return(dir, actor, r))
           else if r.status.Pending? then Failure(NotManager)
           else Failure(WrongState)
  }
}
