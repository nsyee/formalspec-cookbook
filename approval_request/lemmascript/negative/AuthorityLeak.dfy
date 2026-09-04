include "../approval.dfy"

// 検証を通ってはならない主張: 「どこかの部署の上長なら、どの申請でも決裁できる」。これは
// 性質 P1 が対象とする誤り——上長を、1 つの部署の中での役職ではなくユーザーの属性として
// 扱ってしまう誤りである。
//
// approval.ts から生成した定義（approval.dfy）を include し、その上で偽の補題を述べる。
// `./scripts/lemmascript.py verify approval_request/lemmascript --only negative-authority-leak`
// はこのファイルが失敗することを期待している。
lemma AnyManagerCanDecide(dir: Directory, actor: UserId, r: Request, elsewhere: DepartmentId)
  requires r.status.Pending?
  requires isAffiliated(dir, actor, r.department)
  requires isManagerOf(dir, actor, elsewhere)
  ensures step(dir, actor, r, Approve).Success?
{
}
