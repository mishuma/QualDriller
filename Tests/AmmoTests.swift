import XCTest


/// The ammunition model is pure arithmetic and is where most of this app's
/// real bugs have come from. Every test here encodes a rule that was decided
/// deliberately; if one fails, read the comment before "fixing" it.
final class AmmoTests: XCTestCase {

    // MARK: - loaded

    func testLoadedClampsToMaxRoundsAndPadsToThreeMagazines() {
        let a = AmmoState.loaded([99, 3])
        XCTAssertEqual(a.magazines.count, 3)
        XCTAssertEqual(a.magazines.map(\.rounds), [AmmoState.maxRounds, 3, 0])
    }

    func testLoadedRejectsNegativeCapacities() {
        XCTAssertEqual(AmmoState.loaded([-5, 2, 1]).magazines.map(\.rounds), [0, 2, 1])
    }

    func testMagazinesAreNumberedFromOneAsSpoken() {
        XCTAssertEqual(AmmoState.loaded([1, 1, 1]).magazines.map(\.id), [1, 2, 3])
    }

    // MARK: - consume

    func testConsumeDecrementsTheMagazineInTheGun() {
        var a = AmmoState.loaded([2, 5, 5])
        XCTAssertTrue(a.consume())
        XCTAssertEqual(a.roundsInCurrent, 1)
    }

    /// A shout against an empty magazine still happened acoustically; it just
    /// did not eject anything. The caller needs to know which.
    func testConsumeReturnsFalseWhenDryAndDoesNotGoNegative() {
        var a = AmmoState.loaded([1, 0, 0])
        XCTAssertTrue(a.consume())
        XCTAssertFalse(a.consume())
        XCTAssertEqual(a.roundsInCurrent, 0)
    }

    // MARK: - reload: the pool rule

    /// One rule covers both meanings of "reload": a tactical reload wants a
    /// FULL magazine, and the fullest one is full whenever a full one exists.
    func testReloadTakesTheFullestMagazineNotTheNextInOrder() {
        var a = AmmoState.loaded([10, 2, 9])
        _ = a.consume()                       // in the gun: 9
        XCTAssertTrue(a.reload())
        XCTAssertEqual(a.currentMagazine?.id, 3, "should take the 9, not the 2")
    }

    /// The rule Jeff asked for: a magazine you swap out is NOT discarded.
    /// A tactical reload costs time, not ammunition.
    func testReloadRetainsTheRoundsInTheMagazineItSwapsOut() {
        var a = AmmoState.loaded([10, 10, 5])
        for _ in 0..<4 { _ = a.consume() }     // magazine 1 down to 6
        XCTAssertTrue(a.reload())
        XCTAssertEqual(a.currentMagazine?.rounds, 10)
        XCTAssertEqual(a.magazines[0].rounds, 6, "the partial must stay on the belt")
        XCTAssertEqual(a.totalRemaining, 21)
    }

    /// A partial is still worth shooting once the full ones are gone.
    func testReloadFallsBackToAPartialWhenNothingIsFull() {
        var a = AmmoState.loaded([10, 4, 7])
        for _ in 0..<10 { _ = a.consume() }    // magazine 1 empty
        XCTAssertTrue(a.reload())
        XCTAssertEqual(a.currentMagazine?.id, 3)
        for _ in 0..<7 { _ = a.consume() }     // magazine 3 empty
        XCTAssertTrue(a.reload())
        XCTAssertEqual(a.currentMagazine?.id, 2, "the 4 is all that is left")
    }

    func testReloadBreaksTiesTowardTheLowerNumberedMagazine() {
        var a = AmmoState.loaded([3, 10, 10])
        XCTAssertTrue(a.reload())
        XCTAssertEqual(a.currentMagazine?.id, 2)
    }

    func testReloadFailsWhenNoOtherMagazineHasRounds() {
        var a = AmmoState.loaded([5, 0, 0])
        XCTAssertFalse(a.reload())
        XCTAssertEqual(a.currentMagazine?.id, 1, "a failed reload must not move the pointer")
    }

    func testReloadNeverSelectsTheMagazineAlreadyInTheGun() {
        var a = AmmoState.loaded([10, 1, 0])
        XCTAssertTrue(a.reload())
        XCTAssertEqual(a.currentMagazine?.id, 2)
    }

    // MARK: - totals

    /// Regression: totalRemaining used to exclude anything "behind" the
    /// pointer, which made rounds permanently unreachable.
    func testTotalRemainingCountsMagazinesBehindThePointer() {
        var a = AmmoState.loaded([10, 10, 5])
        for _ in 0..<4 { _ = a.consume() }
        _ = a.reload()
        XCTAssertEqual(a.totalRemaining, 21)
    }

    func testHasSpareMagazineIsAboutRoundsNotPosition() {
        var full = AmmoState.loaded([1, 0, 0])
        XCTAssertFalse(full.hasSpareMagazine, "later magazines exist but are empty")
        _ = full.consume()
        XCTAssertFalse(full.hasSpareMagazine)

        let behind = AmmoState.loaded([0, 0, 4])
        XCTAssertTrue(behind.hasSpareMagazine)
    }

    // MARK: - refill

    func testRefillTopsEverythingUpAndReturnsToMagazineOne() {
        var a = AmmoState.loaded([10, 10, 5])
        for _ in 0..<10 { _ = a.consume() }
        _ = a.reload()
        a.refill(to: [10, 10, 1])
        XCTAssertEqual(a.magazines.map(\.rounds), [10, 10, 1])
        XCTAssertEqual(a.currentMagazine?.id, 1)
    }

    // MARK: - the drill-5 arithmetic the task file depends on

    /// Drill 5 is "fire until empty, reload, then two more" and is written in
    /// the task file as a single count of 8. That number is arithmetic on what
    /// is LEFT after drills 1-4, not on a full magazine. If this fails, the
    /// count in tasks.txt is stale.
    func testDrillFiveArithmeticOnTheShippedLoadout() {
        var a = AmmoState.loaded([10, 10, 5])
        for _ in 0..<4 { _ = a.consume() }         // drills 1-4, one round each
        var shots = 0
        while a.roundsInCurrent > 0 { _ = a.consume(); shots += 1 }
        XCTAssertEqual(shots, 6)
        XCTAssertTrue(a.reload())
        for _ in 0..<2 { _ = a.consume(); shots += 1 }
        XCTAssertEqual(shots, 8, "drill 5 is 8 shots on a 10/10/5 loadout")
    }
}
