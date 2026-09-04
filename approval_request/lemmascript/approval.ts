/**
 * 稟議申請システム（../spec.md）の LemmaScript モデル。
 *
 * プログラム本体は普通の TypeScript である。同じ関数が Node.js でそのまま動き
 * （scenarios.ts）、`lsc` によって Dafny にコンパイルされる。`//@` 注釈は Dafny の
 * `requires` / `ensures` / `invariant` になる。すべての名簿・申請・トレースについて
 * 証明される事柄——P1〜P3 と spec.md 3 章の権限規則——はこのファイルの `//@ ensures`
 * として述べる。証明専用の材料（補助補題、`modifies` 節、`//@ pure` な関数の仕様側の
 * 本体）は、生成物 `approval.dfy.gen` の隣にある証明所有ファイル `approval.dfy` に
 * *追記* する。詳しくは README.md。
 *
 * すべての関数に `//@ verify` が付いているのは、末尾のクラスがそれを必要とするため。
 * 1 つでも opt-in した宣言があると、`lsc` は opt-in した宣言だけを検証する。
 */

//@ backend dafny

// === 識別子・役職・名簿（spec.md 1 章） ===

export type UserId = string;
export type DepartmentId = string;

export type Role = "Member" | "Manager";

/**
 * 役職は (ユーザー, 部署) の組の属性なので、名簿はユーザーごとに「所属する部署 → その
 * 部署での役職」の写像を持つ。1 人のユーザーが複数の部署に別々の役職で現れてよい。
 * Map のキーは値を 1 つしか持てないので、「1 所属につき役職は 1 つ」に不変条件は要らない。
 */
export interface Directory {
  roles: Map<UserId, Map<DepartmentId, Role>>;
}

export function isAffiliated(dir: Directory, user: UserId, dep: DepartmentId): boolean {
  //@ verify
  //@ contract `user` が `dep` で何らかの役職を持つとき、かつそのときに限り真。
  const affiliations = dir.roles.get(user);
  if (affiliations === undefined) return false;
  return affiliations.has(dep);
}

export function isManagerOf(dir: Directory, user: UserId, dep: DepartmentId): boolean {
  //@ verify
  //@ contract `user` が `dep` の上長であるとき、かつそのときに限り真——他の部署で何であっても、*その*部署での役職を見る。
  //@ ensures \result ==> isAffiliated(dir, user, dep)
  const affiliations = dir.roles.get(user);
  if (affiliations === undefined) return false;
  return affiliations.get(dep) === "Manager";
}

/**
 * spec.md 1 章: すべての部署に上長が 1 名以上いる。ループが実行側で、`//@ pure` に
 * よってこの関数は仕様の中でも使えるようになる。ループが一致すべき量化子（仕様側の
 * 本体）は approval.dfy が与える。
 */
export function hasManager(dir: Directory, dep: DepartmentId): boolean {
  //@ verify
  //@ pure
  //@ contract 名簿の誰かが `dep` の上長であるとき、かつそのときに限り真。
  for (const [user, affiliations] of dir.roles) {
    if (affiliations.get(dep) === "Manager") return true;
  }
  return false;
}

/** 名簿の整合条件: 上長のいない部署を残さない。 */
export function departmentsHaveManagers(dir: Directory): boolean {
  //@ verify
  //@ pure
  //@ contract いずれかの所属に現れるすべての部署に上長がいるとき、かつそのときに限り真。
  for (const [user, affiliations] of dir.roles) {
    for (const [dep, role] of affiliations) {
      if (!hasManager(dir, dep)) return false;
    }
  }
  return true;
}

// === 稟議申請（spec.md 2 章） ===

export interface Content {
  title: string;
  amount: number;
}

export function validContent(c: Content): boolean {
  //@ verify
  return c.title !== "" && c.amount >= 0;
}

/**
 * spec.md 2 章の状態ごとに 1 つのバリアント。決裁は誰が行ったかを記録するが、その
 * フィールドを持つのは決裁の結果として生じるバリアントだけなので、「承認者のいる
 * Draft」は書けない。
 */
export type Status =
  | { kind: "Draft" }
  | { kind: "Pending" }
  | { kind: "Returned"; returnedBy: UserId }
  | { kind: "Approved"; approvedBy: UserId }
  | { kind: "Rejected"; rejectedBy: UserId };

export function isTerminal(s: Status): boolean {
  //@ verify
  return s.kind === "Approved" || s.kind === "Rejected";
}

export function isEditableByAuthor(s: Status): boolean {
  //@ verify
  return s.kind === "Draft" || s.kind === "Returned";
}

