/*
 * Approval request workflow with multi-affiliation (兼務) users.
 *
 * See ../spec.md for the natural-language specification.
 *
 * Modelling notes:
 *   - A role is a property of a (User, Department) pair, not of a user, so it is
 *     modelled as the ternary relation `roles: User -> Department -> lone Role`.
 *   - The request pool is static; membership in the pool at a given instant is
 *     given by the mutable field `status`. A request with no status has not been
 *     created yet, which keeps the state space small while still letting the
 *     trace contain creation events.
 *   - Every event predicate is a constraint over the current and the next
 *     instant (fields marked `var`, next state written `x'`), and `traces`
 *     turns them into an infinite execution with `always`.
 */
module approval_request/approval

// ---------------------------------------------------------------- static world

enum Role { Member, Manager }

abstract sig Status {}
abstract sig Terminal extends Status {}
one sig Draft, Pending, Returned extends Status {}
one sig Approved, Rejected extends Terminal {}

sig Department {}

sig User {
  // Role held by this user in a department. A user not affiliated with a
  // department is simply not mapped for it; `lone` allows at most one role per
  // department while permitting affiliations with several departments.
  roles: Department -> lone Role
} {
  some roles // every user belongs to at least one department
}

fun affiliations [u: User]: set Department { u.roles.Role }

fun members [d: Department]: set User { { u: User | u.roles[d] = Member } }

fun managers [d: Department]: set User { { u: User | u.roles[d] = Manager } }

// Every department is headed by at least one manager (premise of P3).
fact everyDepartmentIsManaged {
  all d: Department | some managers[d]
}

// Opaque request payload: `edit` replaces it, which makes edits observable
// without modelling any document structure.
sig Content {}

sig Request {
  author: User,
  target: Department,
  var status: lone Status,
  var content: lone Content
} {
  // A request can only be filed against a department its author belongs to.
  target in affiliations[author]
}

// Requests that exist in the system at the current instant.
fun live: set Request { status.Status }

// A request exists exactly as long as it carries a payload.
fact wellFormedState {
  always all r: Request | some r.status iff some r.content
}

// ------------------------------------------------------------------ permissions
// Permissions are pure predicates on the current instant: they never move the
// system, so they can be reused as guards and as subjects of assertions.

pred canRead [u: User, r: Request] {
  r in live
  r.target in affiliations[u] // R1, R2
}

pred canEdit [u: User, r: Request] {
  r in live
  (u = r.author and r.status in Draft + Returned)  // U1 (and U2 by exclusion)
  or
  (u in managers[r.target] and r.status in Draft + Returned + Pending) // U3
}

// Approving, rejecting and returning share the same guard: being a manager of
// the *target* department. Self-approval is allowed on purpose (spec §4 D).
pred canDecide [u: User, r: Request] {
  r.status = Pending
  u in managers[r.target]
}

// ----------------------------------------------------------------------- events

// Frame condition: everything except `r` keeps its status and content.
pred onlyChanges [r: Request] {
  all o: Request - r | o.status' = o.status and o.content' = o.content
}

pred create [u: User, d: Department, r: Request] {
  // guard
  no r.status
  r.author = u
  r.target = d
  d in affiliations[u]
  // effect
  r.status' = Draft
  some r.content'
  onlyChanges[r]
}

pred edit [u: User, r: Request] {
  canEdit[u, r]
  r.content' != r.content // the payload is replaced
  r.status' = r.status    // editing does not move the request (spec §4 B)
  onlyChanges[r]
}

pred submit [u: User, r: Request] {
  u = r.author
  r.status in Draft + Returned
  r.status' = Pending
  r.content' = r.content
  onlyChanges[r]
}

pred decide [u: User, r: Request, s: Status] {
  canDecide[u, r]
  s in Approved + Rejected + Returned
  r.status' = s
  r.content' = r.content
  onlyChanges[r]
}

pred approve [u: User, r: Request] { decide[u, r, Approved] }
pred reject  [u: User, r: Request] { decide[u, r, Rejected] }
pred sendBack[u: User, r: Request] { decide[u, r, Returned] }

pred stutter {
  status' = status
  content' = content
}

// Reified events. Making the firing event visible as a relation lets the
// visualizer label each transition and lets assertions talk about "who did it".
fun creates:  User -> Request { { u: User, r: Request | some d: Department | create[u, d, r] } }
fun edits:    User -> Request { { u: User, r: Request | edit[u, r] } }
fun submits:  User -> Request { { u: User, r: Request | submit[u, r] } }
fun approves: User -> Request { { u: User, r: Request | approve[u, r] } }
fun rejects:  User -> Request { { u: User, r: Request | reject[u, r] } }
fun sendsBack:User -> Request { { u: User, r: Request | sendBack[u, r] } }

fun happenings: User -> Request {
  creates + edits + submits + approves + rejects + sendsBack
}

