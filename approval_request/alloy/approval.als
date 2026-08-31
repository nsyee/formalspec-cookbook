/*
 * 稟議申請システム（兼務を前提としたワークフローと権限モデル）の Alloy 6 モデル。
 *
 * 自然言語での仕様は ../spec.md を参照。
 *
 * モデル化の方針:
 *   - 役職はユーザー単体の属性ではなく (ユーザー, 部署) の組に対して定義されるため、
 *     三項関係 `roles: User -> Department -> lone Role` として表現する。
 *   - 稟議申請の集合は静的に置き、ある時点で「システム上に存在するか」は可変フィールド
 *     `status` の有無で表す（`status` が空なら未作成）。こうすると探索空間を抑えつつ、
 *     申請の作成もトレース上のイベントとして扱える。
 *   - 各アクションは現在と次の時点にまたがる制約として書く（`var` フィールドと次状態 `x'`）。
 *     `fact traces` がそれらを `always` で無限の実行列に組み上げる。
 */
module approval_request/approval

// -------------------------------------------------------------- 静的な構成要素

enum Role { Member, Manager }

abstract sig Status {}
abstract sig Terminal extends Status {}
one sig Draft, Pending, Returned extends Status {}
one sig Approved, Rejected extends Terminal {}

sig Department {}

sig User {
  // その部署でのこのユーザーの役職。所属していない部署は写像を持たない。
  // `lone` により「1 部署につき最大 1 役職」、複数部署への写像により兼務を表す。
  roles: Department -> lone Role
} {
  some roles // ユーザーは 1 つ以上の部署に所属する
}

fun affiliations [u: User]: set Department { u.roles.Role }

fun members [d: Department]: set User { { u: User | u.roles[d] = Member } }

fun managers [d: Department]: set User { { u: User | u.roles[d] = Manager } }

// 各部署には必ず 1 名以上の上長が存在する（P3 の前提となる不変条件）。
fact everyDepartmentIsManaged {
  all d: Department | some managers[d]
}

// 申請の内容。中身は問わない（不透明な値）。編集はこの値の差し替えとして表すため、
// 申請書の構造をモデル化せずに「編集が起きたこと」を観測できる。
sig Content {}

sig Request {
  author: User,
  target: Department,
  var status: lone Status,
  var content: lone Content
} {
  // 申請先部署は、作成者が所属している部署でなければならない。
  target in affiliations[author]
}

// 現時点でシステム上に存在する（作成済みの）稟議申請。
fun live: set Request { status.Status }

// 申請が存在することと内容を持つことは同値。
fact wellFormedState {
  always all r: Request | some r.status iff some r.content
}

// ------------------------------------------------------ アクセス制御（権限ルール）
// 権限は状態遷移を伴わない、現時点についての純粋な述語である。そのためアクションの
// 事前条件としても、検証したい性質の主題としても再利用できる。

pred canRead [u: User, r: Request] {
  r in live
  r.target in affiliations[u] // R1, R2: 申請先部署に所属していること
}

pred canEdit [u: User, r: Request] {
  r in live
  (u = r.author and r.status in Draft + Returned)  // U1（U2 はこの条件に該当しないことで従う）
  or
  (u in managers[r.target] and r.status in Draft + Returned + Pending) // U3
}

// 承認・却下・差し戻しの事前条件は共通で、「*申請先部署の* 上長であること」。
// 自己決裁は仕様どおり許可される（spec §4 D）。
pred canDecide [u: User, r: Request] {
  r.status = Pending
  u in managers[r.target]
}

// ------------------------------------------------ アクションと状態遷移（spec §4）

// フレーム条件: r 以外の申請は状態も内容も変化しない。
pred onlyChanges [r: Request] {
  all o: Request - r | o.status' = o.status and o.content' = o.content
}

// A. 申請の作成
pred create [u: User, d: Department, r: Request] {
  // 事前条件
  no r.status
  r.author = u
  r.target = d
  d in affiliations[u]
  // 事後条件
  r.status' = Draft
  some r.content'
  onlyChanges[r]
}

// B. 申請の編集
pred edit [u: User, r: Request] {
  canEdit[u, r]
  r.content' != r.content // 内容が更新される
  r.status' = r.status    // 編集では状態は変化しない（spec §4 B）
  onlyChanges[r]
}

// C. 申請の提出 / 再提出
pred submit [u: User, r: Request] {
  u = r.author
  r.status in Draft + Returned
  r.status' = Pending
  r.content' = r.content
  onlyChanges[r]
}

// D/E/F. 上長による決裁（承認・却下・差し戻しの共通形）
pred decide [u: User, r: Request, s: Status] {
  canDecide[u, r]
  s in Approved + Rejected + Returned
  r.status' = s
  r.content' = r.content
  onlyChanges[r]
}

pred approve [u: User, r: Request] { decide[u, r, Approved] }
pred reject  [u: User, r: Request] { decide[u, r, Rejected] }
pred sendBack[u: User, r: Request] { decide[u, r, Returned] }

// 何も起きない遷移
pred stutter {
  status' = status
  content' = content
}

// イベントの具体化（reification）。発生したイベントを関係として見えるようにすると、
// GUI で各遷移に「誰が何をしたか」が表示でき、検証式やシナリオ記述でも実行者を参照できる。
fun creates:  User -> Request { { u: User, r: Request | some d: Department | create[u, d, r] } }
fun edits:    User -> Request { { u: User, r: Request | edit[u, r] } }
fun submits:  User -> Request { { u: User, r: Request | submit[u, r] } }
fun approves: User -> Request { { u: User, r: Request | approve[u, r] } }
fun rejects:  User -> Request { { u: User, r: Request | reject[u, r] } }
fun sendsBack:User -> Request { { u: User, r: Request | sendBack[u, r] } }

