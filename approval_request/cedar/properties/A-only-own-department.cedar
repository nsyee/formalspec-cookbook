// A (spec.md §4): 作成が許可されるのは、実行者が申請先部署に所属しているときだけ。
permit (principal, action, resource)
when { principal in resource };
