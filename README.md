# formalspec-cookbook

A cookbook that models the same topics in several formal specification languages, to compare
their expressiveness, ergonomics and verification capabilities.

Each topic directory holds a natural-language specification (`spec.md`) plus one directory per language.

## Matrix

| Topic | Spec | Alloy | TLA+ | Quint |
| --- | --- | --- | --- | --- |
| Approval request workflow (稟議申請) | [spec.md](approval_request/spec.md) | - | - | - |

Legend: `done` implemented / `wip` in progress / `-` not started.

## Layout

```
.
├── README.md                 # project overview and the matrix
├── approval_request/         # topic 1: approval request workflow
│   └── spec.md               # requirements in natural language
└── scripts/                  # automation scripts (catalog generation, etc.)
```

To add a topic, create `<topic>/spec.md` and add a row to the matrix above.
Language models go under `<topic>/<language>/`, e.g. `approval_request/alloy/approval.als`.
