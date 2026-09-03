include "Properties.dfy"

// ワークフローを可変なシステムとして表す: 1 つのディレクトリの下に、番号で識別される
// 稟議申請が複数ある。
//
// Approval.dfy は純粋で、遷移 1 回の意味を述べる。このモジュールは、CLI が動かす
// 命令的な外層である。要はクラス不変条件 `Valid()` で、すべてのメソッドがこれを
// requires し ensures する。だから検証器はメソッド呼び出しについての帰納で、
// どの長さ・どの順序の操作列でも、申請の作成者が申請先部署の外にいる状態や、
// 決裁済みの申請が変わる状態には到達できないことを検査する。これはモデル検査器が
// 列挙で行うのと同じ議論を、申請数とユーザー数に上限を置かずに果たしている。
module Workflow {
  import opened Approval
  import opened Properties

  type RequestId = nat

  class System {
    var directory: Directory
    var requests: map<RequestId, Request>
    var nextId: RequestId

    // ghost フィールドは実行時のコストがゼロで、仕様が過去について語れるようにする。
    // `history` は、モデル検査器が探索するのと同じ実行トレースである。
    ghost var history: seq<(RequestId, UserId, Command)>

    ghost predicate Valid()
      reads this
    {
      && (forall id <- requests.Keys :: id < nextId)
      && (forall id <- requests.Keys :: WellFormed(directory, requests[id]))
    }

    constructor (dir: Directory)
      ensures Valid()
      ensures directory == dir && requests == map[] && history == []
    {
      directory := dir;
      requests := map[];
      nextId := 0;
      history := [];
    }

    // アクション A。識別子は新規で、他の申請には触れない。拒否された場合はシステムを
    // 一切変えない。
    method Create(author: UserId, dep: DepartmentId, title: string, amount: int)
      returns (outcome: Outcome<RequestId>)
      requires Valid()
      modifies this
      ensures Valid()
      ensures directory == old(directory) && history == old(history)
      ensures outcome.Failure? ==> requests == old(requests)
      ensures outcome.Success? ==>
                && outcome.value !in old(requests)
                && requests.Keys == old(requests).Keys + {outcome.value}
                && requests[outcome.value].status.Draft?
                && requests[outcome.value].author == author
                && requests[outcome.value].department == dep
                && forall id <- old(requests).Keys :: requests[id] == old(requests)[id]
    {
      var request :- Approval.Create(directory, author, dep, title, amount);
      var id := nextId;
      requests := requests[id := request];
      nextId := nextId + 1;
      return Success(id);
    }

    // アクション B〜F を、任意のコマンドで駆動する。外の世界が試みうることはすべてここを
    // 通るので、システム全体としての P2 もこのメソッドの事後条件になる: コマンドが何であれ、
    // すでに決裁済みの申請はビット単位で変わらない。
    method Execute(actor: UserId, id: RequestId, cmd: Command)
      returns (outcome: Outcome<Request>)
      requires Valid()
      modifies this
      ensures Valid()
      ensures directory == old(directory) && requests.Keys == old(requests).Keys
      ensures outcome.Failure? ==> requests == old(requests) && history == old(history)
      ensures forall other <- requests.Keys ::
                other != id ==> requests[other] == old(requests)[other]
      ensures forall i <- old(requests).Keys ::
                Terminal(old(requests)[i].status) ==> requests[i] == old(requests)[i]
      ensures outcome.Success? ==>
                && id in requests
                && requests[id] == outcome.value
                && history == old(history) + [(id, actor, cmd)]
    {
      if id !in requests {
        return Failure(NoSuchRequest);
      }
      // `:-` は Outcome の IsFailure / PropagateFailure / Extract を使う。純粋なモデル側の
      // 拒否が、`match` なしでそのままこのメソッドの結果になる。
      var next :- Step(directory, actor, requests[id], cmd);
      requests := requests[id := next];
      history := history + [(id, actor, cmd)];
      return Success(next);
    }

    // 閲覧規則を、述語ではなく問い合わせとして表す（R1 と R2）。事後条件が、答えは
    // 閲覧可能な申請の集合そのものであると述べているので、絞り込みのバグは検証エラーになる。
    // ループにはそれ自身の不変条件と停止測度が必要である。
    method Readable(actor: UserId) returns (visible: set<RequestId>)
      requires Valid()
      ensures forall id <- visible :: id in requests && CanRead(directory, actor, requests[id])
      ensures forall id <- requests.Keys ::
                CanRead(directory, actor, requests[id]) ==> id in visible
    {
      visible := {};
      var remaining := requests.Keys;
      while remaining != {}
        invariant remaining <= requests.Keys
        invariant forall id <- visible :: id in requests && CanRead(directory, actor, requests[id])
        invariant forall id <- requests.Keys - remaining ::
                    CanRead(directory, actor, requests[id]) ==> id in visible
        decreases |remaining|
      {
        var id: RequestId :| id in remaining;
        if CanRead(directory, actor, requests[id]) {
          visible := visible + {id};
        }
        remaining := remaining - {id};
      }
    }

    // 保持されている申請に対する P3。ディレクトリの不変条件は `Valid()` を通して伝わるので、
    // システム内のどの申請も決裁者のいないまま行き詰まらない。
    lemma NoOrphanRequest(id: RequestId)
      requires Valid()
      requires id in requests && requests[id].status.Pending?
      ensures exists decider: UserId :: CanDecide(directory, decider, requests[id])
    {
      EveryPendingRequestHasADecider(directory, requests[id]);
    }
  }
}
