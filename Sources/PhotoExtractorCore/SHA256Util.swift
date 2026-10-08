import Foundation
import CryptoKit

/// 流式 SHA256 计算：分块读取，内存占用恒定为 chunkSize，适合大文件
public enum SHA256Util {

    public static func hash(fileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            if Task.isCancelled { throw CancellationError() } // 大文件哈希时及时响应取消
            hasher.update(data: chunk)
            if chunk.count < chunkSize { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
