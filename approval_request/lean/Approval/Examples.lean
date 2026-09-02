import Approval.Properties
import Approval.Scenario

/-!
# A concrete organisation and the spec's scenarios

Three users, two departments, one cross-affiliated user:

| user  | sales   | eng     |
| ----- | ------- | ------- |
| alice | member  | –       |
| bob   | manager | –       |
| carol | member  | manager |

The `example`s below are checked by `decide` — the kernel evaluates
`Action.apply` — and every scenario is also `#guard`ed at compile time. The CLI
(`lake exe approval`) replays the same scenarios as readable traces.
-/

namespace Approval.Examples

inductive User where
  | alice
  | bob
  | carol
  deriving DecidableEq, Repr

inductive Dept where
  | sales
  | eng
  deriving DecidableEq, Repr

open User Dept

instance : ToString User := ⟨fun u => match u with | alice => "alice" | bob => "bob" | carol => "carol"⟩
instance : ToString Dept := ⟨fun d => match d with | sales => "sales" | eng => "eng"⟩

def dir : Directory User Dept where
  role
    | alice, sales => some .member
    | bob, sales => some .manager
    | carol, sales => some .member
    | carol, eng => some .manager
    | _, _ => none

/-- Every department has a manager, witnessed explicitly. -/
theorem dir_wf : dir.WF where
  managerExists
    | sales => ⟨bob, rfl⟩
    | eng => ⟨carol, rfl⟩

/-! ## Facts about single steps, settled by evaluation -/

def aliceDraft : Request User Dept := { author := alice, target := sales }
def alicePending : Request User Dept := { aliceDraft with status := .pending }
def carolPending : Request User Dept := { author := carol, target := sales, status := .pending }
def bobPending : Request User Dept := { author := bob, target := sales, status := .pending }

/-- C: the author submits a draft. -/
example : Step dir alice .submit aliceDraft alicePending := by decide

/-- D: a manager of the target department approves. -/
example : Step dir bob (.decide .approve) alicePending { alicePending with status := .approved } := by
  decide

/-- Self-approval: bob is author *and* sales manager. -/
example : Step dir bob (.decide .approve) bobPending { bobPending with status := .approved } := by
  decide

/-- P1: carol manages eng but is a member of sales; she cannot approve her own sales request. -/
example : ¬ Step dir carol (.decide .approve) carolPending { carolPending with status := .approved } := by
  decide

/-- The same fact, derived from the general theorem rather than by evaluation. -/
example : ¬ Step dir carol (.decide .approve) carolPending { carolPending with status := .approved } :=
  P1_no_authority_leak (x := eng) rfl rfl

/-- U2: a fellow member (carol) may not edit alice's draft, but the manager (bob) may (U3). -/
example : ¬ dir.CanEdit carol aliceDraft := by decide
example : dir.CanEdit bob aliceDraft := by decide

/-- U1: the author may edit while `Draft`, but not once `Pending`. -/
example : dir.CanEdit alice aliceDraft := by decide
example : ¬ dir.CanEdit alice alicePending := by decide

/-- R2: nobody outside sales can read a sales request; alice cannot read eng requests. -/
example : ¬ dir.CanRead alice { author := carol, target := eng } := by decide

/-- A full trace as a proof term: alice's request is approved after a round trip. -/
example : Reachable dir { aliceDraft with status := .approved } :=
  .step (actor := bob) (.step (actor := alice) (.step (actor := bob) (.step (actor := alice)
    (.create (by decide))
    (.submit rfl (.inl rfl)))
    (.decide .«return» rfl rfl))
    (.submit rfl (.inr rfl)))
    (.decide .approve rfl rfl)

/-! ## Scenarios (replayed by the CLI) -/

def happyPath : Scenario User Dept where
  name := "happy-path"
  description := "alice drafts, edits, submits; bob approves; nothing moves afterwards (P2)"
  dir := dir
  initial := aliceDraft
  script := [
    (alice, .edit, .ok .draft),
    (alice, .submit, .ok .pending),
    (bob, .decide .approve, .ok .approved),
    (bob, .edit, .denied .wrongState),
    (alice, .submit, .denied .wrongState),
    (bob, .decide .reject, .denied .wrongState),
  ]

def roundTrip : Scenario User Dept where
  name := "round-trip"
  description := "return, author edits and resubmits, then rejected"
  dir := dir
  initial := aliceDraft
  script := [
    (alice, .submit, .ok .pending),
    (alice, .edit, .denied .wrongState),
    (bob, .edit, .ok .pending),
    (bob, .decide .«return», .ok .returned),
    (alice, .edit, .ok .returned),
    (alice, .submit, .ok .pending),
    (bob, .decide .reject, .ok .rejected),
  ]

def crossAffiliation : Scenario User Dept where
  name := "cross-affiliation"
  description := "carol (eng manager, sales member) cannot use her eng authority on a sales request (P1)"
  dir := dir
  initial := { author := carol, target := sales }
  script := [
    (carol, .submit, .ok .pending),
    (carol, .decide .approve, .denied .notManager),
    (carol, .decide .«return», .denied .notManager),
    (alice, .edit, .denied .notManager),
    (bob, .decide .approve, .ok .approved),
  ]

def selfApproval : Scenario User Dept where
  name := "self-approval"
  description := "bob, sales manager, approves his own sales request"
  dir := dir
  initial := { author := bob, target := sales }
  script := [
    (alice, .submit, .denied .notAuthor),
    (bob, .submit, .ok .pending),
    (bob, .decide .approve, .ok .approved),
  ]

def engRequest : Scenario User Dept where
  name := "eng-request"
  description := "in eng, carol is the manager: she approves her own request there"
  dir := dir
  initial := { author := carol, target := eng }
  script := [
    (carol, .submit, .ok .pending),
    (bob, .decide .approve, .denied .notManager),
    (carol, .decide .approve, .ok .approved),
  ]

def scenarios : List (Scenario User Dept) :=
  [happyPath, roundTrip, crossAffiliation, selfApproval, engRequest]

#guard scenarios.all Scenario.passes

end Approval.Examples
