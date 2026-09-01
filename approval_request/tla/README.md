# 稟議申請システム — TLA+ モデル

- 仕様本体: [`Approval.tla`](Approval.tla)
- 検証用モジュール: [`MCApproval.tla`](MCApproval.tla)（スコープ・対称性）, [`MCScenarios.tla`](MCScenarios.tla)（履歴変数を足したシナリオ探索）
- 対象仕様: [`../spec.md`](../spec.md)
- ツール: TLA+ Tools 1.7.4（TLC / SANY）。Java 11 以降と Python 3.8 以降があれば、初回実行時に `.tools/` へ自動ダウンロードされる（`.gitignore` 済み）。

## CLI での実行

```console
$ make verify-tla                              # リポジトリ内の全 TLC モデルを検証
$ ./scripts/tla.py verify approval_request/tla
ok   MCActions                   32,977 distinct states (2s)
ok   MCLiveness                  1,559 distinct states (1s)
ok   MCLivenessNoFairness        Temporal properties were violated (1s)
ok   MCSafety                    69,502 distinct states (2s)
ok   MCScenarioCrossAffiliation  Invariant CrossAffiliatedApprovalIsImpossible is violated (1s)
ok   MCScenarioRoundTrip         Invariant RoundTripIsImpossible is violated (3s)
ok   MCScenarioSelfApproval      Invariant SelfApprovalIsImpossible is violated (1s)

7/7 models as expected
```

その他のサブコマンド:

```console
$ ./scripts/tla.py models approval_request/tla                            # モデル一覧
$ ./scripts/tla.py verify approval_request/tla --only MCSafety            # 1 モデルだけ検証
$ ./scripts/tla.py trace approval_request/tla/MCScenarioRoundTrip.cfg     # TLC の出力（反例トレース）を全文表示
$ ./scripts/tla.py parse approval_request/tla/Approval.tla                # SANY で構文・意味検査だけ行う
```

## モデル（`.cfg`）の構成

TLA+ では「仕様」と「検査するモデル（スコープ・検査対象）」が分かれる。1 つのモジュールを複数の `.cfg` から使い回せるので、
検査の目的ごとにモデルを分けてある。各 `.cfg` の先頭にはドライバ用のディレクティブを書く。

```
\* module: MCApproval
\* expect: counterexample   \* 既定は ok（TLC がエラーを出さないこと）
```

| モデル | 仕様式 | 検査するもの | 期待 |
| --- | --- | --- | --- |
| [`MCSafety`](MCSafety.cfg) | `Spec` | 不変条件（P1 / P3 / R2 / U2 / 型） | エラーなし |
| [`MCActions`](MCActions.cfg) | `Spec` | アクション性質（状態遷移図・P2・決裁者） | エラーなし |
| [`MCLiveness`](MCLiveness.cfg) | `FairSpec` | 活性（`Pending` は必ず決裁される） | エラーなし |
| [`MCLivenessNoFairness`](MCLivenessNoFairness.cfg) | `Spec` | 進行仮定を外すと活性が破れること | **反例** |
| [`MCScenarioSelfApproval`](MCScenarioSelfApproval.cfg) | `SSpec` | 自己決裁が起こり得ること | **反例** |
| [`MCScenarioCrossAffiliation`](MCScenarioCrossAffiliation.cfg) | `SSpec` | 兼務ユーザーが他の上長に承認されるシナリオ | **反例** |
| [`MCScenarioRoundTrip`](MCScenarioRoundTrip.cfg) | `SSpec` | 提出→差し戻し→編集→再提出→承認の往復 | **反例** |

「**反例**」を期待するモデルは、Alloy の `run`（想定シナリオが到達可能であることの確認）に対応する。
TLA+/TLC には `run` に当たる機能がないので、**シナリオの否定を不変条件として与え、TLC が返す反例をシナリオの実行トレースとして読む**。
`verify` は「反例が出るはずのモデルで反例が出なかった」場合も失敗にするため、`INVARIANT` を書きすぎてモデルが空になる vacuity をそのまま検出できる（CI ゲートとして利用）。

