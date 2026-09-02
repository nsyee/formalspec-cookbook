# 稟議申請システム — Lean 4 モデル

- 仕様本体（Lake プロジェクト）: [`Approval/`](Approval/)
  - [`Basic.lean`](Approval/Basic.lean) — 役職・状態・申請・所属ディレクトリ（§1, §2）
  - [`Permission.lean`](Approval/Permission.lean) — 閲覧・編集権限（§3）
  - [`Step.lean`](Approval/Step.lean) — アクションと遷移関係 `Step`、到達可能性 `Reachable`、実行可能な `Action.apply` とその健全性・完全性（§4）
  - [`Properties.lean`](Approval/Properties.lean) — P1 / P2 / P3 と関連する不変条件の定理（§5）
  - [`Scenario.lean`](Approval/Scenario.lean) / [`Examples.lean`](Approval/Examples.lean) — 具体的な組織とシナリオ（`decide` / `#guard` でコンパイル時検査）
- 監査スクリプト: [`Audit.lean`](Audit.lean)（`#print axioms`）、CLI: [`Main.lean`](Main.lean)
- 対象仕様: [`../spec.md`](../spec.md)
- ツール: [Lean 4](https://lean-lang.org/)（[`lean-toolchain`](lean-toolchain) に固定、Mathlib なし）。`lake` が `PATH` / `~/.elan` に無ければ [elan](https://github.com/leanprover/elan) が `.tools/elan/` へインストールされ、ツールチェーンは初回実行時に取得される。

## CLI での実行

```console
$ make verify-lean                                   # このリポジトリの全 Lean 検査を実行
$ ./scripts/lean.py verify approval_request/lean
ok   build   8 modules checked, no sorry (9.3s)
ok   axioms  14 theorems audited, axioms used: propext (0.2s)
ok   run     5/5 scenarios passed (0.1s)

3/3 checks passed
```

| 検査 | コマンド | 検査するもの |
| --- | --- | --- |
| `build` | `lake build` | 全定義が型検査を通り、全 `theorem` / `example` の証明が完成していること（`#guard` によるシナリオのコンパイル時評価を含む）。`sorry` を含む宣言は警告として出るので失敗にする |
| `axioms` | `lake env lean Audit.lean` | 主要な定理が依存する公理の一覧。`sorryAx` が現れないこと、標準公理（`propext` / `Classical.choice` / `Quot.sound`）以外を使っていないこと |
| `run` | `lake exe approval` | シナリオを実行し、各ステップの結果（遷移先の状態、または拒否理由）が期待値と一致すること。トレースを人間が読める形で表示する |

その他のサブコマンド:

```console
$ ./scripts/lean.py checks approval_request/lean                     # 検査一覧
$ ./scripts/lean.py verify approval_request/lean --only axioms       # 1 検査だけ実行
$ ./scripts/lean.py trace approval_request/lean --only axioms        # 出力を全文表示
$ ./scripts/lean.py run approval_request/lean --list                 # シナリオ一覧
$ ./scripts/lean.py run approval_request/lean cross-affiliation      # 名前を指定して再生
$ ./scripts/lean.py lake approval_request/lean build                 # lake をそのまま呼ぶ（管理下のツールチェーンで）
```

### シナリオの再生

```console
$ ./scripts/lean.py run approval_request/lean cross-affiliation
== cross-affiliation: carol (eng manager, sales member) cannot use her eng authority on a sales request (P1)
     initial: Draft (author carol, target sales)
  ok   [Draft] carol submit: -> Pending
  ok   [Pending] carol approve: denied: not a manager of the target department
  ok   [Pending] carol return: denied: not a manager of the target department
  ok   [Pending] alice edit: denied: not a manager of the target department
  ok   [Pending] bob approve: -> Approved
     passed (5 steps)

1/1 scenarios passed
```

シナリオを動かしているのは `Action.apply`（関数）だが、`Action.apply_ok_iff` によって `apply` が成功すること ⇔ `Step` の証明が存在すること、が証明されている。したがって CLI が表示するトレースは、そのまま遷移関係 `Step` についての事実になる。

## モデルの構造

| 仕様 (`spec.md`) | モデル上の表現 |
| --- | --- |
| ユーザー / 部署 | 型パラメータ `U` / `D`（`DecidableEq` のみ要求）。定理は任意の `U` `D` について成り立つ |
| 所属と役職 `(ユーザー, 部署) -> 役職` | `Directory.role : U → D → Option Role`。`none` が未所属。`IsManager dir u d := dir.role u d = some .manager` が **唯一の権限概念** |
| 各部署に上長 1 名以上（P3 の前提） | `Directory.WF`（`Prop` 値の `structure`）。定理の仮定として明示的に受け取る |
| 稟議申請 | `structure Request` （`author` `target` `status`）。`Reachable` により「所属ユーザーが作成し、正当な `Step` だけで進んだ申請」を帰納的に定義 |
| 状態と終端 | `inductive Status` と `Status.IsTerminal` / `Status.Submittable`（`abbrev` で `Decidable` を自動導出） |
| 閲覧・編集権限 | `Directory.CanRead` / `Directory.CanEdit`（`Prop`、決定可能）。U2 は「他の節が無い」ことであり、定理 `IsMember.not_canEdit` として証明 |
| アクションと事前条件 | `inductive Step dir actor : Action → Request → Request → Prop`。コンストラクタの引数が事前条件そのもの。D / E / F は `Decision` でパラメータ化した 1 つのコンストラクタ `decide` |
| 事後条件 | コンストラクタの結論 `{ r with status := … }` |
| 実行 | `Action.apply : Action → Request → Except Denial Request`。拒否理由は `Denial`（`notAuthor` / `notManager` / `wrongState`）。`apply_sound` / `apply_complete` で `Step` と一致 |

## 証明した性質（`Properties.lean`）

| 定理 | 内容 |
| --- | --- |
| `Step.author_eq` / `Step.target_eq` | どのアクションも作成者と申請先を変えない |
| `Step.not_terminal` | 遷移元は必ず非終端 |
| `P2_terminal_stuck` / `P2_terminal_status_fixed` | **P2**: 終端状態の申請にはいかなるアクションも適用できない（したがって状態も変わらない） |
| `approved_by_target_manager` | 非 `Approved` から `Approved` へ遷移させた実行者は申請先部署の上長 |
| `decision_by_target_manager` | 承認・却下・差し戻しの実行者は常に申請先部署の上長 |
| `P1_no_authority_leak` | **P1**: 部署 X の上長で申請先部署 Y の一般メンバーであるユーザーは、Y 宛ての申請（自分のものを含む）を決裁できない |
| `P1_no_edit_leak` | 同じユーザーは他人の Y 宛て申請を編集もできない（U2） |
| `self_approval_allowed` | 自己決裁は許可される（作成者かどうかは無関係で、申請先での役職のみで決まる） |
| `Reachable.author_affiliated` | 不変条件: システム内の申請の作成者は申請先部署に所属している |
| `Reachable.approved_inversion` | `Approved` な申請は `Pending` だったものを申請先上長が承認したものであり、それ以外は変わっていない |
| `P3_manager_exists` / `P3_pending_decidable` | **P3**: `WF` な組織では、どの申請にも申請先の上長が存在し、`Pending` なら承認・却下・差し戻しの各操作を実際に行える |
| `stuck_iff_terminal` | `WF` な組織では「誰も何もできない」⇔「終端状態」 |
| `Action.apply_ok_iff` / `Step.unique` | 実行可能意味論と関係的意味論の一致、および決定性 |

`Examples.lean` では 3 人 2 部署の具体的な組織（carol は eng の上長かつ sales の一般メンバー）に対し、`decide` で個別のステップの可否を確定し、5 つのシナリオを `#guard` でコンパイル時に評価している。

## Lean 4 らしさとして意識した点

- **帰納的述語としての遷移関係**: `Step` の値は「その遷移が正当であることの証明」そのもの。`Step.decide d hmanager hs` を作るには上長であることと `Pending` であることの証拠が要り、検査は不要になる。
- **`cases` による網羅性の強制**: P1 / P2 の証明は `cases h` でアクションを場合分けする。将来 `forceApprove` のようなアクションを `Step` に追加すると、性質の証明が「パターンが網羅的でない」としてコンパイルエラーになり、仕様変更が既存の保証を壊していないかを機械的に確認できる。
- **有限スコープに依存しない証明**: Alloy / TLA+ / Quint が「ユーザー 3 人・部署 2 つ」のようなスコープで反例を探すのに対し、`Properties.lean` の定理は任意の型 `U` `D`、任意の `Directory` について成り立つ。組織の大きさに関する仮定はない。
- **関係と関数の二重化とその一致証明**: 証明しやすい関係 `Step` と、実行できる関数 `Action.apply` を両方書き、`apply_ok_iff` で一致させる。これにより `decide` タクティク（カーネルが `apply` を評価する）で具体例を確定でき、CLI の出力も定理の対象になる。`Step` の `Decidable` インスタンスもこの一致から得ている。
- **`Prop` 値の構造体で不変条件を表す**: `Directory.WF` は組織の健全性（各部署に上長）を `Prop` の `structure` として持ち、必要な定理（P3）だけがそれを仮定として受け取る。P1 / P2 のように組織構造に依存しない性質は無条件に成り立つことが型から読める。
- **`abbrev` と `DecidableEq` の導出で決定可能性を無料で得る**: `IsTerminal` や `CanEdit` を `abbrev` で論理結合子と等式に展開できる形で定義しているため、`Decidable` インスタンスは自動的に見つかり、`if dir.CanEdit actor r then …` と直接書ける。
- **決裁のパラメータ化**: 承認・却下・差し戻しは事前条件が同一で結果だけ違うので、`Decision` とその `outcome` で 1 つのコンストラクタにまとめた。証明も 1 ケースで済み、「決裁の実行者は申請先上長」（`decision_by_target_manager`）が 3 つの操作について一度に得られる。
- **到達可能性の帰納的定義**: `Reachable` により「作成 → 正当な遷移の列」を帰納的に定義し、`induction` でトレース不変条件（`author_affiliated`）を、`cases` で逆方向の推論（`approved_inversion`: 承認済なら直前は Pending で、承認者は上長）を証明している。
- **公理の監査**: `#print axioms` で各定理が依存する公理を出力し、`sorryAx`（未完成の証明）が無いこと、`propext` 以外の公理を使っていないことを CI で確認する。証明の完成度が「ビルドが通る」以上の形で可視化される。

## 他の言語との対比

| 観点 | Alloy / TLA+ / Quint | Cedar | Souther | Lean 4 |
| --- | --- | --- | --- | --- |
| 検証の方法 | 状態空間の探索（有界・網羅・記号） | 認可判定のテストと SymCC（SMT）による含意 | 型検査 + コンパイル時に評価される例 | 定理証明（`cases` / `induction`）+ `decide` による具体例の評価 |
| 保証の範囲 | スコープ内の全状態・全トレース | 全エンティティストア上の全リクエスト | 書いた例（網羅性を機械的に測る） | 任意のユーザー・部署・組織構成（無限を含む） |
| 反例 | ツールが自動で探索・提示 | テストの失敗 | 例の不一致 | 出ない。証明が書けないことで気づく（具体例は `decide` で確認） |
| 遷移の事前条件 | アクションのガード | 適用範囲外 | 入力型 + `guard` | コンストラクタの引数（証拠） |
| 実行 | シミュレーション / 反例トレース | `cedar authorize` | `souther run` | `lake exe approval`（`apply` は `Step` と一致することが証明済） |
| 活性・時相性質 | ○（TLA+/Quint） | – | – | 本モデルでは扱わない（`stuck_iff_terminal` が「終端以外では必ず誰かが動ける」という弱い形を与える） |

Lean 4 は反例を自動で見つけてはくれないため、仕様の探索や「こんな振る舞いがあり得るか」の確認は Alloy / TLA+ / Quint 版に向く。
一方、証明された性質はスコープに依存しない普遍的な保証であり、`Step` に変更を加えると影響する証明がコンパイルエラーとして即座に浮上する点が、他の言語には無い強みである。
