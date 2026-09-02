include "Properties.dfy"

// The workflow as a mutable system: many requests, identified by a number,
// under one directory.
//
// Approval.dfy is pure and says what a single transition means; this module
// is the imperative shell that the CLI drives. Its point is the class
// invariant `Valid()`: every method requires it and ensures it, so the
// verifier checks by induction over method calls that no sequence of
// operations -- of any length, in any order -- can reach a state where a
// request has an author outside its target department or a decided request
// changes. That is the same argument a model checker makes by enumeration,
// discharged here for an unbounded number of requests and users.
module Workflow {
  import opened Approval
  import opened Properties

  type RequestId = nat

  class System {
    var directory: Directory
    var requests: map<RequestId, Request>
    var nextId: RequestId

    // A ghost field costs nothing at run time and lets the specification talk
    // about the past: `history` is the trace the model checkers explore.
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

    // Requirement A. The identifier is fresh, no other request is touched,
    // and a refusal leaves the system alone.
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

    // Requirements B-F, driven by an arbitrary command. Everything the
    // outside world may attempt goes through here, which is why the
    // system-wide form of P2 is a postcondition of this method: whatever the
    // command, a request that was already decided is bit-for-bit unchanged.
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
      // `:-` uses Outcome's IsFailure/PropagateFailure/Extract: a denial from
      // the pure model becomes this method's result without a `match`.
      var next :- Step(directory, actor, requests[id], cmd);
      requests := requests[id := next];
      history := history + [(id, actor, cmd)];
      return Success(next);
    }

    // The read rule as a query rather than a predicate (R1 and R2): the
    // postconditions say the answer is exactly the readable set, so a
    // filtering bug is a verification error. The loop needs its own
    // invariants and a termination measure.
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

    // P3 for the stored requests: the directory invariant travels through
    // `Valid()`, so no request in the system is stuck without a decider.
    lemma NoOrphanRequest(id: RequestId)
      requires Valid()
      requires id in requests && requests[id].status.Pending?
      ensures exists decider: UserId :: CanDecide(directory, decider, requests[id])
    {
      EveryPendingRequestHasADecider(directory, requests[id]);
    }
  }
}
