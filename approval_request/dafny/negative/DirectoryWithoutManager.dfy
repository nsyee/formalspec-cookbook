include "../Approval.dfy"

// 検証を通ってはならない主張: `sales` の上長が誰もいない役職の割り当ては `Directory` では
// ない。「各部署には必ず 1 名以上の上長が存在する」という要件はこの部分型の制約なので、
// 下の割り当ては、後の不変条件チェックではなく書かれたその場所で拒否される。
//
// 2 つめの補題は、遷移についての同じ論点である: `Approve` は `CanDecide` が成り立つ場所でしか
// 呼べないので、Draft を承認することは処理すべき拒否ではなく、検証を通らないプログラムである。
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