export interface Request {
  author: UserId;
  department: DepartmentId;
  content: Content;
  status: Status;
}

/** 申請者は申請先部署に所属している（spec.md 1 章）。 */
export function wellFormed(dir: Directory, r: Request): boolean {
  //@ verify
  return isAffiliated(dir, r.author, r.department);
}

// === アクセス制御（spec.md 3 章） ===

export function canRead(dir: Directory, actor: UserId, r: Request): boolean {
  //@ verify
  //@ contract R1/R2: 閲覧できることと、申請先部署に所属していることは同じ。
  //@ ensures \result === isAffiliated(dir, actor, r.department)
  return isAffiliated(dir, actor, r.department);
}

export function canEdit(dir: Directory, actor: UserId, r: Request): boolean {
  //@ verify
  //@ contract U1: 申請者は Draft / Returned を編集できる。U3: 申請先部署の上長は決裁前の申請を編集できる。U2: それ以外は誰も編集できない。
  //@ ensures \result ==> !isTerminal(r.status)
  //@ ensures actor === r.author && isEditableByAuthor(r.status) ==> \result
  //@ ensures isManagerOf(dir, actor, r.department) && r.status.kind === "Pending" ==> \result
  //@ ensures actor !== r.author && !isManagerOf(dir, actor, r.department) ==> !\result
  return (
    (actor === r.author && isEditableByAuthor(r.status)) ||
    (isManagerOf(dir, actor, r.department) && !isTerminal(r.status))
  );
}

export function canSubmit(actor: UserId, r: Request): boolean {
  //@ verify
  //@ contract C: 提出できるのは申請者だけで、Draft または Returned からに限る。
  //@ ensures \result === (actor === r.author && isEditableByAuthor(r.status))
  return actor === r.author && isEditableByAuthor(r.status);
}

/**
 * D / E / F は 1 つの規則を共有し、その規則は実行者の *申請先部署での* 役職しか見ない。
 * P1（権限の漏れがない）と spec.md 4 章 D の自己承認についての注記は、どちらも
 * この 1 つの関数から従う。
 */
export function canDecide(dir: Directory, actor: UserId, r: Request): boolean {
  //@ verify
  //@ contract Pending の申請を決裁するのは、その申請先部署の上長である。
  //@ ensures \result === (r.status.kind === "Pending" && isManagerOf(dir, actor, r.department))
  return r.status.kind === "Pending" && isManagerOf(dir, actor, r.department);
}

// === 遷移（spec.md 4 章） ===

export type Command =
  | { kind: "Edit"; content: Content }
  | { kind: "Submit" }
  | { kind: "Approve" }
  | { kind: "Reject" }
  | { kind: "Return" };

export type Denial =
  | "NotAffiliated"
  | "NotAuthor"
  | "NotManager"
  | "TerminalRequest"
  | "WrongState"
  | "InvalidContent"
  | "NoSuchRequest";

export type Outcome =
  | { kind: "Success"; value: Request }
  | { kind: "Failure"; denial: Denial };

export function success(r: Request): Outcome {
  //@ verify
  return { kind: "Success", value: r };
}

export function failure(d: Denial): Outcome {
  //@ verify
  return { kind: "Failure", denial: d };
}

/** アクション A。生の入力から申請を組み立てる唯一の遷移なので、内容で失敗しうる唯一の遷移でもある。 */
export function create(dir: Directory, author: UserId, dep: DepartmentId, content: Content): Outcome {
  //@ verify
  //@ contract `dep` のメンバーは `dep` に Draft を作成できる。それ以外の人、または不正な内容は拒否される。
  //@ ensures \result.kind === "Success" ==> \result.value.author === author && \result.value.department === dep
  //@ ensures \result.kind === "Success" ==> \result.value.status.kind === "Draft" && wellFormed(dir, \result.value)
  //@ ensures \result.kind === "Success" ==> validContent(content)
  //@ ensures isAffiliated(dir, author, dep) && validContent(content) ==> \result.kind === "Success"
  if (!isAffiliated(dir, author, dep)) return failure("NotAffiliated");
  if (!validContent(content)) return failure("InvalidContent");
  return success({ author, department: dep, content, status: { kind: "Draft" } });
}

/**
 * アクション B〜F は事前条件で守られた全域関数である。権限が `requires` そのものなので、
 * 「Draft を承認する」は実行時の拒否ではなく、検証できないプログラムになる。事後条件は
 * フレーム——何が変わり、何が変わらないか——を述べる。
 */
