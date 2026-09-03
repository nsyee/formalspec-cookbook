// 稟議申請システムの Dafny モデル: データモデル、権限の述語、そして遷移。
//
// 自然言語での仕様は ../spec.md を参照。
//
// このリポジトリの他のモデルは、有界な状態空間を探索する（Alloy / TLA+ / Quint）か、
// 要求とポリシーの組を扱う（Cedar）。対して Dafny は、ある型のすべての値についての
// 命題を *証明* するので、モデル化の重心は型と、関数の事前・事後条件に移る:
//
//   - 整合条件は部分型（`Directory` / `Title` / `Amount`）に持たせる。`Directory`
//     型の値は「各部署に上長が 1 名以上」を破れないので、この要件をどの事前条件でも
//     再掲しなくてよい。
//   - 各遷移は *事前条件付きの全域関数* である。`Approve` は申請が Pending であることと
//     実行者が申請先部署の上長であることを要求し、事後条件で遷移先の状態を特定する。
//     事前条件は各呼び出し地点で検証器が果たすので、「Draft を承認する」は実行時の拒否では
//     なく証明できないプログラムになる。
//   - `Step` は、外の世界からの任意の (稟議申請, コマンド) の組を受け取る単一の入口。
//     failure-compatible な `Outcome` を返すので、呼び出し側は `:-` で拒否を伝播できる。
//
// Properties.dfy はこれらの定義に対して P1〜P3 と spec.md のアクセス制御規則を証明し、
// Workflow.dfy はこれらを可変なシステムとして動かす。
module Approval {

  // === 識別子・役職・ディレクトリ ===

  type UserId = s: string | s != "" witness "u"
  type DepartmentId = s: string | s != "" witness "d"

  datatype Role = Member | Manager

  // 役職は文脈依存である: キーは (ユーザー, 部署) の組であり、ユーザー単体ではない。
  // この組をキーとする map にすると「1 つの所属につき役職は 1 つ」が構造で保証されるので、
  // 関係で表すモデルと違ってこのための不変条件を置く必要がない。
  type Assignment = map<(UserId, DepartmentId), Role>

  ghost predicate HasManager(a: Assignment, dep: DepartmentId) {
    exists u: UserId :: (u, dep) in a && a[(u, dep)] == Manager
  }

  ghost predicate DepartmentsHaveManagers(a: Assignment) {
    forall k <- a.Keys :: HasManager(a, k.1)
  }

  // 組織図。spec.md §1 の不変条件（「各部署には必ず 1 名以上の上長が存在する」）を
  // 型の中に持つ。証人はありえる最小の組織図、すなわち 1 部署とその上長 1 名。
  // Dafny は証人が制約を満たすことを検査するので、この型が空でないと分かる。
  const SomeUser: UserId := "u"
  const SomeDepartment: DepartmentId := "d"

  type Directory = a: Assignment | DepartmentsHaveManagers(a)
    witness map[(SomeUser, SomeDepartment) := Manager]

  predicate IsAffiliated(dir: Directory, user: UserId, dep: DepartmentId) {
    (user, dep) in dir
  }

  predicate IsManagerOf(dir: Directory, user: UserId, dep: DepartmentId) {
    (user, dep) in dir && dir[(user, dep)] == Manager
  }

  // === 稟議申請 ===

  type Title = s: string | s != "" witness "t"
  type Amount = n: int | 0 <= n witness 0

  datatype Content = Content(title: Title, amount: Amount)

  // 生の入力を制約付きの値にするのは、その制約を事前条件に持つ関数である。呼び出し側が
  // 制約を示す必要があり、以降は値自体がそれを持ち運ぶ。
  function AsTitle(s: string): Title
    requires s != ""
  {
    s
  }

  function AsAmount(n: int): Amount
    requires 0 <= n
  {
    n
  }

  // spec.md §2 の状態ごとに 1 ケース。各状態はそこに存在するフィールドだけを持ち、
  // 誰が決裁したかはその決裁を記録するケースにしか現れない。だから「承認者を持つ Draft」は
  // そもそも書けない。
  datatype Status =
    | Draft
    | Pending
    | Returned(returnedBy: UserId)
    | Approved(approvedBy: UserId)
    | Rejected(rejectedBy: UserId)

  predicate Terminal(s: Status) {
    s.Approved? || s.Rejected?
  }

  datatype Request = Request(
    author: UserId,
    department: DepartmentId,
    content: Content,
    status: Status)

  // 作成者は申請先部署に所属していなければならない（spec.md §1）。これは申請単体の
  // 性質ではなく申請とディレクトリの間の関係なので、型ではなく述語として置く。
  ghost predicate WellFormed(dir: Directory, r: Request) {
    IsAffiliated(dir, r.author, r.department)
  }

  // === アクセス制御（spec.md §3）===

  predicate CanRead(dir: Directory, actor: UserId, r: Request) {
    IsAffiliated(dir, actor, r.department) // R1, R2
  }

  predicate CanEdit(dir: Directory, actor: UserId, r: Request) {
    || (actor == r.author && (r.status.Draft? || r.status.Returned?)) // U1
    || (IsManagerOf(dir, actor, r.department) && !Terminal(r.status)) // U3
    // U2 は、第 3 の項がないことそのもの。
  }

  predicate CanSubmit(actor: UserId, r: Request) {
    actor == r.author && (r.status.Draft? || r.status.Returned?) // C
  }

  // D / E / F は権限規則を 1 つ共有し、その規則は *申請先部署での* 実行者の役職にしか
  // 言及しない。P1（部署間で権限が漏れないこと）と spec.md §4 D の自己決裁の注は、
  // どちらもこの 1 つの述語から導かれる。
  predicate CanDecide(dir: Directory, actor: UserId, r: Request) {
    r.status.Pending? && IsManagerOf(dir, actor, r.department)
  }

