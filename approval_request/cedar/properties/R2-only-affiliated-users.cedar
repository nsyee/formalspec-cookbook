// R2 (spec.md §3): 申請先部署に所属していないユーザーには、その申請に対する操作が一切許可されない。
permit (principal, action, resource)
when { principal in resource.department };
