import Foundation
import Testing
@testable import PhotoExtractorCore

/// TC4 提取
@Suite("TC4 提取")
final class FileExtractorTests {
    var root: URL
    var dest: URL

    init() throws {
        root = try Fixtures.makeDir()
        dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoExtractorDest-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        Fixtures.remove(root)
        Fixtures.remove(dest)
    }

    private func scanned(_ relPath: String, _ data: Data) throws -> ScannedFile {
        let url = try Fixtures.write(data, to: root, relPath)
        return ScannedFile(url: url, size: Int64(data.count), kind: .image)
    }

    // TC4.1 嵌套文件提取后平铺在目标目录，无子目录结构
    @Test("嵌套文件平铺提取")
    func extractCopiesFlatWithoutDirectoryStructure() async throws {
        let files = try [
            scanned("a/b/c/img.png", Fixtures.data(size: 10, fill: 1)),
            scanned("v.mp4", Fixtures.data(size: 20, fill: 2)),
        ]

        let result = try await FileExtractor().extract(files, to: dest)

        let entries = try Fixtures.entries(of: dest)
        #expect(entries == ["img.png", "v.mp4"])
        var isDir: ObjCBool = false
        for name in entries {
            FileManager.default.fileExists(atPath: dest.appendingPathComponent(name).path, isDirectory: &isDir)
            #expect(!isDir.boolValue, "\(name) 应为普通文件")
        }
        #expect(result.copiedCount == 2)
        #expect(result.copiedBytes == 30)
        #expect(result.failedCount == 0)
    }

    // TC4.2 排重后的文件列表提取 → 目标目录无重复内容
    @Test("排重后提取无重复内容")
    func extractDeduplicatedListProducesNoDuplicateContent() async throws {
        let same = Fixtures.data(size: 12, fill: 7)
        let a = try scanned("dirA/same.jpg", same)
        let b = try scanned("dirB/same.jpg", same)
        let deduped = try await HashDeduplicator().deduplicate([a, b])

        let result = try await FileExtractor().extract(deduped.uniqueFiles, to: dest)

        #expect(try Fixtures.entries(of: dest) == ["same.jpg"])
        #expect(result.copiedCount == 1)
    }

    // TC4.3 不同目录同名不同内容 → 自动重命名，不覆盖
    @Test("同名冲突自动重命名不覆盖")
    func extractRenamesOnNameCollisionWithoutOverwrite() async throws {
        let files = try [
            scanned("dirA/pic.jpg", Fixtures.data(size: 10, fill: 1)),
            scanned("dirB/pic.jpg", Fixtures.data(size: 10, fill: 2)),
        ]

        let result = try await FileExtractor().extract(files, to: dest)

        let entries = try Fixtures.entries(of: dest)
        #expect(entries == ["pic-1.jpg", "pic.jpg"])
        let contents = Set(entries.map { name -> Data in
            (try? Data(contentsOf: dest.appendingPathComponent(name))) ?? Data()
        })
        #expect(contents == [Fixtures.data(size: 10, fill: 1), Fixtures.data(size: 10, fill: 2)])
        #expect(result.renamedFiles.count == 1)
        #expect(Set(result.renamedFiles.map(\.finalName)) == ["pic-1.jpg"])
    }

    // TC4.4 目标目录不存在 → 自动创建（含多级父目录）
    @Test("自动创建目标目录")
    func extractCreatesMissingDestinationDirectory() async throws {
        let files = [try scanned("x.jpg", Fixtures.data(size: 5, fill: 1))]
        let nestedDest = dest.appendingPathComponent("level1/level2", isDirectory: true)

        _ = try await FileExtractor().extract(files, to: nestedDest)

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: nestedDest.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(try Fixtures.entries(of: nestedDest) == ["x.jpg"])
    }

    // TC4.5 结果统计与磁盘实况一致
    @Test("结果统计与磁盘一致")
    func extractResultMatchesFilesOnDisk() async throws {
        let files = try [
            scanned("1/a.jpg", Fixtures.data(size: 100, fill: 1)),
            scanned("2/b.jpg", Fixtures.data(size: 200, fill: 2)),
            scanned("3/c.jpg", Fixtures.data(size: 300, fill: 3)),
        ]

        let result = try await FileExtractor().extract(files, to: dest)

        let entries = try Fixtures.entries(of: dest)
        #expect(entries.count == 3)
        #expect(result.copiedCount == entries.count)
        #expect(result.copiedBytes == 600)

        let onDiskBytes = entries.reduce(Int64(0)) { sum, name in
            let attr = try? FileManager.default.attributesOfItem(
                atPath: dest.appendingPathComponent(name).path
            )
            return sum + (attr?[.size] as? Int64 ?? 0)
        }
        #expect(onDiskBytes == 600)
    }

