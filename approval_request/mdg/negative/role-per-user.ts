// Mutant for spec.md §6: the role is treated as an attribute of the user rather
// than of the (user, department) pair — "a manager anywhere is a manager
// everywhere they are affiliated". This is the modelling mistake the topic is
// designed to expose; the `@P1` and `@U2` scenarios must fail here.

import { ApprovalModel, Directory, type Request } from "../model.ts";

class FlattenedDirectory extends Directory {
  override isManagerOf(user: string, department: string): boolean {
    return this.isAffiliated(user, department) && this.assignments.some((a) => a.user === user && a.role === "Manager");
  }
}

const flatten = (dir: Directory): Directory => new FlattenedDirectory(dir.assignments);

export default class RolePerUser extends ApprovalModel {
  override canEdit(dir: Directory, actor: string, r: Request): boolean {
    return super.canEdit(flatten(dir), actor, r);
  }

  override canDecide(dir: Directory, actor: string, r: Request): boolean {
    return super.canDecide(flatten(dir), actor, r);
  }
}
