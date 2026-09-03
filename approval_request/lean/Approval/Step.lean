import Approval.Permission

/-!
# アクションと遷移関係（仕様 §4）

`Step dir actor a r r'` は帰納的な述語である。この型の値がそのまま、「`actor` は
`r` に対して `a` を実行でき、結果は `r'` になる」という証明になる。各コンストラクタは
対応する仕様項目の事前条件をそのまま持つので、`Step` への `cases` で証明した定理は、
アクションを追加したときに自動で網羅性を再検査される。

上長の決裁 3 種（D, E, F）は事前条件がすべて共通で、遷移先の状態だけが違うので、
`Decision` でパラメータ付けした 1 つのコンストラクタにまとめている。
-/

namespace Approval

variable {U D : Type}

/-- 申請先部署の上長が `Pending` の申請に対してできること。 -/
inductive Decision where
  | approve
  | reject
  | «return»
  deriving DecidableEq, Repr

/-- 各決裁が遷移先とする状態（仕様 §2 の図）。 -/
def Decision.outcome : Decision → Status
  | .approve => .approved
  | .reject => .rejected
  | .«return» => .returned

/-- 既存の申請に対するアクション。作成（仕様 §4 A）は `Reachable.create` が担う。 -/
inductive Action where
  | edit
  | submit
  | decide (d : Decision)
  deriving DecidableEq, Repr

/-- 遷移関係。 -/
inductive Step (dir : Directory U D) (actor : U) : Action → Request U D → Request U D → Prop where
  /-- B: 編集は内容を変えるだけで、状態は変えない。 -/
  | edit {r} (h : dir.CanEdit actor r) :
      Step dir actor .edit r r
  /-- C: 提出できるのは作成者だけで、`Draft` または `Returned` から行う。 -/
  | submit {r} (hauthor : actor = r.author) (hs : r.status.Submittable) :
      Step dir actor .submit r { r with status := .pending }
  /-- D / E / F: `Pending` の申請を決裁できるのは *申請先部署の* 上長だけ。 -/
  | decide {r} (d : Decision) (hmanager : dir.IsManager actor r.target) (hs : r.status = .pending) :
      Step dir actor (.decide d) r { r with status := d.outcome }

/-- システム上に存在しうる申請。所属するユーザーによって作成され（A）、
その後は正しい遷移によってのみ変化したもの。 -/
inductive Reachable (dir : Directory U D) : Request U D → Prop where
  | create {u : U} {d : D} (h : dir.Affiliated u d) :
      Reachable dir { author := u, target := d }
  | step {r r' : Request U D} {actor : U} {a : Action}
      (hr : Reachable dir r) (hs : Step dir actor a r r') :
      Reachable dir r'

/-! ## 実行可能な意味

`Action.apply` は、アクションを実行するか拒否の理由を返す *関数* である。
`apply_ok_iff` がこれが `Step` と厳密に一致することを証明するので、CLI の実行器と
証明は同じワークフローを語っている。 -/

/-- アクションが拒否された理由。 -/
inductive Denial where
  | notAuthor
  | notManager
  | wrongState
  deriving DecidableEq, Repr

variable [DecidableEq U]

def Action.apply (dir : Directory U D) (actor : U) : Action → Request U D → Except Denial (Request U D)
  | .edit, r =>
    if dir.CanEdit actor r then .ok r
    else if r.status.IsTerminal ∨ actor = r.author then .error .wrongState
    else .error .notManager
  | .submit, r =>
    if actor = r.author then
      if r.status.Submittable then .ok { r with status := .pending } else .error .wrongState
    else .error .notAuthor
  | .decide d, r =>
    if dir.IsManager actor r.target then
      if r.status = .pending then .ok { r with status := d.outcome } else .error .wrongState
    else .error .notManager

namespace Action

variable {dir : Directory U D} {actor : U} {a : Action} {r r' : Request U D}

/-- 健全性: `apply` が実行したことはすべて正しい遷移である。 -/
theorem apply_sound (h : a.apply dir actor r = .ok r') : Step dir actor a r r' := by
  cases a with
  | edit =>
    simp only [apply] at h
    split at h
    · cases h; exact .edit ‹_›
    · split at h <;> cases h
  | submit =>
    simp only [apply] at h
    split at h
    · split at h
      · cases h; exact .submit ‹_› ‹_›
      · cases h
    · cases h
  | decide d =>
    simp only [apply] at h
    split at h
    · split at h
      · cases h; exact .decide d ‹_› ‹_›
      · cases h
    · cases h

/-- 完全性: 正しい遷移はすべて `apply` が実行する。 -/
theorem apply_complete (h : Step dir actor a r r') : a.apply dir actor r = .ok r' := by
  cases h with
  | edit hc => simp [apply, hc]
  | submit ha hs => simp [apply, ha, hs]
  | decide d hm hs => simp [apply, hm, hs]

/-- `apply` は `Step` を関数として表したものにほかならない。 -/
theorem apply_ok_iff : a.apply dir actor r = .ok r' ↔ Step dir actor a r r' :=
  ⟨apply_sound, apply_complete⟩

/-- 拒否されたということは、正しい遷移が存在しないということ。 -/
theorem apply_error {e : Denial} (h : a.apply dir actor r = .error e) :
    ¬ ∃ r', Step dir actor a r r' := by
  rintro ⟨r', hs⟩
  rw [← apply_ok_iff, h] at hs
  cases hs

end Action

/-- 遷移関係は決定的: 1 つのアクションの結果は高々 1 つ。 -/
theorem Step.unique {dir : Directory U D} {actor : U} {a : Action} {r r₁ r₂ : Request U D}
    (h₁ : Step dir actor a r r₁) (h₂ : Step dir actor a r r₂) : r₁ = r₂ := by
  have := Action.apply_complete h₁
  rw [Action.apply_complete h₂] at this
  cases this
  rfl

/-- 遷移が存在するかどうかは、実行可能な意味を通して決定可能である。 -/
instance [DecidableEq D] {dir : Directory U D} {actor : U} {a : Action} {r r' : Request U D} :
    Decidable (Step dir actor a r r') :=
  match h : a.apply dir actor r with
  | .ok r'' =>
    decidable_of_iff (r'' = r') <| by
      rw [← Action.apply_ok_iff, h]
      exact ⟨fun e => e ▸ rfl, fun e => by cases e; rfl⟩
  | .error _ => isFalse fun hs => Action.apply_error h ⟨_, hs⟩

end Approval