## モデルの構造

| 仕様 (`spec.md`) | モデル上の表現 |
| --- | --- |
| 部署 / ユーザー / 申請 / 内容 | 定数集合 `Department`, `User`, `Request`, `Revision`（`.cfg` で模型値を与える） |
| 所属と役職 | `role \in [User -> Affiliation]`。`Affiliation == UNION { [S -> Role] : S \in SUBSET Department \ {{}} }` — 「所属部署 → 役職」の *部分関数*。定義域が所属部署そのものなので、兼務も「非所属」も番兵なしに表せる |
| 各部署に上長 1 名以上 | `EveryDepartmentIsManaged`（`Init` の条件かつ不変条件） |
| 稟議申請 | `req \in [Request -> RequestRecord \cup {Nil}]`。`RequestRecord == [author: User, target: Department, status: Status, revision: Revision]`、未作成は `Nil` |
| 状態 | 文字列集合 `Status` と `Terminal == {"Approved", "Rejected"}` |
| 閲覧・編集・決裁権限 | `CanRead` / `CanEdit` / `CanDecide`。状態遷移を伴わない述語なので、アクションの事前条件と検証式の双方から再利用する |
| アクション A〜F | `Create` / `Edit` / `Submit` / `Decide`（`Approve`・`Reject`・`Return` は `Decide` の特化）|
| P1 / P2 / P3 | `DecisionRightsDependOnTargetRoleOnly`, `TerminalDecidedByTargetManager`, `TerminalRequestsAreFrozen`, `NoOrphanRequest` |

## TLA+ らしさとして意識した点

- **仕様は 1 つの論理式**: `Spec == Init /\ [][Next]_vars`。検査器の都合（スコープ・対称性・状態制約）は `MCApproval.tla` と `.cfg` に押し出し、仕様本体は数学だけにする。
- **部分関数で「所属」を表す**: `DOMAIN role[u]` がそのまま所属部署の集合になる。`Role` に `"None"` のような番兵を混ぜないので、「他部署での役職」と「非所属」を取り違える余地がない（非所属時の `RoleOf` は `Role` の外の値 `"Outsider"` を返す）。
- **`EXCEPT` によるレコードフィールドの局所更新**: `[req EXCEPT ![r].status = "Pending"]` のように「申請 r の status だけ差し替える」と書ける。フレーム条件は残りの変数の `UNCHANGED` で明示する。
- **アクションのパラメータ化と `\E` による量化**: `Decide(u, r, s)` を定義し、`Next` で `\E u \in User, r \in Request, s \in Decision : Decide(u, r, s)` と量化する。承認・却下・差し戻しは「決裁後の状態 s が違うだけ」という仕様の構造がそのまま出る。
- **履歴変数 `event` によるイベントの可視化**: 直前のアクション（種類・実行者・対象）を状態に持たせる。TLC の反例トレースが「誰が何をしたか」の並びとして読めるようになり、`TerminalDecidedByTargetManager` のように **実行者に言及する性質** をアクション性質として書ける。
- **安全性・アクション性質・活性の書き分け**:
  - 状態述語は `INVARIANT`（P1、P3 など）。
  - 遷移の制約は `[][A]_vars` 形のアクション性質。許される状態遷移を **順序対の集合** `StatusTransition` として与え、それ以外の変化が起きないことを主張する（spec.md §2 の図がほぼそのまま式になる）。
  - 活性は `~>`（leads-to）。上長が決裁を先延ばしにする振る舞いも `Spec` は許すので、`FairSpec` で弱公平性 `WF_vars(\E u, s : Decide(u, r, s))` を仮定して検証する。仮定が本当に必要なことは `MCLivenessNoFairness`（反例を期待するモデル）で示す。
