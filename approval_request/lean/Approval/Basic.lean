/-!
# Approval request workflow — entities (spec §1, §2)

Users and departments are left abstract (`U`, `D`); the model only needs
decidable equality on them. Roles are attached to the *pair* (user, department)
through a `Directory`, never to the user alone (spec §6).
-/

namespace Approval

/-- Position of a user *in one department* (spec §1, Affiliation). -/
inductive Role where
  | member
  | manager
  deriving DecidableEq, Repr

/-- Lifecycle state of a request (spec §2). -/
inductive Status where
  | draft
  | pending
  | returned
  | approved
  | rejected
  deriving DecidableEq, Repr

namespace Status

/-- Terminal states: no action may leave them (spec §2, P2). -/
abbrev IsTerminal (s : Status) : Prop := s = approved ∨ s = rejected

/-- States from which the author may (re)submit (spec §4 C). -/
abbrev Submittable (s : Status) : Prop := s = draft ∨ s = returned

theorem Submittable.not_terminal {s : Status} (h : s.Submittable) : ¬ s.IsTerminal := by
  rcases h with rfl | rfl <;> simp

theorem pending_not_terminal : ¬ pending.IsTerminal := by simp

end Status

/-- A request. `author` and `target` are fixed at creation; only `status` evolves. -/
structure Request (U D : Type) where
  author : U
  target : D
  status : Status := .draft
  deriving DecidableEq, Repr

/-- Who holds which role where: `role u d = none` means `u` does not belong to `d`. -/
structure Directory (U D : Type) where
  role : U → D → Option Role

namespace Directory

variable {U D : Type} (dir : Directory U D)

/-- `u` belongs to `d` with some role (spec §1). -/
abbrev Affiliated (u : U) (d : D) : Prop := dir.role u d ≠ none

/-- `u` is a manager *of `d`* — the only notion of authority in this model. -/
abbrev IsManager (u : U) (d : D) : Prop := dir.role u d = some .manager

abbrev IsMember (u : U) (d : D) : Prop := dir.role u d = some .member

variable {dir}

theorem IsManager.affiliated {u : U} {d : D} (h : dir.IsManager u d) : dir.Affiliated u d := by
  simp [h]

theorem IsMember.not_manager {u : U} {d : D} (h : dir.IsMember u d) : ¬ dir.IsManager u d := by
  simp [h]

/-- Structural invariant of a directory: every department has a manager (spec §1). -/
structure WF (dir : Directory U D) : Prop where
  managerExists : ∀ d : D, ∃ u : U, dir.IsManager u d

end Directory

end Approval
