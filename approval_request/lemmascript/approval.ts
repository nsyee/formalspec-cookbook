/**
 * LemmaScript model of the approval request system (../spec.md).
 *
 * The program is plain TypeScript: the same functions run as-is under Node.js
 * (scenarios.ts) and are compiled to Dafny by `lsc`. The `//@` annotations become Dafny
 * `requires` / `ensures` / `invariant`. Everything that is proved for all directories,
 * requests and traces -- P1..P3 and the access rules of spec.md section 3 -- is stated as
 * `//@ ensures` in this file. Proof-only material (helper lemmas, `modifies` clauses, the
 * specification-side bodies of `//@ pure` functions) is *appended* in the proof-owned file
 * `approval.dfy` next to the generated `approval.dfy.gen`. See README.md.
 *
 * Every function carries `//@ verify` because the class at the end needs it: once one
 * declaration opts in, `lsc` verifies only the declarations that opted in.
 */

//@ backend dafny

// === Identifiers, roles and the directory (spec.md section 1) ===

export type UserId = string;
export type DepartmentId = string;

export type Role = "Member" | "Manager";

/**
 * A role is an attribute of a (user, department) pair, so the directory keeps, per user, a
 * map "department the user belongs to -> role in that department". One user may appear in
 * several departments with different roles. A Map key holds one value, so "one role per
 * affiliation" needs no invariant.
 */
export interface Directory {
  roles: Map<UserId, Map<DepartmentId, Role>>;
}

export function isAffiliated(dir: Directory, user: UserId, dep: DepartmentId): boolean {
  //@ verify
  //@ contract True iff `user` holds some role in `dep`.
  const affiliations = dir.roles.get(user);
  if (affiliations === undefined) return false;
  return affiliations.has(dep);
}

export function isManagerOf(dir: Directory, user: UserId, dep: DepartmentId): boolean {
  //@ verify
  //@ contract True iff `user` is a Manager of `dep` -- the role in *that* department, whatever the user is elsewhere.
  //@ ensures \result ==> isAffiliated(dir, user, dep)
  const affiliations = dir.roles.get(user);
  if (affiliations === undefined) return false;
  return affiliations.get(dep) === "Manager";
}

/**
 * spec.md section 1: every department has at least one Manager. The loop is the runtime
 * side; `//@ pure` makes the function usable inside specifications too. The quantifier the
 * loop must agree with (the specification-side body) is supplied by approval.dfy.
 */
export function hasManager(dir: Directory, dep: DepartmentId): boolean {
  //@ verify
  //@ pure
  //@ contract True iff some user of the directory is a Manager of `dep`.
  for (const [user, affiliations] of dir.roles) {
    if (affiliations.get(dep) === "Manager") return true;
  }
  return false;
}

/** Well-formedness of the directory: no department is left without a Manager. */
export function departmentsHaveManagers(dir: Directory): boolean {
  //@ verify
  //@ pure
  //@ contract True iff every department that appears in any affiliation has a Manager.
  for (const [user, affiliations] of dir.roles) {
    for (const [dep, role] of affiliations) {
      if (!hasManager(dir, dep)) return false;
    }
  }
  return true;
}

// === Requests (spec.md section 2) ===

export interface Content {
  title: string;
  amount: number;
}

export function validContent(c: Content): boolean {
  //@ verify
  return c.title !== "" && c.amount >= 0;
}

/**
 * One variant per state of spec.md section 2. Decisions record who made them, but only the
 * variants produced by a decision carry that field, so "a Draft with an approver" cannot be
 * written.
 */
export type Status =
  | { kind: "Draft" }
  | { kind: "Pending" }
  | { kind: "Returned"; returnedBy: UserId }
  | { kind: "Approved"; approvedBy: UserId }
  | { kind: "Rejected"; rejectedBy: UserId };

export function isTerminal(s: Status): boolean {
  //@ verify
  return s.kind === "Approved" || s.kind === "Rejected";
}

export function isEditableByAuthor(s: Status): boolean {
  //@ verify
  return s.kind === "Draft" || s.kind === "Returned";
}

export interface Request {
  author: UserId;
  department: DepartmentId;
  content: Content;
  status: Status;
}

