import Approval.Permission

/-!
# Actions and the transition relation (spec §4)

`Step dir actor a r r'` is an inductive predicate: a value of this type *is* a
proof that `actor` may perform `a` on `r`, yielding `r'`. Each constructor
carries exactly the preconditions of the corresponding spec item, so a theorem
proved by `cases` on a `Step` is automatically re-checked for exhaustiveness
whenever an action is added.

The three manager decisions (D, E, F) share every precondition and differ only
in the resulting status, so they are one constructor parameterised by
`Decision`.
-/

namespace Approval

variable {U D : Type}

/-- What a target-department manager may do with a `Pending` request. -/
inductive Decision where
  | approve
  | reject
  | «return»
  deriving DecidableEq, Repr

/-- The status a decision leads to (spec §2 diagram). -/
def Decision.outcome : Decision → Status
  | .approve => .approved
  | .reject => .rejected
  | .«return» => .returned

/-- Actions on an existing request. Creation (spec §4 A) is `Reachable.create`. -/
inductive Action where
  | edit
  | submit
  | decide (d : Decision)
  deriving DecidableEq, Repr

/-- Transition relation. -/
inductive Step (dir : Directory U D) (actor : U) : Action → Request U D → Request U D → Prop where
  /-- B: editing changes the content, not the status. -/
  | edit {r} (h : dir.CanEdit actor r) :
      Step dir actor .edit r r
  /-- C: only the author submits, from `Draft` or `Returned`. -/
  | submit {r} (hauthor : actor = r.author) (hs : r.status.Submittable) :
      Step dir actor .submit r { r with status := .pending }
  /-- D / E / F: only a manager *of the target department* decides a `Pending` request. -/
  | decide {r} (d : Decision) (hmanager : dir.IsManager actor r.target) (hs : r.status = .pending) :
      Step dir actor (.decide d) r { r with status := d.outcome }

/-- Requests that can exist in the system: created by an affiliated user (A),
then evolved by valid steps only. -/
inductive Reachable (dir : Directory U D) : Request U D → Prop where
  | create {u : U} {d : D} (h : dir.Affiliated u d) :
      Reachable dir { author := u, target := d }
  | step {r r' : Request U D} {actor : U} {a : Action}
      (hr : Reachable dir r) (hs : Step dir actor a r r') :
      Reachable dir r'

/-! ## Executable semantics

`Action.apply` is a *function* that either performs the action or explains the
refusal. `apply_ok_iff` proves it agrees exactly with `Step`, so the CLI runner
and the proofs talk about the same workflow. -/

/-- Why an action was refused. -/
inductive Denial where
  | notAuthor
  | notManager
  | wrongState
  deriving DecidableEq, Repr

variable [DecidableEq U]

def Action.apply (dir : Directory U D) (actor : U) : Action → Request U D → Except Denial (Request U D)
  | .edit, r =>
    if dir.CanEdit actor r then .ok r
    else if r.status.IsTerminal ∨ actor = r.author then .error .wrongState
    else .error .notManager
  | .submit, r =>
    if actor = r.author then
      if r.status.Submittable then .ok { r with status := .pending } else .error .wrongState
    else .error .notAuthor
  | .decide d, r =>
    if dir.IsManager actor r.target then
      if r.status = .pending then .ok { r with status := d.outcome } else .error .wrongState
    else .error .notManager

namespace Action

variable {dir : Directory U D} {actor : U} {a : Action} {r r' : Request U D}

/-- Soundness: whatever `apply` performs is a valid step. -/
theorem apply_sound (h : a.apply dir actor r = .ok r') : Step dir actor a r r' := by
  cases a with
  | edit =>
    simp only [apply] at h
    split at h
    · cases h; exact .edit ‹_›
    · split at h <;> cases h
  | submit =>
    simp only [apply] at h
    split at h
    · split at h
      · cases h; exact .submit ‹_› ‹_›
      · cases h
    · cases h
  | decide d =>
    simp only [apply] at h
    split at h
    · split at h
      · cases h; exact .decide d ‹_› ‹_›
      · cases h
    · cases h

/-- Completeness: every valid step is performed by `apply`. -/
theorem apply_complete (h : Step dir actor a r r') : a.apply dir actor r = .ok r' := by
  cases h with
  | edit hc => simp [apply, hc]
  | submit ha hs => simp [apply, ha, hs]
  | decide d hm hs => simp [apply, hm, hs]

/-- `apply` is exactly the functional presentation of `Step`. -/
theorem apply_ok_iff : a.apply dir actor r = .ok r' ↔ Step dir actor a r r' :=
  ⟨apply_sound, apply_complete⟩

/-- A refusal means no valid step exists. -/
theorem apply_error {e : Denial} (h : a.apply dir actor r = .error e) :
    ¬ ∃ r', Step dir actor a r r' := by
  rintro ⟨r', hs⟩
  rw [← apply_ok_iff, h] at hs
  cases hs

end Action

/-- The relation is deterministic: an action has at most one result. -/
theorem Step.unique {dir : Directory U D} {actor : U} {a : Action} {r r₁ r₂ : Request U D}
    (h₁ : Step dir actor a r r₁) (h₂ : Step dir actor a r r₂) : r₁ = r₂ := by
  have := Action.apply_complete h₁
  rw [Action.apply_complete h₂] at this
  cases this
  rfl

/-- Whether a step exists is decidable, via the executable semantics. -/
instance [DecidableEq D] {dir : Directory U D} {actor : U} {a : Action} {r r' : Request U D} :
    Decidable (Step dir actor a r r') :=
  match h : a.apply dir actor r with
  | .ok r'' =>
    decidable_of_iff (r'' = r') <| by
      rw [← Action.apply_ok_iff, h]
      exact ⟨fun e => e ▸ rfl, fun e => by cases e; rfl⟩
  | .error _ => isFalse fun hs => Action.apply_error h ⟨_, hs⟩

end Approval
