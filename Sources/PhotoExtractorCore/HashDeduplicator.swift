import Foundation

/// 全局排重器。
/// 性能策略：先按文件尺寸分组——尺寸唯一的文件必然内容唯一，无需哈希；
/// 仅对"尺寸碰撞"的文件做 SHA256，并以有限并发窗口执行，避免海量文件时耗尽资源。
public final class HashDeduplicator: HashDeduplicating, Sendable {
    private let maxConcurrentHashing: Int
    private let hashChunkSize: Int

    public init(maxConcurrentHashing: Int = max(2, ProcessInfo.processInfo.activeProcessorCount), hashChunkSize: Int = 1 << 20) {
        self.maxConcurrentHashing = max(1, min(maxConcurrentHashing, 16))
        self.hashChunkSize = hashChunkSize
    }

    public func deduplicate(
        _ files: [ScannedFile],
        progress: DedupProgressHandler? = nil,
        isCancelled: @escaping CancellationCheck = { false }
    ) async throws -> DedupResult {
        if isCancelled() { throw CancellationError() }
        // 第一步：按尺寸分组
        var bySize: [Int64: [Int]] = [:]
        for (index, file) in files.enumerated() {
            bySize[file.size, default: []].append(index)
        }

        var uniqueIndices = Set<Int>()
        var hashWork: [Int] = []
        var checked = 0
        for (_, indices) in bySize {
            if indices.count == 1 {
                uniqueIndices.insert(indices[0])
                checked += 1
            } else {
                hashWork.append(contentsOf: indices)
            }
        }
        progress?(DedupProgress(filesChecked: checked, filesHashed: 0, duplicatesFound: 0))

        // 第二步：滑动窗口并发哈希
        var hashes: [Int: String] = [:]
        var hashedCount = 0
        let chunkSize = hashChunkSize
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func addNext() {
                guard next < hashWork.count, !isCancelled() else { return }
                let index = hashWork[next]
                next += 1
                let url = files[index].url
                group.addTask {
                    (index, try SHA256Util.hash(fileAt: url, chunkSize: chunkSize))
                }
            }
            for _ in 0..<maxConcurrentHashing { addNext() }
            for try await (index, hash) in group {
                if isCancelled() { throw CancellationError() }
                hashes[index] = hash
                hashedCount += 1
                checked += 1
                progress?(DedupProgress(filesChecked: checked, filesHashed: hashedCount, duplicatesFound: 0))
                addNext()
            }
        }

        // 第三步：同哈希分组，保留路径序靠前者，其余计为重复
        if isCancelled() { throw CancellationError() }
        var duplicatesFound = 0
        var duplicateBytes: Int64 = 0
        for (_, indices) in bySize where indices.count > 1 {
            if isCancelled() { throw CancellationError() }
            var firstByHash: [String: Int] = [:]
            for index in indices { // 组内下标升序（files 已按路径排序）
                guard let hash = hashes[index] else { continue }
                if let keep = firstByHash[hash] {
                    duplicatesFound += 1
                    duplicateBytes += files[index].size
                    _ = keep
                } else {
                    firstByHash[hash] = index
                    uniqueIndices.insert(index)
                }
            }
        }

        let uniqueFiles = uniqueIndices.sorted().map { index -> ScannedFile in
            var file = files[index]
            file.sha256 = hashes[index]
            return file
        }
        let uniqueBytes = uniqueFiles.reduce(Int64(0)) { $0 + $1.size }

        // 最终事件（保证进度收敛到结果值）
        progress?(DedupProgress(filesChecked: files.count, filesHashed: hashedCount, duplicatesFound: duplicatesFound))

        return DedupResult(
            uniqueFiles: uniqueFiles,
            uniqueBytes: uniqueBytes,
            duplicateCount: duplicatesFound,
            duplicateBytes: duplicateBytes
        )
    }
}
