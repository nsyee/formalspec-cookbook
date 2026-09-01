// -*- mode: quint -*-
//
// 稟議申請システム（兼務を前提としたワークフローと権限モデル）の Quint 仕様。
//
// 自然言語での仕様は ../spec.md を参照。
//
// モデル化の方針（TLA+ 版 ../tla/Approval.tla との違いを意識している）:
//   - 状態も役職も **直和型（sum type）** で表す。TLA+ では文字列と集合で表し
//     TypeOK で実行時に弾いていたが、Quint では型検査器が静的に弾く。
//   - 「所属していない部署での役職」は Standing 型の Outsider として型の中に
//     入れる。番兵の文字列を Role に混ぜないので、他部署での役職と取り違える
//     余地がない（P1 の本質）。
//   - 申請は Map[ReqId, Request] とし、「まだ存在しない申請」はキーの不在で
//     表す。TLA+ の Nil のような番兵は要らない。
//   - 権限判定は状態を読むだけの純粋な述語なので def、状態を変えるものだけを
//     action として書く。Quint は予約語のレベルでこの分離を強制する。
//   - 直前に起きたイベントを履歴変数として持つ。ここでも直和型が効いて、
//     「作成イベントには対象と実行者がある」といった構造を型で表せる。
module approval {
  // --------------------------------------------------------------------------
  // 1. 型
  // --------------------------------------------------------------------------

  type UserName = str
  type Dept = str
  type ReqId = int
  type Content = str

  /// 役職。spec.md §1 の Member / Manager。
  type Role =
    | Member
    | Manager

  /// ある (ユーザー, 部署) の組における立場。所属していない場合が Outsider で、
  /// 「役職を持たない」ことと「Member である」ことが型として別物になる。
  type Standing =
    | Outsider
    | Holds(Role)

  /// 稟議の状態（spec.md §2）。
  type Status =
    | Draft
    | Pending
    | Returned
    | Approved
    | Rejected

  /// 稟議申請。作成者・申請先部署・内容・状態を持つ（spec.md §1）。
  type Request = {
    author: UserName,
    target: Dept,
    content: Content,
    status: Status,
  }

  /// 直前に起きたイベント（履歴変数）。エラートレースが「誰が何をしたか」の列
  /// として読めるようになり、実行者に言及する性質を書けるようになる。
  type Event =
    | Started
    | Created({ by: UserName, id: ReqId })
    | Edited({ by: UserName, id: ReqId })
    | Submitted({ by: UserName, id: ReqId })
    | Decided({ by: UserName, id: ReqId, into: Status })

  /// 組織図: ユーザーごとの「部署 -> 立場」の全域写像。
  type OrgChart = UserName -> (Dept -> Standing)

  // --------------------------------------------------------------------------
  // 2. 定数（検証スコープ）と状態変数
  // --------------------------------------------------------------------------

  const USERS: Set[UserName]
  const DEPTS: Set[Dept]
  /// 申請 ID の静的なプール。作成もひとつの遷移として観測するために使う。
  const IDS: Set[ReqId]
  /// 申請の内容。中身は問わない不透明な値で、編集は値の差し替えとして表す。
  const CONTENTS: Set[Content]

  assume nonEmptyScope = and {
    USERS != Set(),
    DEPTS != Set(),
    IDS != Set(),
    CONTENTS.size() >= 2,
  }

  /// 所属と役職。時間で変化しないが、init で非決定的に選ぶことで
  /// **すべての兼務パターン** を探索する（P1 は兼務パターンに依存する性質）。
  var roles: OrgChart
  /// 作成済みの申請。キーの集合がそのまま「存在する申請」になる。
  var requests: ReqId -> Request
  /// 直前に起きたイベント。
  var lastEvent: Event

  // --------------------------------------------------------------------------
  // 3. 静的な構造についての純粋関数
  // --------------------------------------------------------------------------

  /// 実行者のその部署での立場。所属していなければ Outsider。
  def standingOf(u: UserName, d: Dept): Standing = roles.get(u).get(d)

  def isManager(u: UserName, d: Dept): bool = standingOf(u, d) == Holds(Manager)

  def isMember(u: UserName, d: Dept): bool = standingOf(u, d) == Holds(Member)

  /// 所属部署の集合（兼務なら複数）。
  def affiliations(u: UserName): Set[Dept] =
    DEPTS.filter(d => standingOf(u, d) != Outsider)

  def isAffiliated(u: UserName, d: Dept): bool = standingOf(u, d) != Outsider

