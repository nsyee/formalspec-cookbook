include "../Approval.dfy"

// 検証を通ってはならない主張: 「どこかの部署の上長なら、どの申請でも決裁できる」。これは
// 性質 P1 が対象とする誤り——上長を、1 つの部署の中での役職ではなくユーザーの属性として
// 扱ってしまう誤りである。
//
// `./scripts/dafny.py verify approval_request/dafny --only negative-authority-leak`
// はこのファイルが失敗することを期待しており、検証器が出す反例は、モデル検査器が出すのと
// 同じ反例である。
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
