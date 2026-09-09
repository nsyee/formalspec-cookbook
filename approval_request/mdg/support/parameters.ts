// Custom parameter types: the Japanese vocabulary of approval.feature.md mapped
// onto the model's commands and statuses, so that step texts read as prose and
// Scenario Outline cells can be substituted without quoting.

import { defineParameterType } from "@cucumber/cucumber";
import type { Command, Status } from "../model.ts";

export const COMMANDS: Record<string, Command> = {
  編集: "Edit",
  提出: "Submit",
  承認: "Approve",
  却下: "Reject",
  差し戻し: "Return",
};

export const STATUSES: Status[] = ["Draft", "Pending", "Returned", "Approved", "Rejected"];

defineParameterType({
  name: "command",
  regexp: new RegExp(Object.keys(COMMANDS).join("|")),
  transformer: (word: string): Command => COMMANDS[word],
});

defineParameterType({
  name: "status",
  regexp: new RegExp(STATUSES.join("|")),
  transformer: (word: string): Status => word as Status,
});

defineParameterType({
  name: "readable",
  regexp: /閲覧できる|閲覧できない/,
  transformer: (word: string): boolean => word === "閲覧できる",
});

defineParameterType({
  name: "editable",
  regexp: /編集できる|編集できない/,
  transformer: (word: string): boolean => word === "編集できる",
});
