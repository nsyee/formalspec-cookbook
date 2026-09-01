# 稟議申請システム — Quint モデル

- 仕様本体: [`approval.qnt`](approval.qnt)
- 検証用モデル / シナリオテスト: [`models.qnt`](models.qnt)
- 検査一覧: [`checks.json`](checks.json)
- 対象仕様: [`../spec.md`](../spec.md)
- ツール: Quint 0.32.0（型検査・シミュレーション・`quint test`）、バックエンドとして Apalache 0.56 と TLC。Node.js 18 以降と Java 17 以降があれば、Quint CLI は初回実行時に `.tools/` へ、Apalache と TLC は Quint 自身によって `~/.quint/` へダウンロードされる。

## CLI での実行

```console
$ make verify-quint                              # このリポジトリの全 Quint 検査を実行
$ ./scripts/quint.py verify approval_request/quint
ok   tests                 13 passing (1s)
ok   safety                no violation, 32977 distinct states (7s)
ok   safety-symbolic       no violation (9s)
ok   liveness              no violation, 27,734 distinct states (9s)
ok   liveness-no-fairness  violation found, 32,977 distinct states (8s)
ok   simulation            no violation, 500 traces (15s)

6/6 checks as expected
```

その他のサブコマンド:

```console
$ ./scripts/quint.py checks approval_request/quint                          # 検査一覧
$ ./scripts/quint.py verify approval_request/quint --only safety             # 1 検査だけ実行
$ ./scripts/quint.py trace approval_request/quint --only liveness-no-fairness # 出力（反例トレース）を全文表示
$ ./scripts/quint.py typecheck approval_request/quint/models.qnt             # 型検査・効果検査だけ行う
```

## 検査（`checks.json`）の構成

Quint は 1 つの CLI に「テスト実行」「ランダムシミュレーション」「網羅検証」が入っているため、
TLA+ の `.cfg` に当たるものはスコープではなく **どのサブコマンドをどのモジュールに対して回すか** になる。
それを宣言的に並べたのが `checks.json` で、`expect: violation` は「反例が出なければ失敗」を意味する。

| 検査 | コマンド | 対象モジュール | 検査するもの | 期待 |
| --- | --- | --- | --- | --- |
| `tests` | `quint test` | `scenarios` | 13 本のシナリオ（正常系・往復・自己決裁・兼務・権限・終端） | 全件 pass |
| `safety` | `quint verify --backend=tlc` | `smallModel` | 不変条件（P1 / P2 / P3 / R2 / U2 / 状態遷移図） | 反例なし |
| `safety-symbolic` | `quint verify --backend=apalache` | `smallModel` | 同じ不変条件を SMT で 8 ステップまで記号的に | 反例なし |
| `liveness` | `quint verify --backend=tlc` | `smallModel` | 進行仮定の下での活性（`Pending` は必ず決裁される） | 反例なし |
| `liveness-no-fairness` | `quint verify --backend=tlc` | `smallModel` | 進行仮定を外すと活性が破れること | **反例** |
| `simulation` | `quint run` | `simulatedModel` | 申請 2 件のランダム実行 500 本で不変条件を破らないこと + 4 つの証人への到達 | 反例なし・全証人が観測される |

バックエンドの使い分け:

- `quint verify --backend=apalache` は SMT による有界記号検証。ステップ数を切るため、深いトレースは見ない代わりに状態爆発に強い。
- `quint verify --backend=tlc` は明示的状態列挙。時相性質（活性）を検査できるのは現状こちらだけで、Apalache は公平性を含む式に対して "Handling fairness is not supported yet!" を返す。
- `quint test` / `quint run` の評価器は TypeScript 版を使う（`--backend=typescript`）。Rust 評価器は初回起動時に GitHub Releases から実行ファイルを取得するため、外向き通信が制限された環境では動かない。`QUINT_BACKEND` 環境変数で切り替えられる。

## モデルの構造

