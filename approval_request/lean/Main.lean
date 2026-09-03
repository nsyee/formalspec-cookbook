import Approval

/-!
CLI: `Approval.Examples` のシナリオを、読めるトレースとして再生する。

    approval              すべてのシナリオを実行
    approval NAME...      名前を指定したシナリオを実行
    approval --list       シナリオ名を一覧表示

期待を満たさない行が 1 つでもあれば、終了ステータスは 1 になる。
-/

open Approval Approval.Examples

def runScenario (s : Scenario User Dept) : IO Bool := do
  IO.println s!"== {s.name}: {s.description}"
  IO.println s!"     initial: {s.initial}"
  let outcomes := s.run
  for o in outcomes do
    IO.println s!"  {o.show}"
  let ok := outcomes.all Outcome.met
  IO.println s!"     {if ok then "passed" else "FAILED"} ({outcomes.length} steps)"
  IO.println ""
  return ok

def main (args : List String) : IO UInt32 := do
  if args = ["--list"] then
    for s in scenarios do
      IO.println s!"{s.name}\t{s.description}"
    return 0
  let selected ← if args.isEmpty then pure scenarios else
    args.mapM fun name =>
      match scenarios.find? (·.name = name) with
      | some s => pure s
      | none => throw <| IO.userError s!"no scenario named {name} (see --list)"
  let mut failed := 0
  for s in selected do
    unless ← runScenario s do failed := failed + 1
  IO.println s!"{selected.length - failed}/{selected.length} scenarios passed"
  return if failed = 0 then 0 else 1
