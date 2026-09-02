// P2 (spec.md §5): Approved / Rejected の申請に対しては、状態を変え得る操作は一切許可されない。
permit (principal, action, resource)
unless {
  resource.status in [Approval::Status::"Approved", Approval::Status::"Rejected"]
};
