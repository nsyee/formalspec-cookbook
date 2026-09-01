// -*- mode: quint -*-
//
// 検証用のモデル（インスタンス）とシナリオテスト。
//
// Quint では「仕様」と「検証スコープ」をモジュールのインスタンス化で分ける。
// TLA+ の .cfg に当たるものが、型の付いた Quint のコードとしてここに書ける。
// 定数はモジュールの引数なので、スコープを変えたモデルを並べて置ける。

/// Apalache による網羅検証用の小さなスコープ。ユーザー 3・部署 2・申請 1・内容 2。
/// P1 は「部署 2 つ・ユーザー 3 人」で兼務パターンが出そろう。
module smallModel {
  import approval(
    USERS = Set("amy", "ben", "cho"),
    DEPTS = Set("sales", "legal"),
    IDS = Set(1),
    CONTENTS = Set("v1", "v2"),
  ).* from "./approval"
}

/// ランダムシミュレーション用の少し大きなスコープ。申請が 2 件同時に走る。
module simulatedModel {
  import approval(
    USERS = Set("amy", "ben", "cho"),
    DEPTS = Set("sales", "legal"),
    IDS = Set(1, 2),
    CONTENTS = Set("v1", "v2"),
  ).* from "./approval"

  /// 探索がどれだけ「面白い」振る舞いに到達したかを数えるための証人。
  /// quint run --witnesses に渡すと、何本のトレースで真になったかを報告する。
  /// TLA+ で反例を出させて到達可能性を確かめる技法の、直接的な代替になる。
  val witnessSelfDecision: bool =
    match lastEvent {
      | Decided(p) => p.by == requestOf(p.id).author
      | _ => false
    }

  val witnessManagerEditedOthersRequest: bool =
    match lastEvent {
      | Edited(p) => p.by != requestOf(p.id).author
      | _ => false
    }

  val witnessReturned: bool =
    live.exists(id => requestOf(id).status == Returned)

  val witnessBothRequestsTerminal: bool =
    IDS.forall(id => live.contains(id) and isTerminal(requestOf(id).status))
}

/// シナリオテスト用のモデル。組織図を決め打ちにして、仕様どおりの手順が
/// 実行できること（と、できてはいけない手順が失敗すること）を run で書く。
///
/// TLA+ では「シナリオの否定を不変条件にして反例を読む」という間接的な方法を
/// とったが、Quint の run は手順そのものを実行できるテストとして書ける。
module scenarios {
  import approval(
    USERS = Set("amy", "ben", "cho", "dan"),
    DEPTS = Set("sales", "legal"),
    IDS = Set(1, 2),
    CONTENTS = Set("v1", "v2"),
  ).* from "./approval"

  /// amy は営業部の上長でありながら法務部では一般メンバー（兼務）。
  /// ben と dan は営業部の一般メンバー、cho は法務部の上長。
  pure val orgChart: OrgChart = Map(
    "amy" -> Map("sales" -> Holds(Manager), "legal" -> Holds(Member)),
    "ben" -> Map("sales" -> Holds(Member), "legal" -> Outsider),
    "cho" -> Map("sales" -> Outsider, "legal" -> Holds(Manager)),
    "dan" -> Map("sales" -> Holds(Member), "legal" -> Outsider),
  )

  /// 組織図が spec.md §1 の仮定を満たしていること（テストの前提の健全性）。
  run orgChartIsWellFormedTest =
    setup(orgChart).expect(orgChartIsWellFormed)

  /// 作成 → 提出 → 承認。上長 amy が営業部宛ての申請を承認する。
  run happyPathTest =
    setup(orgChart)
      .then(create("ben", "sales", 1, "v1"))
      .expect(requestOf(1).status == Draft)
      .then(submit("ben", 1))
      .expect(requestOf(1).status == Pending)
      .then(approve("amy", 1))
      .expect(requestOf(1).status == Approved)

  /// 提出 → 差し戻し → 編集 → 再提出 → 承認の往復（spec.md §2 の図の一周）。
  run returnRoundTripTest =
    setup(orgChart)
      .then(create("ben", "sales", 1, "v1"))
      .then(submit("ben", 1))
      .then(returnBack("amy", 1))
      .expect(requestOf(1).status == Returned)
      .then(edit("ben", 1, "v2"))
      .expect(requestOf(1).content == "v2" and requestOf(1).status == Returned)
      .then(submit("ben", 1))
      .then(approve("amy", 1))
      .expect(requestOf(1).status == Approved)