/** The author belongs to the target department (spec.md section 1). */
export function wellFormed(dir: Directory, r: Request): boolean {
  //@ verify
  return isAffiliated(dir, r.author, r.department);
}

// === Access control (spec.md section 3) ===

export function canRead(dir: Directory, actor: UserId, r: Request): boolean {
  //@ verify
  //@ contract R1/R2: being able to read is the same as being affiliated with the target department.
  //@ ensures \result === isAffiliated(dir, actor, r.department)
  return isAffiliated(dir, actor, r.department);
}

export function canEdit(dir: Directory, actor: UserId, r: Request): boolean {
  //@ verify
  //@ contract U1: the author edits Draft / Returned. U3: a Manager of the target department edits undecided requests. U2: nobody else edits.
  //@ ensures \result ==> !isTerminal(r.status)
  //@ ensures actor === r.author && isEditableByAuthor(r.status) ==> \result
  //@ ensures isManagerOf(dir, actor, r.department) && r.status.kind === "Pending" ==> \result
  //@ ensures actor !== r.author && !isManagerOf(dir, actor, r.department) ==> !\result
  return (
    (actor === r.author && isEditableByAuthor(r.status)) ||
    (isManagerOf(dir, actor, r.department) && !isTerminal(r.status))
  );
}

export function canSubmit(actor: UserId, r: Request): boolean {
  //@ verify
  //@ contract C: only the author submits, and only from Draft or Returned.
  //@ ensures \result === (actor === r.author && isEditableByAuthor(r.status))
  return actor === r.author && isEditableByAuthor(r.status);
}

/**
 * D / E / F share one rule, and that rule only looks at the actor's role *in the target
 * department*. Both P1 (no authority leak) and the note on self-approval in spec.md
 * section 4 D follow from this single function.
 */
export function canDecide(dir: Directory, actor: UserId, r: Request): boolean {
  //@ verify
  //@ contract A Pending request is decided by a Manager of its target department.
  //@ ensures \result === (r.status.kind === "Pending" && isManagerOf(dir, actor, r.department))
  return r.status.kind === "Pending" && isManagerOf(dir, actor, r.department);
}

// === Transitions (spec.md section 4) ===

export type Command =
  | { kind: "Edit"; content: Content }
  | { kind: "Submit" }
  | { kind: "Approve" }
  | { kind: "Reject" }
  | { kind: "Return" };

export type Denial =
  | "NotAffiliated"
  | "NotAuthor"
  | "NotManager"
  | "TerminalRequest"
  | "WrongState"
  | "InvalidContent"
  | "NoSuchRequest";

export type Outcome =
  | { kind: "Success"; value: Request }
  | { kind: "Failure"; denial: Denial };

export function success(r: Request): Outcome {
  //@ verify
  return { kind: "Success", value: r };
}

export function failure(d: Denial): Outcome {
  //@ verify
  return { kind: "Failure", denial: d };
}

/** Action A. The only transition that builds a request from raw input, hence the only one that can fail on content. */
export function create(dir: Directory, author: UserId, dep: DepartmentId, content: Content): Outcome {
  //@ verify
  //@ contract A member of `dep` can create a Draft in `dep`; anybody else, or invalid content, is denied.
  //@ ensures \result.kind === "Success" ==> \result.value.author === author && \result.value.department === dep
  //@ ensures \result.kind === "Success" ==> \result.value.status.kind === "Draft" && wellFormed(dir, \result.value)
  //@ ensures \result.kind === "Success" ==> validContent(content)
  //@ ensures isAffiliated(dir, author, dep) && validContent(content) ==> \result.kind === "Success"
  if (!isAffiliated(dir, author, dep)) return failure("NotAffiliated");
  if (!validContent(content)) return failure("InvalidContent");
  return success({ author, department: dep, content, status: { kind: "Draft" } });
}

/**
 * Actions B..F are total functions guarded by preconditions. The permission *is* the
 * `requires`, so "approve a Draft" is not a runtime denial but a program that does not
 * verify. The postconditions state the frame: what changes and what does not.
 */
export function edit(dir: Directory, actor: UserId, r: Request, content: Content): Request {
  //@ verify
  //@ requires canEdit(dir, actor, r)
  //@ ensures \result.status === r.status && \result.author === r.author && \result.department === r.department
  //@ ensures \result.content === content
  return { ...r, content };
}

