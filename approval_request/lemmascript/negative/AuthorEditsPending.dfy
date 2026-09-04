include "../approval.dfy"

// 検証を通ってはならない主張: 「申請者は自分の申請をいつでも編集できる」。spec.md の
// U1 は Draft と Returned に限っており、Pending の申請を編集できるのは上長だけ（U3）。
lemma AuthorEditsAnyState(dir: Directory, actor: UserId, r: Request)
  requires actor == r.author && r.status.Pending?
  requires isAffiliated(dir, actor, r.department)
  ensures canEdit(dir, actor, r)
  ensures step(dir, actor, r, Edit(r.content)).Success?
{
}
