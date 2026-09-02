# 稟議申請システム — Souther モデル

- 仕様本体: [`approval.sou`](approval.sou)
- コンパイル時に検査される例（テーブル）: [`approval.examples.sou`](approval.examples.sou)
- 対象仕様: [`../spec.md`](../spec.md)
- ツール: [Souther](https://souther-lang.org/) 0.1.0（`souther fmt` / `compile` / `examples` / `run`）。Java 25 が必要。`PATH` や `JAVA_HOME` の Java が 25 未満なら Temurin JDK 25 が `.tools/jdk-25/` へ、Souther CLI（自己実行 jar）が `.tools/souther/` へ初回実行時にダウンロードされる。

## CLI での実行

```console
$ make verify-souther                                # このリポジトリの全 Souther 検査を実行
$ ./scripts/souther.py verify approval_request/souther
ok   format    canonically formatted (0.2s)
ok   compile   209 classes generated (1.3s)
ok   examples  9/9 behaviors implemented, adequacy satisfied (2.1s)

3/3 checks passed
```

| 検査 | コマンド | 検査するもの |
| --- | --- | --- |
| `format` | `souther fmt --check` | 2 つの `.sou` が正規形で書かれていること |
| `compile` | `souther compile` | 型検査・`match` の網羅性・`constructs` 権限・`ensures` の整合が通り、JVM クラス（振る舞い・データ・JSON コーデック）が生成されること |
| `examples` | `souther examples --strict` | 全 `example` 行が成り立ち、かつ行が **モデルを覆っていること**（全振る舞い・全結果ケース・全不変条件の境界値）。網羅性の判定 `adequacy: satisfied` が出ないと失敗 |

その他のサブコマンド:

```console
$ ./scripts/souther.py checks approval_request/souther                     # 検査一覧
$ ./scripts/souther.py verify approval_request/souther --only examples     # 1 検査だけ実行
$ ./scripts/souther.py trace approval_request/souther --only examples      # 出力を全文表示
$ ./scripts/souther.py examples approval_request/souther                   # 例の網羅性レポート（振る舞い x 結果ケース x 境界値）
$ ./scripts/souther.py souther api List                                    # Souther CLI をそのまま呼ぶ（管理下の JDK 25 で）: 標準ライブラリの List の API
```

### 振る舞いを JSON で実行する

Souther は仕様をそのまま JVM のコードにコンパイルするため、モデルは「検査する」だけでなく **入力を与えて実行できる**。
`run` は振る舞いの引数ごとに 1 つの JSON 値を取り、結果を JSON で返す。
直和型は `{"type": "<ケース名>", ...フィールド}`、newtype（`UserId` や `Amount`）は中身の値そのもので書く。

```console
$ DIR='[{"user":"alice","department":"sales","role":"Member"},{"user":"bob","department":"sales","role":"Manager"}]'
$ REQ='{"type":"Pending","author":"alice","department":"sales","content":{"title":"Laptop","amount":1500}}'

$ ./scripts/souther.py run approval_request/souther decide "$DIR" '"bob"' "$REQ" '{"type":"ApproveCommand"}'
{"author":"alice","department":"sales","content":{"title":"Laptop","amount":1500},"approvedBy":"bob","type":"Approved"}

$ ./scripts/souther.py run approval_request/souther decide "$DIR" '"alice"' "$REQ" '{"type":"ApproveCommand"}'
{"type":"NotManager"}

$ ./scripts/souther.py run approval_request/souther registerDirectory '[{"user":"alice","department":"sales","role":"Member"}]'
{"type":"DepartmentWithoutManager"}

$ ./scripts/souther.py run approval_request/souther create "$DIR" '"alice"' '"sales"' '""' 1
{"type":"InvalidContent"}
```

入力の不変条件は 2 段で守られる。`create` のように生の `String` / `Int` を受けて中で `guard Title(title) as t else InvalidContent` と **構築を試みる** 振る舞いでは、不正な値は結果ケースとして返る。一方 `Directory` や `Request` のように不変条件つきの型をそのまま引数に取る場合は、生成された JSON デコーダが入口で拒否する（例: `invariant violated on approval_request.Directory: everyDepartmentHasManager`）。

## モデルの構造

| 仕様 (`spec.md`) | モデル上の表現 |
| --- | --- |
| ユーザー / 部署 | newtype `UserId` / `DepartmentId`（`invariant nonEmpty`） |
| 所属と役職 `(ユーザー, 部署) -> 役職` | レコード `Affiliation { user, department, role }` の列 `Directory`。`Manager` は `Role` の値であり、ユーザーの属性ではない |
| 1 つの所属に 1 つの役職 | `Directory` の `invariant oneRolePerAffiliation`（`List.allDistinctBy`） |
| 各部署に上長 1 名以上（P3） | `Directory` の `invariant everyDepartmentHasManager` |
| 稟議申請の状態 | 状態ごとの product data `Draft` / `Pending` / `Returned` / `Approved` / `Rejected`。共通フィールドは `RequestCore` をスプレッド（`...RequestCore`）で共有し、`approvedBy` のような「その状態でしか存在しない値」はその状態にだけ置く |
| 状態遷移図 | 振る舞いの **入力型** が遷移元を限定する: `submit : Submittable(=Draft \| Returned) -> Pending`、`approve : Pending -> Approved`。終端状態（P2）を `approve` に渡すことは型エラーになり、実行時の判定を要しない |
| 閲覧・編集・提出・決裁の権限 | 述語 `isAffiliated` / `isManagerOf` / `canEdit` と `guard ... else <拒否ケース>`。拒否は `NotAffiliated` / `NotAuthor` / `NotManager` という **結果の直和ケース** で、例外ではない |
| 事後条件 | `ensures`: `create` は作成者・申請先が入力どおり、`edit` は作成者を保ち内容だけ変わる、`approve` などは実行者を `approvedBy` に記録する |
| 外部からの任意の (状態, コマンド) | `decide : (Directory, UserId, Request, Command) -> Request \| Denied`。二重の `match` が全セルを網羅し、`TerminalRequest` / `WrongState` を返す。抜けたセルはコンパイルエラー |
| 検証（シナリオ） | `approval.examples.sou` の `example` テーブル。各振る舞いについて「入力 → 期待結果」を並べ、コンパイラが 1 行ずつ評価する |

## Souther らしさとして意識した点

- **状態を「レコード + status フィールド」ではなく状態ごとの型にする**: `Approved` にだけ `approvedBy` があり、`Returned` にだけ `returnedBy` がある。「Draft なのに承認者が入っている」という不整合な値が **書けない**。TLA+/Quint 版では `TypeOK` や不変条件で禁じていたものが型に吸収される。
- **遷移の前提を入力型で書く**: `Editable = Draft | Pending | Returned`、`Submittable = Draft | Returned` という入力エイリアスを切り、振る舞いの引数型に使う。仕様 4 章の「事前条件: 状態が Draft または Returned」が型シグネチャそのものになり、P2（終端不変）は「終端状態を受け取る遷移がない」ことで示される。
- **不変条件は値の側に、権限は振る舞いの側に**: `Title` の非空や `Amount` の非負、`Directory` の一意性と P3 は data の `invariant` に置き、`guard Title(title) as t else InvalidContent` のように **構築の試行** として使う。権限のような「誰が」の判定は振る舞いの `guard` に置く。両方とも失敗は結果ケースであり、呼び出し側は `match` で扱う。
- **`constructs` で構築権限を宣言する**: `Approved` を作れるのは `approve` だけ、`Directory` を作れるのは `registerDirectory` だけ。`decide` は受け取った値を委譲・転送するだけなので `constructs` を持たない。値がどこで生まれるかがシグネチャから読める。
- **`ensures` を結果ケースごとに書く**: `ensures Approved -> value.approvedBy == actor && value.author == request.author`。成功ケースの事後条件だけを型に沿って書け、拒否ケースには課されない。
- **例はコンパイルの一部**: `example approve` の各行は `souther compile` / `souther examples` が実行し、期待値と一致しなければコンパイルエラー（`E1905`）になる。仕様書の表（U1〜U3、D〜F）を **ほぼそのままの表形式** で書き写せるのが特徴で、行の説明文には対応する要件番号を書いている。
- **`--strict` で例の網羅性を測る**: Souther は「どの振る舞いのどの結果ケースに例があるか」「不変条件の境界値（`String.length == 1`、`amount == 0`）を踏んでいるか」を報告し、抜けがあれば `!` を付ける。`make verify-souther` は `adequacy: satisfied` を要求するので、結果ケースを増やして例を書き忘れると CI で落ちる。他の言語の「反例が出ないこと」とは逆向きに、「書いた例がモデルを覆っていること」を機械的に担保する。
- **P1（兼務による権限漏れ）は述語のシグネチャで防ぐ**: `isManagerOf(directory, actor, request.department)` は必ず **申請先部署** を引数に取る。`carol` が `eng` の上長でも `sales` 宛ての申請には `NotManager`（`decide` 経由なら所属すらないので `NotAffiliated`）。自己決裁（作成者 = 申請先上長）は `isManagerOf` が真になるだけなので特別扱いせずに許可される。
- **実行可能であること**: モデルは JVM クラスにコンパイルされ、`souther run` が JSON を生成コーデックでデコードして振る舞いを呼ぶ。同じ `.sou` が仕様書・テスト・参照実装の 3 役を兼ねる。

## 他の言語との対比

| 観点 | Alloy / TLA+ / Quint | Cedar | Souther |
| --- | --- | --- | --- |
| 検証の方法 | 状態空間の探索（有界・網羅・記号） | 認可判定のテストと SymCC（SMT）による含意 | 型検査 + コンパイル時に評価される例 + 例の網羅性判定 |
| 保証の範囲 | スコープ内の全状態・全トレース | 全エンティティストア上の全リクエスト | 書いた例（ただし網羅性を機械的に測る）。時相性質や到達可能性の探索はない |
| 不正な状態の扱い | 不変条件で禁じる | スキーマで型付け | 状態ごとの型で **表現不可能** にする |
| 遷移の事前条件 | アクションのガード | 適用範囲外 | 振る舞いの入力型（コンパイル時）+ `guard`（実行時） |
| 事後条件 | 次状態を書く | 適用範囲外 | `ensures`（結果ケースごと） |
| 実行 | シミュレーション / 反例トレース | `cedar authorize` | `souther run`（JSON 入出力、JVM 上で実行） |

Souther は活性や「この状態に到達できるか」といった探索を行わないため、時相性質は TLA+/Quint 版に委ねる。
一方で、状態ごとの型・入力型による遷移の限定・結果ケースとしての拒否・コンパイル時に走る例、という組み合わせは、仕様を **そのまま動く実装** として保つのに向いている。
