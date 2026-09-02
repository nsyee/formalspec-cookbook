# 稟議申請システム — Cedar モデル

- スキーマ（エンティティ型・アクション）: [`approval.cedarschema`](approval.cedarschema)
- 認可ポリシー: [`approval.cedar`](approval.cedar)
- エンティティ（組織図と申請のフィクスチャ）: [`entities.json`](entities.json)
- 認可リクエストのテスト: [`cases.json`](cases.json)
- SymCC で検証する性質: [`properties/*.cedar`](properties/)
- 検査一覧: [`checks.json`](checks.json)
- 対象仕様: [`../spec.md`](../spec.md)
- ツール: Cedar CLI 4.12.0（`cedar validate` / `format` / `run-tests` / `symcc`）と SMT ソルバー cvc5 1.3.4。Rust 1.89 以降（cargo）があれば、Cedar CLI は初回実行時に `.tools/cedar/` へビルドされ（`--features analyze`、数分かかる）、cvc5 は `.tools/cvc5/` へダウンロードされる。既存のバイナリを使う場合は環境変数 `CEDAR_BIN` / `CVC5` で指定する。

## Cedar でモデル化するもの・しないもの

Alloy / TLA+ / Quint が「システムの取り得る状態遷移」をモデル化して検証するのに対し、
Cedar（AWS が開発した認可ポリシー言語）は **「この主体 (principal) は、この状態の客体 (resource) に対して、
この操作 (action) を許可されるか」** だけを扱う。したがって spec.md のうち

- 事前条件（§3 の権限ルール、§4 各アクションの「実行者」と「事前条件」）と
- 「〜できてはならない」型の性質（R2 / U2 / P1 / P2）

は Cedar のポリシーとして直接書けるが、事後条件（状態がどう遷移するか）や、
状態遷移の列に関する性質（活性、P3「上長が必ず存在する」のような組織図の整合性）は
Cedar の対象外で、ポリシーを呼び出すアプリケーション側の責務になる。
Cedar 版はいわば **状態機械の各遷移を守るガード** のモデルである。

## CLI での実行

```console
$ make verify-cedar                              # このリポジトリの全 Cedar 検査を実行
$ ./scripts/cedar.py verify approval_request/cedar
ok   validate                                      policies type-check against the schema (0.0s)
ok   format                                        canonically formatted (0.0s)
ok   cases                                         30 passed (0.0s)
ok   P1-only-target-managers-decide                verified for 3 action(s) (0.0s)
ok   P2-terminal-requests-are-frozen               verified for 5 action(s) (0.0s)
ok   R2-only-affiliated-users                      verified for 6 action(s) (0.1s)
ok   U2-only-author-or-manager-edit                verified for 1 action(s) (0.0s)
ok   C-only-author-submits                         verified for 1 action(s) (0.0s)
ok   A-only-own-department                         verified for 1 action(s) (0.0s)
ok   R1-every-affiliated-user-can-read             verified for 1 action(s) (0.0s)
ok   D-self-approval-is-allowed                    verified for 3 action(s) (0.0s)
ok   D-self-approval-without-hierarchy-assumption  counterexample for 1 of 1 action(s) (0.0s)

12/12 checks as expected
```

その他のサブコマンド:

```console
$ ./scripts/cedar.py checks approval_request/cedar                                 # 検査一覧
$ ./scripts/cedar.py verify approval_request/cedar --only cases                    # 1 検査だけ実行
$ ./scripts/cedar.py trace approval_request/cedar --only D-self-approval-without-hierarchy-assumption
                                                                                   # 出力（SymCC の反例）を全文表示
$ ./scripts/cedar.py authorize approval_request/cedar 'User::"alice"' 'Action::"approve"' 'Request::"dev/pending-by-alice"'
DENY

note: this decision was due to the following policies:
  P1-decision-rights-follow-the-target-department

$ ./scripts/cedar.py matrix approval_request/cedar                                 # フィクスチャ全体の判定表
resource                           action    alice    bob      carol    dave
Request::"dev/pending-by-alice"    approve     .        .      ALLOW      .
Request::"dev/pending-by-alice"    edit        .        .      ALLOW      .
Request::"dev/pending-by-alice"    read      ALLOW      .      ALLOW    ALLOW
...
```

