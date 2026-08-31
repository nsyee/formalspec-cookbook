# formalspec-cookbook

同じお題を複数の形式仕様記述言語でモデル化し、表現力・書き味・検証能力の違いを比較するためのリポジトリ。

各お題のディレクトリには、自然言語での仕様 (`spec.md`) と、記述言語ごとのディレクトリを置く。

## 対応表（マトリクス）

| お題 | 仕様 | Alloy | TLA+ | Quint |
| --- | --- | --- | --- | --- |
| 稟議申請システム (approval_request) | [spec.md](approval_request/spec.md) | - | - | - |

凡例: ✓ 実装済 / WIP 作業中 / - 未着手

## ディレクトリ構成

```
.
├── README.md                 # プロジェクトの概要と対応表（マトリクス）
├── approval_request/         # お題1: 稟議申請システム
│   └── spec.md               # お題の仕様・要件定義（自然言語）
└── scripts/                  # カタログ生成などの自動化スクリプト
```

お題を追加するときは `<topic>/spec.md` を作成し、上記マトリクスに行を追加する。
記述言語ごとのモデルは `<topic>/<language>/` 配下に置く（例: `approval_request/alloy/approval.als`）。
ディレクトリ名・ファイル名は英語、文書の本文は日本語で記述する。
