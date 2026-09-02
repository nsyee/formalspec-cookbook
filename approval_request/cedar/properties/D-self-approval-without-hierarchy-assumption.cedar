// D-self-approval-is-allowed から階層の整合性条件を外したもの。
// SymCC は「上長チームが部署の下にない」エンティティ集合も探索するため、これは成立しない（反例が出る）。
permit (principal, action, resource)
when {
  principal in resource.department.managers &&
  principal == resource.author &&
  resource.status == Approval::Status::"Pending"
};
