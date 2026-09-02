include "../Approval.dfy"

// A claim that must NOT verify: "the author may always edit their own
// request". Requirement U1 stops at Draft and Returned; once the request is
// Pending, only a manager of the target department may edit it (U3). Keeping
// the wrong reading here as a failing check means that widening `CanEdit` by
// accident cannot pass CI unnoticed.
module NegativeAuthorEditsPending {
  import opened Approval

  lemma AuthorsAlwaysEditTheirOwnRequests(dir: Directory, r: Request)
    requires !Terminal(r.status)
    requires IsAffiliated(dir, r.author, r.department)
    ensures CanEdit(dir, r.author, r)
  {
  }
}
