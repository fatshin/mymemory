import XCTest

/// 振り返りを見出しごとのカードに分ける処理。分け方を誤ると TODO が別の見出しのカードに混ざる。
final class ReflectionSectionsTests: XCTestCase {
    func testSplitsByHeadings() {
        let s = """
        【1日の流れ】
        - 朝: 打ち合わせ
        【TODO】
        - 資料を送る (田中さん / 金曜)
        【気づき】
        - 価格の話が3回出た
        """
        let r = ReflectionSections.parse(s)
        XCTAssertEqual(r.map(\.title), ["1日の流れ", "TODO", "気づき"])
        XCTAssertEqual(r[1].body, "- 資料を送る (田中さん / 金曜)")
    }

    /// 見出しの無い旧形式の振り返りも、本文を失わず 1 枚で出す。
    func testNoHeadingsKeepsWholeText() {
        let r = ReflectionSections.parse("(1)流れ\n朝に会議\n")
        XCTAssertEqual(r, [.init(title: nil, body: "(1)流れ\n朝に会議")])
    }

    /// 「【重要】請求書を送る」は項目であって見出しではない。
    func testBracketedItemIsNotHeading() {
        let r = ReflectionSections.parse("【TODO】\n【重要】請求書を送る")
        XCTAssertEqual(r, [.init(title: "TODO", body: "【重要】請求書を送る")])
    }

    func testHeadingWithInlineBody() {
        let r = ReflectionSections.parse("【決定事項】: 月額は無料にする")
        XCTAssertEqual(r, [.init(title: "決定事項", body: "月額は無料にする")])
    }
}

/// メイン画面の「今日の要点」と一覧の 1 行目。注記や「なし」を内容として出さない。
final class ReflectionKeyPointTests: XCTestCase {
    func testFirstItemUnderHeadingSkipsNoneAndRouteLabel() {
        let s = "【要点】\n- なし\n- 価格は無料にする\n【TODO】\n- 画像を撮る\n\n(OpenAI で要約)"
        XCTAssertEqual(ReflectionSections.firstItem(in: s, under: "要点"), "価格は無料にする")
        XCTAssertEqual(ReflectionSections.firstItem(in: "【要点】\n- なし\n\n(端末内で要約)", under: "要点"), nil)
    }

    func testRouteLabelIsNotBody() {
        let r = ReflectionSections.parse("【要点】\n- A\n\n(端末内で要約)")
        XCTAssertEqual(r, [.init(title: "要点", body: "- A")])
    }

    /// 見出しの直後に箇条書きが続いても、【重要】のような項目は見出しにしない。
    func testBracketWithBulletIsItem() {
        let r = ReflectionSections.parse("【TODO】\n【重要】- 請求書を送る")
        XCTAssertEqual(r, [.init(title: "TODO", body: "【重要】- 請求書を送る")])
    }

    func testStoreKeyIsPerDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let d = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 23, minute: 59))!
        XCTAssertEqual(ReflectionStore.key(for: d, calendar: cal), "reflection.2026-11-02")
    }
}

/// メイン画面の判断に使う規則。誤ると TODO が要点に出たり、古い振り返りが最新に見えたりする。
final class HomeRulesTests: XCTestCase {
    func testKeyPointDoesNotFallBackToTodo() {
        XCTAssertNil(ReflectionSections.keyPoint(in: "【要点】\n- なし\n【TODO】\n- 画像を撮る"))
        XCTAssertEqual(ReflectionSections.keyPoint(in: "・旧形式の要点\n・二つ目"), "旧形式の要点")
    }

    func testRouteLabelExtracted() {
        XCTAssertEqual(ReflectionSections.routeLabel(in: "【要点】\n- A\n\n(OpenAI で要約)\n"), "(OpenAI で要約)")
        XCTAssertNil(ReflectionSections.routeLabel(in: "【要点】\n- A"))
    }

    func testStalenessCountsAddedRecordings() {
        let t = Date(timeIntervalSince1970: 1_000)
        let saved = ReflectionStore.Saved(text: "x", recordingCount: 2, latestStart: t)
        XCTAssertEqual(saved.added(currentCount: 2, currentLatest: t), 0)
        XCTAssertEqual(saved.added(currentCount: 3, currentLatest: t.addingTimeInterval(60)), 1)
        // 生成時の情報が無い古い保存は、増えたと判断しない
        XCTAssertEqual(ReflectionStore.Saved(text: "x", recordingCount: 0, latestStart: nil).added(currentCount: 5, currentLatest: t), 0)
    }

    func testPurgeKeepsOnlyDaysWithRecordings() {
        let d = UserDefaults(suiteName: "HomeRulesTests")!
        d.removePersistentDomain(forName: "HomeRulesTests")
        let cal = Calendar(identifier: .gregorian)
        let day1 = cal.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let day2 = cal.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        ReflectionStore.save("a", for: day1, recordingCount: 1, latestStart: day1, defaults: d, calendar: cal)
        ReflectionStore.save("b", for: day2, recordingCount: 1, latestStart: day2, defaults: d, calendar: cal)
        ReflectionStore.purge(keepingDays: [day2], defaults: d, calendar: cal)
        XCTAssertNil(ReflectionStore.load(day1, defaults: d, calendar: cal))
        XCTAssertEqual(ReflectionStore.load(day2, defaults: d, calendar: cal)?.text, "b")
    }
}

final class NoneAndLabelTests: XCTestCase {
    func testNoneVariantsAreSkipped() {
        XCTAssertNil(ReflectionSections.keyPoint(in: "【要点】\n- なし。\n-(なし)\n1. 特になし"))
        XCTAssertEqual(ReflectionSections.keyPoint(in: "【要点】\n1. 価格を決めた"), "価格を決めた")
    }

