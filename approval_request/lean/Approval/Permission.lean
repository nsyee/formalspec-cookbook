import Approval.Basic

/-!
# 閲覧・編集権限（仕様 §3）

権限は (ディレクトリ, 実行者, 申請) 上の述語であり、申請を変えない。いずれも
決定可能なので、具体例は `decide` で判定でき、実行可能な意味からも検査できる。
-/

namespace Approval

variable {U D : Type}

namespace Directory

variable (dir : Directory U D) (actor : U) (r : Request U D)

/-- R1 / R2: 実行者が申請先部署に所属しているときに限り閲覧できる。 -/
abbrev CanRead : Prop := dir.Affiliated actor r.target

/-- U1（作成者本人、`Draft` / `Returned` のとき）または U3（申請先部署の上長、
終端状態でないとき）。U2 はこれ以外の項がないことそのもの。 -/
abbrev CanEdit : Prop :=
  (actor = r.author ∧ r.status.Submittable) ∨
  (dir.IsManager actor r.target ∧ ¬ r.status.IsTerminal)

variable {dir actor r}

theorem CanEdit.not_terminal (h : dir.CanEdit actor r) : ¬ r.status.IsTerminal := by
  rcases h with ⟨_, hs⟩ | ⟨_, hs⟩
  · exact hs.not_terminal
  · exact hs

/-- U2: 同じ部署の一般メンバーであっても、作成者本人でなければ編集できない。 -/
theorem IsMember.not_canEdit (hm : dir.IsMember actor r.target) (ha : actor ≠ r.author) :
    ¬ dir.CanEdit actor r := by
  rintro (⟨h, _⟩ | ⟨h, _⟩)
  · exact ha h
  · exact hm.not_manager h

/-- 編集権限が部外者に何かを与えることはない: 作成者が申請先部署に所属している限り、
`CanEdit` は `CanRead` を含意する。 -/
theorem CanEdit.canRead (h : dir.CanEdit actor r) (hauthor : dir.Affiliated r.author r.target) :
    dir.CanRead actor r := by
  rcases h with ⟨rfl, _⟩ | ⟨hm, _⟩
  · exact hauthor
  · exact hm.affiliated

end Directory

end Approval
