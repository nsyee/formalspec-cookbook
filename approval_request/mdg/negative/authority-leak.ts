// Mutant for P1: a manager of *any* department may decide. carol (manager of
// eng) would then approve the sales request she authored — exactly the
// authority leak spec.md §5 P1 forbids. The `@P1` scenarios must fail here.

import { ApprovalModel, type Directory, type Request } from "../model.ts";

export default class AuthorityLeak extends ApprovalModel {
  override canDecide(dir: Directory, actor: string, r: Request): boolean {
    return r.status === "Pending" && dir.departments().some((d) => dir.isManagerOf(actor, d));
  }
}
