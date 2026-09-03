import Approval

/-!
公理の監査。`scripts/lean.py` が実行する（`lake env lean Audit.lean`）。

各行は、その定理が依存する公理を出力する。`sorryAx` がどこかに現れたら
——すなわち証明が未完成のままなら——ドライバは失敗とし、実際に使われた標準の公理
（`propext`, `Classical.choice`, `Quot.sound`）を報告する。
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