| 仕様 (`spec.md`) | モデル上の表現 |
| --- | --- |
| 部署 / ユーザー / 申請 / 内容 | モジュール引数の定数集合 `USERS`, `DEPTS`, `IDS`, `CONTENTS`（`models.qnt` でインスタンス化） |
| 所属と役職 | `var roles: UserName -> (Dept -> Standing)`。`Standing = Outsider \| Holds(Role)` — 「非所属」が型の一部なので、番兵の文字列を `Role` に混ぜずに済む |
| 各部署に上長 1 名以上 | `isWellFormed`（`init` の条件かつ不変条件 `orgChartIsWellFormed`） |
| 稟議申請 | `var requests: ReqId -> Request`。「まだ存在しない申請」はキーの不在で表す（`live == requests.keys()`） |
| 状態 | 直和型 `Status`、`isTerminal`、遷移関係 `canFollow` |
| 閲覧・編集・決裁権限 | `def canRead` / `canEdit` / `canSubmit` / `canDecide`。状態を読むだけの純粋な述語なので、アクションの事前条件と検証式の双方から再利用する |
| アクション A〜F | `action create` / `edit` / `submit` / `decide`（`approve`・`reject`・`returnBack` は `decide` の特化） |
| P1 / P2 / P3 | `decisionRightsDependOnTargetRoleOnly`, `terminalRequestsAreFrozen`, `noOrphanRequest`, `eventsAreAuthorized`, `statusFollowsStateMachine` |
| 活性 | `temporal liveness == decisionsAreFair implies pendingIsEventuallyDecided` |

## Quint らしさとして意識した点

- **直和型で状態と役職を表す**: `type Status = Draft | Pending | ...`、`type Standing = Outsider | Holds(Role)`。TLA+ の `TypeOK` に当たる不変条件は要らず、型検査器が静的に弾く。`match` は網羅性を要求するので、状態を増やせば `canFollow` の抜けがコンパイル時に分かる。
- **`def` と `action` の区別を言語が強制する**: 権限述語は状態を読むだけなので `def`、状態を変えるものだけ `action`。効果検査（effect checker）があるため、不変条件の中でうっかりアクションを呼ぶとエラーになる（実際 `terminalRequestsAreFrozen` を最初にアクションで書いて弾かれた）。おかげで「事前条件を述語として切り出し、アクションと性質の両方から使う」という書き方が自然に導かれる。
- **`nondet` + `any` によるアクションの非決定性**: TLA+ の `\E u \in User, s \in Decision : Decide(u, r, s)` を、「値を選ぶ」`nondet u = oneOf(USERS)` と「アクションを選ぶ」`any { ... }` に分けて書く。値の選択とアクションの選択が構文的に区別される。
- **`.with` / `.put` / `.set` による局所更新**: `requests.set(id, requestOf(id).with("status", Pending))` のように、TLA+ の `EXCEPT` に当たる更新を通常の関数呼び出しで書ける。フレーム条件は `roles' = roles` として明示する。
- **`Map` のキーの不在で「未作成」を表す**: `Nil` のような番兵が不要。`live` はそのまま `requests.keys()`。
- **履歴変数 + 直和型でイベントを構造化**: `type Event = Created({by, id}) | Decided({by, id, into}) | ...`。TLA+ ではレコードのフィールドに文字列を入れていた部分が型で表せる。実行者に言及する性質（`decisionsAreMadeByTargetManagers`）を、次状態演算子を使わない **状態述語** として書けるので、シミュレーションでも Apalache でもそのまま検査できる。
- **モジュール引数によるスコープ指定**: 定数はモジュールの引数なので、検証スコープの指定が型の付いた Quint のコードになる（`models.qnt`）。`.cfg` のような別言語のファイルが要らず、スコープ違いのモデルを 1 ファイルに並べられる。
- **`run` による実行可能なシナリオテスト**: `setup(orgChart).then(create(...)).expect(...)` と手順をそのまま書ける。TLA+ では「シナリオの否定を不変条件にして反例を読む」という間接的な方法をとったが、Quint では **想定手順が動くこと** を直接テストできる。`action.fail()` を使えば「起こってはいけない遷移が存在しないこと」も同じ記法で書ける。
- **証人（`--witnesses`）でシミュレーションの質を測る**: ランダム探索が本当に面白い状態（自己決裁、上長による他人の申請の編集、差し戻し、両申請の終端到達）に届いたかを、トレース本数として報告させる。`scripts/quint.py` は 1 本も観測されなかった証人があれば失敗にするので、モデルが痩せて振る舞いが失われた場合を CI で検出できる。
- **初期状態の非決定性で兼務パターンを全探索**: `nondet chart = oneOf(wellFormedOrgCharts)` として `setOfMaps` で作った全域写像の集合から選ぶ。P1 は兼務パターンに依存する性質なので、ここが本質。決め打ちの組織図が必要なテストのために `setup(chart)` を分けてある。
- **`weakFair` は式として書く**: TLA+ が仕様式に `WF_vars(...)` を織り込むのに対し、Quint では `temporal decisionsAreFair = IDS.forall(id => weakFair(decideSomehow(id), vars))` と独立した式にでき、`decisionsAreFair implies pendingIsEventuallyDecided` のように含意として組める。進行仮定の付け外しがモジュールの複製なしにできる。

