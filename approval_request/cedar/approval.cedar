// 稟議申請システムの認可ポリシー。スキーマは approval.cedarschema、仕様は ../spec.md。
//
// Cedar の判定規則:
//   1 つでも forbid が成立すれば Deny、そうでなく 1 つでも permit が成立すれば Allow、
//   どちらも成立しなければ Deny（デフォルト拒否）。
//
// 書き方の方針:
//   - spec.md の「〜できる」は permit として、「〜できてはならない」（R2 / P1 / P2）は
//     forbid として書く。permit だけでも同じ判定になるが、forbid は permit に
//     常に優先するため、将来 permit を増やしても破れない **ガード** として残る。
//   - 「所属している」= principal in resource.department、
//     「上長である」  = principal in resource.department.managers。
//     どちらも属性の集合演算ではなくエンティティ階層で判定する。
//   - 状態の比較は enum エンティティ Status の `==` / `in [..]` で書く。
// ---------------------------------------------------------------------------
// 閲覧 (spec.md §3 R1 / R2)
// ---------------------------------------------------------------------------
@id("R1-read-if-affiliated")
@doc("R1: 自分が所属する部署宛ての申請は閲覧できる（役職は問わない）")
permit (
  principal is Approval::User,
  action == Approval::Action::"read",
  resource is Approval::Request
)
when { principal in resource.department };

@id("R2-outsiders-see-nothing")
@doc("R2: 申請先部署に所属していないユーザーは、その申請に対して何もできない")
forbid (
  principal is Approval::User,
  action,
  resource is Approval::Request
)
unless { principal in resource.department };

// ---------------------------------------------------------------------------
// A. 申請の作成 (spec.md §4 A)
// ---------------------------------------------------------------------------
@id("A-create-in-own-department")
@doc("作成は自分が所属する部署に対してのみ。resource は申請先の Department")
permit (
  principal is Approval::User,
  action == Approval::Action::"create",
  resource is Approval::Department
)
when { principal in resource };

// ---------------------------------------------------------------------------
// B. 編集 / C. 提出 (spec.md §3 U1〜U3, §4 B / C)
// ---------------------------------------------------------------------------
@id("U1-author-edits-and-submits-own-request")
@doc("U1 / C: 作成者本人は Draft または Returned のとき編集・提出（再提出）できる")
permit (
  principal is Approval::User,
  action in [Approval::Action::"edit", Approval::Action::"submit"],
  resource is Approval::Request
)
when
{
  principal == resource.author &&
  resource.status in [Approval::Status::"Draft", Approval::Status::"Returned"]
};

@id("U3-manager-edits-before-decision")
@doc("U3: 申請先部署の上長は Draft / Returned / Pending のとき編集できる（提出は作成者だけ）")
permit (
  principal is Approval::User,
  action == Approval::Action::"edit",
  resource is Approval::Request
)
when
{
  principal in resource.department.managers &&
  resource.status in [Approval::Status::"Draft",
   Approval::Status::"Returned",
   Approval::Status::"Pending"]
};

// U2（同じ部署の他のメンバーは編集できない）に対応する permit は存在しない。
// Cedar はデフォルト拒否なので、書かないことがそのまま仕様になる。
// ---------------------------------------------------------------------------
// D / E / F. 決裁 (spec.md §4 D〜F, §5 P1)
// ---------------------------------------------------------------------------
@id("D-managers-decide-pending-requests")
@doc("D/E/F: 申請先部署の上長は Pending の申請を承認・却下・差し戻しできる。自己決裁も可")
permit (
  principal is Approval::User,
  action in Approval::Action::"decide",
  resource is Approval::Request
)
when
{
  principal in resource.department.managers &&
  resource.status == Approval::Status::"Pending"
};

@id("P1-decision-rights-follow-the-target-department")
@doc("P1: 決裁できるかは申請先部署での役職だけで決まる。他部署で上長でも決裁できない")
forbid (
  principal is Approval::User,
  action in Approval::Action::"decide",
  resource is Approval::Request
)
unless { principal in resource.department.managers };

// ---------------------------------------------------------------------------
// P2. 終端状態の不変性 (spec.md §5 P2)
// ---------------------------------------------------------------------------
@id("P2-terminal-requests-are-frozen")
@doc("P2: Approved / Rejected の申請は閲覧以外のいかなる操作も受け付けない")
forbid (
  principal is Approval::User,
  action in
    [Approval::Action::"edit",
     Approval::Action::"submit",
     Approval::Action::"decide"],
  resource is Approval::Request
)
when
{
  resource.status in [Approval::Status::"Approved",
   Approval::Status::"Rejected"]
};
