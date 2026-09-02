// C (spec.md §4): 提出・再提出が許可されるのは、作成者本人で Draft / Returned のときだけ。
permit (principal, action, resource)
when {
  principal == resource.author &&
  resource.status in [Approval::Status::"Draft", Approval::Status::"Returned"]
};
