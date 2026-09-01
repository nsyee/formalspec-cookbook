------------------------------- MODULE Approval -------------------------------
(***************************************************************************)
(* 稟議申請システム（兼務を前提としたワークフローと権限モデル）の TLA+ 仕様。  *)
(*                                                                         *)
(* 自然言語での仕様は ../spec.md を参照。                                    *)
(*                                                                         *)
(* モデル化の方針:                                                          *)
(*   - 役職は (ユーザー, 部署) の組に対して定義されるため、ユーザーごとに      *)
(*     「所属する部署 -> 役職」の *部分関数* を割り当てる。定義域が所属部署の  *)
(*     集合そのものになるので、兼務も「所属していない」も追加の番兵なしに表せる。*)
(*   - 申請の識別子は静的な集合 Request として与え、「まだ存在しない申請」は    *)
(*     req[r] = Nil で表す。作成もひとつの遷移として観測できる。              *)
(*   - 各アクションは現在と次の状態を関係づけるアクション（プライム付きの式）と *)
(*     して書き、Next でまとめる。仕様全体は Init /\ [][Next]_vars の形。      *)
(*   - 直前に起きたアクションを履歴変数 event に残す。エラートレースが読みやす *)
(*     くなるうえ、「誰の操作で状態が変わったか」をアクション性質として書ける。  *)
(***************************************************************************)
EXTENDS FiniteSets

CONSTANTS
    User,        \* ユーザーの集合
    Department,  \* 部署の集合
    Request,     \* 稟議申請の識別子の集合（静的なプール）
    Revision,    \* 申請の内容。中身は問わない不透明な値（編集は値の差し替え）
    Nil          \* 「その申請はまだ存在しない」ことを表す値

Role == {"Member", "Manager"}

Status == {"Draft", "Pending", "Returned", "Approved", "Rejected"}

\* spec.md §2 で終端と定義されている状態。
Terminal == {"Approved", "Rejected"}

\* 上長が Pending の申請に対して下せる決裁（承認・却下・差し戻し）。
Decision == {"Approved", "Rejected", "Returned"}

\* 状態を持つ（＝作成済みの）申請の値。
RequestRecord == [author: User, target: Department, status: Status, revision: Revision]

(***************************************************************************)
(* 所属と役職。空でない部署集合を定義域とする関数の全体を、部署集合ごとの関数  *)
(* 集合の合併として作る。「1 つ以上の部署に所属する」が定義域の非空性として、  *)
(* 「1 部署につき役職はひとつ」が関数性として、それぞれ構造で保証される。      *)
(***************************************************************************)
Affiliation == UNION { [S -> Role] : S \in (SUBSET Department \ {{}}) }

ASSUME /\ User # {} /\ Department # {} /\ Request # {} /\ Revision # {}
       /\ Nil \notin RequestRecord

\* 履歴変数 event が取り得る値。初期状態だけは実行者を持たない。
Event ==
    [kind: {"Init"}]
        \cup [kind: {"Create", "Edit", "Submit", "Approve", "Reject", "Return"},
              by: User, req: Request]

VARIABLES
    role,   \* [User -> Affiliation]  静的な構造。Init で非決定的に選ぶ
    req,    \* [Request -> RequestRecord \cup {Nil}]
    event   \* 直前に起きたアクション（履歴変数）

vars == <<role, req, event>>

TypeOK ==
    /\ role \in [User -> Affiliation]
    /\ req \in [Request -> RequestRecord \cup {Nil}]
    /\ event \in Event

------------------------------------------------------------------------------
(***************************************************************************)
(* 静的な構造についての補助定義                                             *)
(***************************************************************************)

Affiliations(u) == DOMAIN role[u]

\* 所属していない部署では役職を持たない。Role の外の値を返すので、他部署での
\* 役職と混同されることがない。
RoleOf(u, d) == IF d \in Affiliations(u) THEN role[u][d] ELSE "Outsider"

IsManager(u, d) == RoleOf(u, d) = "Manager"

Managers(d) == {u \in User : IsManager(u, d)}

Members(d) == {u \in User : RoleOf(u, d) = "Member"}

\* 各部署には必ず 1 名以上の上長が存在する（P3 の前提となる不変条件）。
EveryDepartmentIsManaged == \A d \in Department : Managers(d) # {}

------------------------------------------------------------------------------
(***************************************************************************)
(* 申請の状態についての補助定義                                             *)
(***************************************************************************)