export function edit(dir: Directory, actor: UserId, r: Request, content: Content): Request {
  //@ verify
  //@ requires canEdit(dir, actor, r)
  //@ ensures \result.status === r.status && \result.author === r.author && \result.department === r.department
  //@ ensures \result.content === content
  return { ...r, content };
}

export function submit(actor: UserId, r: Request): Request {
  //@ verify
  //@ requires canSubmit(actor, r)
  //@ ensures \result.status.kind === "Pending"
  //@ ensures \result.author === r.author && \result.department === r.department && \result.content === r.content
  return { ...r, status: { kind: "Pending" } };
}

export function approve(dir: Directory, actor: UserId, r: Request): Request {
  //@ verify
  //@ requires canDecide(dir, actor, r)
  //@ ensures \result.status.kind === "Approved" && \result.status.approvedBy === actor
  //@ ensures \result.author === r.author && \result.department === r.department && \result.content === r.content
  return { ...r, status: { kind: "Approved", approvedBy: actor } };
}

export function reject(dir: Directory, actor: UserId, r: Request): Request {
  //@ verify
  //@ requires canDecide(dir, actor, r)
  //@ ensures \result.status.kind === "Rejected" && \result.status.rejectedBy === actor
  //@ ensures \result.author === r.author && \result.department === r.department && \result.content === r.content
  return { ...r, status: { kind: "Rejected", rejectedBy: actor } };
}

export function returnToAuthor(dir: Directory, actor: UserId, r: Request): Request {
  //@ verify
  //@ requires canDecide(dir, actor, r)
  //@ ensures \result.status.kind === "Returned" && \result.status.returnedBy === actor
  //@ ensures \result.author === r.author && \result.department === r.department && \result.content === r.content
  return { ...r, status: { kind: "Returned", returnedBy: actor } };
}

/**
 * 動的な入口。外の世界から来る任意の (申請, コマンド) の組をここで分類し、事前条件つきの
 * 遷移に委譲するので、`step` は全域である。閲覧できない実行者は申請について何も知らされず、
 * 決裁済みの申請はコマンドを見る前に答えを返す（P2）。
 *
 * 事後条件は、1 ステップについての spec.md の定理である: P1（成功した決裁は申請先部署の
 * 上長による）、P2（決裁済みの申請は何も受け付けない）、申請の同一性は不変、そして各
 * コマンドはちょうどその権限規則のもとで成功する。
 */
export function step(dir: Directory, actor: UserId, r: Request, cmd: Command): Outcome {
  //@ verify
  //@ contract `actor` に代わって `cmd` を `r` に適用する。できない場合は拒否の理由を返す。
  //@ ensures \result.kind === "Success" ==> canRead(dir, actor, r)
  //@ ensures isTerminal(r.status) ==> \result.kind === "Failure"
  //@ ensures \result.kind === "Success" ==> \result.value.author === r.author && \result.value.department === r.department
  //@ ensures \result.kind === "Success" && (cmd.kind === "Approve" || cmd.kind === "Reject" || cmd.kind === "Return") ==> canDecide(dir, actor, r)
  //@ ensures \result.kind === "Success" && cmd.kind === "Submit" ==> canSubmit(actor, r) && \result.value.status.kind === "Pending"
  //@ ensures \result.kind === "Success" && cmd.kind === "Edit" ==> canEdit(dir, actor, r) && \result.value.status === r.status
  //@ ensures canDecide(dir, actor, r) && cmd.kind === "Approve" ==> \result.kind === "Success" && \result.value.status.kind === "Approved"
  //@ ensures canDecide(dir, actor, r) && cmd.kind === "Reject" ==> \result.kind === "Success" && \result.value.status.kind === "Rejected"
  //@ ensures canDecide(dir, actor, r) && cmd.kind === "Return" ==> \result.kind === "Success" && \result.value.status.kind === "Returned"
  //@ ensures \result.kind === "Success" && \result.value.status !== r.status ==> !isTerminal(r.status) && (r.status.kind === "Pending" ? isTerminal(\result.value.status) || \result.value.status.kind === "Returned" : \result.value.status.kind === "Pending")
  if (!canRead(dir, actor, r)) return failure("NotAffiliated");
  if (isTerminal(r.status)) return failure("TerminalRequest");
  switch (cmd.kind) {
    case "Edit":
      if (canEdit(dir, actor, r)) return success(edit(dir, actor, r, cmd.content));
      return failure(r.status.kind === "Pending" ? "NotManager" : "NotAuthor");
    case "Submit":
      if (canSubmit(actor, r)) return success(submit(actor, r));
      return failure(r.status.kind === "Pending" ? "WrongState" : "NotAuthor");
    case "Approve":
      if (canDecide(dir, actor, r)) return success(approve(dir, actor, r));
      return failure(r.status.kind === "Pending" ? "NotManager" : "WrongState");
    case "Reject":
      if (canDecide(dir, actor, r)) return success(reject(dir, actor, r));
      return failure(r.status.kind === "Pending" ? "NotManager" : "WrongState");
    case "Return":
      if (canDecide(dir, actor, r)) return success(returnToAuthor(dir, actor, r));
      return failure(r.status.kind === "Pending" ? "NotManager" : "WrongState");
  }
}

