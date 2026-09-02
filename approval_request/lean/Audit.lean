import Approval

/-!
Axiom audit, run by `scripts/lean.py` (`lake env lean Audit.lean`).

Each line prints the axioms a theorem depends on. The driver fails if `sorryAx`
appears anywhere — i.e. if a proof was left incomplete — and reports the set of
standard axioms (`propext`, `Classical.choice`, `Quot.sound`) actually used.
-/

open Approval

#print axioms Action.apply_ok_iff
#print axioms Step.unique
#print axioms P2_terminal_stuck
#print axioms P2_terminal_status_fixed
#print axioms approved_by_target_manager
#print axioms P1_no_authority_leak
#print axioms P1_no_edit_leak
#print axioms self_approval_allowed
#print axioms Reachable.author_affiliated
#print axioms Reachable.approved_inversion
#print axioms P3_pending_decidable
#print axioms stuck_iff_terminal
#print axioms Directory.IsMember.not_canEdit
#print axioms Examples.dir_wf
