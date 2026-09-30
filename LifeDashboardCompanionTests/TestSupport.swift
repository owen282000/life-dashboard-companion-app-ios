import Foundation
@testable import LifeDashboardCompanion

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
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        let arrived = watchers.filter { $0.count <= arrivals }
        watchers.removeAll { $0.count <= arrivals }
        arrived.forEach { $0.continuation.resume() }
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Suspends until `count` callers have reached `wait`, however long the scheduler takes to
    /// get them there. Unlike `settle` it has no budget of turns to run out of.
    func waitForArrivals(_ count: Int) async {
        if arrivals >= count { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
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

/// Secrets in memory, so the tests never touch the Keychain of the host app.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.withLock { values[key] }
    }

    func setData(_ value: Data, forKey key: String) {
        lock.withLock { values[key] = value }
    }
}

/// A serial executor for one actor that runs each job right away on a serial queue of its own,
/// except those of one task it is told to hold: they wait until `release`. A test keeps one
/// caller out of the actor this way and lets the others in, so the order in which they get in
/// is the test's choice instead of the scheduler's.
final class HoldingExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "HoldingExecutor", qos: .userInitiated)
    private let lock = NSLock()
    private var watching = false
    private var watchedTask: UnsafeRawPointer?
    private var holding = false
    private var held: [UnownedJob] = []
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// The next job to come in starts the task `hold` will keep out. Call it on the actor right
    /// before creating that task, so no other job comes in between. The task is known by that
    /// job: neither its priority, which can rise, nor any other field tells it apart from the
    /// others, but a task is the job it enqueues every time it comes back.
    func watchNextTask() {
        lock.withLock { watching = true }
    }

    func hold() {
        lock.withLock { holding = true }
    }

    /// Suspends until `count` jobs of the watched task are held.
    func held(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if held.count >= count { return true }
                watchers.append((count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Lets the held jobs in, in the order they came, and says how many there were.
    @discardableResult
    func release() -> Int {
        lock.withLock {
            holding = false
            held.forEach(run)
            defer { held.removeAll() }
            return held.count
        }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let task = unsafeBitCast(job, to: UnsafeRawPointer.self)
        let (hold, arrived) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
            if watching {
                watchedTask = task
                watching = false
            }
            guard holding, task == watchedTask else { return (false, []) }
            held.append(job)
            let arrived = watchers.filter { $0.count <= held.count }.map(\.continuation)
            watchers.removeAll { $0.count <= held.count }
            return (true, arrived)
        }
        arrived.forEach { $0.resume() }
        if !hold { run(job) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    private func run(_ job: UnownedJob) {
        queue.async(qos: .userInitiated, flags: .enforceQoS) {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }
}
