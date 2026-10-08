import Foundation

/// 提取器：把去重后的文件平铺复制到目标目录（不带目录结构），
/// 同名冲突自动追加 "-n" 序号（含目标目录中已存在的文件，绝不覆盖）；
/// 目标中"同名且同尺寸（内容可证时哈希验证）"的文件视为已提取并跳过，
/// 使提取具备幂等性 —— 中断后续传 / 重复提取不会产生重复数据。
/// 有限并发复制，单文件失败不中断整体。
public final class FileExtractor: FileExtracting, Sendable {
    private let maxConcurrentCopies: Int

    public init(maxConcurrentCopies: Int = 4) {
        self.maxConcurrentCopies = max(1, maxConcurrentCopies)
    }

    public func extract(
        _ files: [ScannedFile],
        to destination: URL,
        progress: ExtractProgressHandler? = nil,
        isCancelled: @escaping CancellationCheck = { false }
    ) async throws -> ExtractResult {
        if isCancelled() { throw CancellationError() }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // 目标目录既有条目纳入判重（大小写不敏感，适配 APFS 默认行为）
        var usedNames = Set<String>()
        var existingSizes: [String: Int64] = [:]
        let existing = (try? fm.contentsOfDirectory(atPath: destination.path)) ?? []
        for entry in existing {
            let key = entry.lowercased()
            usedNames.insert(key)
            if existingSizes[key] == nil {
                let attr = try? fm.attributesOfItem(atPath: destination.appendingPathComponent(entry).path)
                existingSizes[key] = (attr?[.size] as? NSNumber)?.int64Value
            }
        }

        // 预分配目标文件名；命中"已提取"的文件不参与复制
        struct PlanItem {
            let source: URL
            let name: String
            let size: Int64
            let renamedFrom: String?
        }
        var plan: [PlanItem] = []
        var skippedCount = 0
        plan.reserveCapacity(files.count)
        for file in files {
            let original = file.url.lastPathComponent
            let ext = file.url.pathExtension
            let stem = ext.isEmpty ? original : String(original.dropLast(ext.count + 1))
            var candidate = original
            var n = 1
            var skip = false
            while usedNames.contains(candidate.lowercased()) {
                if isAlreadyExtracted(file, name: candidate, in: destination, existingSizes: existingSizes) {
                    skip = true
                    break
                }
                candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
                n += 1
            }
            usedNames.insert(candidate.lowercased())
            if skip {
                skippedCount += 1
                continue // 已提取，不进复制计划
            }
            plan.append(PlanItem(
                source: file.url,
                name: candidate,
                size: file.size,
                renamedFrom: candidate == original ? nil : original
            ))
        }

        let totalFiles = plan.count
        let totalBytes = plan.reduce(Int64(0)) { $0 + $1.size }
        var copiedCount = 0
        var copiedBytes: Int64 = 0
        var failedCount = 0

        try await withThrowingTaskGroup(of: Result<Int, Error>.self) { group in
            let destPath = destination.path
            var next = 0
            func addNext() {
                guard next < plan.count, !isCancelled() else { return }
                let item = plan[next]
                let index = next
                next += 1
                group.addTask { () -> Result<Int, Error> in
                    do {
                        if isCancelled() { throw CancellationError() }
                        let target = URL(fileURLWithPath: destPath).appendingPathComponent(item.name)
                        try FileManager.default.copyItem(at: item.source, to: target)
                        return .success(index)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for _ in 0..<maxConcurrentCopies { addNext() }
            for try await result in group {
                if isCancelled() { throw CancellationError() }
                switch result {
                case .success(let index):
                    copiedCount += 1
                    copiedBytes += plan[index].size
                case .failure(let error):
                    if error is CancellationError { throw error }
                    failedCount += 1 // 单文件失败不中断整体
                }
                progress?(ExtractProgress(
                    filesCopied: copiedCount,
                    bytesCopied: copiedBytes,
                    totalFiles: totalFiles,
                    totalBytes: totalBytes
                ))
                addNext()
            }
        }

        progress?(ExtractProgress(
            filesCopied: copiedCount,
            bytesCopied: copiedBytes,
            totalFiles: totalFiles,
            totalBytes: totalBytes
        ))

        let renamedFiles = plan.compactMap { item -> RenamedFile? in
            item.renamedFrom.map { RenamedFile(originalName: $0, finalName: item.name) }
        }
        return ExtractResult(
            copiedCount: copiedCount,
            copiedBytes: copiedBytes,
            renamedFiles: renamedFiles,
            failedCount: failedCount,
            skippedCount: skippedCount
        )
    }

    /// 判定目标目录中名为 name 的既有文件是否就是 source 此前提取的结果。
    /// 尺寸必须一致；源哈希可用（去重阶段已算）时做哈希验证，否则按尺寸启发式判定。
    private func isAlreadyExtracted(
        _ source: ScannedFile,
        name: String,
        in destination: URL,
        existingSizes: [String: Int64]
    ) -> Bool {
        guard existingSizes[name.lowercased()] == source.size else { return false }
        let destURL = destination.appendingPathComponent(name)
        guard let expected = source.sha256 else { return true } // 尺寸启发式（独占尺寸文件从未哈希过）
        guard let actual = try? SHA256Util.hash(fileAt: destURL) else { return false }
        return actual == expected
    }
}