// ------------------------------------------------------------------- executions

pred init {
  no status
  no content
}

pred step {
  some happenings or stutter
}

fact traces {
  init
  always step
}

// Progress assumption used by the liveness checks only: a manager who can
// decide on a request does not procrastinate forever.
pred fairness {
  all u: User, r: Request |
    always (canDecide[u, r] implies eventually (u -> r in approves + rejects + sendsBack))
}

// ------------------------------------------------------------------- assertions

// P1 - separation of duties for multi-affiliated users: the right to decide is a
// function of the role held in the target department only, so two users that
// agree there have exactly the same rights, whatever else they are managers of.
assert decisionRightsDependOnTargetRoleOnly {
  always all u1, u2: User, r: Request |
    u1.roles[r.target] = u2.roles[r.target] implies (canDecide[u1, r] iff canDecide[u2, r])
}
check decisionRightsDependOnTargetRoleOnly for 4 but 1..5 steps

// P1 (transition level): a request only ever reaches a terminal state through a
// manager of its target department, and nobody else could have caused it.
assert terminalDecidedByTargetManager {
  always all r: Request |
    r.status not in Terminal and r.status' in Terminal implies
      let deciders = { u: User | u -> r in approves + rejects } |
        some deciders and deciders in managers[r.target]
}
check terminalDecidedByTargetManager for 4 but 1..8 steps

// P2 - terminal states are absorbing.
assert terminalStatesAreStable {
  all r: Request, s: Terminal | always (r.status = s implies always r.status = s)
}
check terminalStatesAreStable for 4 but 1..10 steps

// P3 - no orphan request: whatever exists can always be decided upon by someone.
assert noOrphanRequest {
  always all r: live | some managers[r.target]
}
check noOrphanRequest for 5 but 1..5 steps

// R2 - a user never sees a request filed against a department they do not belong to.
assert readsRequireAffiliation {
  always all u: User, r: Request | canRead[u, r] implies r.target in affiliations[u]
}
check readsRequireAffiliation for 5 but 1..5 steps

// U1/U2/U3 - the payload only ever changes while an authorized editor exists,
// and only the author or a manager of the target department qualifies.
assert contentChangesNeedAuthorizedEditor {
  always all r: live |
    r.content' != r.content implies
      some u: User | canEdit[u, r] and u in r.author + managers[r.target]
}
check contentChangesNeedAuthorizedEditor for 4 but 1..8 steps

// U2 - a plain member of the target department cannot touch somebody else's request.
assert plainMembersCannotEditOthersRequests {
  always all r: live, u: members[r.target] - r.author | not canEdit[u, r]
}
check plainMembersCannotEditOthersRequests for 4 but 1..5 steps

// The state machine of spec §2 is respected: no transition skips a step.
assert statusFollowsStateMachine {
  always all r: Request | let from = r.status, to = r.status' |
    from != to implies
      (no from and to = Draft)
      or (from = Draft and to = Pending)
      or (from = Returned and to = Pending)
      or (from = Pending and to in Approved + Rejected + Returned)
}
check statusFollowsStateMachine for 4 but 1..10 steps

// A returned request must have been submitted before (past-time operator).
assert returnedImpliesEarlierSubmission {
  always all r: Request | r.status = Returned implies once r.status = Pending
}
check returnedImpliesEarlierSubmission for 4 but 1..10 steps

// Liveness: under the progress assumption, a submitted request does not stay
// pending forever - it is approved, rejected or sent back.
assert pendingIsEventuallyDecided {
  fairness implies always all r: Request | r.status = Pending implies eventually r.status != Pending
}
check pendingIsEventuallyDecided for 3 but 1..8 steps

// ---------------------------------------------------------------- example runs

// The interesting scenario behind P1: the author is a manager somewhere else,
// files against a department where they are a mere member, and therefore has to
// wait for that department's manager.
run crossAffiliatedAuthorCannotSelfApprove {
  some u: User, r: Request {
    r.author = u
    u.roles[r.target] = Member
    Manager in u.roles[Department]
    eventually (u -> r in submits)
    eventually (r.status = Approved and not (u -> r in approves))
  }
} for 3 but exactly 2 Department, exactly 1 Request, 1..8 steps

// Self-approval is legitimate when the author manages the target department.
run selfApprovalIsAllowed {
  some u: User, r: Request {
    r.author = u
    u in managers[r.target]
    eventually (u -> r in approves)
  }
} for 3 but exactly 1 Request, 1..6 steps

// Full round trip: submit, send back, edit, resubmit, approve.
run returnAndResubmitRoundTrip {
  some r: Request, m: User {
    eventually (r.author -> r in submits)
    eventually (m -> r in sendsBack)
    eventually (r.author -> r in edits)
    eventually (r.status = Approved)
  }
} for 3 but exactly 1 Request, exactly 2 Content, 1..10 steps
