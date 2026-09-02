// R1 (spec.md §3): 申請先部署に所属していれば、役職や状態を問わず閲覧できる。
permit (principal, action, resource)
when { principal in resource.department };