Cedar CLI を直接呼ぶ場合（`.tools/cedar/bin/cedar` または `cedar`）:

```console
$ cd approval_request/cedar
$ cedar validate --schema approval.cedarschema --policies approval.cedar --deny-warnings
$ cedar authorize --schema approval.cedarschema --policies approval.cedar --entities entities.json \
    --principal 'Approval::User::"alice"' --action 'Approval::Action::"approve"' \
    --resource 'Approval::Request::"sales/pending-by-alice"' --verbose
$ CVC5=../../.tools/cvc5/cvc5 cedar symcc --schema approval.cedarschema \
    --principal-type Approval::User --action 'Approval::Action::"approve"' --resource-type Approval::Request \
    implies --policies1 approval.cedar --policies2 properties/P1-only-target-managers-decide.cedar
✓ Policy set 1 implies policy set 2: VERIFIED
```

## 検査（`checks.json`）の構成

| 検査 | コマンド | 検査するもの | 期待 |
| --- | --- | --- | --- |
| `validate` | `cedar validate --deny-warnings` | ポリシーがスキーマに対して型付けできる（存在しない属性・状態・アクションを参照していない） | 通る |
| `format` | `cedar format --check` | ポリシーが正規のフォーマットである | 通る |
| `cases` | `cedar run-tests` | `cases.json` の 30 リクエスト（`entities.json` の組織図に対する）が期待する判定になり、期待するポリシーが判定理由に含まれる | 全件 pass |
| `P1-only-target-managers-decide` | `cedar symcc implies` | approve / reject / return が許可されるなら、実行者は申請先部署の上長で申請は Pending | 成立 |
| `P2-terminal-requests-are-frozen` | 同上 | edit / submit / 決裁が許可されるなら、申請は Approved / Rejected ではない | 成立 |
| `R2-only-affiliated-users` | 同上 | 申請への全アクションについて、許可されるなら実行者は申請先部署に所属 | 成立 |
| `U2-only-author-or-manager-edit` | 同上 | edit が許可されるなら U1 または U3 の条件を満たす（他のメンバーは編集できない） | 成立 |
| `C-only-author-submits` | 同上 | submit が許可されるなら作成者本人で Draft / Returned | 成立 |
| `A-only-own-department` | 同上 | create が許可されるなら実行者はその部署に所属 | 成立 |
| `R1-every-affiliated-user-can-read` | 同上（逆向き） | 申請先部署に所属していれば read は必ず許可される | 成立 |
| `D-self-approval-is-allowed` | 同上（逆向き） | 申請先部署の上長なら自分の Pending 申請も決裁できる（階層の整合性を仮定） | 成立 |
| `D-self-approval-without-hierarchy-assumption` | 同上（逆向き） | 上と同じだが階層の整合性の仮定なし | **反例** |

`cases` は具体的なフィクスチャに対する **テスト**、`symcc` の検査は **すべてのリクエストとすべてのエンティティ集合** に対する **証明** である。
SymCC（Cedar 4.x の `analyze` フィーチャ）はポリシー集合を SMT 式にコンパイルし、cvc5 で
「ポリシー集合 1 が許可するリクエストは必ずポリシー集合 2 も許可するか」（`implies`）を判定する。
性質は `properties/` に **1 つの permit だけからなるポリシー集合** として書き、方向を `checks.json` の `kind` で指定する:

- `allowed-only-if`（ポリシー ⇒ 性質）: 健全性。ポリシーが許可するものは性質を満たす。R2 / U2 / P1 / P2 のような「〜できてはならない」はこれ。
- `allowed-whenever`（性質 ⇒ ポリシー）: 完全性。性質が記述するリクエストはすべて許可される。R1 や自己決裁のような「〜できる」はこれ。