  // === 遷移（spec.md §4）===

  // 生の入力から内容を組み立てる遷移は `Create` だけで、型が禁じる値を渡されうるのも
  // ここだけである（だから Outcome を返す）。事後条件はアクション A の事後条件そのもの。
  function Create(
    dir: Directory,
    author: UserId,
    dep: DepartmentId,
    title: string,
    amount: int): Outcome<Request>
    ensures Create(dir, author, dep, title, amount).Success?
            ==> var r := Create(dir, author, dep, title, amount).value;
                r.author == author && r.department == dep && r.status.Draft?
                && WellFormed(dir, r)
  {
    if !IsAffiliated(dir, author, dep) then Failure(NotAffiliated)
    else if title == "" || amount < 0 then Failure(InvalidContent)
    else Success(Request(author, dep, Content(AsTitle(title), AsAmount(amount)), Draft))
  }

  // 編集は状態と作成者を保ち、内容だけを差し替える（アクション B）。これを事後条件として
  // 書いておけば、`Edit` の呼び出し側（`Step` も含む）はそれをただで得られる。
  function Edit(dir: Directory, actor: UserId, r: Request, content: Content): Request
    requires CanEdit(dir, actor, r)
    ensures Edit(dir, actor, r, content) == r.(content := content)
    ensures Edit(dir, actor, r, content).status == r.status
  {
    r.(content := content)
  }

  function Submit(actor: UserId, r: Request): Request
    requires CanSubmit(actor, r)
    ensures Submit(actor, r).status.Pending?
  {
    r.(status := Pending)
  }

  function Approve(dir: Directory, actor: UserId, r: Request): Request
    requires CanDecide(dir, actor, r)
    ensures Approve(dir, actor, r).status == Approved(actor)
  {
    r.(status := Approved(actor))
  }

  function Reject(dir: Directory, actor: UserId, r: Request): Request
    requires CanDecide(dir, actor, r)
    ensures Reject(dir, actor, r).status == Rejected(actor)
  {
    r.(status := Rejected(actor))
  }

  function Return(dir: Directory, actor: UserId, r: Request): Request
    requires CanDecide(dir, actor, r)
    ensures Return(dir, actor, r).status == Returned(actor)
  {
    r.(status := Returned(actor))
  }

  // === コマンドと拒否 ===

  datatype Command =
    | EditCommand(content: Content)
    | SubmitCommand
    | ApproveCommand
    | RejectCommand
    | ReturnCommand

  datatype Denial =
    | NotAffiliated
    | NotAuthor
    | NotManager
    | TerminalRequest
    | WrongState
    | InvalidContent
    | NoSuchRequest

  // failure-compatible な結果型。`var x :- expr;` を使えるようにするために Dafny が
  // 探すのが `IsFailure` / `PropagateFailure` / `Extract` である。おかげでモデルの
  // 呼び出し側（Workflow.dfy / Scenarios.dfy）は `match` なしで拒否を伝播できる。
  datatype Outcome<T> = Success(value: T) | Failure(denial: Denial)
  {
    predicate IsFailure() {
      Failure?
    }

    function PropagateFailure<U>(): Outcome<U>
      requires IsFailure()
    {
      Failure(denial)
    }

    function Extract(): T
      requires !IsFailure()
    {
      value
    }
  }

  // === 動的な入口 ===

  // 上の遷移は誤って適用できない。事前条件が各呼び出し地点で証明されるからである。しかし
  // 外から届くのは任意の (稟議申請, コマンド) の組なので、`Step` がその組を分類して委譲する。
  // `Step` は全域的で、(状態, コマンド) のすべての組に対して、遷移後の申請か拒否の
  // いずれかを返す。
  //
  // その申請を閲覧すらできない実行者には状態を漏らさない: 最初に所属を検査し、
  // 終端状態の申請にはコマンドを見る前に答える（P2）。
  function Step(dir: Directory, actor: UserId, r: Request, cmd: Command): Outcome<Request>
    ensures Step(dir, actor, r, cmd).Success? ==> CanRead(dir, actor, r)
    ensures Step(dir, actor, r, cmd).Success? ==> !Terminal(r.status)
    ensures Step(dir, actor, r, cmd).Success?
            ==> var next := Step(dir, actor, r, cmd).value;
                next.author == r.author && next.department == r.department
  {
    if !CanRead(dir, actor, r) then Failure(NotAffiliated)
    else if Terminal(r.status) then Failure(TerminalRequest)
    else match cmd
         case EditCommand(content) =>
           if CanEdit(dir, actor, r) then Success(Edit(dir, actor, r, content))
           else if r.status.Pending? then Failure(NotManager)
           else Failure(NotAuthor)
         case SubmitCommand =>
           if CanSubmit(actor, r) then Success(Submit(actor, r))
           else if r.status.Pending? then Failure(WrongState)
           else Failure(NotAuthor)
         case ApproveCommand =>
           if CanDecide(dir, actor, r) then Success(Approve(dir, actor, r))
           else if r.status.Pending? then Failure(NotManager)
           else Failure(WrongState)
         case RejectCommand =>
           if CanDecide(dir, actor, r) then Success(Reject(dir, actor, r))
           else if r.status.Pending? then Failure(NotManager)
           else Failure(WrongState)
         case ReturnCommand =>
           if CanDecide(dir, actor, r) then Success(Return(dir, actor, r))
           else if r.status.Pending? then Failure(NotManager)
           else Failure(WrongState)
  }
}
