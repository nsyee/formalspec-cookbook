// Executable model of approval_request/spec.md that the MDG scenarios drive.
//
// The scenarios in approval.feature.md are the specification; this file is the
// smallest implementation that makes them meaningful. It is deliberately written
// as a class so that the mutants under negative/ can override a single rule and
// show which scenarios catch the resulting violation.

export type UserId = string;
export type DepartmentId = string;
export type Role = "Member" | "Manager";

export type Status = "Draft" | "Pending" | "Returned" | "Approved" | "Rejected";

export type Command = "Edit" | "Submit" | "Approve" | "Reject" | "Return";

export type Denial =
  | "NotAffiliated" // R2: the actor is not affiliated with the target department
  | "NotAuthor" // C / U1: only the author may do this
  | "NotManager" // D-F / U3: only a manager of the target department may do this
  | "WrongState" // the command is not enabled in the current status
  | "TerminalRequest" // P2: Approved / Rejected requests accept no command
  | "DepartmentWithoutManager"; // directory invariant: every department has a manager

export interface Assignment {
  user: UserId;
  department: DepartmentId;
  role: Role;
}

export interface Request {
  author: UserId;
  department: DepartmentId;
  status: Status;
  /** Who approved, rejected or returned the request last, if anyone. */
  decidedBy?: UserId;
  /** Number of edits applied; stands in for the request body of spec.md. */
  revision: number;
}

export type Outcome = { kind: "Success"; value: Request } | { kind: "Failure"; denial: Denial };

export const success = (value: Request): Outcome => ({ kind: "Success", value });
export const failure = (denial: Denial): Outcome => ({ kind: "Failure", denial });

export class Directory {
  readonly assignments: readonly Assignment[];

  constructor(assignments: readonly Assignment[]) {
    this.assignments = assignments;
  }

  roleOf(user: UserId, department: DepartmentId): Role | undefined {
    return this.assignments.find((a) => a.user === user && a.department === department)?.role;
  }

  isAffiliated(user: UserId, department: DepartmentId): boolean {
    return this.roleOf(user, department) !== undefined;
  }

  isManagerOf(user: UserId, department: DepartmentId): boolean {
    return this.roleOf(user, department) === "Manager";
  }

  departments(): DepartmentId[] {
    return [...new Set(this.assignments.map((a) => a.department))];
  }

  users(): UserId[] {
    return [...new Set(this.assignments.map((a) => a.user))];
  }

  managersOf(department: DepartmentId): UserId[] {
    return this.users().filter((u) => this.isManagerOf(u, department));
  }

  /** Invariant of spec.md §1: every department has at least one manager. */
  departmentsWithoutManager(): DepartmentId[] {
    return this.departments().filter((d) => this.managersOf(d).length === 0);
  }

  without(user: UserId): Directory {
    return new Directory(this.assignments.filter((a) => a.user !== user));
  }
}

export const isTerminal = (status: Status): boolean => status === "Approved" || status === "Rejected";

export class ApprovalModel {
  /** R1 / R2. */
  canRead(dir: Directory, actor: UserId, r: Request): boolean {
    return dir.isAffiliated(actor, r.department);
  }

  /** U1 / U2 / U3. */
  canEdit(dir: Directory, actor: UserId, r: Request): boolean {
    if (dir.isManagerOf(actor, r.department)) {
      return r.status === "Draft" || r.status === "Returned" || r.status === "Pending";
    }
    return actor === r.author && (r.status === "Draft" || r.status === "Returned");
  }

  /** Common precondition of D / E / F. */
  canDecide(dir: Directory, actor: UserId, r: Request): boolean {
    return r.status === "Pending" && dir.isManagerOf(actor, r.department);
  }

  /** P3: the users who could approve, reject or return the request right now. */
  deciders(dir: Directory, r: Request): UserId[] {
    return dir.users().filter((u) => this.canDecide(dir, u, r));
  }

  /** Action A. */
  create(dir: Directory, actor: UserId, department: DepartmentId): Outcome {
    if (!dir.isAffiliated(actor, department)) return failure("NotAffiliated");
    return success({ author: actor, department, status: "Draft", revision: 0 });
  }

  /** Actions B-F behind a single guarded entry point that explains every denial. */
  step(dir: Directory, actor: UserId, r: Request, command: Command): Outcome {
    if (!this.canRead(dir, actor, r)) return failure("NotAffiliated");
    if (isTerminal(r.status)) return failure("TerminalRequest");
    switch (command) {
      case "Edit":
        if (this.canEdit(dir, actor, r)) return success({ ...r, revision: r.revision + 1 });
        return failure(actor === r.author ? "NotManager" : "NotAuthor");
      case "Submit":
        if (actor !== r.author) return failure("NotAuthor");
        if (r.status !== "Draft" && r.status !== "Returned") return failure("WrongState");
        return success({ ...r, status: "Pending" });
      case "Approve":
      case "Reject":
      case "Return":
        if (r.status !== "Pending") return failure("WrongState");
        if (!this.canDecide(dir, actor, r)) return failure("NotManager");
        return success({ ...r, status: decided[command], decidedBy: actor });
    }
  }
}

const decided: Record<"Approve" | "Reject" | "Return", Status> = {
  Approve: "Approved",
  Reject: "Rejected",
  Return: "Returned",
};