fun happenings: User -> Request {
  creates + edits + submits + approves + rejects + sendsBack
}

// ------------------------------------------------------------------ 実行列の定義

pred init {
  no status
  no content
}

pred step {
  some happenings or stutter
}

fact traces {
  init
  always step
}

// 進行仮定。活性（liveness）の検証でのみ使う: 決裁できる上長は永遠に放置しない。
pred fairness {
  all u: User, r: Request |
    always (canDecide[u, r] implies eventually (u -> r in approves + rejects + sendsBack))
}

// ------------------------------------------- 検証したい性質（アサーション、spec §5）

// P1 兼務ユーザーの権限分離: 決裁可否は申請先部署での役職のみで決まる。すなわち、
// 申請先部署での役職が同じ 2 ユーザーの権限は、他の部署での役職に関係なく常に一致する。
assert decisionRightsDependOnTargetRoleOnly {
  always all u1, u2: User, r: Request |
    u1.roles[r.target] = u2.roles[r.target] implies (canDecide[u1, r] iff canDecide[u2, r])
}
check decisionRightsDependOnTargetRoleOnly for 4 but 1..5 steps

// P1（遷移レベル）: 申請が終端状態に至るのは申請先部署の上長による決裁のときだけであり、
// それ以外のユーザーはその遷移を引き起こし得ない。
assert terminalDecidedByTargetManager {
  always all r: Request |
    r.status not in Terminal and r.status' in Terminal implies
      let deciders = { u: User | u -> r in approves + rejects } |
        some deciders and deciders in managers[r.target]
}
check terminalDecidedByTargetManager for 4 but 1..8 steps

// P2 終端状態の不変性: 一度 Approved / Rejected になった申請は二度と別の状態に遷移しない。
assert terminalStatesAreStable {
  all r: Request, s: Terminal | always (r.status = s implies always r.status = s)
}
check terminalStatesAreStable for 4 but 1..10 steps

// P3 迷子申請の不在: 存在する申請には常に、それを決裁できる上長が 1 名以上いる。
assert noOrphanRequest {
  always all r: live | some managers[r.target]
}
check noOrphanRequest for 5 but 1..5 steps

// R2: 自分が所属していない部署宛ての申請は一切閲覧できない。
assert readsRequireAffiliation {
  always all u: User, r: Request | canRead[u, r] implies r.target in affiliations[u]
}
check readsRequireAffiliation for 5 but 1..5 steps

// U1/U2/U3: 内容が更新されるのは編集権限を持つユーザーがいるときだけであり、
// それに該当するのは作成者本人か申請先部署の上長のみ。
assert contentChangesNeedAuthorizedEditor {
  always all r: live |
    r.content' != r.content implies
      some u: User | canEdit[u, r] and u in r.author + managers[r.target]
}
check contentChangesNeedAuthorizedEditor for 4 but 1..8 steps

// U2: 申請先部署の一般メンバーは、他人が作成した申請を編集できない。
assert plainMembersCannotEditOthersRequests {
  always all r: live, u: members[r.target] - r.author | not canEdit[u, r]
}
check plainMembersCannotEditOthersRequests for 4 but 1..5 steps

// spec §2 の状態マシンに従う: 定義されていない遷移（工程飛ばし）は起きない。
assert statusFollowsStateMachine {
  always all r: Request | let from = r.status, to = r.status' |
    from != to implies
      (no from and to = Draft)
      or (from = Draft and to = Pending)
      or (from = Returned and to = Pending)
      or (from = Pending and to in Approved + Rejected + Returned)
}
check statusFollowsStateMachine for 4 but 1..10 steps

// 差し戻された申請は、必ず過去に提出されている（過去演算子 once を使用）。
assert returnedImpliesEarlierSubmission {
  always all r: Request | r.status = Returned implies once r.status = Pending
}
check returnedImpliesEarlierSubmission for 4 but 1..10 steps

// 活性（liveness）: 進行仮定の下では、提出された申請が永遠に承認待ちのままになることはない
// （必ず承認・却下・差し戻しのいずれかに至る）。
assert pendingIsEventuallyDecided {
  fairness implies always all r: Request | r.status = Pending implies eventually r.status != Pending
}
check pendingIsEventuallyDecided for 3 but 1..8 steps

// -------------------------------------------------- 到達可能性の確認（シナリオ）

// P1 の背景にあるシナリオ: 作成者は別の部署では上長だが、一般メンバーとして所属する
// 部署宛てに申請しているため、その部署の上長による承認を待つしかない。
run crossAffiliatedAuthorCannotSelfApprove {
  some u: User, r: Request {
    r.author = u
    u.roles[r.target] = Member
    Manager in u.roles[Department]
    eventually (u -> r in submits)
    eventually (r.status = Approved and not (u -> r in approves))
  }
} for 3 but exactly 2 Department, exactly 1 Request, 1..8 steps

// 作成者が申請先部署の上長である場合、自己決裁は正当に行える。
run selfApprovalIsAllowed {
  some u: User, r: Request {
    r.author = u
    u in managers[r.target]
    eventually (u -> r in approves)
  }
} for 3 but exactly 1 Request, 1..6 steps

// 一通りの往復: 提出 → 差し戻し → 編集 → 再提出 → 承認。
run returnAndResubmitRoundTrip {
  some r: Request, m: User {
    eventually (r.author -> r in submits)
    eventually (m -> r in sendsBack)
    eventually (r.author -> r in edits)
    eventually (r.status = Approved)
  }
} for 3 but exactly 1 Request, exactly 2 Content, 1..10 steps