\* 現時点でシステム上に存在する（作成済みの）申請。
Live == {r \in Request : req[r] # Nil}

\* 未作成の申請にも使える status。Status の外の値を返す。
StatusOf(r) == IF req[r] = Nil THEN "Absent" ELSE req[r].status

------------------------------------------------------------------------------
(***************************************************************************)
(* アクセス制御（spec.md §3）                                               *)
(*                                                                         *)
(* 権限は状態遷移を伴わない、現在の状態についての述語である。そのためアクション*)
(* の事前条件としても、検証したい性質の主題としても再利用できる。             *)
(***************************************************************************)

\* R1, R2: 申請先部署に所属しているかどうかだけで決まる。
CanRead(u, r) ==
    /\ r \in Live
    /\ req[r].target \in Affiliations(u)

CanEdit(u, r) ==
    /\ r \in Live
    /\ \/ /\ u = req[r].author                            \* U1（U2 は U1 に該当しないことから従う）
          /\ req[r].status \in {"Draft", "Returned"}
       \/ /\ IsManager(u, req[r].target)                  \* U3
          /\ req[r].status \in {"Draft", "Returned", "Pending"}

\* 承認・却下・差し戻しの事前条件は共通で、「*申請先部署の* 上長であること」。
\* 自己決裁は仕様どおり許可される（spec.md §4 D）。
CanDecide(u, r) ==
    /\ r \in Live
    /\ req[r].status = "Pending"
    /\ IsManager(u, req[r].target)

------------------------------------------------------------------------------
(***************************************************************************)
(* アクションと状態遷移（spec.md §4）                                        *)
(***************************************************************************)

\* 履歴変数の更新。アクションごとに書くのはこれだけ。
Log(kind, u, r) == event' = [kind |-> kind, by |-> u, req |-> r]

\* A. 申請の作成。ユーザー u が自分の所属部署 d 宛ての申請 r を内容 v で作る。
Create(u, d, v, r) ==
    /\ req[r] = Nil
    /\ d \in Affiliations(u)
    /\ req' = [req EXCEPT ![r] = [author |-> u, target |-> d,
                                  status |-> "Draft", revision |-> v]]
    /\ Log("Create", u, r)
    /\ UNCHANGED role

\* B. 申請の編集。内容が別の値に差し替わる。状態は変化しない。
Edit(u, r, v) ==
    /\ CanEdit(u, r)
    /\ v # req[r].revision
    /\ req' = [req EXCEPT ![r].revision = v]
    /\ Log("Edit", u, r)
    /\ UNCHANGED role

\* C. 申請の提出 / 再提出。
Submit(u, r) ==
    /\ r \in Live
    /\ u = req[r].author
    /\ req[r].status \in {"Draft", "Returned"}
    /\ req' = [req EXCEPT ![r].status = "Pending"]
    /\ Log("Submit", u, r)
    /\ UNCHANGED role

\* D/E/F. 上長による決裁。承認・却下・差し戻しは決裁後の状態 s だけが異なる。
Decide(u, r, s) ==
    /\ CanDecide(u, r)
    /\ s \in Decision
    /\ req' = [req EXCEPT ![r].status = s]
    /\ Log(CASE s = "Approved" -> "Approve"
             [] s = "Rejected" -> "Reject"
             [] OTHER          -> "Return", u, r)
    /\ UNCHANGED role

Approve(u, r) == Decide(u, r, "Approved")
Reject(u, r)  == Decide(u, r, "Rejected")
Return(u, r)  == Decide(u, r, "Returned")

\* すべての申請が終端に達したら、それ以上の遷移はない。ここで明示的に停止させて
\* おくことで、TLC のデッドロック検査を「意図しない行き止まり」の検出に使える。
Done ==
    /\ \A r \in Request : StatusOf(r) \in Terminal
    /\ UNCHANGED vars

Next ==
    \/ \E u \in User, d \in Department, v \in Revision, r \in Request : Create(u, d, v, r)
    \/ \E u \in User, r \in Request, v \in Revision : Edit(u, r, v)
    \/ \E u \in User, r \in Request : Submit(u, r)
    \/ \E u \in User, r \in Request, s \in Decision : Decide(u, r, s)
    \/ Done

Init ==
    /\ role \in [User -> Affiliation]   \* 所属と役職のあらゆる組み合わせを探索する
    /\ EveryDepartmentIsManaged
    /\ req = [r \in Request |-> Nil]
    /\ event = [kind |-> "Init"]

Spec == Init /\ [][Next]_vars

\* 活性（liveness）の検証用。決裁できる上長は永遠に放置しない、という進行仮定を
\* 弱公平性として置く。安全性の検証にはこの仮定は不要なので Spec と分けている。
FairSpec ==
    /\ Spec
    /\ \A r \in Request : WF_vars(\E u \in User, s \in Decision : Decide(u, r, s))