  /// 自己決裁は許可される: amy は営業部の上長なので、自分の申請を承認できる
  /// （spec.md §4 D の注記）。
  run selfApprovalTest =
    setup(orgChart)
      .then(create("amy", "sales", 1, "v1"))
      .then(submit("amy", 1))
      .then(approve("amy", 1))
      .expect(requestOf(1).status == Approved)

  /// P1 兼務ユーザーの権限分離: amy は営業部の上長だが、法務部宛ての自分の申請
  /// は承認できない。決裁できるのは法務部の上長 cho だけである。
  run crossAffiliationApprovalTest =
    setup(orgChart)
      .then(create("amy", "legal", 1, "v1"))
      .then(submit("amy", 1))
      .expect(and { not(canDecide("amy", 1)), canDecide("cho", 1) })
      .then(approve("cho", 1))
      .expect(requestOf(1).status == Approved)

  /// 同じ状況で、amy による承認アクションそのものが起こり得ないこと。
  /// action.fail() はアクションが偽になる（＝遷移が存在しない）ことを主張する。
  run crossAffiliationApprovalIsImpossibleTest =
    setup(orgChart)
      .then(create("amy", "legal", 1, "v1"))
      .then(submit("amy", 1))
      .then(approve("amy", 1).fail())

  /// U1 / U2 / U3: 作成者は Draft を編集でき、同じ部署の他の一般メンバーは
  /// 編集できず、申請先部署の上長は Pending でも編集できる。
  run editPermissionTest =
    setup(orgChart)
      .then(create("ben", "sales", 1, "v1"))
      .expect(and {
        canEdit("ben", 1),        // U1: 作成者本人
        not(canEdit("dan", 1)),   // U2: 同じ部署の他の一般メンバー
        not(canEdit("cho", 1)),   // R2: 非所属の上長
        canEdit("amy", 1),        // U3: 申請先部署の上長
      })
      .then(edit("ben", 1, "v2"))
      .expect(requestOf(1).content == "v2")
      .then(submit("ben", 1))
      .expect(and { not(canEdit("ben", 1)), canEdit("amy", 1) })
      .then(edit("amy", 1, "v1"))
      .expect(requestOf(1).content == "v1" and requestOf(1).status == Pending)

  /// Pending の申請を作成者本人が編集するアクションは存在しない（U1）。
  run authorCannotEditPendingTest =
    setup(orgChart)
      .then(create("ben", "sales", 1, "v1"))
      .then(submit("ben", 1))
      .then(edit("ben", 1, "v2").fail())

  /// P2 終端状態の不変性: 却下された申請は、誰も動かせない。
  run terminalIsFrozenTest =
    setup(orgChart)
      .then(create("ben", "sales", 1, "v1"))
      .then(submit("ben", 1))
      .then(reject("amy", 1))
      .expect(requestOf(1).status == Rejected)
      .expect(terminalRequestsAreFrozen)
      .then(approve("amy", 1).fail())

  /// R1 / R2: 閲覧できるのは申請先部署に所属しているユーザーだけ。
  run readPermissionTest =
    setup(orgChart)
      .then(create("ben", "sales", 1, "v1"))
      .expect(and {
        canRead("ben", 1),
        canRead("amy", 1),
        canRead("dan", 1),
        not(canRead("cho", 1)),
      })

  /// 申請先は所属部署に限られる（spec.md §4 A の事前条件）。
  run createRequiresAffiliationTest =
    setup(orgChart)
      .then(create("ben", "sales", 1, "v1"))
      .then(create("cho", "legal", 2, "v1"))
      .expect(live == Set(1, 2))

  /// ben は法務部に所属していないので、法務部宛ての申請は作成できない。
  run createOutsideAffiliationIsImpossibleTest =
    setup(orgChart)
      .then(create("ben", "legal", 1, "v1").fail())

  /// 2 件の申請が独立に進むこと（フレーム条件の確認）。
  run independentRequestsTest =
    setup(orgChart)
      .then(create("ben", "sales", 1, "v1"))
      .then(create("cho", "legal", 2, "v1"))
      .then(submit("ben", 1))
      .then(approve("amy", 1))
      .expect(requestOf(1).status == Approved and requestOf(2).status == Draft)
}
