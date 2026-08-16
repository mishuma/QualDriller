import Foundation

/// One magazine. `retired` means it has been swapped out — per the range rules
/// this session, a magazine that has been reloaded past is never used again,
/// even if rounds were left in it.
struct Magazine: Identifiable, Hashable {
    let id: Int                 // 1...3, as spoken
    var capacity: Int
    var rounds: Int
    var retired: Bool = false

    var isEmpty: Bool { rounds <= 0 }
}

/// Session ammunition state.
///
/// Magazines are consumed strictly in order 1 -> 2 -> 3. Reloading advances the
/// pointer and retires everything behind it; there is no going back. State
/// persists across drills for the whole session, so a drill can begin with a
/// partially depleted magazine — which is the point.
struct AmmoState: Hashable {

    static let maxMagazines = 3
    static let maxRounds = 10
    static let defaultCapacities = [10, 10, 1]

    private(set) var magazines: [Magazine]
    /// Index into `magazines` of the magazine currently in the gun.
    private(set) var current: Int

    static func loaded(_ capacities: [Int]) -> AmmoState {
        let caps = (0..<maxMagazines).map { i -> Int in
            let raw = i < capacities.count ? capacities[i] : 0
            return min(maxRounds, max(0, raw))
        }
        return AmmoState(
            magazines: caps.enumerated().map { Magazine(id: $0.offset + 1,
                                                        capacity: $0.element,
                                                        rounds: $0.element) },
            current: 0)
    }

    var currentMagazine: Magazine? {
        magazines.indices.contains(current) ? magazines[current] : nil
    }
    var roundsInCurrent: Int { currentMagazine?.rounds ?? 0 }
    /// Everything still reachable: the current magazine plus the untouched ones
    /// behind it. Retired magazines don't count.
    var totalRemaining: Int {
        magazines.indices.filter { $0 >= current }.reduce(0) { $0 + magazines[$1].rounds }
    }
    var hasSpareMagazine: Bool { current + 1 < magazines.count }

    /// Fires one round. Returns false when the current magazine is already dry —
    /// the event still happened acoustically, it just didn't eject anything.
    mutating func consume() -> Bool {
        guard magazines.indices.contains(current), magazines[current].rounds > 0 else { return false }
        magazines[current].rounds -= 1
        return true
    }

    // No per-round undo: a voided run restores the whole `AmmoState` snapshot
    // taken at T0 (see DrillEngine.ammoAtRunStart). The old `restoreRound`
    // existed only for the removed voice-reload un-count heuristic.

    /// Refills every magazine to the given capacities and goes back to magazine
    /// one, un-retiring everything.
    ///
    /// This is the between-drills reload: the shooter is off the clock, has
    /// picked their magazines up and topped them off. It is deliberately NOT
    /// the same operation as `reload()`, which is the in-string magazine change
    /// and can never un-retire anything — during a string, a magazine you have
    /// swapped past is on the ground.
    mutating func refill(to capacities: [Int]) {
        self = .loaded(capacities)
    }

    /// Swaps in the next magazine. Returns false when there isn't one.
    @discardableResult
    mutating func reload() -> Bool {
        guard hasSpareMagazine else { return false }
        magazines[current].retired = true
        current += 1
        return true
    }

    var summary: String {
        magazines.map { m in
            m.retired ? "—" : "\(m.rounds)"
        }.joined(separator: " / ")
    }
}
