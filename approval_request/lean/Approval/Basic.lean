/-!
# 稟議申請ワークフロー — 構成要素（仕様 §1, §2）

ユーザーと部署は抽象的な型（`U`, `D`）のままにしておく。モデルが必要とするのは
それらの上の決定可能な等価性だけである。役職は `Directory` を通して
(ユーザー, 部署) の *組* に対して与え、ユーザー単体には与えない（仕様 §6）。
-/

namespace Approval

/-- *ある部署での* ユーザーの役職（仕様 §1 「所属と役職」）。 -/
inductive Role where
  | member
  | manager
  deriving DecidableEq, Repr

/-- 稟議申請の状態（仕様 §2）。 -/
inductive Status where
  | draft
  | pending
  | returned
  | approved
  | rejected
  deriving DecidableEq, Repr

namespace Status

/-- 終端状態。どのアクションでもここからは出られない（仕様 §2, P2）。 -/
abbrev IsTerminal (s : Status) : Prop := s = approved ∨ s = rejected

/-- 作成者が提出（再提出）できる状態（仕様 §4 C）。 -/
abbrev Submittable (s : Status) : Prop := s = draft ∨ s = returned

theorem Submittable.not_terminal {s : Status} (h : s.Submittable) : ¬ s.IsTerminal := by
  rcases h with rfl | rfl <;> simp

theorem pending_not_terminal : ¬ pending.IsTerminal := by simp

end Status

/-- 稟議申請。`author`（作成者）と `target`（申請先部署）は作成時に定まり、
変化するのは `status` だけ。 -/
structure Request (U D : Type) where
  author : U
  target : D
  status : Status := .draft
  deriving DecidableEq, Repr

/-- 誰がどこでどの役職を持つか。`role u d = none` は `u` が `d` に所属していないこと。 -/
structure Directory (U D : Type) where
  role : U → D → Option Role

namespace Directory

variable {U D : Type} (dir : Directory U D)

/-- `u` が何らかの役職で `d` に所属している（仕様 §1）。 -/
abbrev Affiliated (u : U) (d : D) : Prop := dir.role u d ≠ none

/-- `u` が *`d` の* 上長である — このモデルにおける権限の唯一の根拠。 -/
abbrev IsManager (u : U) (d : D) : Prop := dir.role u d = some .manager

abbrev IsMember (u : U) (d : D) : Prop := dir.role u d = some .member

variable {dir}

theorem IsManager.affiliated {u : U} {d : D} (h : dir.IsManager u d) : dir.Affiliated u d := by
  simp [h]

theorem IsMember.not_manager {u : U} {d : D} (h : dir.IsMember u d) : ¬ dir.IsManager u d := by
  simp [h]

/-- ディレクトリの構造上の不変条件: 各部署には上長が 1 名以上存在する（仕様 §1）。 -/
structure WF (dir : Directory U D) : Prop where
  managerExists : ∀ d : D, ∃ u : U, dir.IsManager u d

end Directory

end Approval