`expect: violation` は「反例が出なければ失敗」で、Quint 版の `liveness-no-fairness` と同じ役割
（仮定が本当に必要であることを CI で確かめる）を持つ。

## モデルの構造

| 仕様 (`spec.md`) | モデル上の表現 |
| --- | --- |
| 部署 | エンティティ型 `Department`。属性 `members` / `managers` で 2 つの `Team` を指す |
| 所属と役職 | **エンティティ階層**。`User in Team`、`Team in Department`、上長チームは同じ部署のメンバーチームの子（`sales/managers in sales/members in sales`） |
| 兼務 | `User` が複数の `Team` を親に持つ（`alice in [sales/managers, dev/members]`） |
| 「所属している」 | `principal in resource.department`（`in` は階層を推移的にたどる） |
| 「申請先部署の上長である」 | `principal in resource.department.managers` |
| 稟議申請 | エンティティ型 `Request`。属性 `author` / `department` / `status`、親は申請先 `Department` |
| 状態 | **列挙エンティティ** `Status enum ["Draft", "Pending", "Returned", "Approved", "Rejected"]` |
| アクション A〜F | `action create / read / edit / submit`、決裁 3 種は **アクショングループ** `decide` の子 |
| 「〜できる」（R1 / A / U1 / U3 / C / D〜F） | `permit` |
| 「〜できてはならない」（R2 / P1 / P2） | `forbid` + `unless` / `when`。permit より常に優先する **ガード** |
| U2（他のメンバーは編集不可） | 対応する permit を書かない（デフォルト拒否） |
| P3（上長が必ず存在する） | 認可の性質ではないため対象外。アプリケーション側でエンティティ集合の整合性として保つ |

## Cedar らしさとして意識した点

- **属性の集合演算ではなく、エンティティ階層 (`in`) で所属と役職を表す**: 叩き台は `principal.member_of.contains(resource.target_department)` のようにユーザーの属性に部署集合を持たせていた。Cedar の中核はエンティティ階層に対する `in` なので、`User ∈ Team ∈ Department` とし、`principal in resource.department` の 1 語で「所属している」を判定する。上長チームをメンバーチームの子にすることで「上長は所属者でもある」も階層から導かれ、ポリシーに `||` を書く必要がない。
- **役職が (ユーザー, 部署) の組で決まる**という spec.md §6 の要請は、Team が 1 つの Department にだけ属することで自然に満たされる。P1 の本質（他部署での上長権限は使えない）は `resource.department.managers` が申請先部署のチームを指す、というただそれだけで表現できる。
- **列挙エンティティで状態を閉じる**: `status` を `String` にした叩き台では `"Pendng"` のような綴り違いも型検査を通る。`entity Status enum [...]` にすると、存在しない状態を参照したポリシーは `cedar validate` が弾く。比較は `resource.status == Status::"Pending"` や `resource.status in [Status::"Draft", Status::"Returned"]` と書ける。
- **アクショングループ**: approve / reject / return を `action decide` の下にまとめ、ポリシーでは `action in Action::"decide"` と書く。決裁アクションが増えてもポリシーは変わらない。
- **`appliesTo` で principal / resource の型を限定する**: `create` の resource は `Department`、それ以外は `Request`。型が合わないリクエストはポリシー評価に入る前にリクエスト検証で拒否され、ポリシー側にも `principal is User, resource is Request` の型制約を書く。
- **permit と forbid の使い分け**: 仕様の「〜できる」は permit、「〜できてはならない」は forbid。判定結果は permit だけで書いても同じだが、forbid は permit に常に優先するため、後から permit を追加しても R2 / P1 / P2 が破れない **深層防御** になる。「他のメンバーは編集できない」（U2）のように否定の permit が要らないものは、デフォルト拒否に任せて何も書かない。
- **`@id` / `@doc` アノテーション**: 各ポリシーに spec.md の規則番号を含む id を付けると、`cedar authorize --verbose` と `run-tests` の `reason` にそのまま現れ、「どの規則で拒否されたか」が読める。
- **`cedar run-tests` で仕様の例をテストとして書く**: `cases.json` の各行は「この人が・この申請に・この操作」を期待判定と **判定理由となるポリシー id** と共に書く。判定だけでなく理由まで検査するので、意図しないポリシーで偶然同じ判定になっている状態を検出できる。
- **SymCC で性質を証明する**: フィクスチャに依存しない本命の検証。性質そのものを Cedar のポリシーとして書き、`implies` で比較する。R1 のような完全性はポリシー ⇐ 性質、P1 / P2 / R2 のような健全性はポリシー ⇒ 性質。反例は「こういう組織図と申請があれば破れる」という具体的なエンティティ集合として返る。
- **スキーマで言えない整合性条件を仮定として明示する**: 「上長チームは部署の下にある」「申請の `department` 属性と親は一致する」といった階層の整合性はスキーマでは書けないので、SymCC はそれを満たさないエンティティ集合も探索する。健全性の検査はその仮定なしでも成立する（より強い結果）が、完全性の検査（自己決裁ができること）は仮定が必要で、`properties/D-self-approval-is-allowed.cedar` に `principal in resource.department` として書いてある。仮定を外すと反例が出ることも `expect: violation` の検査として残した。

