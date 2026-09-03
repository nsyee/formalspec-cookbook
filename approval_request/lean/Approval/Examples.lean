import Approval.Properties
import Approval.Scenario

/-!
# 具体的な組織と、仕様のシナリオ

ユーザー 3 人、部署 2 つ、うち 1 人は兼務:

| ユーザー | sales        | eng          |
| ------ | ------------ | ------------ |
| alice  | 一般メンバー   | –            |
| bob    | 上長         | –            |
| carol  | 一般メンバー   | 上長         |

下の `example` は `decide` で検査され（カーネルが `Action.apply` を評価する）、
各シナリオもコンパイル時に `#guard` で検査される。CLI（`lake exe approval`）は
同じシナリオを、読めるトレースとして再生する。
-/

namespace Approval.Examples

inductive User where
  | alice
  | bob
  | carol
  deriving DecidableEq, Repr

inductive Dept where
  | sales
  | eng
  deriving DecidableEq, Repr

open User Dept

instance : ToString User := ⟨fun u => match u with | alice => "alice" | bob => "bob" | carol => "carol"⟩
instance : ToString Dept := ⟨fun d => match d with | sales => "sales" | eng => "eng"⟩

def dir : Directory User Dept where
  role
    | alice, sales => some .member
    | bob, sales => some .manager
    | carol, sales => some .member
    | carol, eng => some .manager
    | _, _ => none

/-- 各部署に上長が 1 名以上いることを、証人を明示して示す。 -/
theorem dir_wf : dir.WF where
  managerExists
    | sales => ⟨bob, rfl⟩
    | eng => ⟨carol, rfl⟩

/-! ## 評価だけで判定できる、単一遷移についての事実 -/

def aliceDraft : Request User Dept := { author := alice, target := sales }
def alicePending : Request User Dept := { aliceDraft with status := .pending }
def carolPending : Request User Dept := { author := carol, target := sales, status := .pending }
def bobPending : Request User Dept := { author := bob, target := sales, status := .pending }

/-- C: 作成者が Draft を提出する。 -/
example : Step dir alice .submit aliceDraft alicePending := by decide

/-- D: 申請先部署の上長が承認する。 -/
example : Step dir bob (.decide .approve) alicePending { alicePending with status := .approved } := by
  decide

/-- 自己決裁: bob は作成者であり、*かつ* sales の上長でもある。 -/
example : Step dir bob (.decide .approve) bobPending { bobPending with status := .approved } := by
  decide

/-- P1: carol は eng の上長だが sales では一般メンバーなので、自分が作成した
sales 宛ての申請を承認できない。 -/
example : ¬ Step dir carol (.decide .approve) carolPending { carolPending with status := .approved } := by
  decide

/-- 同じ事実を、評価ではなく一般の定理から導いたもの。 -/
example : ¬ Step dir carol (.decide .approve) carolPending { carolPending with status := .approved } :=
  P1_no_authority_leak (x := eng) rfl rfl

/-- U2: 同じ部署の一般メンバー（carol）は alice の Draft を編集できないが、
上長（bob）は編集できる（U3）。 -/
example : ¬ dir.CanEdit carol aliceDraft := by decide
example : dir.CanEdit bob aliceDraft := by decide

/-- U1: 作成者は `Draft` の間は編集できるが、`Pending` になると編集できない。 -/
example : dir.CanEdit alice aliceDraft := by decide
example : ¬ dir.CanEdit alice alicePending := by decide

/-- R2: 所属していない部署宛ての申請は閲覧できない。alice は eng 宛ての申請を読めない。 -/
example : ¬ dir.CanRead alice { author := carol, target := eng } := by decide

/-- 証明項として書いた完全なトレース: alice の申請が差し戻しと再提出を経て承認される。 -/
example : Reachable dir { aliceDraft with status := .approved } :=
  .step (actor := bob) (.step (actor := alice) (.step (actor := bob) (.step (actor := alice)
    (.create (by decide))
    (.submit rfl (.inl rfl)))
    (.decide .«return» rfl rfl))
    (.submit rfl (.inr rfl)))
    (.decide .approve rfl rfl)

/-! ## シナリオ（CLI が再生する） -/

def happyPath : Scenario User Dept where
  name := "happy-path"
  description := "alice drafts, edits, submits; bob approves; nothing moves afterwards (P2)"
  dir := dir
  initial := aliceDraft
  script := [
    (alice, .edit, .ok .draft),
    (alice, .submit, .ok .pending),
    (bob, .decide .approve, .ok .approved),
    (bob, .edit, .denied .wrongState),
    (alice, .submit, .denied .wrongState),
    (bob, .decide .reject, .denied .wrongState),
  ]

def roundTrip : Scenario User Dept where
  name := "round-trip"
  description := "return, author edits and resubmits, then rejected"
  dir := dir
  initial := aliceDraft
  script := [
    (alice, .submit, .ok .pending),
    (alice, .edit, .denied .wrongState),
    (bob, .edit, .ok .pending),
    (bob, .decide .«return», .ok .returned),
    (alice, .edit, .ok .returned),
    (alice, .submit, .ok .pending),
    (bob, .decide .reject, .ok .rejected),
  ]

def crossAffiliation : Scenario User Dept where
  name := "cross-affiliation"
  description := "carol (eng manager, sales member) cannot use her eng authority on a sales request (P1)"
  dir := dir
  initial := { author := carol, target := sales }
  script := [
    (carol, .submit, .ok .pending),
    (carol, .decide .approve, .denied .notManager),
    (carol, .decide .«return», .denied .notManager),
    (alice, .edit, .denied .notManager),
    (bob, .decide .approve, .ok .approved),
  ]

def selfApproval : Scenario User Dept where
  name := "self-approval"
  description := "bob, sales manager, approves his own sales request"
  dir := dir
  initial := { author := bob, target := sales }
  script := [
    (alice, .submit, .denied .notAuthor),
    (bob, .submit, .ok .pending),
    (bob, .decide .approve, .ok .approved),
  ]

def engRequest : Scenario User Dept where
  name := "eng-request"
  description := "in eng, carol is the manager: she approves her own request there"
  dir := dir
  initial := { author := carol, target := eng }
  script := [
    (carol, .submit, .ok .pending),
    (bob, .decide .approve, .denied .notManager),
    (carol, .decide .approve, .ok .approved),
  ]

def scenarios : List (Scenario User Dept) :=
  [happyPath, roundTrip, crossAffiliation, selfApproval, engRequest]

#guard scenarios.all Scenario.passes

end Approval.Examples
