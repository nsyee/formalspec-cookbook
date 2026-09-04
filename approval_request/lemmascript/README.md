# 稟議申請システム — LemmaScript モデル

[`../spec.md`](../spec.md) を [LemmaScript](https://lemmascript.org/) で書いたモデル。LemmaScript は注釈つきの TypeScript で、
`lsc` が Dafny にコンパイルし、Dafny 上で検証する。プログラム（`approval.ts`）はそのまま動く TypeScript モジュール、
`//@ requires` / `//@ ensures` / `//@ invariant` の注釈が仕様、証明義務は生成されたコードに対して Dafny が解く。
したがって同じ 1 つのソースが、実行可能な参照実装（`scenarios.ts` が Node.js で実行する）であると同時に、権限規則と
P1〜P3 の証明されたモデルになる。

後半では、TypeScript を経由せずに同じ性質を証明している直接 Dafny 版のモデル [`../dafny/`](../dafny/) と比較する。

| ファイル | 役割 |
| --- | --- |
| `approval.ts` | モデル本体: 名簿、状態、権限規則、遷移、トレース、`Workflow` クラス——契約つき |
| `approval.dfy.gen` | `lsc gen` が生成した Dafny。**手で編集しない**。`approval.ts` から再生成される |
| `approval.dfy` | 証明所有のコピー: `approval.dfy.gen` に *追記だけ* をしたもの——ループ不変条件、`modifies`、P1〜P3 の補題 |
| `scenarios.ts` | `spec.md` の表を、検証したものと同じ TypeScript で Node.js 上で実行する |
| `negative/*.dfy` | 検証を通っては**ならない**主張。CI は失敗することを要求する |
| `checks.json` | `scripts/lemmascript.py` と CI が実行する検査の一覧 |

## CLI での実行

必要なもの: Python 3.11 以上、Node.js 22.18 以上または 24 以上（npm 込み。`scenarios.ts` は組み込みの型注釈除去に依存する）、
Dafny 4.11.0。ドライバーは `scripts/dafny.py` を通じて Dafny を `.tools/dafny-4.11.0/` にダウンロードし、初回に LemmaScript
CLI（`lemmascript@0.6.1`）を `.tools/lemmascript/` に npm でインストールする（そのバージョンの `lsc` が `PATH` 上にある、
または `LSC_BIN` で指定されている場合は除く）。

```sh
$ make verify-lemmascript                                  # すべての */lemmascript ディレクトリ
$ ./scripts/lemmascript.py verify approval_request/lemmascript
ok   check                               approval.dfy.gen regenerated, 41 proof obligation group(s) verified (2.5s)
ok   scenarios                           8/8 scenarios passed (0.1s)
ok   negative-authority-leak             as expected, 1 verification error(s), 0 verified (1.3s)
ok   negative-directory-without-manager  as expected, 2 verification error(s), 0 verified (1.1s)
ok   negative-author-edits-pending       as expected, 1 verification error(s), 0 verified (1.1s)

5/5 checks passed
```

検査は `checks.json` から来る。`"kind": "check"` は `lsc check --backend=dafny` を実行し、`approval.dfy.gen` を再生成し、
`approval.dfy` がそれに対して追記のみであることを確認し、`approval.dfy` を検証する。コミットされている `approval.dfy.gen` が
古い場合はドライバーが失敗させる。`"kind": "run"` はシナリオを Node.js で実行する。`"kind": "verify"` はファイルに
`dafny verify` を実行し、`"expect": "violation"` は検証失敗を期待どおりの結果に変える。

```sh
$ ./scripts/lemmascript.py checks approval_request/lemmascript                     # 検査の一覧
$ ./scripts/lemmascript.py verify approval_request/lemmascript --only check        # 検査 1 つ
$ ./scripts/lemmascript.py trace  approval_request/lemmascript --only negative-authority-leak   # Dafny の出力全体
$ ./scripts/lemmascript.py run    approval_request/lemmascript                     # シナリオを詳細表示つきで
$ ./scripts/lemmascript.py lsc -- version                                          # LemmaScript CLI そのもの
$ ./scripts/lemmascript.py dafny -- verify approval_request/lemmascript/approval.dfy
```

### モデルを編集するとき

`approval.dfy` には証明の追記があるので、`approval.ts` を変更したあとに削除して再生成してはいけない。代わりに

```sh
$ ./scripts/lemmascript.py lsc -- regen --backend=dafny approval_request/lemmascript/approval.ts
```

を実行する。`approval.dfy.gen` を再生成し、追記を新しいコードへ 3-way マージする（マージに失敗すると `lsc regen` は
`approval.dfy.base` を残す。衝突を解消したら削除して再実行する）。証明の追記は `approval.dfy` だけに置く——生成された行を
変更・削除してはならず、`//@ assume` はどこにも使っていない。

## モデルの構造

| 仕様 (`spec.md`) | モデル上の表現 |
| --- | --- |
| ユーザー / 部署 | `type UserId = string`、`type DepartmentId = string`（別名。非空の制約はない。比較の節を参照） |
| 所属と役職 `(ユーザー, 部署) -> 役職` | `interface Directory { roles: Map<UserId, Map<DepartmentId, Role>> }`。ユーザーごとに部署から役職への写像。`Map` のキーは値を 1 つしか持てないので「1 つの所属に 1 つの役職」に不変条件は不要 |
| 各部署に上長 1 名以上（P3 の前提） | `hasManager` / `departmentsHaveManagers`: 本体がループの `//@ pure` 関数。Node.js で動き、`//@ ensures` の中でも使える。ループが一致すべき量化子は `approval.dfy` が与える |
| 稟議申請の状態 | discriminated union `Status = { kind: "Draft" } \| { kind: "Pending" } \| { kind: "Returned"; returnedBy } \| { kind: "Approved"; approvedBy } \| { kind: "Rejected"; rejectedBy }`。決裁者を持つのは決裁だけ |
| 状態遷移図 | `edit` / `submit` / `approve` / `reject` / `returnToAuthor`: `//@ requires canEdit(...)` などで守られた全域関数。「Draft を承認する」は実行時の拒否ではなく、検証が通らないプログラム |
| 事後条件 | `//@ ensures`——各遷移のフレーム（`\result.status === r.status && \result.author === r.author ...`） |
| 閲覧・編集・提出・決裁の権限 | `canRead` / `canEdit` / `canSubmit` / `canDecide`。それぞれ規則を固定する `//@ ensures` を持つ（`canDecide` ⇔ Pending ∧ *申請先*部署の上長）。U2 は「申請者でも上長でもなければ編集できない」という `ensures` |
| 外部からの任意の (状態, コマンド) | `step(dir, actor, r, cmd): Outcome`。`Outcome = Success \| Failure(denial)` で、`Denial` union が理由を名指しする。全域で、分類してから守られた遷移に委譲する |
| トレース | `run(dir, r, events)` が配列にわたって `step` を畳み込む。`//@ invariant` が `step` の 1 ステップの `ensures` を、任意のトレースに沿った同一性不変と P2 に持ち上げる |
| 複数申請を持つシステム | `class Workflow`、`requests: Map<number, Request>`。クラス不変条件（保存されたすべての申請が整合）は `open` と `apply` の `//@ requires` / `//@ ensures` として述べるので、任意の呼び出し列で保たれる |
| P1〜P3 | 1 ステップ版は `approval.ts` の `step` の `//@ ensures`。名前つきの定理（`NoAuthorityLeakAcrossDepartments`、`TerminalRequestsRejectEveryCommand`、`EveryPendingRequestHasADecider`、`PendingRequestsCanBeDecided`、`WorkflowHasNoOrphanedRequests`）は `approval.dfy` の証明追記 |
| シナリオ検証 | `scenarios.ts`: TypeScript そのものの名前つき実行 8 本（`node scenarios.ts`） |
| 意図 | 権限規則と遷移に付けた `//@ contract` の文——読者やエージェント向けの自然言語メタデータで、証明義務ではない |

### LemmaScript らしさとして意識した点

- **1 つのソース、2 人の読者。** `approval.ts` は `scenarios.ts` から無変更で import され Node.js で実行される。同じファイルを
  `lsc` がコンパイルし、その契約を Dafny が証明する。モデルと同期を取るべき参照実装は存在しない——モデル *が* 実装である。
- **discriminated union は Dafny の datatype になる。** `Status`、`Command`、`Outcome` は `{ kind: ... }` の union で、
  `datatype Status = Draft | Pending | Returned(returnedBy: UserId) | ...` になる。`switch (cmd.kind)` は `match` に、
  絞り込み（`if (outcome.kind === "Success") outcome.value`）は `Success?` で守られたデストラクタになる。
- **仕様が必要とするループには `//@ pure`。** `hasManager` と `departmentsHaveManagers` は `Map` を走査する。`//@ pure` を
  付けると Dafny の `function ... by method` として出力されるので、`//@ ensures` や P3 の補題から参照でき、Node.js は
  ループを実行する。
- **事前条件が権限を担う。** `approve` は `//@ requires canDecide(dir, actor, r)` を持つ。呼び出す側——`step` でも、将来
  別モジュールから呼ぶ誰かでも——が権限を確立しなければならず、Dafny がすべての呼び出し箇所でそれを検査する。`step` は
  権限を *仮定する* のではなく *検査する* 唯一の場所。
- **フレームを `ensures` で。** 各遷移は何が変わるかだけでなく何が変わらないか
  （`\result.author === r.author && \result.department === r.department && \result.content === r.content`）を述べる。
  これがあるから、モデル側に帰納法の議論を書かずに任意のトレースに沿った同一性不変が証明できる。
- **TLA+ ならモデル検査器に任せるところにループ不変条件。** `run` は `//@ invariant current.author === r.author` と
  `//@ invariant isTerminal(r.status) ==> current === r` を持ち、Dafny がそれを一度だけ、任意長のトレースと任意の大きさの
  名簿について証明する。
- **可変な外殻には契約つきクラス。** `Workflow.open` / `Workflow.apply` はストアの不変条件を
  `forall(id, this.requests.has(id) ==> wellFormed(this.directory, this.requests.get(id)))` として `requires` と `ensures`
  に述べる。ヒープ更新に Dafny が要求する `modifies this` 節は `approval.dfy` への 1 行の追記。
- **反証。** `negative/*.dfy` は `approval.dfy` を include し、失敗しなければならない主張を述べる: 他部署の上長による決裁
  （P1）、`departmentsHaveManagers` なしの P3、Draft の承認、申請者による Pending の編集（U1/U3）。`canEdit` を誤って広げると
  `negative-author-edits-pending` が通ってしまい、CI が落ちる。

## 直接 Dafny 版（`../dafny/`）との比較

どちらのモデルも同じ主張を証明する——P1、P2（1 ステップと任意のトレース）、P3（決裁者の存在と終端後続状態の存在）、権限規則
R/U/C/D〜F、同一性不変、整合性の保存——そしてどちらもスコープを持たない: 任意のユーザー数・部署数・手数について成り立つ。
どちらも `negative/` ディレクトリと `checks.json` を持ち、同種の `scripts/*.py` ドライバーで実行する。違いは、仕様が *どこに*
あるか、型システムが *何を* 担えるか、証明のテキストの *どれだけ* を人が書くか、にある。

### 仕様がどこにあるか

| | 直接 Dafny（`Approval.dfy` など） | LemmaScript（`approval.ts` + `approval.dfy`） |
| --- | --- | --- |
| 正本 | 5 つの Dafny モジュール（`Approval`、`Properties`、`Workflow`、`Scenarios`、`Demo`） | TypeScript 1 ファイル。`approval.dfy` はそこから導出したもの + 追記 |
| 実行形態 | `dafny run` / `dafny test` が Python にコンパイル | `node scenarios.ts` が TypeScript を直接実行。コンパイル不要 |
| 仕様の構文 | Dafny の `requires` / `ensures` / `invariant` / `ghost` | TypeScript 内の `//@ requires` / `//@ ensures` / `//@ invariant`、`\result`、`forall(x, ...)`、`===` |
| 証明のテキスト | すべて手書き: `Properties.dfy`（200 行）、`calc`、`:|`、`|events|` に関する帰納法 | `.ts` に述べたものはすべて生成。不変条件・`modifies`・名前つき補題の追記は手書きで 80 行弱 |
| 読者 | Dafny を知っている人 | TypeScript の読者がプログラムと契約の大半を追える。追記と検証エラーを読むには Dafny の知識が要る |

具体的には、直接版は「決裁済みの申請は任意のトレースに沿って凍結される」を帰納法で証明する補題として述べる:

```dafny
lemma TerminalRequestsAreFrozen(dir: Directory, r: Request, events: seq<Event>)
  requires Terminal(r.status)
  ensures Run(dir, r, events) == r
  decreases |events|
{ /* events[1..] に関する再帰 */ }
```

LemmaScript 版は実行可能なループの `ensures` として述べ、ループ不変条件が帰納法になる:

```typescript
export function run(dir: Directory, r: Request, events: Event[]): Request {
  //@ ensures isTerminal(r.status) ==> \result === r
  let current = r;
  for (let i = 0; i < events.length; i++) {
    //@ invariant isTerminal(r.status) ==> current === r
    ...
```

### 型システムが何を担うか

| 制約 | 直接 Dafny | LemmaScript |
| --- | --- | --- |
| 非空の識別子 | 部分型 `type UserId = s: string \| s != "" witness "u"` | 単なる `string` の別名。制約なし。`spec.md` は要求していないので、モデルも検査しない |
| 非空の件名、非負の金額 | 部分型 `Title` / `Amount`: 不正な `Content` は**構築できない** | 実行時述語 `validContent(c)`。`create` が検査し（拒否 `InvalidContent`）、その `ensures` に記録する |
| 各部署に上長がいる | `type Directory = a: Assignment \| DepartmentsHaveManagers(a) witness ...`: 上長のいない割り当ては**`Directory` ではない**ので、どの述語・補題も前提を再掲しない | `Directory` はレコード。`departmentsHaveManagers(dir)` は `//@ pure` 関数。P3 の補題は `requires` としてこれを持つ——`negative/DirectoryWithoutManager.dfy` は、これがないと補題が失敗することを示す |
| 割り当てのキー | `map<(UserId, DepartmentId), Role>`——組をキーにした写像 | `Map<UserId, Map<DepartmentId, Role>>`——入れ子の写像（TypeScript の `Map` のキーは同一性で比較されるので、組のキーは実行時に機能しない） |
| 申請 ID | `nat` | `number`（`number` の nominal な別名は生成される `map<int, ...>` と衝突したため使わなかった） |

これがモデリング上の最大の違いである。Dafny の部分型は整合性を *型* に移すので、構築時に一度確立されれば再掲する必要が
ない。LemmaScript の型は TypeScript の型なので、整合性は *述語* であり、必要な場所で仮定（`requires`）または確立
（`ensures`）しなければならない。そのため LemmaScript 版は P3 に `requires departmentsHaveManagers(dir)` と書く必要があり、
`create` は実行時に `validContent` を検査しなければならない——これはまさに TypeScript のサービスがやることであり、Dafny 版が
表現できないこと（不正な値がそこには存在しない）でもある。

### 遷移の形

| | 直接 Dafny | LemmaScript |
| --- | --- | --- |
| 守られた遷移 | `function Approve(...) requires CanDecide(...)` | `//@ requires canDecide(...)` つきの `approve(...)`——同じ形 |
| 動的な入口 | `Step(...): Outcome<Request>`。*失敗互換型*（`IsFailure` / `PropagateFailure` / `Extract`）なので `Workflow` は `var next :- Step(...)` と書ける | `step(...): Outcome`。単なる discriminated union。`Workflow.apply` は `outcome.kind === "Success"` を検査する |
| 拒否の理由 | `datatype Denial`——同じ考え方 | `type Denial = "NotAffiliated" \| "NotAuthor" \| ... \| "NoSuchRequest"`。文字列リテラルの union で、Dafny の datatype になる |
| ストア | `class System`、`ghost var history` と `ghost predicate Valid()` | `class Workflow`。ghost 状態なし。不変条件は各メソッドの `requires` / `ensures` に `forall(...)` として書き下す |
| 更新 | `requests := requests[id := next]` | `const stored = new Map(this.requests); stored.set(id, ...); this.requests = stored;`——フィールドへの in-place な `this.requests.set(...)` は `lsc 0.6.1` が不正な入れ子更新に lower するため、Map をコピーする |

LemmaScript 版に最も欠けているのは `ghost` である。直接版は仕様専用の `history` 列を持ち、`Scenarios.dfy` から参照する
（`assert system.history == [...]`）。LemmaScript に ghost 状態はないので、トレースについての定理はクラスではなく純粋な
`run` 関数の上で述べている。

### 証明がどう作られるか

| | 直接 Dafny | LemmaScript |
| --- | --- | --- |
| `ensures` ごとの補題 | `Properties.dfy` に手書き。規則ごとに 1 補題 | 生成: `lsc` が `isManagerOf_ensures`、`canEdit_ensures`、`step_ensures`……を関数の隣に補題として出力する（`approval.dfy.gen`） |
| 名前つきの定理 P1〜P3 | `Properties.dfy` | `approval.dfy` 末尾の証明追記（6 補題）。存在証明は直接版とまったく同じく `:|` で witness を取り出す |
| ループ | `Run` は再帰なのでループ不変条件はなく、帰納法は補題に明示的 | `run`、`hasManager`、`departmentsHaveManagers` はループ。TypeScript で述べられる不変条件は `.ts` の `//@ invariant`、lowering 後にしか存在しない `i_user_keys[j]` のような変数が要る不変条件は `approval.dfy` に追記 |
| `//@ pure` ループの仕様側本体 | 該当なし——Dafny の `predicate` は量化子として直接書く | 生成される `function by method` に関数本体がないので、`approval.dfy` が `exists user <- dir.roles.Keys :: isManagerOf(dir, user, dep)`（および `departmentsHaveManagers` の `forall`）を追記し、ループがそれを計算することを Dafny が証明する |
| フレーム条件 | `System` のメソッドに `modifies this` | `approval.dfy` で `modifies this` を追記（LemmaScript 0.6.1 は出力しない） |
| 検証の内訳 | 5 ファイル、`dafny verify` + `dafny test` + `dafny run` | `approval.dfy` の 41 の証明義務グループを `lsc check` 経由で検証。シナリオは `dafny test` の代わりに Node.js で実行 |

### 信頼境界

- 直接版は Dafny と、`dafny run` / `dafny test` のための Dafny→Python コンパイラを信頼する。
- LemmaScript 版は Dafny **と `lsc`** を信頼する。「TypeScript が契約を満たす」という主張は、`approval.dfy.gen` が
  `approval.ts` を忠実に反映している限りで成り立つ。生成ファイルはコミットされ diff で見られ、`approval.dfy` が追記以外で
  ずれれば `lsc check` は失敗し、`scenarios.ts` は TypeScript そのものを動かす——しかし TypeScript の意味論と生成された
  Dafny の同値性はコンパイラのものであり、検証器のものではない。LemmaScript 0.6.1 の振る舞い 2 つ（フィールドへの in-place
  な `Map.set`、`number` の nominal な別名）がモデルの形を左右したので、将来のバージョンで解消できるよう上に記録した。
- モジュールをまたぐ呼び出しは `lsc` によって `function {:axiom}` として出力される。モデルは 1 ファイルに収めることで
  これを避けている。

### まとめ

直接 Dafny 版はより強い *仕様* である: 部分型が不正な名簿・件名・金額を表現不可能にし、`ghost` 状態と失敗互換型が仕様を
実行コードの外に保ち、証明は読まれる場所に書かれる。LemmaScript 版はより強い *実装* である: 証明されたプログラムが無変更で
動く普通の TypeScript であり、権限規則とフレーム条件はサービスが実際に呼ぶ関数の契約であり、補題のテキストの大半が生成される。
このお題では両者は同じ定理を証明する。トレードオフは、Dafny の型レベルの不変条件と ghost 状態に対して、LemmaScript の
単一ソースで直接実行できるモデルと、トラストベースに入るコンパイラである。
