----------------------------- MODULE MCScenarios -----------------------------
(***************************************************************************)
(* 到達可能性（vacuity）の確認用モデル。                                     *)
(*                                                                         *)
(* 不変条件がすべて成り立つのは、モデルが空（＝制約を書きすぎて何も起こらない） *)
(* からでもあり得る。そこで「起こってほしいシナリオ」の否定を不変条件として与  *)
(* え、*反例が出ること* を期待する。TLC が返す反例はそのシナリオの実行トレース *)
(* そのものなので、Alloy の run コマンドに相当する使い方になる。              *)
(*                                                                         *)
(* シナリオは複数の遷移にまたがるため、履歴変数 log（起きたアクションの列）を   *)
(* この検証用モジュールでだけ追加する。仕様本体 Approval.tla は変更しない       *)
(* ——「補助変数を加えても元の仕様の振る舞いは変わらない」という TLA+ の        *)
(* 定石で、log を隠せば SSpec は Spec に一致する。                            *)
(***************************************************************************)
EXTENDS Approval, Integers, Sequences

CONSTANT MaxLog        \* 探索する実行トレースの長さの上限（有界検証）

VARIABLE log           \* 起きたアクションの列（履歴変数）

SVars == <<role, req, event, log>>

SInit == Init /\ log = << >>

SNext ==
    /\ Next
    /\ log' = IF vars' = vars THEN log ELSE Append(log, event')

SSpec == SInit /\ [][SNext]_SVars

\* 状態空間を有限に保つための制約（CONSTRAINT として使う）。
LogIsBounded == Len(log) =< MaxLog

------------------------------------------------------------------------------

\* kinds に並べた種類のアクションが、申請 r に対してこの順で（間に何が挟まっても
\* よい）起きたか。列に対する再帰定義。
RECURSIVE HappenedInOrder(_, _, _)
HappenedInOrder(kinds, r, from) ==
    IF kinds = << >>
    THEN TRUE
    ELSE \E i \in from..Len(log) :
            /\ log[i].kind = Head(kinds)
            /\ log[i].req = r
            /\ HappenedInOrder(Tail(kinds), r, i + 1)

DidTo(kind, u, r) == \E i \in 1..Len(log) : log[i] = [kind |-> kind, by |-> u, req |-> r]

------------------------------------------------------------------------------
(***************************************************************************)
(* シナリオ 1: 自己決裁。作成者が申請先部署の上長であれば、自分の申請を自分で  *)
(* 承認できる（spec.md §4 D の注記）。                                       *)
(***************************************************************************)
SelfApprovalHappens ==
    \E r \in Live :
        /\ IsManager(req[r].author, req[r].target)
        /\ DidTo("Approve", req[r].author, r)

SelfApprovalIsImpossible == ~SelfApprovalHappens

(***************************************************************************)
(* シナリオ 2: P1 の背景。作成者は別部署では上長だが、申請先部署では一般メンバ *)
(* ーなので、自分では承認できず他の上長の承認を待つしかない。                 *)
(***************************************************************************)
CrossAffiliatedApprovalHappens ==
    \E r \in Live, u \in User :
        LET a == req[r].author
        IN /\ RoleOf(a, req[r].target) = "Member"
           /\ \E d \in Affiliations(a) : IsManager(a, d)   \* 別部署では上長
           /\ u # a
           /\ DidTo("Approve", u, r)

CrossAffiliatedApprovalIsImpossible == ~CrossAffiliatedApprovalHappens

(***************************************************************************)
(* シナリオ 3: 一通りの往復。提出 → 差し戻し → 編集 → 再提出 → 承認。        *)
(***************************************************************************)
RoundTripHappens ==
    \E r \in Request :
        HappenedInOrder(<<"Submit", "Return", "Edit", "Submit", "Approve">>, r, 1)

RoundTripIsImpossible == ~RoundTripHappens

==============================================================================