## 叩き台からの主な変更点

| 叩き台 | このモデル | 理由 |
| --- | --- | --- |
| `User.member_of: Set<Department>` / `manager_of: Set<Department>` | `User in Team in Department`、`Department.managers: Team` | Cedar の主要機構である階層と `in` を使う。member と manager の整合性（上長は所属者）も階層で保証 |
| `status: String` | `entity Status enum [...]` | 存在しない状態を validator が弾く |
| アクションを 7 つ列挙 | `decide` グループ + `action in Action::"decide"` | 決裁 3 種の共通ルールを 1 つの permit で書く |
| permit のみ | permit + forbid ガード（R2 / P1 / P2） | 「〜できてはならない」を仕様どおりの向きで書き、将来の permit 追加に対して壊れないようにする |
| JSON スキーマ | Cedar スキーマ構文（`.cedarschema`） | コメントとアノテーションが書ける |
| 「Validator が性質を証明できる」 | validator は型検査、性質の証明は `cedar symcc`（SymCC + cvc5） | 役割の切り分けを正確に |

## Alloy / TLA+ / Quint との対比

| 観点 | Alloy / TLA+ / Quint | Cedar |
| --- | --- | --- |
| モデル化の対象 | 状態遷移系（事前条件 + 事後条件 + 不変条件） | 各遷移の認可判定（事前条件のみ） |
| 「所属」「役職」 | 関係 `roles: User -> Dept -> Role` | エンティティ階層 `User in Team in Department` |
| 状態 | 集合 / 直和型 | 列挙エンティティ |
| 「できてはならない」 | 不変条件・アサーション | `forbid`（判定にも組み込まれる） |
| 検証の主体 | モデル検査（有界の網羅探索 / 記号的検証） | SMT による **非有界** の証明（エンティティの個数に制限なし）+ フィクスチャに対するテスト |
| 反例 | 状態遷移のトレース | 1 つのリクエストと 1 つのエンティティ集合 |
| 活性・P3・終端後の遷移禁止 | 検証できる | 対象外（P2 は「終端状態への操作を拒否する」ガードとして表現） |
| 本番との距離 | 仕様と実装は別物 | ポリシーそのものをアプリケーションに組み込んで実行できる |

## 検証結果

12 検査すべてが期待どおり（全体で 1 秒未満）。
SymCC による 8 つの性質は、エンティティの個数や組織図の形に依存しない **すべてのリクエスト** について成立する。
`cases` の 30 件は、兼務ユーザー alice（sales の上長 / dev のメンバー）を中心とした具体例で、
P1（alice は自分の dev 宛て申請を承認できない）と自己決裁（alice は自分の sales 宛て申請を承認できる）の両方を含む。