  def managers(d: Dept): Set[UserName] = USERS.filter(u => isManager(u, d))

  /// spec.md §1 の構造上の仮定。init の条件かつ不変条件として使う。
  pure def isWellFormed(chart: OrgChart): bool = and {
    // ユーザーは 1 つ以上の部署に所属する。
    chart.keys().forall(u => DEPTS.exists(d => chart.get(u).get(d) != Outsider)),
    // 各部署には必ず 1 名以上の Manager が存在する（P3 の前提）。
    DEPTS.forall(d => chart.keys().exists(u => chart.get(u).get(d) == Holds(Manager))),
  }

  /// 探索対象の組織図。全域写像の集合として作るので、powerset を経由せずに
  /// 「兼務」「非所属」を表せる。
  val orgCharts: Set[OrgChart] =
    setOfMaps(USERS, setOfMaps(DEPTS, Set(Outsider, Holds(Member), Holds(Manager))))

  val wellFormedOrgCharts: Set[OrgChart] = orgCharts.filter(c => isWellFormed(c))

  // --------------------------------------------------------------------------
  // 4. 申請についての純粋関数
  // --------------------------------------------------------------------------

  /// 現時点で存在する（作成済みの）申請。
  val live: Set[ReqId] = requests.keys()

  def requestOf(id: ReqId): Request = requests.get(id)

  pure def isTerminal(s: Status): bool = s == Approved or s == Rejected

  /// spec.md §2 の状態遷移図そのもの。どの状態からどの状態へ動けるかを
  /// match で網羅的に書く（状態を増やすと型検査器が抜けを指摘してくれる）。
  pure def canFollow(from: Status, into: Status): bool =
    match from {
      | Draft    => into == Pending
      | Returned => into == Pending
      | Pending  => into == Approved or into == Rejected or into == Returned
      | Approved => false
      | Rejected => false
    }

  /// 上長が Pending の申請に下せる決裁の結果（spec.md §4 D/E/F）。
  pure val decisions: Set[Status] = Set(Approved, Rejected, Returned)

  // --------------------------------------------------------------------------
  // 5. アクセス制御（spec.md §3）
  //
  // 権限は状態遷移を伴わない述語なので def として書く。アクションの事前条件
  // としても、検証したい性質の主題としても、同じ定義を再利用する。
  // --------------------------------------------------------------------------

  /// R1 / R2: 申請先部署に所属しているかどうかだけで決まる。
  def canRead(u: UserName, id: ReqId): bool = and {
    live.contains(id),
    isAffiliated(u, requestOf(id).target),
  }

  /// U1 / U2 / U3。U2（他の一般メンバーは編集できない）は U1 にも U3 にも
  /// 当てはまらないことから従うので、独立した条件としては書かない。
  def canEdit(u: UserName, id: ReqId): bool = and {
    live.contains(id),
    val req = requestOf(id)
    or {
      // U1: 作成者本人は Draft / Returned のときだけ編集できる。
      and { u == req.author, req.status == Draft or req.status == Returned },
      // U3: 申請先部署の上長は Draft / Returned / Pending のとき編集できる。
      and { isManager(u, req.target), not(isTerminal(req.status)) },
    },
  }

  /// 提出 / 再提出できるのは作成者本人で、Draft か Returned のときだけ
  /// （spec.md §4 C）。
  def canSubmit(u: UserName, id: ReqId): bool = and {
    live.contains(id),
    u == requestOf(id).author,
    requestOf(id).status == Draft or requestOf(id).status == Returned,
  }

  /// 承認・却下・差し戻しの事前条件は共通で、「*申請先部署の* 上長であること」。
  /// 自己決裁は仕様どおり許可される（spec.md §4 D の注記）。
  def canDecide(u: UserName, id: ReqId): bool = and {
    live.contains(id),
    requestOf(id).status == Pending,
    isManager(u, requestOf(id).target),
  }

  // --------------------------------------------------------------------------
  // 6. アクションと状態遷移（spec.md §4）
  // --------------------------------------------------------------------------

  /// A. 申請の作成。実行者 u が所属部署 d 宛ての申請を内容 c で作る。
  action create(u: UserName, d: Dept, id: ReqId, c: Content): bool = all {
    not(live.contains(id)),
    isAffiliated(u, d),
    requests' = requests.put(id, { author: u, target: d, content: c, status: Draft }),
    lastEvent' = Created({ by: u, id: id }),
    roles' = roles,
  }

