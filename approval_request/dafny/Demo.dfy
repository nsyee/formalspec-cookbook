include "Scenarios.dfy"

// モデルをプログラムとして見る: `dafny run` はこのファイルをコンパイルし、コマンドラインで
// 与えたコマンドをデモ組織に対して実行する。
//
// ここには仕様の一部は何もない——検証済みのモデルを端末から観察できるようにする
// 外層である。面白いのは、その接続部分も検証されていることだ: `Apply` はクラス不変条件を
// requires し保つので、フロントエンドがワークフローを、証明がカバーしていない状態に
// 追い込むことはできない。
//
//   $ ./scripts/dafny.py run approval_request/dafny \
//       'alice create sales laptop 1500' 'alice submit 0' 'bob approve 0'
module Demo {
  import opened Approval
  import opened Workflow
  import opened Scenarios

  // === 文字列の補助関数（検証済みなので、パーサーが範囲外を参照することはない）===

  function Split(s: string, sep: char): (parts: seq<string>)
    ensures |parts| >= 1
    decreases |s|
  {
    if s == [] then [""]
    else
      var rest := Split(s[1..], sep);
      if s[0] == sep then [""] + rest else [[s[0]] + rest[0]] + rest[1..]
  }

  // -1 は「十進数でない」を表す。こうしてパーサーを全域的に保つ。
  function ParseInt(s: string, acc: int := 0): int
    requires acc >= 0
    decreases |s|
  {
    if s == [] then acc
    else if '0' <= s[0] <= '9' then ParseInt(s[1..], acc * 10 + (s[0] as int - '0' as int))
    else -1
  }

  function IntToString(n: nat): string
    decreases n
  {
    if n < 10 then ['0' + n as char]
    else IntToString(n / 10) + ['0' + (n % 10) as char]
  }

  function ShowStatus(s: Status): string {
    match s
    case Draft => "Draft"
    case Pending => "Pending"
    case Returned(who) => "Returned(by " + who + ")"
    case Approved(who) => "Approved(by " + who + ")"
    case Rejected(who) => "Rejected(by " + who + ")"
  }

  function ShowRequest(r: Request): string {
    r.author + "@" + r.department + " " + ShowStatus(r.status)
    + " \"" + r.content.title + "\" " + IntToString(r.content.amount)
  }

  function ShowDenial(d: Denial): string {
    match d
    case NotAffiliated => "denied: NotAffiliated"
    case NotAuthor => "denied: NotAuthor"
    case NotManager => "denied: NotManager"
    case TerminalRequest => "denied: TerminalRequest"
    case WrongState => "denied: WrongState"
    case InvalidContent => "denied: InvalidContent"
    case NoSuchRequest => "denied: NoSuchRequest"
  }

  function ShowOutcome(outcome: Outcome<Request>): string {
    match outcome
    case Success(r) => ShowRequest(r)
    case Failure(d) => ShowDenial(d)
  }

  // === コマンド 1 行 ===

  // 受け付ける形式（引数 1 つにつき 1 行）:
  //   <actor> create <department> <title> <amount>
  //   <actor> edit <id> <title> <amount>
  //   <actor> submit|approve|reject|return <id>
  //   <actor> readable
  method Apply(system: System, line: string) returns (message: string)
    requires system.Valid()
    modifies system
    ensures system.Valid()
  {
    var words := Split(line, ' ');
    if |words| < 2 || words[0] == "" {
      return "usage: <actor> create|edit|submit|approve|reject|return|readable ...";
    }
    var actor: UserId := words[0];
    var verb := words[1];

    if verb == "create" {
      if |words| != 5 {
        return "usage: <actor> create <department> <title> <amount>";
      }
      if words[2] == "" {
        return ShowDenial(NotAffiliated);
      }
      var outcome := system.Create(actor, words[2], words[3], ParseInt(words[4]));
      return match outcome
             case Success(id) => "created #" + IntToString(id)
             case Failure(d) => ShowDenial(d);
    }

    if verb == "readable" {
      var visible := system.Readable(actor);
      var ids := "";
      var remaining := visible;
      while remaining != {}
        decreases |remaining|
      {
        var id: RequestId :| id in remaining;
        ids := ids + " #" + IntToString(id);
        remaining := remaining - {id};
      }
      return "readable:" + (if ids == "" then " none" else ids);
    }

    if |words| < 3 {
      return "usage: <actor> " + verb + " <id>";
    }
    var id := ParseInt(words[2]);
    if id < 0 {
      return "not a request id: " + words[2];
    }

    var command;
    if verb == "submit" {
      command := SubmitCommand;
    } else if verb == "approve" {
      command := ApproveCommand;
    } else if verb == "reject" {
      command := RejectCommand;
    } else if verb == "return" {
      command := ReturnCommand;
    } else if verb == "edit" {
      if |words| != 5 || words[3] == "" || ParseInt(words[4]) < 0 {
        return "usage: <actor> edit <id> <title> <amount>";
      }
      command := EditCommand(Content(AsTitle(words[3]), AsAmount(ParseInt(words[4]))));
    } else {
      return "unknown command: " + verb;
    }

    var outcome := system.Execute(actor, id, command);
    return ShowOutcome(outcome);
  }

  method Main(args: seq<string>) {
    var system := new System(DemoDirectory());
    print "directory: alice=sales(Member) bob=sales(Manager) ",
          "carol=sales(Member),eng(Manager) dave=eng(Member)\n";
    var lines := if |args| > 1 then args[1..] else DefaultSession();
    for i := 0 to |lines|
      invariant system.Valid()
    {
      var message := Apply(system, lines[i]);
      print lines[i], "\n  -> ", message, "\n";
    }
  }

  function DefaultSession(): seq<string> {
    ["alice create sales laptop 1500",
     "alice submit 0",
     "carol approve 0", // P1: carol は eng の上長で、sales の上長ではない
     "bob return 0",
     "alice submit 0",
     "bob approve 0",
     "bob reject 0", // P2: 決裁は終局的である
     "dave readable"] // R2: dave は sales に所属していない
  }
}
