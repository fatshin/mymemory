import XCTest

/// 追加の指示は基本の指示の後ろに付くだけで、空なら基本の指示を変えないことを固定する (見出しの形式を守るため)。
final class SummaryPromptTests: XCTestCase {
    func testEmptyExtraKeepsBasePrompt() {
        XCTAssertEqual(SummaryPrompt.withCustom(SummaryPrompt.final, ""), SummaryPrompt.final)
        XCTAssertEqual(SummaryPrompt.withCustom(SummaryPrompt.final, "  \n "), SummaryPrompt.final)
    }

    func testExtraIsAppendedAfterBaseWithFormatGuard() {
        let p = SummaryPrompt.withCustom(SummaryPrompt.final, "TODO には担当者を必ず書く")
        XCTAssertTrue(p.hasPrefix(SummaryPrompt.final))
        XCTAssertTrue(p.hasSuffix("TODO には担当者を必ず書く"))
        XCTAssertTrue(p.contains("見出し・順序"))
    }

    func testExtraIsTrimmedAndCapped() {
        XCTAssertEqual(SummaryPrompt.clean(" a "), "a")
        XCTAssertEqual(SummaryPrompt.clean(String(repeating: "あ", count: 700)).count, SummaryPrompt.customMaxChars)
    }

    func testStatsCountsItemsPerSection() {
        let s = "【概要】\n話した。\n\n【要点】\n- A\n- B\n\n【決定事項】\n- なし\n\n【TODO】\n- 資料を送る\n\n(端末内で要約)"
        let st = SummaryPrompt.stats(s)
        XCTAssertEqual(st.keyPoints, 2)
        XCTAssertEqual(st.decisions, 0)
        XCTAssertEqual(st.todos, 1)
    }
}

/// 追加の指示で見出しが崩れた要約を見分ける (崩れたら追加の指示なしで作り直すため)。
final class SummaryPromptHeadingTests: XCTestCase {
    func testDetectsMissingHeadings() {
        XCTAssertTrue(SummaryPrompt.hasRequiredHeadings("【概要】\nx\n【要点】\n- a\n【決定事項】\n- なし\n【TODO】\n- b"))
        XCTAssertTrue(SummaryPrompt.hasRequiredHeadings("【概要】\nx\n【要点】\n- a\n【決定事項】\n- なし\n【ＴＯＤＯ】\n- b"))
        XCTAssertFalse(SummaryPrompt.hasRequiredHeadings("【概要】\nx\n【要点】\n- a\n【決定事項】\n- なし"))
        XCTAssertFalse(SummaryPrompt.hasRequiredHeadings("Summary\n- a\nTODO\n- b"))
    }
}

/// 書き換えられる指示は、一覧と台帳が読む見出しを残した文だけ保存する。
final class EditablePromptTests: XCTestCase {
    private let prompt = SummaryPrompt.Editable(key: "test.editablePrompt.\(UUID().uuidString)", defaultText: SummaryPrompt.final,
                                                requiredHeadings: SummaryPrompt.requiredHeadings, maxChars: 900)

    override func tearDown() { prompt.reset() }

    /// 見出しを 1 つでも消した指示は保存しない (決定事項・TODO の一覧が空になるため)。理由に欠けた見出しを示す。
    func testRejectsPromptMissingHeadings() {
        let broken = SummaryPrompt.final.replacingOccurrences(of: "【決定事項】", with: "決まったこと:")
        let reason = prompt.save(broken)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("【決定事項】") == true)
        XCTAssertFalse(prompt.isCustomized)
        XCTAssertEqual(prompt.current, SummaryPrompt.final)
    }

    /// 見出しを残した書き換えは保存して使う。既定に戻すと既定の文に戻る。
    func testSavesAndResets() {
        let edited = SummaryPrompt.final + "\n固有名詞は文字起こしの表記のまま残す。"
        XCTAssertNil(prompt.save(edited))
        XCTAssertTrue(prompt.isCustomized)
        XCTAssertEqual(prompt.current, edited)
        prompt.reset()
        XCTAssertEqual(prompt.current, SummaryPrompt.final)
    }

    /// 空・長すぎる文は保存しない。既定と同じ文の保存は「既定のまま」として扱う。全角半角の見出しの違いは許す。
    func testEmptyTooLongAndDefault() {
        XCTAssertNotNil(prompt.save("   "))
        XCTAssertNotNil(prompt.save(SummaryPrompt.final + String(repeating: "あ", count: 900)))
        XCTAssertNil(prompt.save(SummaryPrompt.final))
        XCTAssertFalse(prompt.isCustomized)
        XCTAssertTrue(SummaryPrompt.contains("【TODO】", in: "【ＴＯＤＯ】を書く"))
    }

    /// 既定の要約と振り返りの指示は、それぞれの見出しの条件を満たす (既定がそのまま保存できる)。
    func testDefaultsSatisfyTheirOwnHeadings() {
        XCTAssertNil(SummaryPrompt.base.problem(SummaryPrompt.final))
        XCTAssertNil(SummaryPrompt.reflectionBase.problem(SummaryPrompt.reflection))
    }
}


final class MediaAudioPromptTests: XCTestCase {
    /// 既定の指示は、テレビ・動画の再生音声を本人の発言として扱わないよう伝え、そのまま保存できる長さに収まる。
    func testDefaultsMentionPlaybackAudioAndFitLimits() {
        XCTAssertTrue(SummaryPrompt.final.contains("再生音声"))
        XCTAssertTrue(SummaryPrompt.reflection.contains("再生音声"))
        XCTAssertTrue(SummaryPrompt.chunk.contains("再生音声"))
        XCTAssertNil(SummaryPrompt.base.problem(SummaryPrompt.final))
        XCTAssertNil(SummaryPrompt.reflectionBase.problem(SummaryPrompt.reflection))
    }
}
