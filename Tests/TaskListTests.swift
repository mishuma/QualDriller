import XCTest


final class TaskListTests: XCTestCase {

    // MARK: - parsing

    func testParsesTextParAndShots() {
        let t = TaskList.parse("From the holster, two to the chest. | 6.0 | 2")
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].text, "From the holster, two to the chest.")
        XCTAssertEqual(t[0].par, 6.0)
        XCTAssertEqual(t[0].shots, .fixed(2))
        XCTAssertNil(t[0].refill)
    }

    func testOmittedShotCountMeansOne() {
        XCTAssertEqual(TaskList.parse("Draw and fire. | 3.0")[0].shots, .fixed(1))
    }

    func testDashParMeansTimedButUnscored() {
        XCTAssertNil(TaskList.parse("Warm up. | - | 2")[0].par)
    }

    func testMagAndOpenEndedForms() {
        XCTAssertEqual(TaskList.parse("Fire until empty. | 8 | mag")[0].shots, .magazine)
        XCTAssertEqual(TaskList.parse("Whatever. | 8 | *")[0].shots, .openEnded)
    }

    func testLeadingNumberingIsStripped() {
        XCTAssertEqual(TaskList.parse("12. Fire until empty. | 8 | mag")[0].text,
                       "Fire until empty.")
    }

    func testCommentsAndBlankLinesAreIgnored() {
        let t = TaskList.parse("""
        # a comment
        // another

        Real drill. | 4.0 | 1
        """)
        XCTAssertEqual(t.count, 1)
    }

    /// Invariant 5. The real list is full of decoy numbers; inferring a count
    /// from the text would silently mis-time runs.
    func testShotCountIsNeverInferredFromDecoyNumbersInTheText() {
        let t = TaskList.parse("""
        Bringing the target out to 7 yards, you have six seconds. | 6.0 | 2
        From 15 yards, one shot to the head. | 6.0
        """)
        XCTAssertEqual(t[0].shots, .fixed(2), "not 7 and not 6")
        XCTAssertEqual(t[1].shots, .fixed(1), "not 15")
    }

    // MARK: - the staged-reload field

    func testParsesAStagedLoadout() {
        XCTAssertEqual(TaskList.parse("Two to the body. | 4.0 | 2 | 10/10/1")[0].refill,
                       [10, 10, 1])
    }

    func testStagedLoadoutAcceptsCommasAndSpaces() {
        XCTAssertEqual(TaskList.parse("Two. | 4.0 | 2 | 10, 10, 1")[0].refill, [10, 10, 1])
    }

    func testMalformedStagedLoadoutIsIgnoredRatherThanGuessed() {
        XCTAssertNil(TaskList.parse("Two. | 4.0 | 2 | nonsense")[0].refill)
    }

    // MARK: - loadoutInForce (regression: the one-way staged reload)

    private func staged() -> [DrillTask] {
        TaskList.parse("""
        1. Stage one A. | 3.0 | 1
        2. Stage one B. | 3.0 | 1
        3. Stage two A. | 4.0 | 2 | 10/10/1
        4. Stage two B. | 4.0 | 2
        """)
    }

    func testLoadoutBeforeAnyDeclarationIsTheSessionDefault() {
        let t = staged(), order = Array(t.indices)
        XCTAssertEqual(TaskList.loadoutInForce(at: 0, order: order, tasks: t, base: [10, 10, 5]),
                       [10, 10, 5])
        XCTAssertEqual(TaskList.loadoutInForce(at: 1, order: order, tasks: t, base: [10, 10, 5]),
                       [10, 10, 5])
    }

    func testLoadoutAtAndAfterTheDeclaringDrill() {
        let t = staged(), order = Array(t.indices)
        XCTAssertEqual(TaskList.loadoutInForce(at: 2, order: order, tasks: t, base: [10, 10, 5]),
                       [10, 10, 1])
        XCTAssertEqual(TaskList.loadoutInForce(at: 3, order: order, tasks: t, base: [10, 10, 5]),
                       [10, 10, 1], "a later drill declaring nothing stays on the stage")
    }

    /// THE REGRESSION. The staged reload used to be applied as a one-shot side
    /// effect when a declaring drill was queued, so arrowing FORWARD past
    /// drill 3 switched to 10/10/1 and arrowing BACK to drill 2 left it there —
    /// a first-stage drill running on second-stage ammunition.
    func testArrowingBackwardsRestoresTheEarlierLoadout() {
        let t = staged(), order = Array(t.indices)
        XCTAssertEqual(TaskList.loadoutInForce(at: 1, order: order, tasks: t, base: [10, 10, 5]),
                       [10, 10, 5], "going back must resolve to the first stage again")
    }

    func testLoadoutResolutionFollowsShuffledOrderNotFileOrder() {
        let t = staged()
        let order = [3, 0, 2, 1]        // the declaring drill (index 2) sits third
        XCTAssertEqual(TaskList.loadoutInForce(at: 1, order: order, tasks: t, base: [1, 1, 1]),
                       [1, 1, 1])
        XCTAssertEqual(TaskList.loadoutInForce(at: 2, order: order, tasks: t, base: [1, 1, 1]),
                       [10, 10, 1])
    }

    func testLoadoutResolutionSurvivesOutOfRangeAndEmptyInput() {
        let t = staged(), order = Array(t.indices)
        XCTAssertEqual(TaskList.loadoutInForce(at: -1, order: order, tasks: t, base: [7, 7, 7]),
                       [7, 7, 7])
        XCTAssertEqual(TaskList.loadoutInForce(at: 99, order: order, tasks: t, base: [7, 7, 7]),
                       [10, 10, 1], "clamps to the end rather than trapping")
        XCTAssertEqual(TaskList.loadoutInForce(at: 0, order: [], tasks: t, base: [7, 7, 7]),
                       [7, 7, 7])
    }

    // MARK: - the shipped list

    func testShippedTaskListHasNoOpenEndedDrills() {
        let t = TaskList.parse(TaskList.fallback)
        XCTAssertFalse(t.contains { $0.shots == .openEnded },
                       "an open-ended string cannot stop the timer or be scored")
    }
}
