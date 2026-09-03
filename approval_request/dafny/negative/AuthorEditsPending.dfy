include "../Approval.dfy"

// 検証を通ってはならない主張: 「作成者は自分の申請をいつでも編集できる」。アクション U1 は
// Draft と Returned までで、申請が Pending になったら編集できるのは申請先部署の上長だけ
// である（U3）。誤った読みを失敗するチェックとしてここに残しておくことで、`CanEdit` を
// うっかり広げてしまっても気付かれずに CI を通ることがなくなる。
module NegativeAuthorEditsPending {
  import opened Approval

  lemma AuthorsAlwaysEditTheirOwnRequests(dir: Directory, r: Request)
    requires !Terminal(r.status)
    requires IsAffiliated(dir, r.author, r.department)
    ensures CanEdit(dir, r.author, r)
  {
  }
}
