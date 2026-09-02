import Approval.Basic

/-!
# Read / update permissions (spec §3)

Permissions are predicates over (directory, actor, request); they do not change
the request. They are decidable, so `decide` can settle concrete instances and
the executable semantics can test them.
-/

namespace Approval

variable {U D : Type}

namespace Directory

variable (dir : Directory U D) (actor : U) (r : Request U D)

/-- R1 / R2: readable iff the actor belongs to the target department. -/
abbrev CanRead : Prop := dir.Affiliated actor r.target

/-- U1 (author, while `Draft`/`Returned`) or U3 (target manager, while not terminal).
U2 is the absence of any other clause. -/
abbrev CanEdit : Prop :=
  (actor = r.author ∧ r.status.Submittable) ∨
  (dir.IsManager actor r.target ∧ ¬ r.status.IsTerminal)

variable {dir actor r}

theorem CanEdit.not_terminal (h : dir.CanEdit actor r) : ¬ r.status.IsTerminal := by
  rcases h with ⟨_, hs⟩ | ⟨_, hs⟩
  · exact hs.not_terminal
  · exact hs

/-- U2: a plain member of the department who is not the author can never edit. -/
theorem IsMember.not_canEdit (hm : dir.IsMember actor r.target) (ha : actor ≠ r.author) :
    ¬ dir.CanEdit actor r := by
  rintro (⟨h, _⟩ | ⟨h, _⟩)
  · exact ha h
  · exact hm.not_manager h

/-- Editing never grants anything to outsiders: `CanEdit` implies `CanRead`
whenever the author belongs to the target department. -/
theorem CanEdit.canRead (h : dir.CanEdit actor r) (hauthor : dir.Affiliated r.author r.target) :
    dir.CanRead actor r := by
  rcases h with ⟨rfl, _⟩ | ⟨hm, _⟩
  · exact hauthor
  · exact hm.affiliated

end Directory

end Approval