    // TC4.6 提取进度最终值与结果一致
    @Test("提取进度与结果一致")
    func extractReportsProgressMatchingResult() async throws {
        let files = try [
            scanned("1/a.jpg", Fixtures.data(size: 100, fill: 1)),
            scanned("2/b.jpg", Fixtures.data(size: 200, fill: 2)),
        ]

        var events: [ExtractProgress] = []
        let result = try await FileExtractor().extract(
            files,
            to: dest,
            progress: { events.append($0) }
        )

        #expect(!events.isEmpty)
        #expect(events.last?.filesCopied == result.copiedCount)
        #expect(events.last?.bytesCopied == result.copiedBytes)
    }

    // TC5.4(提取部分) 取消后抛出 CancellationError 且不复制任何文件
    @Test("提取支持取消且不落盘")
    func extractHonoursCancellationBeforeCopying() async throws {
        let files = [try scanned("x.jpg", Fixtures.data(size: 5, fill: 1))]

        await #expect(throws: CancellationError.self) {
            _ = try await FileExtractor().extract(files, to: dest, isCancelled: { true })
        }

        let entries = (try? Fixtures.entries(of: dest)) ?? []
        #expect(entries.isEmpty)
    }

    // TC4.7 同名冲突在扩展名为空时也能重命名
    @Test("无扩展名冲突也能重命名")
    func collisionHandlingWithoutExtension() async throws {
        let files = try [
            scanned("dirA/README", Fixtures.data(size: 4, fill: 1)),
            scanned("dirB/README", Fixtures.data(size: 4, fill: 2)),
        ]

        let result = try await FileExtractor().extract(files, to: dest)

        #expect(try Fixtures.entries(of: dest) == ["README", "README-1"])
        #expect(result.renamedFiles.count == 1)
    }

    // TC4.8 目标目录已有同名文件时自动重命名，不覆盖既有文件
    @Test("目标已有同名文件时重命名不覆盖")
    func extractRenamesAroundPreExistingFiles() async throws {
        try Fixtures.write(Fixtures.data(size: 9, fill: 9), to: dest, "pic.jpg")
        let files = [try scanned("dirA/pic.jpg", Fixtures.data(size: 10, fill: 1))]

        let result = try await FileExtractor().extract(files, to: dest)

        #expect(try Fixtures.entries(of: dest).sorted() == ["pic-1.jpg", "pic.jpg"])
        #expect(try Data(contentsOf: dest.appendingPathComponent("pic.jpg")) == Fixtures.data(size: 9, fill: 9))
        #expect(result.renamedFiles.count == 1)
        #expect(result.copiedCount == 1)
    }

    // TC4.9 重复提取同一集合时跳过已提取文件（幂等，支持中断续传）
    @Test("重复提取跳过已存在文件")
    func extractSkipsAlreadyExtractedFiles() async throws {
        let files = try [
            scanned("a/x.jpg", Fixtures.data(size: 10, fill: 1)),
            scanned("b/y.jpg", Fixtures.data(size: 20, fill: 2)),
        ]
        let first = try await FileExtractor().extract(files, to: dest)
        #expect(first.copiedCount == 2)

        let second = try await FileExtractor().extract(files, to: dest)

        #expect(second.copiedCount == 0)
        #expect(second.skippedCount == 2)
        #expect(second.failedCount == 0)
        #expect(try Fixtures.entries(of: dest).sorted() == ["x.jpg", "y.jpg"])
    }

    // TC4.10 同名同尺寸但内容不同的目标文件不会被误跳过（有源哈希可证时）
    @Test("同尺寸不同内容不误跳过")
    func extractDoesNotSkipWhenContentDiffers() async throws {
        try Fixtures.write(Fixtures.data(size: 10, fill: 9), to: dest, "x.jpg")
        var file = try scanned("a/x.jpg", Fixtures.data(size: 10, fill: 1))
        file.sha256 = "deadbeef" // 去重阶段填充的源哈希（与预置内容不符）

        let result = try await FileExtractor().extract([file], to: dest)

        #expect(result.copiedCount == 1)
        #expect(result.skippedCount == 0)
        #expect(try Fixtures.entries(of: dest).sorted() == ["x-1.jpg", "x.jpg"])
        #expect(try Data(contentsOf: dest.appendingPathComponent("x.jpg")) == Fixtures.data(size: 10, fill: 9))
    }
}
