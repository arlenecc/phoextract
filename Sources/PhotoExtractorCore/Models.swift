import Foundation

// MARK: - 文件类别与识别规则

/// 媒体文件类别
public enum FileKind: String, Sendable, Codable, CaseIterable, Comparable {
    case image
    case video

    public static func < (lhs: FileKind, rhs: FileKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 识别规则：按扩展名（小写、不含点）分类，用户可增删
public struct FileCategoryRules: Equatable, Sendable {
    public var imageExtensions: Set<String>
    public var videoExtensions: Set<String>

    public init(imageExtensions: Set<String>, videoExtensions: Set<String>) {
        self.imageExtensions = imageExtensions
        self.videoExtensions = videoExtensions
    }

    public static let standard = FileCategoryRules(
        imageExtensions: [
            "jpg", "jpeg", "png", "heic", "heif", "gif", "bmp", "tiff", "tif",
            "webp", "dng", "raw", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
        ],
        videoExtensions: [
            "mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm",
            "mpg", "mpeg", "3gp", "mts", "m2ts", "ts", "vob", "rmvb",
        ]
    )

    public func kind(ofExtension ext: String) -> FileKind? {
        let key = ext.lowercased()
        if imageExtensions.contains(key) { return .image }
        if videoExtensions.contains(key) { return .video }
        return nil
    }
}

// MARK: - 数据模型

/// 扫描到的媒体文件
public struct ScannedFile: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let kind: FileKind
    /// 去重阶段为参与哈希的文件填充；免哈希（独占尺寸）的文件为 nil
    public var sha256: String?

    public init(url: URL, size: Int64, kind: FileKind, sha256: String? = nil) {
        self.url = url
        self.size = size
        self.kind = kind
        self.sha256 = sha256
    }
}

// MARK: - 扫描进度与结果

public struct ScanProgress: Equatable, Sendable {
    public var filesFound: Int
    public var bytesFound: Int64
    public static let zero = ScanProgress(filesFound: 0, bytesFound: 0)

    public init(filesFound: Int, bytesFound: Int64) {
        self.filesFound = filesFound
        self.bytesFound = bytesFound
    }
}

public struct ScanResult: Sendable {
    public let files: [ScannedFile]
    public let totalBytes: Int64
    public var count: Int { files.count }

    public init(files: [ScannedFile], totalBytes: Int64) {
        self.files = files
        self.totalBytes = totalBytes
    }
}

// MARK: - 排重进度与结果

public struct DedupProgress: Equatable, Sendable {
    public var filesChecked: Int
    public var filesHashed: Int
    public var duplicatesFound: Int
    public static let zero = DedupProgress(filesChecked: 0, filesHashed: 0, duplicatesFound: 0)

    public init(filesChecked: Int, filesHashed: Int, duplicatesFound: Int) {
        self.filesChecked = filesChecked
        self.filesHashed = filesHashed
        self.duplicatesFound = duplicatesFound
    }
}

public struct DedupResult: Sendable {
    public let uniqueFiles: [ScannedFile]
    public let uniqueBytes: Int64
    public let duplicateCount: Int
    public let duplicateBytes: Int64

    public init(uniqueFiles: [ScannedFile], uniqueBytes: Int64, duplicateCount: Int, duplicateBytes: Int64) {
        self.uniqueFiles = uniqueFiles
        self.uniqueBytes = uniqueBytes
        self.duplicateCount = duplicateCount
        self.duplicateBytes = duplicateBytes
    }
}

// MARK: - 提取进度与结果

public struct ExtractProgress: Equatable, Sendable {
    public var filesCopied: Int
    public var bytesCopied: Int64
    public var totalFiles: Int
    public var totalBytes: Int64
    public static let zero = ExtractProgress(filesCopied: 0, bytesCopied: 0, totalFiles: 0, totalBytes: 0)

    public init(filesCopied: Int, bytesCopied: Int64, totalFiles: Int, totalBytes: Int64) {
        self.filesCopied = filesCopied
        self.bytesCopied = bytesCopied
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
    }
}

public struct RenamedFile: Equatable, Sendable {
    public let originalName: String
    public let finalName: String

    public init(originalName: String, finalName: String) {
        self.originalName = originalName
        self.finalName = finalName
    }
}

public struct ExtractResult: Sendable {
    public let copiedCount: Int
    public let copiedBytes: Int64
    public let renamedFiles: [RenamedFile]
    public let failedCount: Int
    /// 已存在于目标目录（同名同尺寸且内容可证一致）而跳过复制的文件数
    public let skippedCount: Int

    public init(
        copiedCount: Int,
        copiedBytes: Int64,
        renamedFiles: [RenamedFile],
        failedCount: Int,
        skippedCount: Int = 0
    ) {
        self.copiedCount = copiedCount
        self.copiedBytes = copiedBytes
        self.renamedFiles = renamedFiles
        self.failedCount = failedCount
        self.skippedCount = skippedCount
    }
}

// MARK: - 错误

public enum ScanError: Error, Equatable {
    case rootNotFound(URL)
}

// MARK: - 取消令牌

/// 协作式取消令牌（线程安全，可复位以便重复运行）
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public init() {}

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    public func reset() {
        lock.withLock { cancelled = false }
    }
}
