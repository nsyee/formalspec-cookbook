// D (spec.md §4 の注記): 申請先部署の上長であれば、自分が作成した Pending の申請も決裁できる。
// `principal in resource.department` は「上長チームは部署の下にある」というエンティティ階層の
// 整合性条件で、スキーマでは表せないため仮定としてここに書く（無いと検証が通らない。checks.json 参照）。
permit (principal, action, resource)
when {
  principal in resource.department &&
  principal in resource.department.managers &&
  principal == resource.author &&
  resource.status == Approval::Status::"Pending"
};
