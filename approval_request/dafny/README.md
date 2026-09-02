# 稟議申請システム — Dafny モデル

- モデル本体: [`Approval.dfy`](Approval.dfy)（型・権限述語・遷移）
- 性質の証明: [`Properties.dfy`](Properties.dfy)（P1〜P3 と 3 章の権限規則）
- 可変システム: [`Workflow.dfy`](Workflow.dfy)（クラス不変条件つきの `System` クラス）
- シナリオ: [`Scenarios.dfy`](Scenarios.dfy)（`dafny test` が実行する `{:test}` メソッド）
- 実行可能フロントエンド: [`Demo.dfy`](Demo.dfy)（`Main` — コマンド行を受け取って実行）
- 「通ってはならない」検査: [`negative/`](negative/)（検証が失敗することを CI で確認する）
- 検査一覧: [`checks.json`](checks.json)
- 対象仕様: [`../spec.md`](../spec.md)
- ツール: [Dafny](https://dafny.org/) 4.11.0（`dafny format` / `verify` / `test` / `run`）。Z3 を同梱した自己完結リリースが初回実行時に `.tools/dafny-4.11.0/` へダウンロードされる。コンパイルは Python バックエンド（`--target=py`）を使うので、必要なのはこのスクリプトを動かす Python 3 だけ（.NET SDK は不要）。

## CLI での実行

```console
$ make verify-dafny                                # このリポジトリの全 Dafny 検査を実行
$ ./scripts/dafny.py verify approval_request/dafny
ok   format                              canonically formatted (1.6s)
ok   verify                              65 proof obligation group(s) verified (4.0s)
ok   tests                               8/8 scenarios passed, 10 proof obligation group(s) verified (2.4s)
ok   run                                 7 proof obligation group(s) verified, 18 line(s) of output (1.6s)
ok   negative-authority-leak             as expected, 1 verification error(s), 0 verified (1.0s)
ok   negative-directory-without-manager  as expected, 2 verification error(s), 0 verified (1.0s)
ok   negative-author-edits-pending       as expected, 1 verification error(s), 0 verified (0.9s)

7/7 checks passed
```

| 検査 | コマンド | 検査するもの |
| --- | --- | --- |
| `format` | `dafny format --check` | 全 `.dfy` が正規形で書かれていること |
| `verify` | `dafny verify` | 型検査・全 `requires` / `ensures` / ループ不変条件・クラス不変条件・`Properties.dfy` の補題がすべて証明されること |
| `tests` | `dafny test --target=py` | `{:test}` メソッド（仕様の表をなぞったシナリオ）が Python にコンパイルされて実際に走り、`expect` が成り立つこと |
| `run` | `dafny run --target=py` | モデルが実行可能であること（既定セッションを最後まで流す） |
| `negative-*` | `dafny verify`（失敗を期待） | 「成り立ってはならない主張」が実際に証明できないこと |

その他のサブコマンド:

```console
$ ./scripts/dafny.py checks approval_request/dafny                      # 検査一覧
$ ./scripts/dafny.py verify approval_request/dafny --only verify        # 1 検査だけ実行
$ ./scripts/dafny.py trace approval_request/dafny --only tests          # 出力を全文表示（反例つき）
$ ./scripts/dafny.py dafny -- --version                                 # Dafny CLI をそのまま呼ぶ
```

### モデルを実行する

`Demo.dfy` の `Main` はコマンド行を 1 引数につき 1 つ受け取り、デモ組織（alice=sales の Member、bob=sales の Manager、carol=sales の Member かつ eng の Manager、dave=eng の Member）に対して順に適用する。

```console
$ ./scripts/dafny.py run approval_request/dafny \
    'alice create sales laptop 1500' 'alice submit 0' 'carol approve 0' 'bob approve 0'
directory: alice=sales(Member) bob=sales(Manager) carol=sales(Member),eng(Manager) dave=eng(Member)
alice create sales laptop 1500
  -> created #0
alice submit 0
  -> alice@sales Pending "laptop" 1500
carol approve 0
  -> denied: NotManager
bob approve 0
  -> alice@sales Approved(by bob) "laptop" 1500
```

引数を省略すると、P1（carol の越権が拒否される）・P2（承認後の却下が拒否される）・R2（dave には見えない）を含む既定セッションが流れる。
受け付ける形式は `<actor> create <department> <title> <amount>` / `<actor> edit <id> <title> <amount>` / `<actor> submit|approve|reject|return <id>` / `<actor> readable`。

## モデルの構造

| 仕様 (`spec.md`) | モデル上の表現 |
| --- | --- |
| ユーザー / 部署 | 部分型 `UserId` / `DepartmentId`（`s != ""` を型の制約に持つ `string`） |
| 所属と役職 `(ユーザー, 部署) -> 役職` | `type Assignment = map<(UserId, DepartmentId), Role>`。キーが組なので「1 つの所属に 1 つの役職」は構造から従い、不変条件を書く必要がない |
| 各部署に上長 1 名以上（P3 の前提） | 部分型 `Directory = a: Assignment \| DepartmentsHaveManagers(a) witness ...`。**型に制約が入る**ので、以降どの述語・どの遷移もこの前提を再掲しない |
| 稟議申請の状態 | `datatype Status = Draft \| Pending \| Returned(returnedBy) \| Approved(approvedBy) \| Rejected(rejectedBy)`。決裁者はその決裁を記録するケースだけが持つ |
| 状態遷移図 | 各遷移が `requires` を持つ全域関数。`Approve` は `requires CanDecide(...)`（= `Pending` かつ申請先部署の上長）なので、Draft への承認は「実行時に拒否される呼び出し」ではなく **検証が通らないプログラム** |
| 事後条件 | 関数の `ensures`。`Edit` は `ensures Edit(...) == r.(content := content)`、`Approve` は `ensures ....status == Approved(actor)` |
| 閲覧・編集・提出・決裁の権限 | 述語 `CanRead` / `CanEdit` / `CanSubmit` / `CanDecide`。U2 は「3 つ目の選言がないこと」として表れる |
| 外部からの任意の (状態, コマンド) | `Step(dir, actor, request, command): Outcome<Request>`。失敗互換型（`IsFailure` / `PropagateFailure` / `Extract`）なので、呼び出し側は `var next :- Step(...)` で拒否を伝播できる |
| 複数申請を持つシステム | `Workflow.System` クラス。`Valid()` を全メソッドが `requires` かつ `ensures` するので、**任意の長さ・任意の順序の操作列**に対して不変条件が帰納法で保たれる。`ghost var history` が探索器のトレースに相当する |
| 検証したい性質 P1〜P3 | `Properties.dfy` の補題。全ユーザー・全部署・全トレースについての定理で、スコープ（ユーザー数や手数の上限）を持たない |
| シナリオ検証 | `Scenarios.dfy` の `{:test}` メソッド。証明済みの規則を具体的な人名で読めるようにするための表 |

## Dafny らしさとして意識した点

- **不変条件を型の制約にする**: 「各部署に上長が 1 名以上」は `Directory` という部分型の制約であり、`witness` によって型が空でないことも検査される。この型の値を受け取る述語・遷移・クラスは前提を書き直す必要がなく、P3 の証明は「制約が約束する上長に名前を付ける」だけで終わる（`EveryPendingRequestHasADecider`）。`Title`（非空）と `Amount`（非負）も同様に部分型。
- **事前条件で不正な遷移を消す**: 他言語版では「Draft を承認しようとしたら拒否される」という**振る舞い**を書くが、Dafny では `Approve` の `requires` が呼び出し側で証明されるため、その呼び出しは存在し得ない。だから「Draft は承認できない」という補題は書いていない（書くことがない）。代わりに外界からの任意入力を受ける `Step` にだけ定理を置く。
- **証明はスコープを持たない**: `TerminalRequestsAreFrozen` は「任意の長さのトレース `events` について、決裁済みの申請は不変」を `|events|` に関する帰納法で証明する（P2）。TLA+/Quint の有界モデル検査に対応する部分が、ここでは無限の状態空間に対する定理になる。
- **クラス不変条件 + `modifies` で可変状態を扱う**: `System` の各メソッドは `requires Valid()` / `ensures Valid()` を持ち、フレーム条件（`modifies this`）と事後条件（他の申請は変わらない、決裁済みの申請はビット単位で不変）を宣言する。検証器がメソッド呼び出しに関する帰納法を回すので、システム全体の安全性が操作列の列挙なしに得られる。
- **ghost で仕様専用の状態を持つ**: `history` と `Valid()` は `ghost`。コンパイル後のコードには存在しないが、`Scenarios.dfy` の `assert system.history == [...]` のように仕様の側からは参照できる。実行時コストゼロで「トレースについての主張」が書ける。
- **失敗互換型と `:-`**: 拒否は例外ではなく `Outcome` の `Failure` ケース。`IsFailure` / `PropagateFailure` / `Extract` を実装しているので、`Workflow` は `var next :- Step(...)` と書いて拒否をそのまま呼び出し元へ返す。純粋なモデルと命令的なシェルの境目が 1 行で済む。
- **`calc` と補題呼び出しで人が読める証明を書く**: `PendingRequestsCanBeDecided` は P3 の存在証明から決裁者を取り出し（`var decider :| ...`）、`calc` で `Run(dir, r, [e])` を 1 手ずつ展開して終端状態に到達することを示す。モデル検査器の活性（fairness つき liveness）に対応する主張を、反例探索ではなく計算として書いた形。
- **反証も CI に載せる**: Dafny は「証明できない」ことを CI で表明する手段を持たないので、`negative/` に**通ってはならない主張**を置き、`checks.json` の `"expect": "violation"` で検証失敗を要求している（Quint の fairness なし liveness や Cedar の反例チェックと同じ役割）。`CanEdit` を誤って広げると `negative-author-edits-pending` が通ってしまい、CI が落ちる。
- **仕様がそのまま動く**: `dafny test` は `{:test}` メソッドを Python にコンパイルして実行し、`dafny run` は `Main` を実行する。証明・テスト・参照実装が同じ 1 つのソースから出てくる。

## 他の言語との対比

| 観点 | Alloy / TLA+ / Quint | Cedar | Souther | Dafny |
| --- | --- | --- | --- | --- |
| 検証の方法 | 有界・網羅・記号的な状態空間探索 | 認可テストと SymCC（SMT）による含意 | 型検査 + コンパイル時に評価される例 | SMT による演繹的証明（`requires` / `ensures` / 不変条件） |
| 保証の範囲 | スコープ内の全状態・全トレース | 全エンティティストア上の全リクエスト | 書いた例（網羅性は機械的に測る） | 型の全値・全操作列（スコープなし） |
| 不正な状態の扱い | 不変条件で禁じる | スキーマで型付け | 状態ごとの型で表現不可能にする | 部分型の制約とデータ型のケースで表現不可能にする |
| 遷移の事前条件 | アクションのガード | 適用範囲外 | 振る舞いの入力型 | 関数の `requires`（呼び出し側で証明される） |
| 反例 | トレース | SMT の反例 | 失敗した例の行 | 検証エラー + 反例モデル（`negative/` で常設） |
| 活性・到達可能性 | 時相論理式 | 適用範囲外 | 扱わない | 存在命題として証明（`PendingRequestsCanBeDecided`） |
| 実行 | シミュレーション | `cedar authorize` | `souther run` | `dafny run` / `dafny test`（Python にコンパイル） |

Dafny は時相論理を持たないため、「公平性の仮定がないと決裁されないトレースが存在する」といった性質は TLA+/Quint 版に委ねる。
一方、状態空間の大きさに依存せず（ユーザー数・部署数・手数に上限を置かず）安全性と権限規則を証明でき、しかも同じソースが実行可能な実装になる点が、このお題における Dafny の立ち位置。