  /// B. 申請の編集。内容が別の値に差し替わる。状態は変化しない。
  /// レコードの局所更新は .with で書ける（TypeScript のスプレッド構文に相当）。
  action edit(u: UserName, id: ReqId, c: Content): bool = all {
    canEdit(u, id),
    requestOf(id).content != c,
    requests' = requests.set(id, requestOf(id).with("content", c)),
    lastEvent' = Edited({ by: u, id: id }),
    roles' = roles,
  }

  /// C. 申請の提出 / 再提出。実行者は作成者本人。
  action submit(u: UserName, id: ReqId): bool = all {
    canSubmit(u, id),
    requests' = requests.set(id, requestOf(id).with("status", Pending)),
    lastEvent' = Submitted({ by: u, id: id }),
    roles' = roles,
  }

  /// D/E/F. 上長による決裁。承認・却下・差し戻しは決裁後の状態 into だけが違う。
  action decide(u: UserName, id: ReqId, into: Status): bool = all {
    canDecide(u, id),
    decisions.contains(into),
    requests' = requests.set(id, requestOf(id).with("status", into)),
    lastEvent' = Decided({ by: u, id: id, into: into }),
    roles' = roles,
  }

  action approve(u: UserName, id: ReqId): bool = decide(u, id, Approved)
  action reject(u: UserName, id: ReqId): bool = decide(u, id, Rejected)
  action returnBack(u: UserName, id: ReqId): bool = decide(u, id, Returned)

  /// 組織図を与えて初期状態にする。run テストから決め打ちの組織図を渡せるよう
  /// に、非決定的な選択とは分けてある。
  action setup(chart: OrgChart): bool = all {
    roles' = chart,
    requests' = Map(),
    lastEvent' = Started,
  }

  action init = {
    nondet chart = oneOf(wellFormedOrgCharts)
    setup(chart)
  }

  /// すべての申請が終端に達したら、それ以上の遷移はない。明示的に stutter させ
  /// ておくと、行き止まり（どのアクションも実行できない状態）とは区別できる。
  action done = all {
    IDS.forall(id => live.contains(id) and isTerminal(requestOf(id).status)),
    roles' = roles,
    requests' = requests,
    lastEvent' = lastEvent,
  }

  /// 非決定的に実行者・申請・内容を選び、いずれかのアクションを起こす。
  /// TLA+ の \E u \in User, ... : A(u, ...) に当たるが、Quint では
  /// 「値を選ぶ」ことと「アクションを選ぶ」ことが nondet と any に分かれる。
  action step = {
    nondet u = oneOf(USERS)
    nondet d = oneOf(DEPTS)
    nondet id = oneOf(IDS)
    nondet c = oneOf(CONTENTS)
    nondet into = oneOf(decisions)
    any {
      create(u, d, id, c),
      edit(u, id, c),
      submit(u, id),
      decide(u, id, into),
      done,
    }
  }

  // --------------------------------------------------------------------------
  // 7. 検証したい性質（spec.md §5）
  //
  // TLA+ の TypeOK に当たる不変条件は要らない。型は静的に検査されている。
  // --------------------------------------------------------------------------

  /// 構造の健全性: 兼務パターンは変化せず、常に spec.md §1 を満たす。
  val orgChartIsWellFormed: bool = isWellFormed(roles)

  /// 申請先部署は作成者の所属部署である（spec.md §1）。
  val targetIsAuthorsDept: bool =
    live.forall(id => isAffiliated(requestOf(id).author, requestOf(id).target))

  /// P1 兼務ユーザーの権限分離: 決裁可否は申請先部署での立場のみで決まる。
  /// すなわち申請先部署で同じ立場の 2 ユーザーの決裁権限は、他部署での役職に
  /// 関係なく常に一致する。
  val decisionRightsDependOnTargetRoleOnly: bool =
    live.forall(id =>
      tuples(USERS, USERS).forall(((u1, u2)) =>
        (standingOf(u1, requestOf(id).target) == standingOf(u2, requestOf(id).target))
          implies (canDecide(u1, id) iff canDecide(u2, id))))

  /// P3 迷子申請の不在: 存在する申請には決裁できる上長が常に 1 名以上いる。
  val noOrphanRequest: bool =
    live.forall(id => managers(requestOf(id).target) != Set())

  /// R2: 所属していない部署宛ての申請は一切閲覧できない。
  val readsRequireAffiliation: bool =
    tuples(USERS, live).forall(((u, id)) =>
      canRead(u, id) implies isAffiliated(u, requestOf(id).target))

