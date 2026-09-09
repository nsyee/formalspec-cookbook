// Mutant for P2: terminal requests are not frozen. Approving an already
// Rejected request (or rejecting an Approved one) goes through as if the
// request were Pending. The `@P2` scenarios must fail here.

import { ApprovalModel, isTerminal, type Command, type Directory, type Outcome, type Request } from "../model.ts";

export default class TerminalThaw extends ApprovalModel {
  override step(dir: Directory, actor: string, r: Request, command: Command): Outcome {
    const thawed: Request = isTerminal(r.status) ? { ...r, status: "Pending" } : r;
    return super.step(dir, actor, thawed, command);
  }
}
