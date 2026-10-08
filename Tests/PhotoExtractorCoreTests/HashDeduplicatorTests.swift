import Foundation
import Testing
@testable import PhotoExtractorCore

/// TC3 Hash 排重
@Suite("TC3 Hash 排重")
final class HashDeduplicatorTests {
    var root: URL

    init() throws {
        root = try Fixtures.makeDir()
    }

    deinit {
        Fixtures.remove(root)
    }

    private func makeFiles(_ specs: [(String, Data)]) throws -> [ScannedFile] {
        var files: [ScannedFile] = []
        for (relPath, data) in specs {
            let url = try Fixtures.write(data, to: root, relPath)
            files.append(ScannedFile(url: url, size: Int64(data.count), kind: .image))
        }
        return files.sorted { $0.url.path < $1.url.path }
    }

    // TC3.4a 小文件哈希值与标准测试向量一致
    @Test("SHA256 与标准测试向量一致")
    func sha256MatchesStandardTestVectors() throws {
        let abc = try Fixtures.write(Data("abc".utf8), to: root, "abc.txt")
        let empty = try Fixtures.write(Data(), to: root, "empty.txt")

        #expect(try SHA256Util.hash(fileAt: abc, chunkSize: 4)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try SHA256Util.hash(fileAt: empty, chunkSize: 4)
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // TC3.4b 超过缓冲区大小（3MB / 1MB 分块）的哈希与独立参考实现一致
    @Test("3MB 分块哈希与参考实现一致")
    func sha256ChunkedReadMatchesReferenceImplementation() throws {
        let big = try Fixtures.write(Data("0123456789".utf8).repeated(300_000), to: root, "big.bin")

        #expect(try SHA256Util.hash(fileAt: big, chunkSize: 1_000_000)
            == "6ca41633343f162f0f0604879eeac607e5e5087adeee2e4247199301968790d0")
    }

    // TC3.1 + TC3.3 相同内容、不同文件名、分布在不同子目录 → 全局去重只保留一个
    @Test("同内容跨子目录全局去重")
    func identicalContentDeduplicatesAcrossSubdirectories() async throws {
        let same = Fixtures.data(size: 10, fill: 7)
        let files = try makeFiles([
            ("dirA/x.jpg", same),
            ("dirB/y.png", same),
            ("other.jpg", Fixtures.data(size: 10, fill: 8)),
        ])

        let result = try await HashDeduplicator().deduplicate(files)

        #expect(result.uniqueFiles.count == 2)
        #expect(result.duplicateCount == 1)
        #expect(result.duplicateBytes == 10)
        #expect(result.uniqueBytes == 20)
        #expect(Set(result.uniqueFiles.map(\.url.lastPathComponent)) == ["x.jpg", "other.jpg"])
        #expect(result.uniqueFiles.allSatisfy { $0.sha256 != nil })
    }

    // TC3.2 不同内容全部保留（即使文件名相同）
    @Test("同名不同内容都保留")
    func differentContentWithSameNameAreBothKept() async throws {
        let files = try makeFiles([
            ("dirA/pic.jpg", Fixtures.data(size: 10, fill: 1)),
            ("dirB/pic.jpg", Fixtures.data(size: 10, fill: 2)),
        ])

        let result = try await HashDeduplicator().deduplicate(files)

        #expect(result.uniqueFiles.count == 2)
        #expect(result.duplicateCount == 0)
    }

    // TC3.5 相同大小、不同内容 → 都保留（哈希消歧）
    @Test("同尺寸不同内容都保留")
    func sameSizeDifferentContentAreBothKept() async throws {
        let files = try makeFiles([
            ("a.bin", Fixtures.data(size: 100, fill: 1)),
            ("b.bin", Fixtures.data(size: 100, fill: 2)),
        ])

        let result = try await HashDeduplicator().deduplicate(files)

        #expect(result.uniqueFiles.count == 2)
        #expect(result.duplicateCount == 0)
    }

    // TC3.6 相同内容前缀但尺寸不同 → 都保留（不同尺寸必不同内容，不得误删）
    @Test("同前缀不同尺寸都保留")
    func samePrefixButDifferentSizesAreBothKept() async throws {
        let files = try makeFiles([
            ("small.jpg", Fixtures.data(size: 1000, fill: 5)),
            ("large.jpg", Fixtures.data(size: 2000, fill: 5)),
        ])

        let result = try await HashDeduplicator().deduplicate(files)

        #expect(result.uniqueFiles.count == 2)
        #expect(result.duplicateCount == 0)
    }

    // TC3.7 独占尺寸的文件无需哈希即为唯一
    @Test("独占尺寸文件免哈希即唯一")
    func uniqueSizeFilesAreUniqueWithoutHashing() async throws {
        let files = try makeFiles([
            ("a.jpg", Fixtures.data(size: 11, fill: 1)),
            ("b.jpg", Fixtures.data(size: 22, fill: 2)),
            ("c.jpg", Fixtures.data(size: 33, fill: 3)),
        ])

        let result = try await HashDeduplicator().deduplicate(files)

        #expect(result.uniqueFiles.count == 3)
        #expect(result.duplicateCount == 0)
        #expect(result.uniqueBytes == 11 + 22 + 33)
    }

    // TC3.8 重复组保留排序靠前的文件
    @Test("重复组保留路径序靠前者")
    func firstFileByPathOrderIsKept() async throws {
        let same = Fixtures.data(size: 8, fill: 9)
        let files = try makeFiles([
            ("z_first/keep.jpg", same),
            ("z_second/drop.jpg", same),
        ])

        let result = try await HashDeduplicator().deduplicate(files)

        #expect(result.uniqueFiles.map(\.url.lastPathComponent) == ["keep.jpg"])
        #expect(result.uniqueFiles.first?.sha256?.count == 64)
    }

    // TC3.9 去重进度最终值与结果一致
    @Test("去重进度最终值与结果一致")
    func dedupProgressFinalEventMatchesResult() async throws {
        let same = Fixtures.data(size: 16, fill: 4)
        let files = try makeFiles([
            ("1/a.jpg", same), ("2/b.jpg", same), ("3/c.jpg", same),
            ("4/d.jpg", Fixtures.data(size: 16, fill: 5)),
            ("5/e.jpg", Fixtures.data(size: 16, fill: 6)),
        ])

        var events: [DedupProgress] = []
        let result = try await HashDeduplicator().deduplicate(
            files,
            progress: { events.append($0) }
        )

        #expect(!events.isEmpty)
        #expect(events.last?.filesChecked == files.count)
        #expect(events.last?.duplicatesFound == result.duplicateCount)
        #expect(result.duplicateCount == 2)
    }

    // TC5.4(排重部分) 取消后抛出 CancellationError
    @Test("去重支持取消")
    func dedupHonoursCancellation() async throws {
        let same = Fixtures.data(size: 64, fill: 1)
        var files = try makeFiles([("a.jpg", same), ("b.jpg", same)])
        files += try makeFiles([("c.jpg", Fixtures.data(size: 64, fill: 2))])

        var progressCalls = 0
        await #expect(throws: CancellationError.self) {
            _ = try await HashDeduplicator().deduplicate(
                files,
                progress: { _ in progressCalls += 1 },
                isCancelled: { progressCalls >= 1 }
            )
        }
    }
}
