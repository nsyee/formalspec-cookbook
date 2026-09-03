import Approval.Step

/-!
# 検証した性質（仕様 §5 と、その背後にある不変条件）

ここの命題はすべて、*あらゆる* ディレクトリ・ユーザー・部署・申請についての定理であり、
ユーザー数や部署数の上限は一切使わない。`Step` への `cases` による証明はアクションを
列挙するので、`Step` にアクションを追加してここの性質を見直さなければコンパイルエラーになる。
-/

namespace Approval

variable {U D : Type} {dir : Directory U D} {actor : U} {a : Action} {r r' : Request U D}

/-! ## 遷移が変えられるものと変えられないもの -/

/-- 遷移は作成者と申請先部署には一切触れない（仕様 §1）。 -/
theorem Step.author_eq (h : Step dir actor a r r') : r'.author = r.author := by
  cases h <;> rfl

theorem Step.target_eq (h : Step dir actor a r r') : r'.target = r.target := by
  cases h <;> rfl

/-- 遷移を開始できるのは、終端状態でない申請からだけ。 -/
theorem Step.not_terminal (h : Step dir actor a r r') : ¬ r.status.IsTerminal := by
  cases h with
  | edit hc => exact hc.not_terminal
  | submit _ hs => exact hs.not_terminal
  | decide _ _ hs => rw [hs]; exact Status.pending_not_terminal

/-! ## P2 — 終端状態の不変性 -/

/-- `Approved` または `Rejected` の申請には、どのアクションも適用できない。 -/
theorem P2_terminal_stuck (hterm : r.status.IsTerminal) : ¬ Step dir actor a r r' :=
  fun h => h.not_terminal hterm

/-- 仕様の言い方に合わせた形: 終端状態の申請の状態は決して変わらない。 -/
theorem P2_terminal_status_fixed (hterm : r.status.IsTerminal) (h : Step dir actor a r r') :
    r'.status = r.status :=
  absurd h (P2_terminal_stuck hterm)

/-! ## P1 — 権限は申請先部署での役職のみで判定する -/

/-- 他の状態から `Approved` に到達させられるのは、*申請先* 部署の上長だけである
（他モデルの `only_manager_can_approve` に相当）。 -/
theorem approved_by_target_manager (h : Step dir actor a r r')
    (hbefore : r.status ≠ .approved) (hafter : r'.status = .approved) :
    dir.IsManager actor r.target := by
  cases h with
  | edit => exact absurd hafter hbefore
  | submit => cases hafter
  | decide d hm _ => exact hm

/-- 決裁（承認 / 却下 / 差し戻し）はすべて、申請先部署の上長が行っている。 -/
theorem decision_by_target_manager {d : Decision} (h : Step dir actor (.decide d) r r') :
    dir.IsManager actor r.target := by
  cases h; assumption

/-- P1 本体: 部署 `x` の上長でありながら申請先部署 `y` では一般メンバーでしかない
ユーザーは、`y` 宛ての申請を——たとえ自分が作成したものでも——決裁できない。 -/
theorem P1_no_authority_leak {x : D} {d : Decision}
    (_hx : dir.IsManager actor x) (hy : dir.IsMember actor r.target) :
    ¬ Step dir actor (.decide d) r r' :=
  fun h => hy.not_manager (decision_by_target_manager h)

/-- 他人の申請を *編集* することさえ、申請先部署の上長にしかできない（U2）。 -/
theorem P1_no_edit_leak {x : D} (_hx : dir.IsManager actor x) (hy : dir.IsMember actor r.target)
    (hauthor : actor ≠ r.author) : ¬ Step dir actor .edit r r' := by
  intro h
  cases h with
  | edit hc => exact hy.not_canEdit hauthor hc

/-- 自己決裁は許可される（仕様 §4 D）。実行者が申請先部署の上長であれば、
作成者本人であることは障害にならない。 -/
theorem self_approval_allowed (hm : dir.IsManager r.author r.target) (hs : r.status = .pending) :
    Step dir r.author (.decide .approve) r { r with status := .approved } :=
  .decide .approve hm hs

/-! ## 到達可能な申請の不変条件 -/

/-- システム上のどの申請でも、作成者はその申請先部署に所属している。 -/
theorem Reachable.author_affiliated (h : Reachable dir r) : dir.Affiliated r.author r.target := by
  induction h with
  | create haff => exact haff
  | step _ hs ih => rw [hs.author_eq, hs.target_eq]; exact ih

/-- 作成者は自分の申請を常に閲覧できる（作成者にとっての R1）。 -/
theorem Reachable.author_canRead (h : Reachable dir r) : dir.CanRead r.author r :=
  h.author_affiliated

/-- `Approved` の申請は、`Pending` であったものを申請先部署の上長が承認したものであり、
承認はそれ以外の何も変えていない。 -/
theorem Reachable.approved_inversion (h : Reachable dir r) (hs : r.status = .approved) :
    ∃ (m : U) (r₀ : Request U D), Reachable dir r₀ ∧ r₀.status = .pending ∧
      dir.IsManager m r.target ∧ r = { r₀ with status := .approved } := by
  cases h with
  | create => cases hs
  | step hr hstep =>
    cases hstep with
    | edit hc => exact absurd hs (fun h => hc.not_terminal (.inl h))
    | submit => cases hs
    | decide d hm hpending =>
      cases d with
      | approve => exact ⟨_, _, hr, hpending, hm, rfl⟩
      | reject => cases hs
      | «return» => cases hs

/-! ## P3 — 迷子申請の不在 -/

/-- 正しいディレクトリの下では、どの申請にも決裁できるユーザーが存在し… -/
theorem P3_manager_exists (hwf : dir.WF) (r : Request U D) : ∃ m, dir.IsManager m r.target :=
  hwf.managerExists r.target

/-- …そのユーザーは `Pending` の間、実際に承認・却下・差し戻しを行える。 -/
theorem P3_pending_decidable (hwf : dir.WF) (hs : r.status = .pending) (d : Decision) :
    ∃ m, Step dir m (.decide d) r { r with status := d.outcome } :=
  let ⟨m, hm⟩ := hwf.managerExists r.target
  ⟨m, .decide d hm hs⟩

/-- 逆に、動けるのは終端状態でない申請だけである: 申請が行き止まるのは、それが終端状態である
ときに限る（正しいディレクトリの下では、`Pending` からは上長が常に動け、
`Draft` / `Returned` からは作成者が常に提出できる）。 -/
theorem stuck_iff_terminal (hwf : dir.WF) :
    (¬ ∃ (u : U) (a : Action) (r' : Request U D), Step dir u a r r') ↔ r.status.IsTerminal := by
  constructor
  · intro hstuck
    match hs : r.status with
    | .approved => exact .inl rfl
    | .rejected => exact .inr rfl
    | .pending =>
      obtain ⟨m, hm⟩ := P3_pending_decidable (r := r) hwf hs .approve
      exact absurd ⟨m, _, _, hm⟩ hstuck
    | .draft => exact absurd ⟨r.author, .submit, _, .submit rfl (.inl hs)⟩ hstuck
    | .returned => exact absurd ⟨r.author, .submit, _, .submit rfl (.inr hs)⟩ hstuck
  · rintro hterm ⟨_, _, _, h⟩
    exact P2_terminal_stuck hterm h

end Approval
