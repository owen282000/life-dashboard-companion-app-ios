import Foundation

/// A clock the test moves by hand. `sleep` suspends until the test has advanced past the
/// deadline, so timing tests neither wait in real time nor depend on a busy CI machine.
actor ManualClock {
    private var now: TimeInterval = 0
    private var waiters: [(deadline: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []

    var waiterCount: Int { waiters.count }

    func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            waiters.append((now + seconds, continuation))
        }
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        let due = waiters.filter { $0.deadline <= now }
        waiters.removeAll { $0.deadline <= now }
        due.forEach { $0.continuation.resume() }
    }
}

/// Holds work at a point the test chooses: `wait` suspends until `open` is called.
actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Lets other tasks run until `condition` holds, or fails the wait after a generous number of
/// turns. Used to reach a known state (a timer armed, a run started) before the test moves on.
func settle(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