    /// 最後の節が空でも、注記を TODO として拾わない。
    func testRouteLabelIsNotTodo() {
        let r = SummarySections.parse("【TODO】\n- なし\n\n(端末内で要約)")
        XCTAssertTrue(r.todos.isEmpty)
    }
}

final class OverviewContextTests: XCTestCase {
    /// やることの出どころとして、概要の 1 文目だけを添える。
    func testOverviewSentence() {
        XCTAssertEqual(ReflectionSections.overviewSentence(in: "【概要】\n田中さんとB社の見積もりについて話した。来週送る。\n【要点】\n- A"),
                       "田中さんとB社の見積もりについて話した。")
        XCTAssertNil(ReflectionSections.overviewSentence(in: "【要点】\n- A"))
    }
}

final class ReplacingSectionTests: XCTestCase {
    /// 振り返りの【TODO】だけを差し替え、他の節と注記は残す。
    func testReplaceTodoSection() {
        let s = "【1日の流れ】\n- 朝\n【TODO】\n- 古い\n- 古い2\n\n【気づき】\n- 傾向\n\n(端末内で要約)"
        let out = ReflectionSections.replacingSection("TODO", in: s, with: "- 新しい")
        XCTAssertEqual(ReflectionSections.parse(out).map(\.title), ["1日の流れ", "TODO", "気づき"])
        XCTAssertEqual(ReflectionSections.parse(out)[1].body, "- 新しい")
        XCTAssertEqual(ReflectionSections.routeLabel(in: out), "(端末内で要約)")
        XCTAssertEqual(ReflectionSections.replacingSection("TODO", in: "【要点】\n- A", with: "- x"), "【要点】\n- A")
    }
}

final class EditingLineTests: XCTestCase {
    private let text = "【1日の流れ】\n- 朝: 散歩\n- 昼: テレビの通販番組で鍋を買うと決めた\n\n【気づき】\n- 傾向A\n\n(端末内で要約)"

    /// 間違った項目だけを直し、記号・他の節・注記は残す。
    func testEditKeepsBulletAndOtherSections() {
        let out = ReflectionSections.editingLine(in: text, section: 0, line: 1, to: "昼: テレビを見ていた")
        let sections = ReflectionSections.parse(out)
        XCTAssertEqual(sections[0].body, "- 朝: 散歩\n- 昼: テレビを見ていた")
        XCTAssertEqual(sections[1].body, "- 傾向A")
        XCTAssertEqual(ReflectionSections.routeLabel(in: out), "(端末内で要約)")
    }

    /// 削除は 1 行だけ。節が空になったら見出しは残して「- なし」にする (見出しで読む処理を壊さない)。
    func testDeleteLineAndEmptySectionBecomesNone() {
        let one = ReflectionSections.editingLine(in: text, section: 0, line: 0, to: "")
        XCTAssertEqual(ReflectionSections.parse(one)[0].body, "- 昼: テレビの通販番組で鍋を買うと決めた")
        let empty = ReflectionSections.editingLine(in: text, section: 1, line: 0, to: "  ")
        XCTAssertEqual(ReflectionSections.parse(empty).map(\.title), ["1日の流れ", "気づき"])
        XCTAssertEqual(ReflectionSections.parse(empty)[1].body, "- なし")
        XCTAssertEqual(ReflectionSections.routeLabel(in: empty), "(端末内で要約)")
    }

    /// 画面の行番号 (items) と書き換える行が一致する。範囲外は何も変えない。
    func testIndexesMatchItemsAndOutOfRangeIsNoop() {
        let sections = ReflectionSections.parse(text)
        XCTAssertEqual(ReflectionSections.items(of: sections[0]).count, 2)
        XCTAssertEqual(ReflectionSections.editingLine(in: text, section: 0, line: 5, to: "x"), text)
        XCTAssertEqual(ReflectionSections.editingLine(in: text, section: 9, line: 0, to: "x"), text)
        let inline = "【気づき】: 一言だけ\n- 二つ目"
        XCTAssertEqual(ReflectionSections.items(of: ReflectionSections.parse(inline)[0]), ["一言だけ", "- 二つ目"])
        let edited = ReflectionSections.editingLine(in: inline, section: 0, line: 0, to: "直した")
        XCTAssertEqual(ReflectionSections.parse(edited)[0].body, "直した\n- 二つ目")
    }
}

final class EditingLineGuardTests: XCTestCase {
    /// 数字で始まる文の数字を記号として消さない。見出しや注記の形の文を入れても節は増えない。
    func testNumbersKeptAndHeadingLikeInputDoesNotSplitSections() {
        XCTAssertEqual(ReflectionSections.stripEditBullet("10.5万円の見積もり"), "10.5万円の見積もり")
        XCTAssertEqual(ReflectionSections.stripEditBullet("1. 朝の散歩"), "朝の散歩")
        let text = "前置きの一文\n【気づき】\n傾向A\n\r\n(端末内で要約)"
        let out = ReflectionSections.editingLine(in: text, section: 1, line: 0, to: "【メモ】大事")
        XCTAssertEqual(ReflectionSections.parse(out).map(\.title), [nil, "気づき"])
        XCTAssertEqual(ReflectionSections.parse(out)[1].body, "- 【メモ】大事")
        XCTAssertEqual(ReflectionSections.parse(ReflectionSections.editingLine(in: text, section: 0, line: 0, to: "直した"))[0].body, "直した")
    }
}
