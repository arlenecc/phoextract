import Foundation

/// 目录扫描器：惰性递归遍历，逐条处理，内存中仅保留文件元信息
public final class MediaScanner: MediaScanning, Sendable {

    public init() {}

    public func scan(
        root: URL,
        rules: FileCategoryRules,
        progress: ScanProgressHandler? = nil,
        isCancelled: @escaping CancellationCheck = { false }
    ) async throws -> ScanResult {
        if isCancelled() { throw CancellationError() }
        guard FileManager.default.isDirectory(root) else {
            throw ScanError.rootNotFound(root)
        }
        // 深遍历是长耗时同步工作：放到全局并发队列执行，
        // 避免阻塞 Swift 协作线程池（海量文件时可阻塞数分钟）。
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let files = try self.enumerateMedia(
                        root: root, rules: rules, progress: progress, isCancelled: isCancelled
                    )
                    let sorted = files.sorted { $0.url.path < $1.url.path }
                    let totalBytes = sorted.reduce(Int64(0)) { $0 + $1.size }
                    continuation.resume(returning: ScanResult(files: sorted, totalBytes: totalBytes))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func enumerateMedia(
        root: URL,
        rules: FileCategoryRules,
        progress: ScanProgressHandler?,
        isCancelled: CancellationCheck
    ) throws -> [ScannedFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            // 预取属性让后续 resourceValues 读取近乎零开销
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true } // 单个条目出错时继续遍历
        ) else {
            throw ScanError.rootNotFound(root)
        }

        var files: [ScannedFile] = []
        files.reserveCapacity(1024)
        var bytesFound: Int64 = 0

        for case let url as URL in enumerator {
            if isCancelled() { throw CancellationError() }

            let name = url.lastPathComponent
            if name.hasPrefix(".") { // 跳过隐藏文件与隐藏目录（如 .git、.DS_Store）
                enumerator.skipDescendants()
                continue
            }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true {
                // 符号链接不追踪：目录链接防成环，文件链接防同内容重复计数
                enumerator.skipDescendants()
                continue
            }

            guard let kind = rules.kind(ofExtension: url.pathExtension) else { continue }
            guard values?.isRegularFile == true else { continue } // 目录伪装成 .jpg 不计入
            guard fm.isReadableFile(atPath: url.path) else { continue }

            let size = Int64(values?.fileSize ?? 0)
            bytesFound += size // 增量累加，避免每次进度事件全量求和的 O(n²) 开销
            files.append(ScannedFile(url: url, size: size, kind: kind))
            progress?(ScanProgress(filesFound: files.count, bytesFound: bytesFound))
        }
        return files
    }
}

private extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
