include "../Approval.dfy"

// A claim that must NOT verify: a role assignment in which nobody manages
// `sales` is not a `Directory`. The requirement "each department has at least
// one Manager" is the constraint of that subset type, so the assignment below
// is rejected where it is written, not later by an invariant check.
//
// The second lemma is the same point about a transition: `Approve` may only be
// called where `CanDecide` holds, so approving a Draft is not a denial to be
// handled but a program that does not verify.
module NegativeDirectoryWithoutManager {
  import opened Approval

  lemma ManagerlessDirectory()
  {
    var assignment: Assignment := map[("alice", "sales") := Member];
    var dir: Directory := assignment;
  }

  lemma ApprovingADraft(dir: Directory, actor: UserId, r: Request)
    requires r.status.Draft?
    requires IsManagerOf(dir, actor, r.department)
  {
    var approved := Approve(dir, actor, r);
  }
}
