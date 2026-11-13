import Foundation

/// Serial queue for CoreAudio work that the caller only ever waits on for a bounded time.
///
/// AVAudioEngine can block forever inside CoreAudio (seen after sleep and device changes, in
/// `AVAudioEngine.inputNode`). A plain `queue.sync` from the main thread then freezes the whole app.
/// Here a job that overruns its timeout gets its queue abandoned: later work moves to a fresh queue,
/// and whatever the stuck job eventually produces is handed to `discard`.
final class AudioWorker {
    /// Stop opening new queues past this many stuck ones, so a broken audio system can't pile up threads.
    static let maxStuckQueues = 3

    private final class Job<T> {
        var value: T?
        var abandoned = false
    }

    private let label: String
    private let lock = NSLock()
    private var queue: DispatchQueue
    private var currentGeneration = 0
    private var stuckQueues = 0

    init(label: String) {
        self.label = label
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Changes each time a queue is abandoned. Work can compare it to tell whether it was left behind.
    var generation: Int { lock.withLock { currentGeneration } }

    /// Runs `work` on the worker's queue and waits at most `timeout`. Returns nil if it did not finish in
    /// time or the worker has too many stuck queues. A job still waiting for its turn when it times out
    /// never runs; one already running finishes later and its result goes to `discard`.
    func run<T>(timeout: TimeInterval, work: @escaping () -> T, discard: @escaping (T) -> Void = { _ in }) -> T? {
        let slot: (queue: DispatchQueue, generation: Int)? = lock.withLock {
            stuckQueues < Self.maxStuckQueues ? (queue, currentGeneration) : nil
        }
        guard let slot else { return nil }
        let target = slot.queue, generation = slot.generation

        let job = Job<T>()
        let done = DispatchSemaphore(value: 0)
        target.async { [lock] in
            if lock.withLock({ job.abandoned }) { return }
            let value = work()
            let delivered: Bool = lock.withLock {
                if job.abandoned { return false }
                job.value = value
                return true
            }
            if delivered { done.signal() } else { discard(value) }
        }

        if done.wait(timeout: .now() + timeout) == .success { return lock.withLock { job.value } }
        return lock.withLock {
            // The job may have delivered between the timeout and taking the lock.
            if let value = job.value { return value }
            job.abandoned = true
            abandon(generation)
            return nil
        }
    }

    /// Call with `lock` held.
    private func abandon(_ generation: Int) {
        guard generation == currentGeneration else { return }   // another job already moved us on
        let stuck = queue
        currentGeneration += 1
        stuckQueues += 1
        queue = DispatchQueue(label: "\(label).\(currentGeneration)", qos: .userInitiated)
        stuck.async { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.stuckQueues -= 1 }
        }
    }
}
