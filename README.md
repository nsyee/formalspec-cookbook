# formalspec-cookbook

同じお題を複数の形式仕様記述言語でモデル化し、表現力・書き味・検証能力の違いを比較するためのリポジトリ。

各お題のディレクトリには、自然言語での仕様 (`spec.md`) と、記述言語ごとのディレクトリを置く。

## 対応表（マトリクス）

| お題 | 仕様 | Alloy | TLA+ | Quint | Cedar | Souther | Lean 4 | Dafny |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 稟議申請システム (approval_request) | [spec.md](approval_request/spec.md) | [✓](approval_request/alloy/) | [✓](approval_request/tla/) | [✓](approval_request/quint/) | [✓](approval_request/cedar/) | [✓](approval_request/souther/) | [✓](approval_request/lean/) | [✓](approval_request/dafny/) |

凡例: ✓ 実装済 / WIP 作業中 / - 未着手

## ディレクトリ構成

```
.
├── README.md                 # プロジェクトの概要と対応表（マトリクス）
├── Makefile                  # make verify で全モデルを検証
├── approval_request/         # お題1: 稟議申請システム
│   ├── spec.md               # お題の仕様・要件定義（自然言語）
│   ├── alloy/                # Alloy 6 モデル（README.md + approval.als）
│   ├── tla/                  # TLA+ モデル（README.md + *.tla + TLC モデル *.cfg）
│   ├── quint/                # Quint モデル（README.md + *.qnt + 検査一覧 checks.json）
│   ├── cedar/                # Cedar 認可モデル（README.md + *.cedarschema + *.cedar + 検査一覧 checks.json）
│   ├── souther/              # Souther 実行可能仕様（README.md + *.sou + コンパイル時に検査される *.examples.sou）
│   ├── lean/                 # Lean 4 定理証明モデル（README.md + Lake プロジェクト: Approval/*.lean + 証明 + シナリオ再生 CLI）
│   └── dafny/                # Dafny 検証つきモデル（README.md + *.dfy + 失敗を期待する negative/*.dfy + 検査一覧 checks.json）
└── scripts/                  # 検証ドライバなどの自動化スクリプト
```

## 検証の実行（CLI）

```console
$ make help      # 使えるターゲットの一覧
$ make verify    # 全モデルの check / run を実行して結果を集計
$ make verify-alloy   # Alloy 6 のモデルだけ
$ make verify-tla     # TLA+（TLC）のモデルだけ
$ make verify-quint   # Quint（シナリオテスト・シミュレーション・Apalache/TLC）のモデルだけ
$ make verify-cedar   # Cedar（validate・run-tests・SymCC による記号的検証）のモデルだけ
$ make verify-souther # Souther（fmt・compile・examples --strict による網羅性つき例検査）のモデルだけ
$ make verify-lean    # Lean 4（lake build による証明検査・#print axioms 監査・シナリオ再生）のモデルだけ
$ make verify-dafny   # Dafny（format・verify による演繹的証明・test・run）のモデルだけ
```

必要なのは Java 17 以降と Python 3.8 以降のみで、モデル検査器の本体（Alloy、TLA+ Tools）は初回実行時に `.tools/` へ自動ダウンロードされる。
Quint は追加で Node.js 18 以降を必要とし、Quint CLI が `.tools/` に、Apalache と TLC が Quint 自身によって `~/.quint/` へ取得される。
Cedar は追加で Rust 1.89 以降（cargo）を必要とし、Cedar CLI が `.tools/` にビルドされ、SMT ソルバー cvc5 が `.tools/` へダウンロードされる。
Souther は Java 25 を必要とし、`PATH` / `JAVA_HOME` の Java が古い場合は Temurin JDK 25 が `.tools/jdk-25/` へ、Souther CLI（自己実行 jar）が `.tools/souther/` へダウンロードされる。
Lean 4 は追加要件なし。`lake` が `PATH` / `~/.elan` に無ければ elan が `.tools/elan/` へインストールされ、`lean-toolchain` に固定された Lean が elan により取得される（Mathlib は使わない）。
Dafny は追加要件がなく、Z3 を同梱した自己完結リリースが `.tools/dafny-4.11.0/` へダウンロードされ、コンパイルは Python バックエンドを使う（.NET SDK 不要）。
個別のモデルだけを回す方法や GUI の起動方法は各言語ディレクトリの README を参照（[Alloy](approval_request/alloy/README.md) / [TLA+](approval_request/tla/README.md) / [Quint](approval_request/quint/README.md) / [Cedar](approval_request/cedar/README.md) / [Souther](approval_request/souther/README.md) / [Lean 4](approval_request/lean/README.md) / [Dafny](approval_request/dafny/README.md)）。
検証はプルリクエストごとに GitHub Actions でも実行される（[.github/workflows/verify.yml](.github/workflows/verify.yml)）。

## お題の追加

お題を追加するときは `<topic>/spec.md` を作成し、上記マトリクスに行を追加する。
記述言語ごとのモデルは `<topic>/<language>/` 配下に置く（例: `approval_request/alloy/approval.als`）。
ディレクトリ名・ファイル名は英語、文書の本文は日本語で記述する。
