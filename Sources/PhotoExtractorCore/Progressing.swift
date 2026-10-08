import Foundation

/// 进度节流器：基于时间间隔决定事件是否交付（合成时钟可测）。
/// 非线程安全，请在单一线程/任务内使用。
public final class ProgressThrottler {
    private let interval: TimeInterval
    private var lastDelivery: Date?

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// 是否应当交付该事件；若交付则记录本次时间
    @discardableResult
    public func shouldDeliver(now: Date = Date()) -> Bool {
        if let last = lastDelivery, now.timeIntervalSince(last) < interval {
            return false
        }
        lastDelivery = now
        return true
    }

    /// 强制下一次事件交付（用于阶段结束时送达最终进度）
    public func forceDeliver() {
        lastDelivery = nil
    }
}

/// 线程安全的进度缓冲：后台高频 submit 合并成单值，主线程低频 takePending 刷新 UI，
/// 避免海量文件时高频 UI 更新导致卡顿。
public final class ProgressBuffer<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let reduce: (Value, Value) -> Value
    private var pending: Value?

    public init(_ reduce: @escaping (Value, Value) -> Value) {
        self.reduce = reduce
    }

    public func submit(_ event: Value) {
        lock.lock()
        pending = pending.map { reduce($0, event) } ?? event
        lock.unlock()
    }

    /// 取走并清空缓冲
    public func takePending() -> Value? {
        lock.withLock {
            let value = pending
            pending = nil
            return value
        }
    }
}
