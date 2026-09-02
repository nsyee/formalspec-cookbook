import Approval.Step

/-!
# Verified properties (spec §5 and the invariants behind them)

Every statement here is a theorem about *all* directories, users, departments
and requests — no bound on the number of users or departments is involved. A
proof by `cases` on a `Step` enumerates the actions, so adding an action to
`Step` without revisiting a property here is a compile error.
-/

namespace Approval

variable {U D : Type} {dir : Directory U D} {actor : U} {a : Action} {r r' : Request U D}

/-! ## What a step can and cannot change -/

/-- Steps never touch the author or the target department (spec §1). -/
theorem Step.author_eq (h : Step dir actor a r r') : r'.author = r.author := by
  cases h <;> rfl

theorem Step.target_eq (h : Step dir actor a r r') : r'.target = r.target := by
  cases h <;> rfl

/-- A step may only start from a non-terminal request. -/
theorem Step.not_terminal (h : Step dir actor a r r') : ¬ r.status.IsTerminal := by
  cases h with
  | edit hc => exact hc.not_terminal
  | submit _ hs => exact hs.not_terminal
  | decide _ _ hs => rw [hs]; exact Status.pending_not_terminal

/-! ## P2 — terminal states are immutable -/

/-- No action applies to an `Approved` or `Rejected` request at all. -/
theorem P2_terminal_stuck (hterm : r.status.IsTerminal) : ¬ Step dir actor a r r' :=
  fun h => h.not_terminal hterm

/-- Phrased as in the spec: a terminal request never changes its status. -/
theorem P2_terminal_status_fixed (hterm : r.status.IsTerminal) (h : Step dir actor a r r') :
    r'.status = r.status :=
  absurd h (P2_terminal_stuck hterm)

/-! ## P1 — authority is judged in the target department only -/

/-- Reaching `Approved` from anywhere else is possible only for a manager of the
*target* department (the attachment's `only_manager_can_approve`). -/
theorem approved_by_target_manager (h : Step dir actor a r r')
    (hbefore : r.status ≠ .approved) (hafter : r'.status = .approved) :
    dir.IsManager actor r.target := by
  cases h with
  | edit => exact absurd hafter hbefore
  | submit => cases hafter
  | decide d hm _ => exact hm

/-- Every decision (approve / reject / return) is taken by a target manager. -/
theorem decision_by_target_manager {d : Decision} (h : Step dir actor (.decide d) r r') :
    dir.IsManager actor r.target := by
  cases h; assumption

/-- P1 proper: a user who is a manager of `x` but only a member of the target
department `y` cannot decide on a request to `y` — even their own. -/
theorem P1_no_authority_leak {x : D} {d : Decision}
    (_hx : dir.IsManager actor x) (hy : dir.IsMember actor r.target) :
    ¬ Step dir actor (.decide d) r r' :=
  fun h => hy.not_manager (decision_by_target_manager h)

/-- Only a target manager can even *edit* somebody else's request (U2). -/
theorem P1_no_edit_leak {x : D} (_hx : dir.IsManager actor x) (hy : dir.IsMember actor r.target)
    (hauthor : actor ≠ r.author) : ¬ Step dir actor .edit r r' := by
  intro h
  cases h with
  | edit hc => exact hy.not_canEdit hauthor hc

/-- Self-approval is allowed (spec §4 D): being the author is no obstacle when
the actor is a target manager. -/
theorem self_approval_allowed (hm : dir.IsManager r.author r.target) (hs : r.status = .pending) :
    Step dir r.author (.decide .approve) r { r with status := .approved } :=
  .decide .approve hm hs

/-! ## Invariants of reachable requests -/

/-- The author of any request in the system belongs to its target department. -/
theorem Reachable.author_affiliated (h : Reachable dir r) : dir.Affiliated r.author r.target := by
  induction h with
  | create haff => exact haff
  | step _ hs ih => rw [hs.author_eq, hs.target_eq]; exact ih

/-- The author can always read their own request (R1 for the author). -/
theorem Reachable.author_canRead (h : Reachable dir r) : dir.CanRead r.author r :=
  h.author_affiliated

/-- An `Approved` request was `Pending` and approved by a target manager;
the approval changed nothing else. -/
theorem Reachable.approved_inversion (h : Reachable dir r) (hs : r.status = .approved) :
    ∃ (m : U) (r₀ : Request U D), Reachable dir r₀ ∧ r₀.status = .pending ∧
      dir.IsManager m r.target ∧ r = { r₀ with status := .approved } := by
  cases h with
  | create => cases hs
  | step hr hstep =>
    cases hstep with
    | edit hc => exact absurd hs (fun h => hc.not_terminal (.inl h))
    | submit => cases hs
    | decide d hm hpending =>
      cases d with
      | approve => exact ⟨_, _, hr, hpending, hm, rfl⟩
      | reject => cases hs
      | «return» => cases hs

/-! ## P3 — no orphaned request -/

/-- In a well-formed directory every request has a potential decider … -/
theorem P3_manager_exists (hwf : dir.WF) (r : Request U D) : ∃ m, dir.IsManager m r.target :=
  hwf.managerExists r.target

/-- … who can actually approve, reject or return it while it is `Pending`. -/
theorem P3_pending_decidable (hwf : dir.WF) (hs : r.status = .pending) (d : Decision) :
    ∃ m, Step dir m (.decide d) r { r with status := d.outcome } :=
  let ⟨m, hm⟩ := hwf.managerExists r.target
  ⟨m, .decide d hm hs⟩

/-- Conversely, only non-terminal requests can move: a request is stuck exactly
when it is terminal (in a well-formed directory, from `Pending` a manager can
always act, and from `Draft`/`Returned` the author can always submit). -/
theorem stuck_iff_terminal (hwf : dir.WF) :
    (¬ ∃ (u : U) (a : Action) (r' : Request U D), Step dir u a r r') ↔ r.status.IsTerminal := by
  constructor
  · intro hstuck
    match hs : r.status with
    | .approved => exact .inl rfl
    | .rejected => exact .inr rfl
    | .pending =>
      obtain ⟨m, hm⟩ := P3_pending_decidable (r := r) hwf hs .approve
      exact absurd ⟨m, _, _, hm⟩ hstuck
    | .draft => exact absurd ⟨r.author, .submit, _, .submit rfl (.inl hs)⟩ hstuck
    | .returned => exact absurd ⟨r.author, .submit, _, .submit rfl (.inr hs)⟩ hstuck
  · rintro hterm ⟨_, _, _, h⟩
    exact P2_terminal_stuck hterm h

end Approval
