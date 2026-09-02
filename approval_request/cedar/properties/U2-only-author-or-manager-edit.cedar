// U1〜U3 (spec.md §3): 編集が許可されるのは「作成者本人で Draft / Returned」または
// 「申請先部署の上長で Draft / Returned / Pending」のときだけ。同じ部署の他のメンバーは編集できない (U2)。
permit (principal, action, resource)
when {
  (principal == resource.author &&
   resource.status in [Approval::Status::"Draft", Approval::Status::"Returned"]) ||
  (principal in resource.department.managers &&
   resource.status in
     [Approval::Status::"Draft", Approval::Status::"Returned", Approval::Status::"Pending"])
};