## TLA+ との対比

| 観点 | TLA+ ([`../tla/Approval.tla`](../tla/Approval.tla)) | Quint ([`approval.qnt`](approval.qnt)) |
| --- | --- | --- |
| 状態・役職の表現 | 文字列の集合 + `TypeOK` による実行時検査 | 直和型 + 静的な型検査 |
| 「非所属」 | 部分関数の定義域外（`RoleOf` は `"Outsider"` を返す） | `Standing` の構成子 `Outsider` |
| 「未作成の申請」 | 番兵 `Nil` | `Map` のキーの不在 |
| 純粋な述語とアクションの区別 | 慣習（プライムを使わなければ述語） | 言語仕様（`def` / `action` と効果検査） |
| 状態の更新 | `[req EXCEPT ![r].status = "Pending"]` | `requests.set(id, r.with("status", Pending))` |
| 非決定性 | 論理の `\E` | `nondet` / `oneOf`（値）と `any`（アクション） |
| 検証スコープの指定 | 別ファイルの `.cfg`（`CONSTANTS` / `INVARIANT` / `SYMMETRY`） | モジュール引数によるインスタンス化 + `checks.json` |
| シナリオの到達可能性 | 否定を `INVARIANT` にして反例を読む | `run` テスト（手順を実行）と `--witnesses`（証人の観測） |
| ランダム探索 | なし（TLC は網羅探索） | `quint run` によるシミュレーション（大きなスコープでも回る） |
| 記号的検証 | なし（TLC は明示的状態列挙） | `quint verify --backend=apalache`（SMT） |
| 網羅検証 | TLC | `quint verify --backend=tlc`（Quint を TLA+ に変換して TLC を呼ぶ） |
| 公平性 | 仕様式に `WF_vars` を織り込み、モデルを分ける | `weakFair` を式として書き、含意で組む（ただし現状 TLC バックエンド限定） |
| 過去への言及 | 履歴変数（過去時相演算子はない） | 同じく履歴変数。直和型で構造を型付けできる |
| 対称性による削減 | `SYMMETRY Permutations(...)` | 相当する指定はない（その代わりシミュレーションと記号検証がある） |

## 検証結果（既定スコープ）

6 検査すべてが期待どおり（全体で 50 秒程度）。
`safety` は既定スコープ（ユーザー 3・部署 2・申請 1・内容 2）で約 33,000 状態を全探索し、
`safety-symbolic` は同じスコープを 8 ステップまで記号的に検証する。
`simulation` は申請 2 件のスコープでランダムに 500 本のトレースを回し、4 つの証人すべてに到達する。

有界検証であるため、定数集合を大きくすれば新たな反例が出る可能性は残る。
TLA+ 版と同じ理由で、P1 については既定スコープで本質的な範囲を覆っている。
