// Cucumber World: the state one scenario accumulates while its steps run.
//
// The model implementation is chosen with MDG_MODEL (a module path relative to
// the model directory, default ./model.ts) so the very same scenarios can be run against the
// mutants under negative/ to show that they fail there.

import { BeforeAll, setWorldConstructor, World, type IWorldOptions } from "@cucumber/cucumber";
import { ApprovalModel, Directory, type Command, type Outcome, type Request } from "../model.ts";

export interface Attempt {
  actor: string;
  command: Command | "Create";
  before: Request | undefined;
  outcome: Outcome;
}

let model: ApprovalModel;

BeforeAll(async function () {
  const module = await import(new URL(process.env.MDG_MODEL ?? "./model.ts", new URL("../", import.meta.url)).href);
  const Model = (module.default ?? module.ApprovalModel) as typeof ApprovalModel;
  model = new Model();
});

export class ApprovalWorld extends World {
  directory = new Directory([]);
  request: Request | undefined;
  /** Attempts made by `もし` steps, in order; the last one is what `ならば` steps inspect. */
  attempts: Attempt[] = [];
  /** Index into `attempts` where the latest batch (`次の操作を順に試みる`) began. */
  batchStart = 0;

  constructor(options: IWorldOptions) {
    super(options);
  }

  get model(): ApprovalModel {
    return model;
  }

  get last(): Attempt {
    if (this.attempts.length === 0) throw new Error("no operation has been attempted yet");
    return this.attempts[this.attempts.length - 1];
  }

  /** The request the scenario is about; fails loudly if a step forgot to create it. */
  get current(): Request {
    if (!this.request) throw new Error("no request exists in this scenario");
    return this.request;
  }

  create(actor: string, department: string): Outcome {
    const outcome = model.create(this.directory, actor, department);
    if (outcome.kind === "Success") this.request = outcome.value;
    this.attempts.push({ actor, command: "Create", before: undefined, outcome });
    return outcome;
  }

  apply(actor: string, command: Command): Outcome {
    const before = this.current;
    const outcome = model.step(this.directory, actor, before, command);
    if (outcome.kind === "Success") this.request = outcome.value;
    this.attempts.push({ actor, command, before, outcome });
    return outcome;
  }
}

setWorldConstructor(ApprovalWorld);