export function submit(actor: UserId, r: Request): Request {
  //@ verify
  //@ requires canSubmit(actor, r)
  //@ ensures \result.status.kind === "Pending"
  //@ ensures \result.author === r.author && \result.department === r.department && \result.content === r.content
  return { ...r, status: { kind: "Pending" } };
}

export function approve(dir: Directory, actor: UserId, r: Request): Request {
  //@ verify
  //@ requires canDecide(dir, actor, r)
  //@ ensures \result.status.kind === "Approved" && \result.status.approvedBy === actor
  //@ ensures \result.author === r.author && \result.department === r.department && \result.content === r.content
  return { ...r, status: { kind: "Approved", approvedBy: actor } };
}

export function reject(dir: Directory, actor: UserId, r: Request): Request {
  //@ verify
  //@ requires canDecide(dir, actor, r)
  //@ ensures \result.status.kind === "Rejected" && \result.status.rejectedBy === actor
  //@ ensures \result.author === r.author && \result.department === r.department && \result.content === r.content
  return { ...r, status: { kind: "Rejected", rejectedBy: actor } };
}

export function returnToAuthor(dir: Directory, actor: UserId, r: Request): Request {
  //@ verify
  //@ requires canDecide(dir, actor, r)
  //@ ensures \result.status.kind === "Returned" && \result.status.returnedBy === actor
  //@ ensures \result.author === r.author && \result.department === r.department && \result.content === r.content
  return { ...r, status: { kind: "Returned", returnedBy: actor } };
}

/**
 * The dynamic entry point. Any (request, command) pair coming from the outside world is
 * classified here and delegated to a preconditioned transition, so `step` is total. An actor
 * who cannot read learns nothing about the request, and a decided request answers before the
 * command is even looked at (P2).
 *
 * The postconditions are the one-step theorems of spec.md: P1 (a successful decision is by a
 * Manager of the target department), P2 (a decided request accepts nothing), identity is
 * immutable, and each command succeeds exactly under its access rule.
 */
export function step(dir: Directory, actor: UserId, r: Request, cmd: Command): Outcome {
  //@ verify
  //@ contract Apply `cmd` to `r` on behalf of `actor`, or explain why it is denied.
  //@ ensures \result.kind === "Success" ==> canRead(dir, actor, r)
  //@ ensures isTerminal(r.status) ==> \result.kind === "Failure"
  //@ ensures \result.kind === "Success" ==> \result.value.author === r.author && \result.value.department === r.department
  //@ ensures \result.kind === "Success" && (cmd.kind === "Approve" || cmd.kind === "Reject" || cmd.kind === "Return") ==> canDecide(dir, actor, r)
  //@ ensures \result.kind === "Success" && cmd.kind === "Submit" ==> canSubmit(actor, r) && \result.value.status.kind === "Pending"
  //@ ensures \result.kind === "Success" && cmd.kind === "Edit" ==> canEdit(dir, actor, r) && \result.value.status === r.status
  //@ ensures canDecide(dir, actor, r) && cmd.kind === "Approve" ==> \result.kind === "Success" && \result.value.status.kind === "Approved"
  //@ ensures canDecide(dir, actor, r) && cmd.kind === "Reject" ==> \result.kind === "Success" && \result.value.status.kind === "Rejected"
  //@ ensures canDecide(dir, actor, r) && cmd.kind === "Return" ==> \result.kind === "Success" && \result.value.status.kind === "Returned"
  //@ ensures \result.kind === "Success" && \result.value.status !== r.status ==> !isTerminal(r.status) && (r.status.kind === "Pending" ? isTerminal(\result.value.status) || \result.value.status.kind === "Returned" : \result.value.status.kind === "Pending")
  if (!canRead(dir, actor, r)) return failure("NotAffiliated");
  if (isTerminal(r.status)) return failure("TerminalRequest");
  switch (cmd.kind) {
    case "Edit":
      if (canEdit(dir, actor, r)) return success(edit(dir, actor, r, cmd.content));
      return failure(r.status.kind === "Pending" ? "NotManager" : "NotAuthor");
    case "Submit":
      if (canSubmit(actor, r)) return success(submit(actor, r));
      return failure(r.status.kind === "Pending" ? "WrongState" : "NotAuthor");
    case "Approve":
      if (canDecide(dir, actor, r)) return success(approve(dir, actor, r));
      return failure(r.status.kind === "Pending" ? "NotManager" : "WrongState");
    case "Reject":
      if (canDecide(dir, actor, r)) return success(reject(dir, actor, r));
      return failure(r.status.kind === "Pending" ? "NotManager" : "WrongState");
    case "Return":
      if (canDecide(dir, actor, r)) return success(returnToAuthor(dir, actor, r));
      return failure(r.status.kind === "Pending" ? "NotManager" : "WrongState");
  }
}

