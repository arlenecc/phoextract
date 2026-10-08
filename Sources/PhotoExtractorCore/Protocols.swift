import Foundation

// MARK: - 回调类型

public typealias ScanProgressHandler = @Sendable (ScanProgress) -> Void
public typealias DedupProgressHandler = @Sendable (DedupProgress) -> Void
public typealias ExtractProgressHandler = @Sendable (ExtractProgress) -> Void
public typealias CancellationCheck = @Sendable () -> Bool

// MARK: - 引擎协议（便于依赖注入与测试）

public protocol MediaScanning: Sendable {
    func scan(
        root: URL,
        rules: FileCategoryRules,
        progress: ScanProgressHandler?,
        isCancelled: @escaping CancellationCheck
    ) async throws -> ScanResult
}

public protocol HashDeduplicating: Sendable {
    func deduplicate(
        _ files: [ScannedFile],
        progress: DedupProgressHandler?,
        isCancelled: @escaping CancellationCheck
    ) async throws -> DedupResult
}

public protocol FileExtracting: Sendable {
    func extract(
        _ files: [ScannedFile],
        to destination: URL,
        progress: ExtractProgressHandler?,
        isCancelled: @escaping CancellationCheck
    ) async throws -> ExtractResult
}