------------------------------------------------------------------------------
(***************************************************************************)
(* 検証したい性質（spec.md §5）                                             *)
(*                                                                         *)
(* 状態述語（INVARIANT）／アクション性質（[][A]_vars）／時相性質（~>）を書き   *)
(* 分ける。TLA+ では「不変条件」も「遷移の制約」も同じ論理の中で表現できる。   *)
(***************************************************************************)

\* 構造の健全性: 申請先部署は作成者の所属部署である（spec.md §1）。
TargetIsAuthorsDepartment ==
    \A r \in Live : req[r].target \in Affiliations(req[r].author)

\* P1 兼務ユーザーの権限分離: 決裁可否は申請先部署での役職のみで決まる。すなわち
\* 申請先部署での役職が等しい 2 ユーザーの決裁権限は、他部署での役職に関係なく
\* 常に一致する。
DecisionRightsDependOnTargetRoleOnly ==
    \A u1, u2 \in User, r \in Live :
        RoleOf(u1, req[r].target) = RoleOf(u2, req[r].target)
            => (CanDecide(u1, r) <=> CanDecide(u2, r))

\* P3 迷子申請の不在: 存在する申請には常に決裁できる上長が 1 名以上いる。
NoOrphanRequest == \A r \in Live : Managers(req[r].target) # {}

\* R2: 所属していない部署宛ての申請は一切閲覧できない。
ReadsRequireAffiliation ==
    \A u \in User, r \in Live : CanRead(u, r) => req[r].target \in Affiliations(u)

\* U2: 申請先部署の一般メンバーは、他人が作成した申請を編集できない。
PlainMembersCannotEditOthersRequests ==
    \A r \in Live :
        \A u \in Members(req[r].target) \ {req[r].author} : ~CanEdit(u, r)

Safety ==
    /\ TypeOK
    /\ EveryDepartmentIsManaged
    /\ TargetIsAuthorsDepartment
    /\ DecisionRightsDependOnTargetRoleOnly
    /\ NoOrphanRequest
    /\ ReadsRequireAffiliation
    /\ PlainMembersCannotEditOthersRequests

------------------------------------------------------------------------------
(***************************************************************************)
(* アクション性質                                                           *)
(***************************************************************************)

\* P2 終端状態の不変性: Approved / Rejected になった申請は、状態も内容も二度と
\* 変化しない（終端では編集権限も持たないので、内容の不変性まで主張できる）。
TerminalRequestsAreFrozen ==
    [][\A r \in Request : StatusOf(r) \in Terminal => req'[r] = req[r]]_vars

\* spec.md §2 の状態遷移図。許される遷移を関係（順序対の集合）として与え、
\* それ以外の状態変化が起きないことをアクション性質として主張する。
StatusTransition ==
    {<<"Absent", "Draft">>, <<"Draft", "Pending">>, <<"Returned", "Pending">>,
     <<"Pending", "Approved">>, <<"Pending", "Rejected">>, <<"Pending", "Returned">>}

StatusFollowsStateMachine ==
    [][\A r \in Request :
          LET from == StatusOf(r)
              to   == StatusOf(r)'
          IN from # to => <<from, to>> \in StatusTransition]_vars

\* P1（遷移レベル）: 申請が終端状態に至るのは、申請先部署の上長による承認・却下
\* のときだけである。履歴変数 event により「その遷移を起こした実行者」を参照する。
TerminalDecidedByTargetManager ==
    [][\A r \in Request :
          (StatusOf(r) \notin Terminal /\ StatusOf(r)' \in Terminal)
              => /\ event'.kind \in {"Approve", "Reject"}
                 /\ event'.req = r
                 /\ IsManager(event'.by, req[r].target)]_vars

\* 内容が変わるのは編集権限を持つ実行者による編集のときだけである（U1/U2/U3）。
ContentChangesNeedAuthorizedEditor ==
    [][\A r \in Live :
          req'[r] # Nil /\ req'[r].revision # req[r].revision
              => /\ event'.kind = "Edit"
                 /\ event'.req = r
                 /\ CanEdit(event'.by, r)]_vars

------------------------------------------------------------------------------
(***************************************************************************)
(* 時相性質（活性）                                                         *)
(***************************************************************************)

\* 進行仮定（FairSpec）の下では、提出された申請が永遠に承認待ちのままになること
\* はない。安全性の仕様 Spec の下では成り立たないので、仕様を分けて検証する。
PendingIsEventuallyDecided ==
    \A r \in Request : (StatusOf(r) = "Pending") ~> (StatusOf(r) # "Pending")

\* 決裁は最終的に終端状態へ落ち着く（差し戻しは Pending を出るだけで終端でない）。
EveryRequestIsEventuallyClosed ==
    \A r \in Request : (StatusOf(r) = "Pending") ~> (StatusOf(r) \in Terminal \/ StatusOf(r) = "Returned")

==============================================================================
