import Foundation

/// One magazine.
///
/// A magazine you swap out is NOT discarded — it goes back on the belt with
/// whatever is left in it and can be used again. That is how a tactical reload
/// actually works: you retain the partial. Magazines are therefore a POOL, not
/// a one-way sequence, and there is no "retired" state.
struct Magazine: Identifiable, Hashable {
    let id: Int                 // 1...3, as spoken
    var capacity: Int
    var rounds: Int

    var isEmpty: Bool { rounds <= 0 }
    var isFull: Bool { rounds >= capacity && capacity > 0 }
}

/// Session ammunition state.
///
/// Magazines are a pool of three. `reload()` always swaps in the one with the
/// most rounds, which satisfies both things the shooter means by "reload":
/// a tactical reload wants a FULL magazine, and that is the fullest one when
/// any full one exists; running dry just wants whatever still has rounds, and
/// partials get used once the full ones are gone.
///
/// State persists across drills for the whole session, so a drill can begin
/// with a partially depleted magazine — which is the point.
struct AmmoState: Hashable {

    static let maxMagazines = 3
    static let maxRounds = 10
    static let defaultCapacities = [10, 10, 5]

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
    /// Every round on the belt, in any magazine. Nothing is ever unreachable.
    var totalRemaining: Int { magazines.reduce(0) { $0 + $1.rounds } }

    /// Is there another magazine with anything in it? This — not a position in
    /// a sequence — is what decides whether a reload is possible.
    var hasSpareMagazine: Bool { bestSpare != nil }

    /// The magazine to swap in: the one with the most rounds that is not
    /// already in the gun. Ties break toward the lower number so the choice is
    /// deterministic and matches the order they are spoken in.
    private var bestSpare: Int? {
        magazines.indices
            .filter { $0 != current && magazines[$0].rounds > 0 }
            .max(by: { (magazines[$0].rounds, $1) < (magazines[$1].rounds, $0) })
    }

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

    /// Swaps in the fullest magazine that isn't already in the gun. Returns
    /// false when nothing else has rounds in it.
    ///
    /// The one being taken out keeps its rounds and stays in the pool. A
    /// tactical reload therefore costs nothing but time, which is the point of
    /// doing one, and the partial can be shot later once the full magazines are
    /// gone.
    @discardableResult
    mutating func reload() -> Bool {
        guard let next = bestSpare else { return false }
        current = next
        return true
    }

    var summary: String {
        magazines.map { "\($0.rounds)" }.joined(separator: " / ")
    }
}
