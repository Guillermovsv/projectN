import Foundation
import Testing
@testable import ProjectN

struct AudioWorkerTests {
    @Test func returnsResultOfFinishedWork() {
        let worker = AudioWorker(label: "test")
        #expect(worker.run(timeout: 2, work: { 42 }) == 42)
    }

    @Test func hungJobTimesOutAndLaterWorkStillRuns() {
        let worker = AudioWorker(label: "test")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let t0 = Date()
        let hung: Int? = worker.run(timeout: 0.1, work: { release.wait(); return 1 })
        #expect(hung == nil)
        #expect(Date().timeIntervalSince(t0) < 2)
        #expect(worker.generation == 1)
        #expect(worker.run(timeout: 2, work: { 2 }) == 2)
    }

    @Test func lateResultGoesToDiscard() {
        let worker = AudioWorker(label: "test")
        let release = DispatchSemaphore(value: 0)
        let discarded = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var value: Int?

        let hung: Int? = worker.run(timeout: 0.1, work: { release.wait(); return 7 }, discard: { v in
            lock.withLock { value = v }
            discarded.signal()
        })
        #expect(hung == nil)
        release.signal()
        #expect(discarded.wait(timeout: .now() + 2) == .success)
        #expect(lock.withLock { value } == 7)
    }

    @Test func jobQueuedBehindHungJobNeverRuns() {
        let worker = AudioWorker(label: "test")
        let release = DispatchSemaphore(value: 0)
        let blockerDone = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var queuedRan = false

        DispatchQueue.global().async {
            let _: Int? = worker.run(timeout: 0.5, work: { release.wait(); return 1 })
            blockerDone.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)
        let queued: Int? = worker.run(timeout: 0.1, work: { lock.withLock { queuedRan = true }; return 2 })
        #expect(queued == nil)
        #expect(blockerDone.wait(timeout: .now() + 2) == .success)
        release.signal()
        #expect(worker.run(timeout: 2, work: { 3 }) == 3)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(lock.withLock { queuedRan } == false)
    }

    @Test func stopsOpeningQueuesWhenTooManyAreStuckThenRecovers() {
        let worker = AudioWorker(label: "test")
        let release = DispatchSemaphore(value: 0)
        for _ in 0..<AudioWorker.maxStuckQueues {
            let hung: Int? = worker.run(timeout: 0.05, work: { release.wait(); return 1 })
            #expect(hung == nil)
        }

        let t0 = Date()
        let refused: Int? = worker.run(timeout: 5, work: { 2 })
        #expect(refused == nil)
        #expect(Date().timeIntervalSince(t0) < 1)

        for _ in 0..<AudioWorker.maxStuckQueues { release.signal() }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(worker.run(timeout: 2, work: { 3 }) == 3)
    }
}
