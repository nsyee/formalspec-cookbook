include "../approval.dfy"

// Two claims that must NOT verify.
//
// First: "even if some department has no manager, a Pending request has a decider". The
// `Directory` of approval.ts is a plain record, not a subset type as in the Dafny model, so
// the existence of managers is only available once `departmentsHaveManagers(dir)` is written
// as a `requires`. Drop it and P3 does not hold -- which is why the real
// `EveryPendingRequestHasADecider` carries that premise.
lemma PendingRequestHasADeciderAnyway(dir: Directory, r: Request)
  requires wellFormed(dir, r) && r.status.Pending?
  ensures exists decider: UserId :: canDecide(dir, decider, r)
{
}

// Second: "a Draft can be approved". The precondition `canDecide` of `approve` demands
// Pending, so this call is not a runtime denial but a program that cannot be verified.
function ApproveADraft(dir: Directory, actor: UserId, r: Request): Request
  requires r.status.Draft?
  requires isManagerOf(dir, actor, r.department)
{
  approve(dir, actor, r)
}
