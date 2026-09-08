// Step definitions for approval.feature.md.
//
// Each step is a thin bridge between one Japanese sentence of the specification
// and the model in ../model.ts. Assertions use node:assert so that a failing
// scenario prints the expected and actual values side by side.

import assert from "node:assert/strict";
import { DataTable, Given, Then, When } from "@cucumber/cucumber";
import { Directory, type Assignment, type Command, type Request, type Role } from "../model.ts";
import { COMMANDS } from "../support/parameters.ts";
import type { ApprovalWorld } from "../support/world.ts";

type Step = ApprovalWorld;

const denialOf = (world: Step, index = world.attempts.length - 1): string => {
  const outcome = world.attempts[index].outcome;
  return outcome.kind === "Failure" ? outcome.denial : `Success(${outcome.value.status})`;
};

// ---------------------------------------------------------------------------
// Directory
// ---------------------------------------------------------------------------

Given("名簿が次の通りである:", function (this: Step, table: DataTable) {
  const assignments: Assignment[] = table.hashes().map((row) => ({
    user: row["ユーザー"],
    department: row["部署"],
    role: row["役職"] as Role,
  }));
  this.directory = new Directory(assignments);
});

Given("すべての部署に上長が 1 名以上いる", function (this: Step) {
  assert.deepEqual(this.directory.departmentsWithoutManager(), []);
});

Given("名簿から {word} を外す", function (this: Step, user: string) {
  this.directory = this.directory.without(user);
});

Then("名簿は不変条件「各部署に上長が 1 名以上」に違反する", function (this: Step) {
  assert.notDeepEqual(this.directory.departmentsWithoutManager(), []);
});

// ---------------------------------------------------------------------------
// Creating a request (A)
// ---------------------------------------------------------------------------

When("{word} が {word} 宛ての申請を作成する", function (this: Step, actor: string, department: string) {
  this.create(actor, department);
});

Given("{word} が {word} 宛ての申請を作成している", function (this: Step, actor: string, department: string) {
  const outcome = this.create(actor, department);
  assert.equal(outcome.kind, "Success", `setup failed: ${denialOf(this)}`);
});

Given("申請の状態が {status} である", function (this: Step, status: Request["status"]) {
  this.request = { ...this.current, status };
});

Then("申請は存在しない", function (this: Step) {
  assert.equal(this.request, undefined);
});

Then("申請の申請先部署は {word} である", function (this: Step, department: string) {
  assert.equal(this.current.department, department);
});

Then("申請は次の JSON と一致する:", function (this: Step, json: string) {
  const expected = JSON.parse(json) as Partial<Request>;
  const actual = Object.fromEntries(Object.keys(expected).map((k) => [k, this.current[k as keyof Request]]));
  assert.deepEqual(actual, expected);
});

// ---------------------------------------------------------------------------
// Commands (B-F)
// ---------------------------------------------------------------------------

When("{word} が申請を{command}する", function (this: Step, actor: string, command: Command) {
  this.apply(actor, command);
});

When("次の操作を順に試みる:", function (this: Step, table: DataTable) {
  this.batchStart = this.attempts.length;
  for (const row of table.hashes()) {
    this.apply(row["実行者"], COMMANDS[row["操作"]]);
  }
});

Then("{word} が申請を{command}すると {string} として拒否される", function (this: Step, actor: string, command: Command, denial: string) {
  this.apply(actor, command);
  assert.equal(denialOf(this), denial);
});

Then("操作は {string} として拒否される", function (this: Step, denial: string) {
  assert.equal(denialOf(this), denial);
});

Then("すべての操作は {string} として拒否される", function (this: Step, denial: string) {
  const denials = this.attempts.slice(this.batchStart).map((_, i) => denialOf(this, this.batchStart + i));
  assert.deepEqual(denials, denials.map(() => denial));
});

Then("すべての操作は成功する", function (this: Step) {
  const outcomes = this.attempts.slice(this.batchStart).map((a) => a.outcome.kind);
  assert.deepEqual(outcomes, outcomes.map(() => "Success"));
});

// ---------------------------------------------------------------------------
// Observing the request
// ---------------------------------------------------------------------------

Then("申請の状態は {string} になる", function (this: Step, status: string) {
  assert.equal(this.current.status, status);
});

Then("申請の状態は {string} のままである", function (this: Step, status: string) {
  assert.equal(this.last.before?.status, status, "the request was not in that state before the operation");
  assert.equal(this.current.status, status);
});

Then("申請は変化しない", function (this: Step) {
  assert.deepEqual(this.current, this.attempts[this.batchStart].before);
});

Then("申請の決裁者は {word} である", function (this: Step, user: string) {
  assert.equal(this.current.decidedBy, user);
});

Then("履歴は次の通りである:", function (this: Step, expected: string) {
  const names = Object.fromEntries(Object.entries(COMMANDS).map(([ja, cmd]) => [cmd, ja]));
  const lines = this.attempts
    .filter((a) => a.before !== undefined && a.outcome.kind === "Success")
    .map((a) => `${a.before!.status} --${a.actor}:${names[a.command]}--> ${a.outcome.kind === "Success" ? a.outcome.value.status : ""}`);
  assert.equal(lines.join("\n"), expected.trim());
});

// ---------------------------------------------------------------------------
// Permission predicates (R, U) and P3
// ---------------------------------------------------------------------------

Then("{word} は申請を{readable}", function (this: Step, user: string, readable: boolean) {
  assert.equal(this.model.canRead(this.directory, user, this.current), readable);
});

Then("{word} は申請を{editable}", function (this: Step, user: string, editable: boolean) {
  assert.equal(this.model.canEdit(this.directory, user, this.current), editable);
});

Then("申請を決裁できるユーザーが少なくとも 1 人存在する", function (this: Step) {
  assert.ok(this.model.deciders(this.directory, this.current).length >= 1);
});

Then("申請を決裁できるユーザーは {word} である", function (this: Step, user: string) {
  assert.deepEqual(this.model.deciders(this.directory, this.current), [user]);
});

Then(
  "不変条件を無視して {word} が {word} 宛ての申請を作成し Pending にすると、申請を決裁できるユーザーは存在しない",
  function (this: Step, actor: string, department: string) {
    const outcome = this.create(actor, department);
    assert.equal(outcome.kind, "Success", `setup failed: ${denialOf(this)}`);
    this.request = { ...this.current, status: "Pending" };
    assert.deepEqual(this.model.deciders(this.directory, this.current), []);
  },
);
