include "../Approval.dfy"

// A claim that must NOT verify: "a manager of some department may decide any
// request". This is the mistake property P1 is about -- treating Manager as a
// user attribute instead of a role inside one department.
//
// `./scripts/dafny.py verify approval_request/dafny --only negative-authority-leak`
// expects this file to fail, and the counterexample the verifier prints is the
// counterexample a model checker would produce.
module NegativeAuthorityLeak {
  import opened Approval

  lemma AnyManagerCanDecide(dir: Directory, actor: UserId, r: Request, elsewhere: DepartmentId)
    requires r.status.Pending?
    requires IsAffiliated(dir, actor, r.department)
    requires IsManagerOf(dir, actor, elsewhere)
    ensures Step(dir, actor, r, ApproveCommand).Success?
  {
  }
}