- **初期状態の非決定性で構造を全探索**: 役職の割り当ては時間で変化しないが、定数にしてしまうと 1 通りしか検査できない。`Init` で `role \in [User -> Affiliation]` と非決定的に選び、各アクションで `UNCHANGED role` とすることで、**すべての兼務パターン**を探索する（P1 は兼務パターンに依存する性質なので、ここが本質）。
- **対称性による状態空間の削減**: ユーザー・部署・申請・内容は互換な模型値なので `SYMMETRY Permutations(...)` で商をとる。不変条件の検査では健全だが活性では使えないため、`.cfg` を分けている。
- **補助変数の追加はモジュールを分けて行う**: シナリオ（複数遷移にまたがる到達可能性）の確認には履歴が必要なので、`MCScenarios.tla` で `log`（アクションの列）を追加した `SSpec` を定義する。仕様本体は触らない。`log` を隠せば `SSpec` は `Spec` と同じ振る舞いを表す、という TLA+ の定石。
- **`CONSTRAINT` で状態空間を有界化**: `log` を足すと状態空間が無限になるので、`LogIsBounded == Len(log) =< MaxLog` を状態制約として与える（`MaxLog` は `.cfg` のパラメータ）。
- **`RECURSIVE` による列の走査**: 「この順にアクションが起きた」を `HappenedInOrder(<<"Submit", "Return", "Edit", "Submit", "Approve">>, r, 1)` と書けるよう、列に対する再帰演算子を定義する。TLA+ には過去時相演算子がないため、履歴を明示的に持って一階の論理で書くのが定石。
- **デッドロック検査を活かす**: すべての申請が終端に達した状態だけは `Done` として明示的に stutter させる。こうしておくと、TLC の既定のデッドロック検査が「意図しない行き止まり（どのアクションも実行できない状態）」の検出器として機能する。

## Alloy 6 との対比

| 観点 | Alloy 6 ([`../alloy/approval.als`](../alloy/approval.als)) | TLA+ ([`Approval.tla`](Approval.tla)) |
| --- | --- | --- |
| 状態の表現 | シグネチャの可変フィールド `var status: lone Status` | 状態変数 `req` に対する関数（`[Request -> RequestRecord \cup {Nil}]`） |
| 構造 | 三項関係 `roles: User -> Department -> lone Role` | 関数の関数 `role \in [User -> Affiliation]`（`Affiliation` は部分関数の集合） |
| 「未作成」 | `no r.status`（部分関数） | 番兵 `Nil` |
| フレーム条件 | `pred onlyChanges[r]`（明示的に「r 以外は不変」） | `UNCHANGED` 句 + `EXCEPT` による局所更新 |
| 検証の指定 | モデル内の `check` / `run` コマンド + スコープ (`for 4 but 1..10 steps`) | モジュール外の `.cfg`（`INVARIANT` / `PROPERTIES` / `CONSTANTS` / `SYMMETRY` / `CONSTRAINT`） |
| 探索の仕組み | SAT による有界モデル発見（反例そのものを探す） | 明示的状態列挙（BFS）。到達可能な状態を全て構成する |
| 有界性の出方 | 原子数と `steps` を必ず与える | 定数集合の大きさを与える。トレース長は無制限（状態が有限なら全探索できる） |
| 過去への言及 | 過去時相演算子 `once` がある | 過去演算子はないので履歴変数を足す（`MCScenarios.tla` の `log`） |
| シナリオの到達可能性 | `run` コマンド（インスタンスを探す） | 否定を `INVARIANT` として与え、反例を得る |
| 活性 | `assert ... implies always ...` + 進行仮定の述語 | `WF_vars` / `SF_vars` を仕様式に入れ、`~>` を `PROPERTY` として検査 |

## 検証結果（既定スコープ）

7 モデルすべてが期待どおり（全体で 10 秒程度）。既定スコープはユーザー 3・部署 2・申請 1〜2・内容 2 で、
`MCSafety` は対称性による商をとって約 7 万状態を全探索する。

有界検証であるため、定数集合を大きくすれば新たな反例が出る可能性は残る。P1 は「部署 2 つ・ユーザー 3 人」で
兼務パターンが出そろうため、既定スコープで本質的な範囲を覆っている。
