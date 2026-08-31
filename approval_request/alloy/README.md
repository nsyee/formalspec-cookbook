# 稟議申請システム — Alloy 6 モデル

- モデル: [`approval.als`](approval.als)
- 対象仕様: [`../spec.md`](../spec.md)
- Alloy バージョン: 6.2.0（時相論理 `var` / `always` / `once` などを使用するため 6 系が必須）

## CLI での実行

Java 17 以降と Python 3.8 以降があれば、Alloy 本体は初回実行時に `.tools/` へ自動ダウンロードされる（`.gitignore` 済み）。

```console
$ make verify                              # リポジトリ内の全 Alloy モデルを検証
$ ./scripts/alloy.py verify approval_request/alloy/approval.als
ok   decisionRightsDependOnTargetRoleOnly    check no counterexample
ok   terminalDecidedByTargetManager          check no counterexample
...
13/13 commands as expected
```

`verify` は「`check` に反例が出た」または「`run` が充足不能（想定シナリオが起こり得ない）」の場合に終了コード 1 を返すため、そのまま CI ゲートとして使える（[`.github/workflows/verify.yml`](../../.github/workflows/verify.yml)）。

その他のサブコマンド:

```console
$ ./scripts/alloy.py commands approval_request/alloy/approval.als                       # コマンド一覧
$ ./scripts/alloy.py verify approval_request/alloy/approval.als 'selfApproval*'         # 名前で絞り込み
$ ./scripts/alloy.py trace approval_request/alloy/approval.als selfApprovalIsAllowed    # 見つかった実行トレースを表示
$ ./scripts/alloy.py gui approval_request/alloy/approval.als                            # GUI（可視化）を開く
```

## モデルの構造

| 仕様 (`spec.md`) | モデル上の表現 |
| --- | --- |
| 部署 / ユーザー | `sig Department`, `sig User` |
| 所属と役職 | `roles: Department -> lone Role`（`(User, Department) -> Role` の三項関係。`lone` で「1 部署につき最大 1 役職」、複数部署への写像で兼務を表現） |
| 各部署に上長 1 名以上 | `fact everyDepartmentIsManaged` |
| 稟議申請 | `sig Request { author, target, var status, var content }`。`target in affiliations[author]` を sig 制約（appended fact）に置き、「作成者が所属する部署宛て」を構造として保証 |
| 状態 | `abstract sig Status` と `Terminal extends Status`。`Approved`/`Rejected` を `Terminal` の下に置くことで「終端状態」を集合として扱える（`enum` では不可） |
| 閲覧・編集権限 | `canRead` / `canEdit` / `canDecide`。状態遷移を伴わない純粋な述語なので、アクションの事前条件と検証式の両方から再利用する |
| アクション A〜F | `create` / `edit` / `submit` / `decide`（`approve`・`reject`・`sendBack` は `decide` の特化）|
| P1 / P2 / P3 | `check decisionRightsDependOnTargetRoleOnly`, `check terminalDecidedByTargetManager`, `check terminalStatesAreStable`, `check noOrphanRequest` |

## Alloy 6 らしさとして意識した点

- **時相論理で状態遷移を表す**: 状態を明示的な `State` sig で持たず、`var status` / `var content` と次状態 `x'`、`always` / `eventually` / `once` で記述する。`util/ordering` による旧来の状態列モデリングは不要。
- **申請の生成をトレース内で扱う**: 申請プールは静的にし、「`status` が空 = まだ存在しない」と解釈する（`fun live: set Request { status.Status }`）。`var sig` で原子を生成するより探索空間が小さく、`create` イベントもトレース上に現れる。
- **イベントの具体化（reification）**: `fun approves: User -> Request { { u: User, r: Request | approve[u, r] } }` のようにイベントを関係として定義する。これにより
  - GUI 上で「どの遷移で誰が何をしたか」が可視化でき、
  - `u -> r in approves` の形で「実行者付き」の性質を検証式やシナリオ記述に書ける（`terminalDecidedByTargetManager` や各 `run` で使用）。
- **フレーム条件の局所化**: `pred onlyChanges[r]` に「r 以外は不変」をまとめ、各イベントは自分が触るフィールドだけを書く。
- **`steps` スコープ**: `check ... for 4 but 1..10 steps` のように Alloy 6 のトレース長スコープを明示し、無限トレース（ループ）まで含めて有界検証する。
- **過去演算子**: 「差し戻された申請は必ず提出済みだった」を `once r.status = Pending` で直接書く（履歴変数を追加しない）。
- **liveness と公平性**: 「`Pending` は永遠に放置されない」は自明には成り立たないため、進行仮定 `pred fairness` を置いた上で `check pendingIsEventuallyDecided` として検証する。安全性（safety）と活性（liveness）を分けて扱えるのが Alloy 6 の利点。
- **反例が出る性質と、出てはいけないシナリオの両方を書く**: `check` だけでなく `run`（`crossAffiliatedAuthorCannotSelfApprove` など）を置き、「仕様が想定するシナリオが実際に到達可能である（＝制約を書きすぎてモデルが空になっていない）」ことも確認する。この vacuity 検査を `verify` は「`run` が充足不能なら失敗」として自動化している。

## 検証結果（既定スコープ）

13 コマンドすべてが期待通り（`check` は反例なし、`run` はインスタンスあり）。全体で約 15 秒（SAT4J、4〜5 原子 / 最大 10 steps）。

有界検証であるため、スコープを広げれば新たな反例が出る可能性は残る。特に P1 は「部署 2 つ・ユーザー 3 人」で反例が出るかどうかが本質なので、既定スコープで十分な範囲を覆っている。
