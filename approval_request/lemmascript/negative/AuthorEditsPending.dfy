include "../approval.dfy"

// A claim that must NOT verify: "the author can edit their own request at any time".
// U1 of spec.md is limited to Draft and Returned; a Pending request is edited only by
// managers (U3).
lemma AuthorEditsAnyState(dir: Directory, actor: UserId, r: Request)
  requires actor == r.author && r.status.Pending?
  requires isAffiliated(dir, actor, r.department)
  ensures canEdit(dir, actor, r)
  ensures step(dir, actor, r, Edit(r.content)).Success?
{
}
