include "../approval.dfy"

// A claim that must NOT verify: "a manager of some department can decide any request".
// This is the mistake property P1 is about: treating Manager as an attribute of the user
// instead of a role within one department.
//
// The file includes the definitions generated from approval.ts (approval.dfy) and states a
// false lemma on top of them.
// `./scripts/lemmascript.py verify approval_request/lemmascript --only negative-authority-leak`
// expects this file to fail.
lemma AnyManagerCanDecide(dir: Directory, actor: UserId, r: Request, elsewhere: DepartmentId)
  requires r.status.Pending?
  requires isAffiliated(dir, actor, r.department)
  requires isManagerOf(dir, actor, elsewhere)
  ensures step(dir, actor, r, Approve).Success?
{
}
