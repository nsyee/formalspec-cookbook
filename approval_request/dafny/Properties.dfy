include "Approval.dfy"

// spec.md の性質を、*あらゆる* ディレクトリ・稟議申請・実行トレースについて証明する。
//
// このリポジトリのモデル検査器は同じ問いに有限なスコープの中で答える（「ユーザー 3 人、
// 部署 2 つ、遷移 8 回まで」）。ここでは各命題が型のすべての値について量化された
// 補題なので、保証にスコープがない: `TerminalRequestsAreFrozen` は、任意の大きさの組織の
// 上で、任意の長さのトレースに対して成り立つ。
//
// 読者があると思うかもしれない補題——「Draft は承認できない」——は意図的に置いていない。
// `Approve` は `CanDecide` を要求するので、そのような呼び出しはそもそも検証を通らず、
// 証明すべきことがない。定理を必要とするのは動的な入口 `Step` だけである。
module Properties {
  import opened Approval

  // === 実行トレース ===

  datatype Event = Event(actor: UserId, command: Command)

  // トレース全体を適用する。拒否されたコマンドは申請に触れない——ユーザーが拒否されたときに
  // 外部が見るのはこの振る舞いである。
  function Run(dir: Directory, r: Request, events: seq<Event>): Request
    decreases |events|
  {
    if events == [] then r
    else
      var outcome := Step(dir, events[0].actor, r, events[0].command);
      Run(dir, if outcome.Success? then outcome.value else r, events[1..])
  }

  // === P1: 文脈依存の権限は部署間で漏れない ===

  // 成功した決裁はすべて *申請先* 部署の上長によるものであり、実行者が他の部署で
  // どんな役職を持っていても関係ない。
  lemma OnlyTargetManagersDecide(dir: Directory, actor: UserId, r: Request, cmd: Command)
    requires cmd.ApproveCommand? || cmd.RejectCommand? || cmd.ReturnCommand?
    requires Step(dir, actor, r, cmd).Success?
    ensures r.status.Pending? && IsManagerOf(dir, actor, r.department)
  {
    // `Step` は `Approve` / `Reject` / `Return` に委譲し、いずれも上の連言そのものである
    // `CanDecide` で守られている。
  }

  // P1 の具体的な形: `elsewhere` の上長でありながら申請先部署では一般メンバーでしかない
  // ユーザーは、たとえ自分が作成した申請であっても拒否される。
  lemma NoAuthorityLeakAcrossDepartments(
    dir: Directory, actor: UserId, r: Request, elsewhere: DepartmentId, cmd: Command)
    requires cmd.ApproveCommand? || cmd.RejectCommand? || cmd.ReturnCommand?
    requires elsewhere != r.department
    requires IsManagerOf(dir, actor, elsewhere)
    requires IsAffiliated(dir, actor, r.department) && !IsManagerOf(dir, actor, r.department)
    ensures Step(dir, actor, r, cmd).Failure?
    ensures r.status.Pending? ==> Step(dir, actor, r, cmd) == Failure(NotManager)
  {
    if Step(dir, actor, r, cmd).Success? {
      OnlyTargetManagersDecide(dir, actor, r, cmd);
      assert false;
    }
  }

  // 自己決裁（spec.md §4 D）は同じ規則を反対側から見たものなので、可能のままでなければ
  // ならない。この補題は証人を示すので、上の P1 が空虚でないことの証明にもなっている。
  lemma SelfApprovalIsAllowed()
    ensures exists dir: Directory, actor: UserId, r: Request ::
              r.author == actor && Step(dir, actor, r, ApproveCommand).Success?
  {
    var assignment: Assignment := map[(SomeUser, SomeDepartment) := Manager];
    assert HasManager(assignment, SomeDepartment) by {
      assert (SomeUser, SomeDepartment) in assignment;
    }
    var dir: Directory := assignment;
    var r := Request(SomeUser, SomeDepartment, Content("laptop", 1500), Pending);
    assert Step(dir, SomeUser, r, ApproveCommand).Success?;
  }

  // === P2: 終端状態の不変性 ===

  lemma TerminalRequestsRejectEveryCommand(dir: Directory, actor: UserId, r: Request, cmd: Command)
    requires Terminal(r.status)
    ensures Step(dir, actor, r, cmd).Failure?
  {
  }

  // …したがって、どの長さのトレースも、決裁済みの申請を動かせない。
  lemma TerminalRequestsAreFrozen(dir: Directory, r: Request, events: seq<Event>)
    requires Terminal(r.status)
    ensures Run(dir, r, events) == r
    decreases |events|
  {
    if events != [] {
      TerminalRequestsRejectEveryCommand(dir, events[0].actor, r, events[0].command);
      TerminalRequestsAreFrozen(dir, r, events[1..]);
    }
  }

  // === P3: 迷子申請の不在 ===

