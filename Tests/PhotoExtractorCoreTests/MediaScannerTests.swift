import Foundation
import Testing
@testable import PhotoExtractorCore

/// TC2 目录遍历
@Suite("TC2 目录遍历")
final class MediaScannerTests {
    var root: URL

    init() throws {
        root = try Fixtures.makeDir()
    }

    deinit {
        Fixtures.remove(root)
    }

    // TC2.1 递归扫描多级子目录，媒体文件全部找到，非媒体文件忽略
    @Test("递归扫描并忽略非媒体文件")
    func scanFindsMediaFilesRecursivelyAndIgnoresOthers() async throws {
        try Fixtures.write(Fixtures.data(size: 3, fill: 1), to: root, "a.jpg")
        try Fixtures.write(Fixtures.data(size: 4, fill: 2), to: root, "notes.txt")
        try Fixtures.write(Fixtures.data(size: 5, fill: 3), to: root, "sub/b.png")
        try Fixtures.write(Fixtures.data(size: 6, fill: 4), to: root, "sub/deep/c.mov")
        try Fixtures.write(Fixtures.data(size: 7, fill: 5), to: root, "sub/deep/d.pdf")

        let result = try await MediaScanner().scan(root: root, rules: .standard)

        let names = result.files.map(\.url.lastPathComponent).sorted()
        #expect(names == ["a.jpg", "b.png", "c.mov"])
        #expect(result.files.first { $0.url.lastPathComponent == "c.mov" }?.kind == .video)
        #expect(result.files.first { $0.url.lastPathComponent == "a.jpg" }?.kind == .image)
        #expect(result.totalBytes == 3 + 5 + 6)
        #expect(result.count == 3)
    }

    // TC2.2 空目录返回空结果
    @Test("空目录返回空结果")
    func scanEmptyDirectoryReturnsEmptyResult() async throws {
        let result = try await MediaScanner().scan(root: root, rules: .standard)
        #expect(result.count == 0)
        #expect(result.totalBytes == 0)
    }

    // TC2.3 不存在的目录抛出 rootNotFound
    @Test("不存在的目录抛出 rootNotFound")
    func scanNonexistentRootThrowsRootNotFound() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-missing-\(UUID().uuidString)")

        await #expect(throws: ScanError.self) {
            _ = try await MediaScanner().scan(root: missing, rules: .standard)
        }
    }

    // TC2.4 隐藏文件与隐藏目录（如 .git、.DS_Store）被跳过
    @Test("隐藏文件与隐藏目录被跳过")
    func scanSkipsHiddenFilesAndHiddenDirectories() async throws {
        try Fixtures.write(Fixtures.data(size: 2, fill: 1), to: root, ".hidden.jpg")
        try Fixtures.write(Fixtures.data(size: 2, fill: 1), to: root, ".DS_Store")
        try Fixtures.write(Fixtures.data(size: 2, fill: 1), to: root, ".git/cached.jpg")
        try Fixtures.write(Fixtures.data(size: 2, fill: 9), to: root, "visible.jpg")

        let result = try await MediaScanner().scan(root: root, rules: .standard)

        #expect(result.files.map(\.url.lastPathComponent) == ["visible.jpg"])
    }

    // TC2.5 大写扩展名同样被识别
    @Test("大写扩展名同样识别")
    func scanMatchesUppercaseExtensions() async throws {
        try Fixtures.write(Fixtures.data(size: 4, fill: 1), to: root, "IMG_0001.JPG")
        try Fixtures.write(Fixtures.data(size: 4, fill: 2), to: root, "VID_0001.MOV")

        let result = try await MediaScanner().scan(root: root, rules: .standard)

        #expect(result.count == 2)
        let kinds = result.files.map(\.kind).sorted { $0.rawValue < $1.rawValue }
        #expect(kinds == [.image, .video])
    }

    // TC2.6 不可读的文件被跳过而不是导致扫描失败
    @Test("不可读文件被跳过")
    func scanSkipsUnreadableFiles() async throws {
        try Fixtures.write(Fixtures.data(size: 2, fill: 1), to: root, "locked.jpg")
        try Fixtures.write(Fixtures.data(size: 2, fill: 2), to: root, "ok.jpg")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: root.appendingPathComponent("locked.jpg").path
        )

        let result = try await MediaScanner().scan(root: root, rules: .standard)

        #expect(result.files.map(\.url.lastPathComponent) == ["ok.jpg"])
    }

    // TC2.7 自定义规则生效：移除的类型不采集
    @Test("自定义规则生效")
    func scanRespectsCustomRules() async throws {
        try Fixtures.write(Fixtures.data(size: 2, fill: 1), to: root, "a.jpg")
        try Fixtures.write(Fixtures.data(size: 2, fill: 2), to: root, "b.mp4")

        var rules = FileCategoryRules.standard
        rules.videoExtensions.remove("mp4")
        let result = try await MediaScanner().scan(root: root, rules: rules)

        #expect(result.files.map(\.url.lastPathComponent) == ["a.jpg"])
    }

    // TC2.8 目录伪装成媒体扩展名（如 foo.jpg/ 是目录）不计入文件
    @Test("目录伪装媒体扩展名不计入")
    func scanSkipsDirectoriesNamedLikeMedia() async throws {
        try Fixtures.write(Fixtures.data(size: 2, fill: 1), to: root, "real.jpg")
        try Fixtures.write(Fixtures.data(size: 2, fill: 2), to: root, "fake.jpg/inner.txt")

        let result = try await MediaScanner().scan(root: root, rules: .standard)

        #expect(result.files.map(\.url.lastPathComponent) == ["real.jpg"])
    }

    // TC2.9 符号链接不追踪：目录链接不会造成死循环，文件链接不重复计数
    @Test("符号链接不追踪")
    func scanSkipsSymbolicLinks() async throws {
        try Fixtures.write(Fixtures.data(size: 2, fill: 1), to: root, "real.jpg")
        // 指向根目录自身的符号链接 —— 若被进入则会无限循环
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("loop").path,
            withDestinationPath: root.path
        )
        // 指向媒体文件的符号链接 —— 不计入，避免同内容重复提取
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("link.jpg").path,
            withDestinationPath: "real.jpg"
        )

        let start = Date()
        let result = try await MediaScanner().scan(root: root, rules: .standard)

        #expect(Date().timeIntervalSince(start) < 5, "遇到目录符号链接不应死循环")
        #expect(result.files.map(\.url.lastPathComponent) == ["real.jpg"])
    }

    // TC5.1(扫描部分) 进度回调最终值与结果一致
    @Test("扫描进度最终值与结果一致")
    func scanProgressFinalEventMatchesResult() async throws {
        for i in 0..<10 {
            try Fixtures.write(Fixtures.data(size: 100 + i, fill: UInt8(i)), to: root, "d\(i)/f\(i).jpg")
        }

        var events: [ScanProgress] = []
        let result = try await MediaScanner().scan(
            root: root,
            rules: .standard,
            progress: { events.append($0) }
        )

        #expect(!events.isEmpty)
        #expect(events.last?.filesFound == result.count)
        #expect(events.last?.bytesFound == result.totalBytes)
        #expect(events.map(\.filesFound) == Array(1...events.count))
    }
}