  /// U2: 申請先部署の一般メンバーは、他人が作成した申請を編集できない。
  val plainMembersCannotEditOthersRequests: bool =
    tuples(USERS, live).forall(((u, id)) =>
      (isMember(u, requestOf(id).target) and u != requestOf(id).author)
        implies not(canEdit(u, id)))

  val safety: bool = and {
    orgChartIsWellFormed,
    targetIsAuthorsDept,
    decisionRightsDependOnTargetRoleOnly,
    noOrphanRequest,
    readsRequireAffiliation,
    plainMembersCannotEditOthersRequests,
  }

  // --------------------------------------------------------------------------
  // 8. 遷移についての性質
  //
  // 「直前のイベント」を状態に持たせてあるので、遷移の正しさを *状態述語* と
  // して書ける。次状態演算子を使わずに済むため、シミュレーションでも
  // Apalache でも同じ式をそのまま検査できる。
  // --------------------------------------------------------------------------

  /// 履歴変数が指す申請と実行者を取り出す（Started には実行者がいない）。
  pure def actorOf(e: Event): Set[(UserName, ReqId)] =
    match e {
      | Started      => Set()
      | Created(p)   => Set((p.by, p.id))
      | Edited(p)    => Set((p.by, p.id))
      | Submitted(p) => Set((p.by, p.id))
      | Decided(p)   => Set((p.by, p.id))
    }

  /// 内容が変わるのは編集権限を持つ実行者による編集のときだけ（U1/U2/U3）。
  /// 編集イベントは、その時点で編集権限を持っていた者しか起こせない。
  val editsAreAuthorized: bool =
    match lastEvent {
      | Edited(p) => canEdit(p.by, p.id)
      | _         => true
    }

  /// 決裁イベントは、申請先部署の上長しか起こせない（自己決裁は可）。
  val decisionsAreMadeByTargetManagers: bool =
    match lastEvent {
      | Decided(p) => isManager(p.by, requestOf(p.id).target)
      | _          => true
    }

  /// 提出は作成者本人しか起こせない（spec.md §4 C）。
  val submissionsAreMadeByAuthors: bool =
    match lastEvent {
      | Submitted(p) => p.by == requestOf(p.id).author
      | _            => true
    }

  val eventsAreAuthorized: bool = and {
    editsAreAuthorized,
    decisionsAreMadeByTargetManagers,
    submissionsAreMadeByAuthors,
  }

  /// P2 終端状態の不変性: 終端に達した申請は状態も内容も二度と変わらない。
  /// アクションの事前条件を述語として切り出してあるので、「終端の申請を動かせる
  /// アクションはどのユーザーにも 1 つもない」ことを状態述語として書ける。
  /// これで反例が出なければ、終端からの遷移は構文的に不可能である。
  val terminalRequestsAreFrozen: bool =
    live.filter(id => isTerminal(requestOf(id).status)).forall(id =>
      USERS.forall(u => and {
        not(canEdit(u, id)),
        not(canSubmit(u, id)),
        not(canDecide(u, id)),
      }))

  /// spec.md §2 の状態遷移図に沿っていること。Created は Draft から始まり、
  /// Submitted / Decided は canFollow が許す遷移しか起こさない。
  val statusFollowsStateMachine: bool =
    match lastEvent {
      | Created(p)   => requestOf(p.id).status == Draft
      | Submitted(p) => requestOf(p.id).status == Pending
      | Decided(p)   => decisions.contains(requestOf(p.id).status)
      | _            => true
    }

  // --------------------------------------------------------------------------
  // 9. 時相性質（活性）
  // --------------------------------------------------------------------------

  /// 申請 id に対する何らかの決裁。TLA+ の \E u, s : Decide(u, r, s) に当たる
  /// が、アクションの選択は論理の exists ではなく nondet + any で書く。
  action decideSomehow(id: ReqId): bool = {
    nondet u = oneOf(USERS)
    nondet into = oneOf(decisions)
    decide(u, id, into)
  }

  /// 決裁できる上長がいつまでも放置しない、という進行仮定。
  temporal decisionsAreFair: bool =
    IDS.forall(id => weakFair(decideSomehow(id), (roles, requests, lastEvent)))

  /// 提出された申請が永遠に承認待ちのままになることはない。
  temporal pendingIsEventuallyDecided: bool =
    IDS.forall(id =>
      always(
        (live.contains(id) and requestOf(id).status == Pending)
          implies eventually(not(live.contains(id) and requestOf(id).status == Pending))))

  /// 進行仮定の下では活性が成り立つ。仮定を外すと破れる（models.qnt 参照）。
  temporal liveness: bool = decisionsAreFair implies pendingIsEventuallyDecided
}