  // `Directory` は部分型なので、`dir` がその型を持つという事実だけから
  // 「各部署に上長が 1 名以上」が使える。証明は、制約が約束する上長を名指しすればよい。
  lemma EveryPendingRequestHasADecider(dir: Directory, r: Request)
    requires WellFormed(dir, r) && r.status.Pending?
    ensures exists decider: UserId :: CanDecide(dir, decider, r)
  {
    assert (r.author, r.department) in dir.Keys;
    assert HasManager(dir, r.department);
    var decider: UserId :| (decider, r.department) in dir
                           && dir[(decider, r.department)] == Manager;
    assert CanDecide(dir, decider, r);
  }

  // 到達可能性側の命題。モデル検査器では進行仮定の下の活性として得られるもので、
  // Pending の申請はイベント 1 つで終端状態に到達できる。
  lemma PendingRequestsCanBeDecided(dir: Directory, r: Request)
    requires WellFormed(dir, r) && r.status.Pending?
    ensures exists e: Event :: Terminal(Run(dir, r, [e]).status)
  {
    EveryPendingRequestHasADecider(dir, r);
    var decider: UserId :| CanDecide(dir, decider, r);
    var e := Event(decider, ApproveCommand);
    calc {
      Run(dir, r, [e]);
      Run(dir, Approve(dir, decider, r), []);
      Approve(dir, decider, r);
    }
    assert Terminal(Run(dir, r, [e]).status);
  }

  // === アクセス制御（spec.md §3）===

  // R1 と R2 をまとめて: 閲覧可能であることは、申請先部署に所属していることに他ならない。
  // `<==>` にすると両方向を 1 つの補題で述べられる。
  lemma ReadIsExactlyAffiliation(dir: Directory, actor: UserId, r: Request)
    ensures CanRead(dir, actor, r) <==> IsAffiliated(dir, actor, r.department)
  {
  }

  // U2: 同じ部署の同僚でも、作成者本人でなくその部署の上長でもないなら、どの状態でも
  // 編集できない。
  lemma OtherMembersCannotEdit(dir: Directory, actor: UserId, r: Request)
    requires actor != r.author
    requires !IsManagerOf(dir, actor, r.department)
    ensures !CanEdit(dir, actor, r)
    ensures Step(dir, actor, r, EditCommand(r.content)).Failure?
  {
  }

  // U1 と U3: 編集は spec.md に列挙された状態に限られ、そこに列挙された 2 つの立場に対しては
  // 実際に成功する。
  lemma EditFollowsTheStateTable(dir: Directory, actor: UserId, r: Request, content: Content)
    ensures CanEdit(dir, actor, r) ==> !Terminal(r.status)
    ensures actor == r.author && (r.status.Draft? || r.status.Returned?) ==> CanEdit(dir, actor, r)
    ensures IsManagerOf(dir, actor, r.department) && r.status.Pending? ==> CanEdit(dir, actor, r)
    ensures CanEdit(dir, actor, r) ==> Edit(dir, actor, r, content).status == r.status
  {
  }

  // C: 提出できるのは作成者だけである。
  lemma OnlyTheAuthorSubmits(dir: Directory, actor: UserId, r: Request)
    requires Step(dir, actor, r, SubmitCommand).Success?
    ensures actor == r.author && (r.status.Draft? || r.status.Returned?)
    ensures Step(dir, actor, r, SubmitCommand).value.status.Pending?
  {
  }

  // === トレースに沿った不変条件 ===

  // 作成者と申請先部署は作成時に定まる。これを `Step` ではなく `Run` について証明することで、
  // 1 つの遷移の性質ではなくシステムの不変条件になる。
  lemma IdentityIsImmutable(dir: Directory, r: Request, events: seq<Event>)
    ensures Run(dir, r, events).author == r.author
    ensures Run(dir, r, events).department == r.department
    decreases |events|
  {
    if events != [] {
      var outcome := Step(dir, events[0].actor, r, events[0].command);
      IdentityIsImmutable(dir, if outcome.Success? then outcome.value else r, events[1..]);
    }
  }

  // したがって、整合した申請は整合したままである: 作成者は申請先部署に所属し続けるので、
  // P3 もその申請に適用され続ける。
  lemma WellFormednessIsPreserved(dir: Directory, r: Request, events: seq<Event>)
    requires WellFormed(dir, r)
    ensures WellFormed(dir, Run(dir, r, events))
  {
    IdentityIsImmutable(dir, r, events);
  }

  // spec.md §2 の状態機構には他の辺がない: 1 回の遷移は、状態を保つか、図の矢印の
  // いずれかに従うかのどちらかである。
  lemma StatusFollowsTheStateMachine(dir: Directory, actor: UserId, r: Request, cmd: Command)
    requires Step(dir, actor, r, cmd).Success?
    ensures var next := Step(dir, actor, r, cmd).value.status;
            || next == r.status // 編集
            || (r.status.Draft? && next.Pending?) // 提出
            || (r.status.Returned? && next.Pending?) // 再提出
            || (r.status.Pending? && (next.Approved? || next.Rejected? || next.Returned?))
  {
  }
}
