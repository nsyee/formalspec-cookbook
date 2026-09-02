import Approval.Step

/-!
# Scenarios: executable traces with expected outcomes

A `Scenario` is a request plus a script of `(actor, action, expectation)`. It is
run with `Action.apply`, whose agreement with `Step` is proved in
`Approval.Step`, so a scenario that checks at compile time (`#guard`) is a
genuine fact about the relation.
-/

namespace Approval

variable {U D : Type}

/-- What a scripted step should produce. -/
inductive Expect where
  | ok (status : Status)
  | denied (why : Denial)
  deriving DecidableEq, Repr

structure Scenario (U D : Type) where
  name : String
  description : String
  dir : Directory U D
  initial : Request U D
  script : List (U × Action × Expect)

/-- One executed line of a scenario. -/
structure Outcome (U D : Type) where
  actor : U
  action : Action
  expected : Expect
  result : Except Denial (Request U D)
  before : Request U D

namespace Outcome

def met [DecidableEq D] (o : Outcome U D) : Bool :=
  match o.expected, o.result with
  | .ok s, .ok r => r.status = s
  | .denied e, .error e' => e = e'
  | _, _ => false

end Outcome

namespace Scenario

variable [DecidableEq U] [DecidableEq D]

/-- Run the script; a denied step leaves the request unchanged. -/
def run (s : Scenario U D) : List (Outcome U D) :=
  go s.initial s.script
where
  go (r : Request U D) : List (U × Action × Expect) → List (Outcome U D)
    | [] => []
    | (actor, a, e) :: rest =>
      let res := a.apply s.dir actor r
      let next := match res with
        | .ok r' => r'
        | .error _ => r
      { actor, action := a, expected := e, result := res, before := r } :: go next rest

/-- Every line met its expectation. -/
def passes (s : Scenario U D) : Bool :=
  s.run.all Outcome.met

end Scenario

/-! ## Pretty printing for the CLI -/

def Status.show : Status → String
  | .draft => "Draft"
  | .pending => "Pending"
  | .returned => "Returned"
  | .approved => "Approved"
  | .rejected => "Rejected"

instance : ToString Status := ⟨Status.show⟩

def Decision.show : Decision → String
  | .approve => "approve"
  | .reject => "reject"
  | .«return» => "return"

def Action.show : Action → String
  | .edit => "edit"
  | .submit => "submit"
  | .decide d => d.show

instance : ToString Action := ⟨Action.show⟩

def Denial.show : Denial → String
  | .notAuthor => "denied: not the author"
  | .notManager => "denied: not a manager of the target department"
  | .wrongState => "denied: not allowed in this state"

instance : ToString Denial := ⟨Denial.show⟩

def Expect.show : Expect → String
  | .ok s => s!"-> {s}"
  | .denied e => e.show

instance : ToString Expect := ⟨Expect.show⟩

instance [ToString U] [ToString D] : ToString (Request U D) where
  toString r := s!"{r.status} (author {r.author}, target {r.target})"

def Outcome.show [ToString U] [ToString D] [DecidableEq D] (o : Outcome U D) : String :=
  let verdict := if o.met then "ok  " else "FAIL"
  let actual := match o.result with
    | .ok r' => s!"-> {r'.status}"
    | .error e => e.show
  let expectation := if o.met then "" else s!"   (expected {o.expected})"
  s!"{verdict} [{o.before.status}] {o.actor} {o.action}: {actual}{expectation}"

end Approval
