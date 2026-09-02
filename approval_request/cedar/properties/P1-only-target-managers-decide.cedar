// P1 (spec.md §5): 決裁が許可されるのは、実行者が申請先部署の上長で、かつ申請が Pending のときだけ。
// 他部署での上長権限は根拠にならない。
permit (principal, action, resource)
when {
  principal in resource.department.managers &&
  resource.status == Approval::Status::"Pending"
};
