# 稟議申請システム — Markdown with Gherkin (MDG) モデル

- 仕様本体: [`approval.feature.md`](approval.feature.md) — GitHub でそのまま読める Markdown であり、同時に Cucumber が実行する Gherkin
- 実行可能モデル（ステップが叩く最小実装）: [`model.ts`](model.ts)
- ステップ定義: [`steps/approval.steps.ts`](steps/approval.steps.ts)、World とカスタムパラメータ型: [`support/`](support/)
- 失敗しなければならない変異体（ミュータント）: [`negative/`](negative/)
- 検査一覧: [`checks.json`](checks.json)
- 対象仕様: [`../spec.md`](../spec.md)
- ツール: [Cucumber.js](https://github.com/cucumber/cucumber-js) 13.2（Gherkin パーサー `@cucumber/gherkin` 42 を同梱）と TypeScript 7.0（型検査のみ）。Node.js 22.18 以降（型注釈の除去が組み込み）と npm が必要で、`npm ci` により `node_modules/` へ取得される。

## MDG とは

[Markdown with Gherkin](https://github.com/cucumber/gherkin/blob/main/MARKDOWN_WITH_GHERKIN.md) は GitHub Flavored Markdown の
**厳密な上位互換** で、`.feature.md` 拡張子の文書を Gherkin パーサーが読む方言。解釈の規則は次の通り。

| Gherkin | MDG での書き方 | この仕様での使い方 |
| --- | --- | --- |
| `Feature:` / `Rule:` / `Background:` / `Scenario:` / `Scenario Outline:` / `Examples:` | 任意の深さの見出し `#` 〜 `####` にキーワードを置く（`# 機能:` `## ルール:` `### シナリオ:` `#### 例:`） | 見出し階層が文書構造 = Gherkin 構造になる。`ルール` は `spec.md` の R/U/C/D〜F/P1〜P3 の各規則と 1 対 1 |
| `Given` / `When` / `Then` / `And` / `But` | 箇条書き `*` または `-` の直後にキーワード（`* 前提` `* もし` `* ならば` `* かつ` `* しかし`） | 各シナリオの本文 |
| Data Table | ステップの下に **2〜5 スペースで字下げした** GFM 表 | 背景の名簿、`次の操作を順に試みる:` の操作列 |
| Examples Table | `#### 例:` の下に字下げした GFM 表。1 つのアウトラインに **複数の `例:` 見出し** を置ける | `例: 所属している (R1)` / `例: 所属していない (R2)` のように、表を規則の条項ごとに分割して見出しを付ける |
| Doc String | ステップの下の GFM フェンスドコードブロック（` ```json ` のように言語も付けられる） | 期待する申請の JSON、往復シナリオの履歴 |
| Tag | バッククォートで囲み、見出しの **直前の行** に置く（`` `@P1` `@R2` ``） | 規則番号 `@A`〜`@F`、`@R1`〜`@U3`、`@P1`〜`@P3`、`@self-approval`。`--tags` で絞って実行・変異体検査に使う |
| 説明文 | 上記に当たらない行はすべて自由記述として **無視される** | 規則の根拠、状態遷移図（コードブロック）、構成要素の表（字下げ無しなので Data Table にならない）、`spec.md` へのリンク |
| 言語 | `# language: ja` ヘッダーは MDG では **意図的に未対応**。`cucumber.json` の `"language": "ja"` で文書全体に指定する | 日本語方言（`機能` / `ルール` / `シナリオテンプレート` / `前提` / `もし` / `ならば` / `かつ` / `しかし`）で記述 |

## CLI での実行

```console
$ make verify-mdg                                    # このリポジトリの全 MDG 検査を実行
$ ./scripts/mdg.py verify approval_request/mdg
ok   typecheck                no type errors (0.1s)
ok   dry-run                  46 scenarios / 269 steps, every step defined (0.3s)
ok   scenarios                46 scenarios (46 passed) (0.3s)
ok   negative-authority-leak  as expected, 5 scenarios (2 passed, 3 failed) (0.3s)
ok   negative-terminal-thaw   as expected, 2 scenarios (2 failed) (0.3s)
ok   negative-role-per-user   as expected, 18 scenarios (12 passed, 6 failed) (0.3s)

6/6 checks passed
```

| 検査 | コマンド | 検査するもの |
| --- | --- | --- |
| `typecheck` | `tsc -p .` | `model.ts`・ステップ定義・変異体が型検査を通ること（Node.js は型注釈を剥がすだけで検査しない） |
| `dry-run` | `cucumber-js --dry-run` | `approval.feature.md` が Gherkin として parse でき、全シナリオの全ステップに **ちょうど 1 つ** のステップ定義が対応すること（未定義・曖昧なら失敗） |
| `scenarios` | `cucumber-js` | 46 シナリオ（アウトラインの展開後）がすべて `model.ts` に対して成立すること |
| `negative-authority-leak` | `cucumber-js --tags @P1`、`MDG_MODEL=negative/authority-leak.ts` | 「どこかの部署の上長なら決裁できる」モデルが `@P1` のシナリオで **落ちる** こと |
| `negative-terminal-thaw` | `cucumber-js --tags @P2`、`MDG_MODEL=negative/terminal-thaw.ts` | 終端状態の申請が操作を受け付けるモデルが `@P2` のシナリオで落ちること |
| `negative-role-per-user` | `cucumber-js --tags '@P1 or @U2'`、`MDG_MODEL=negative/role-per-user.ts` | 役職を (ユーザー, 部署) ではなくユーザーに付けたモデル（`spec.md` §6 が戒める誤り）が `@P1` と `@U2` のシナリオで落ちること |

その他のサブコマンド:

```console
$ ./scripts/mdg.py checks approval_request/mdg                                  # 検査一覧
$ ./scripts/mdg.py verify approval_request/mdg --only scenarios                 # 1 検査だけ実行
$ ./scripts/mdg.py trace approval_request/mdg --only negative-authority-leak    # 出力を全文表示（失敗したステップの期待値と実際の値）
$ ./scripts/mdg.py run approval_request/mdg --tags '@P1 or @P3'                 # タグで絞って、ステップを 1 行ずつ表示しながら実行
$ ./scripts/mdg.py run approval_request/mdg --tags @P1 --model negative/authority-leak.ts   # 変異体に対して実行
$ ./scripts/mdg.py report approval_request/mdg                                  # 自己完結の HTML レポートを report/approval.html へ
$ ./scripts/mdg.py cucumber approval_request/mdg -- --format message           # cucumber-js をそのまま呼ぶ（Cucumber Messages を NDJSON で）
$ ./scripts/mdg.py tsc approval_request/mdg                                     # TypeScript コンパイラをそのまま呼ぶ
```

## モデルの構成

| `spec.md` | `approval.feature.md` |
| --- | --- |
| §1 構成要素・名簿 | `## 背景:` の Data Table。`carol` が sales の `Member` かつ eng の `Manager`（兼務）。`かつ すべての部署に上長が 1 名以上いる` で不変条件を確認 |
| §2 状態モデル | 説明文としての遷移図（コードブロック）。遷移そのものは各ルールのシナリオアウトラインが表で列挙する |
| §3 R1/R2 | `ルール: 閲覧できるのは…` — 1 つのアウトラインに `例: 所属している (R1)` と `例: 所属していない (R2)` |
| §3 U1/U2/U3 | `ルール: 編集できるのは…` — (状態 × 実行者) の編集可否の表を、条項ごとに 3 つの `例:` に分割 |
| §4 A〜F | ルール 1 つずつ。成功遷移のアウトライン、`WrongState` / `NotAuthor` / `NotAffiliated` で拒否されるアウトライン、自己決裁のシナリオ（`@self-approval`） |
| §5 P1 | `carol` が sales 宛ての申請を決裁できない（3 操作）、同じ `carol` が eng 宛てなら承認できる（裏側）、`dave` はどの操作も `NotAffiliated` |
| §5 P2 | Approved / Rejected それぞれに 7 通りの操作を Data Table で試み、`すべての操作は "TerminalRequest" として拒否される` かつ `申請は変化しない` |
| §5 P3 | 申請先部署ごとに決裁者が存在する（`bob` / `carol`）。加えて `名簿から bob を外す` と不変条件に違反し、迷子申請が生まれることを示すシナリオ |
| §6 留意点 | 変異体 `negative/role-per-user.ts`（役職をユーザーの属性にした誤り）が `@P1` `@U2` で落ちることを `checks.json` が要求する |

ステップの語彙は `support/parameters.ts` の **カスタムパラメータ型** で束ねている: `{command}` は `承認|却下|差し戻し|提出|編集` を `Approve|Reject|Return|Submit|Edit` に、
`{status}` は 5 状態を、`{readable}` / `{editable}` は `閲覧できる|閲覧できない` などを真偽値に変換する。おかげでアウトラインのセルにそのまま日本語を書け、
`もし <実行者> が申請を<操作>する` の 1 ステップ定義が 5 操作を受ける。

## MDG らしさとして意識した点

- **文書がそのまま仕様。** `approval.feature.md` は GitHub 上で見出し・表・図つきの文書として読める。Gherkin として解釈されるのは見出しと箇条書きだけなので、
  「なぜこの規則があるか」「P1 と自己決裁がなぜ矛盾しないか」といった根拠を、実行されるシナリオの直前の段落に書ける。Classic Gherkin の説明文は
  キーワード行の直下にしか置けず（ステップの間には書けない）、表や図やリンクとして描画されることもない。
- **ルールで章立て。** `## ルール:` を `spec.md` の条項 (A〜F, R, U, P1〜P3) に対応させ、その下にシナリオを置く。読者は `spec.md` の見出しを
  MDG の見出しで辿れる。
- **表を条項ごとに分ける。** 1 つのシナリオアウトラインに複数の `#### 例:` を置き、見出しに `(U1)` `(U2)` `(U3)` を付ける。同じステップ本文を
  共有しながら、表の意味（作成者本人・他のメンバー・上長）を見出しで語れる。
- **字下げの有無で「表」と「Data Table」を使い分ける。** 冒頭の構成要素の表は字下げなし = 説明文、背景の名簿は字下げあり = Data Table。同じ GFM 表が
  意味を変える、MDG 固有の書き分け。
- **DocString を仕様値に使う。** 期待する申請を ` ```json ` で、往復の履歴を `Draft --alice:提出--> Pending` の形式で書く。GitHub ではシンタックスハイライト付きの
  コードブロックとして表示される。
- **タグを規則番号にする。** `` `@P1` `` のようにバッククォートで囲むので、レンダリングではコード片として目立つ。`--tags` で「P1 に関わるシナリオだけ」を
  走らせ、変異体検査では「この変異なら **この規則の** シナリオが落ちるはず」と `checks.json` に書く。
- **変異体で仕様の効き目を測る。** BDD のシナリオは実装が正しいことしか示せない。`negative/` の 3 つの変異体（他部署の権限で決裁、終端状態の解凍、
  役職をユーザー属性にする）に対して同じシナリオを走らせ、期待した規則のシナリオが落ちることを CI で要求する。落ちなければ、その規則を言い表す
  シナリオが足りていない。

## 他のモデルとの比較

- **検証の性質。** Alloy / TLA+ / Quint は有界探索、Lean / Dafny / LemmaScript は証明、Cedar は記号的検証で、いずれも「すべての名簿・すべての手順」について
  性質を述べる。MDG は **具体例による仕様** で、5 人 2 部署の 1 つの名簿と 46 の筋書きしか検査しない。P2 の「いかなるアクションによっても」は
  7 通りの操作の表であり、量化ではない。
- **読者。** 一方で、この文書は形式手法の知識なしに読め、`spec.md` を書いた人がそのままレビューできる。他のモデルの README が「モデルをどう読むか」
  の説明に紙面を割くのに対し、MDG は文書そのものが説明である。
- **モデルと実装の距離。** `model.ts` は LemmaScript 版の `approval.ts` とほぼ同じ形（`step` が `Outcome` を返し、`Denial` で拒否理由を語る）だが、
  契約も証明もない。その代わりステップ定義を介して **どの実装にも** 同じシナリオを当てられる: `MDG_MODEL` を差し替えるだけで変異体を検査したのと
  同じ要領で、本番のサービスに対する受け入れテストとして使える。
- **Souther の `examples` との近さ。** Souther はコンパイル時に例の表を検査し、網羅性（adequacy）を判定する。MDG の Examples 表はそれに最も近いが、
  網羅性の判定はない。変異体検査はその代替として置いたもの。
