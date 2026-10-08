import Foundation
import Testing
@testable import PhotoExtractorCore

/// TC5.2 进度节流与缓冲（UI 性能关键路径）
@Suite("TC5.2 进度节流与缓冲")
struct ProgressThrottlingTests {

    // TC5.2a 首个事件必达，间隔内的事件被抑制
    @Test("间隔内事件被抑制")
    func throttlerDeliversFirstAndSuppressesWithinInterval() {
        let throttler = ProgressThrottler(interval: 1.0)
        let base = Date(timeIntervalSince1970: 1_000_000)

        #expect(throttler.shouldDeliver(now: base))
        #expect(!throttler.shouldDeliver(now: base + 0.1))
        #expect(!throttler.shouldDeliver(now: base + 0.5))
        #expect(!throttler.shouldDeliver(now: base + 0.99))
    }

    // TC5.2b 间隔到期后再次放行（边界时刻即放行）
    @Test("间隔到期后再次放行")
    func throttlerDeliversAgainAfterIntervalElapsed() {
        let throttler = ProgressThrottler(interval: 1.0)
        let base = Date(timeIntervalSince1970: 1_000_000)

        #expect(throttler.shouldDeliver(now: base))
        #expect(!throttler.shouldDeliver(now: base + 0.5))
        #expect(throttler.shouldDeliver(now: base + 1.0))
        #expect(!throttler.shouldDeliver(now: base + 1.5))
        #expect(throttler.shouldDeliver(now: base + 2.0))
    }

    // TC5.2c forceDeliver 后下一事件必达（用于阶段结束的最终事件）
    @Test("forceDeliver 后下一事件必达")
    func throttlerForceDeliverMakesNextEventDeliver() {
        let throttler = ProgressThrottler(interval: 10.0)
        let base = Date(timeIntervalSince1970: 1_000_000)

        #expect(throttler.shouldDeliver(now: base))
        #expect(!throttler.shouldDeliver(now: base + 1))

        throttler.forceDeliver()
        #expect(throttler.shouldDeliver(now: base + 2))
    }

    // TC5.2d 并发提交合并为最终值，takePending 取走后清空
    @Test("并发提交合并为最终值")
    func progressBufferMergesConcurrentSubmits() async throws {
        let buffer = ProgressBuffer { (a: ScanProgress, b: ScanProgress) in
            ScanProgress(
                filesFound: a.filesFound + b.filesFound,
                bytesFound: a.bytesFound + b.bytesFound
            )
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    for _ in 0..<200 {
                        buffer.submit(ScanProgress(filesFound: 1, bytesFound: 2))
                    }
                }
            }
        }

        let pending = buffer.takePending()
        #expect(pending?.filesFound == 10_000)
        #expect(pending?.bytesFound == 20_000)
        #expect(buffer.takePending() == nil)
    }
}