// === トレース ===

export interface Event {
  actor: UserId;
  command: Command;
}

/**
 * トレース全体を適用する。拒否されたコマンドは申請に手を触れない。ループ不変条件が
 * `step` の 1 ステップの定理をシステムの不変条件に持ち上げる: どんなトレースに沿っても
 * 同一性は不変で、決裁済みの申請は凍結される（P2）——任意の長さのトレース、任意の
 * 大きさの名簿について。
 */
export function run(dir: Directory, r: Request, events: Event[]): Request {
  //@ verify
  //@ contract `events` にわたって `step` を畳み込む。コマンドが拒否されたところでは申請をそのまま保つ。
  //@ ensures \result.author === r.author && \result.department === r.department
  //@ ensures wellFormed(dir, r) ==> wellFormed(dir, \result)
  //@ ensures isTerminal(r.status) ==> \result === r
  let current = r;
  for (let i = 0; i < events.length; i++) {
    //@ invariant 0 <= i && i <= events.length
    //@ invariant current.author === r.author && current.department === r.department
    //@ invariant isTerminal(r.status) ==> current === r
    const outcome = step(dir, events[i].actor, current, events[i].command);
    if (outcome.kind === "Success") current = outcome.value;
  }
  return current;
}

// === 可変なシステム（spec.md を動くサービスとして） ===

/**
 * 動くサービスの申請ストア。クラス不変条件——保存されているすべての申請は名簿に対して
 * 整合している——は各メソッドの `requires` / `ensures` として述べる。P3（取り残された
 * 申請がない）は、名簿が `departmentsHaveManagers` を満たすどんなストアについても
 * 成り立つ定理になる（approval.dfy の `WorkflowHasNoOrphanedRequests`）。
 */
export class Workflow {
  directory: Directory;
  requests: Map<number, Request>;
  nextId: number;

  constructor(directory: Directory) {
    this.directory = directory;
    this.requests = new Map();
    this.nextId = 0;
  }

  /** ストア上のアクション A: 作成に成功した申請は新しい id で記録される。 */
  open(author: UserId, dep: DepartmentId, content: Content): Outcome {
    //@ verify
    //@ requires forall(id, this.requests.has(id) ==> wellFormed(this.directory, this.requests.get(id)))
    //@ ensures forall(id, this.requests.has(id) ==> wellFormed(this.directory, this.requests.get(id)))
    //@ ensures \result.kind === "Success" ==> this.requests.has(this.nextId - 1) && this.requests.get(this.nextId - 1) === \result.value
    //@ ensures \result.kind === "Success" ==> \result.value.author === author && \result.value.department === dep && \result.value.status.kind === "Draft"
    const outcome = create(this.directory, author, dep, content);
    if (outcome.kind === "Success") {
      const stored = new Map(this.requests);
      stored.set(this.nextId, outcome.value);
      this.requests = stored;
      this.nextId = this.nextId + 1;
    }
    return outcome;
  }

  /** ストア上のアクション B〜F: `step` が判断し、成功したときだけ書き戻す。 */
  apply(actor: UserId, id: number, cmd: Command): Outcome {
    //@ verify
    //@ requires forall(k, this.requests.has(k) ==> wellFormed(this.directory, this.requests.get(k)))
    //@ ensures forall(k, this.requests.has(k) ==> wellFormed(this.directory, this.requests.get(k)))
    //@ ensures \result.kind === "Success" ==> this.requests.has(id) && this.requests.get(id) === \result.value
    const current = this.requests.get(id);
    if (current === undefined) return failure("NoSuchRequest");
    const outcome = step(this.directory, actor, current, cmd);
    if (outcome.kind === "Success") {
      const stored = new Map(this.requests);
      stored.set(id, outcome.value);
      this.requests = stored;
    }
    return outcome;
  }
}
