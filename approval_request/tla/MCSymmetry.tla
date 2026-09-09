------------------------------ MODULE MCSymmetry ------------------------------
\* typecheck: skip
(***************************************************************************)
(* 不変条件の検査（MCSafety.cfg）で使う対称性集合。                          *)
(*                                                                         *)
(* ユーザー・部署・申請・内容はいずれも互換な模型値（model value）なので、それ *)
(* らの置換で状態空間を商にできる。不変条件の検査では健全で、探索する状態数が  *)
(* 大きく減る（活性の検査には使えないので、そちらの .cfg では指定しない）。    *)
(*                                                                         *)
(* Permutations(User) と Permutations(Department) は要素の型が異なる集合なの *)
(* で、その合併は Snowcat では型付けできない。Apalache は対称性を使わないため、 *)
(* このモジュールだけ型検査の対象から外す（先頭の `typecheck: skip`）。        *)
(***************************************************************************)
EXTENDS MCApproval, TLC

Symmetry ==
    Permutations(User) \cup Permutations(Department)
        \cup Permutations(Request) \cup Permutations(Revision)

==============================================================================
