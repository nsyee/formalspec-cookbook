include "../approval.dfy"

// 検証を通ってはならない主張が 2 つ。
//
// 1 つ目: 「上長のいない部署があっても、Pending の申請には決裁者がいる」。approval.ts の
// `Directory` は Dafny 版のような部分型ではなく単なるレコードなので、上長の存在は
// `departmentsHaveManagers(dir)` を `requires` に書いて初めて手に入る。それを落とすと
// P3 は成り立たない——本物の `EveryPendingRequestHasADecider` にこの前提がある理由である。
lemma PendingRequestHasADeciderAnyway(dir: Directory, r: Request)
  requires wellFormed(dir, r) && r.status.Pending?
  ensures exists decider: UserId :: canDecide(dir, decider, r)
{
}

// 2 つ目: 「Draft は承認できる」。`approve` の事前条件 `canDecide` は Pending を要求する
// ので、この呼び出しは実行時の拒否ではなく、検証できないプログラムになる。
function ApproveADraft(dir: Directory, actor: UserId, r: Request): Request
  requires r.status.Draft?
  requires isManagerOf(dir, actor, r.department)
{
  approve(dir, actor, r)
}