// === Traces ===

export interface Event {
  actor: UserId;
  command: Command;
}

/**
 * Apply a whole trace; denied commands leave the request untouched. The loop invariants lift
 * the one-step theorems of `step` to system invariants: identity is immutable and decided
 * requests are frozen (P2) along any trace -- of any length, over a directory of any size.
 */
export function run(dir: Directory, r: Request, events: Event[]): Request {
  //@ verify
  //@ contract Fold `step` over `events`, keeping the request where a command is denied.
  //@ ensures \result.author === r.author && \result.department === r.department
  //@ ensures wellFormed(dir, r) ==> wellFormed(dir, \result)
  //@ ensures isTerminal(r.status) ==> \result === r
  let current = r;
  for (let i = 0; i < events.length; i++) {
    //@ invariant 0 <= i && i <= events.length
    //@ invariant current.author === r.author && current.department === r.department
    //@ invariant isTerminal(r.status) ==> current === r
    const outcome = step(dir, events[i].actor, current, events[i].command);
    if (outcome.kind === "Success") current = outcome.value;
  }
  return current;
}

// === The mutable system (spec.md as a running service) ===

/**
 * The request store of a running service. The class invariant -- every stored request is
 * well-formed against the directory -- is stated as `requires` / `ensures` of each method.
 * P3 (no orphaned request) becomes a theorem about any store whose directory satisfies
 * `departmentsHaveManagers` (`WorkflowHasNoOrphanedRequests` in approval.dfy).
 */
export class Workflow {
  directory: Directory;
  requests: Map<number, Request>;
  nextId: number;

  constructor(directory: Directory) {
    this.directory = directory;
    this.requests = new Map();
    this.nextId = 0;
  }

  /** Action A on the store: a successfully created request is recorded under a fresh id. */
  open(author: UserId, dep: DepartmentId, content: Content): Outcome {
    //@ verify
    //@ requires forall(id, this.requests.has(id) ==> wellFormed(this.directory, this.requests.get(id)))
    //@ ensures forall(id, this.requests.has(id) ==> wellFormed(this.directory, this.requests.get(id)))
    //@ ensures \result.kind === "Success" ==> this.requests.has(this.nextId - 1) && this.requests.get(this.nextId - 1) === \result.value
    //@ ensures \result.kind === "Success" ==> \result.value.author === author && \result.value.department === dep && \result.value.status.kind === "Draft"
    const outcome = create(this.directory, author, dep, content);
    if (outcome.kind === "Success") {
      const stored = new Map(this.requests);
      stored.set(this.nextId, outcome.value);
      this.requests = stored;
      this.nextId = this.nextId + 1;
    }
    return outcome;
  }

  /** Actions B..F on the store: `step` decides, and only a success is written back. */
  apply(actor: UserId, id: number, cmd: Command): Outcome {
    //@ verify
    //@ requires forall(k, this.requests.has(k) ==> wellFormed(this.directory, this.requests.get(k)))
    //@ ensures forall(k, this.requests.has(k) ==> wellFormed(this.directory, this.requests.get(k)))
    //@ ensures \result.kind === "Success" ==> this.requests.has(id) && this.requests.get(id) === \result.value
    const current = this.requests.get(id);
    if (current === undefined) return failure("NoSuchRequest");
    const outcome = step(this.directory, actor, current, cmd);
    if (outcome.kind === "Success") {
      const stored = new Map(this.requests);
      stored.set(id, outcome.value);
      this.requests = stored;
    }
    return outcome;
  }
}
