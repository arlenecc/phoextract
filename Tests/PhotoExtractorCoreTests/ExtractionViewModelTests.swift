import Foundation
import Testing
@testable import PhotoExtractorCore

/// TC5 端到端流水线、大规模性能与 VM 状态机
@Suite("TC5 流水线与 VM 状态机")
@MainActor
final class ExtractionViewModelTests {
    var root: URL
    var dest: URL

    init() throws {
        root = try Fixtures.makeDir()
        dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoExtractorVMDest-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        Fixtures.remove(root)
        Fixtures.remove(dest)
    }

    /// 写入 count 个文件：内容按 distinctContents 循环，同内容文件尺寸一致（构成真实重复组）
    private func seedFiles(_ count: Int, distinctContents: Int) throws {
        for i in 0..<count {
            let fill = UInt8(i % distinctContents + 1)
            try Fixtures.write(
                Fixtures.data(size: 32, fill: fill),
                to: root,
                "batch\(i % 5)/f\(i).jpg"
            )
        }
    }

    // TC5.1 完整分析流水线 → ready，统计正确，进度值为 0.5
    @Test("分析流水线产出 ready 与正确统计")
    func analysisPipelineProducesReadyPhaseWithStats() async throws {
        try seedFiles(20, distinctContents: 5)
        let vm = ExtractionViewModel()
        vm.sourceURL = root

        await vm.startAnalysis()

        #expect(vm.phase == .ready)
        #expect(vm.scanResult?.count == 20)
        #expect(vm.scanResult?.totalBytes == Int64(20 * 32))
        // 5 种内容各 4 份 → 保留 5 个，重复 15 个
        #expect(vm.dedupResult?.uniqueFiles.count == 5)
        #expect(vm.dedupResult?.duplicateCount == 15)
        #expect(abs(vm.overallProgress - 0.5) < 0.0001)
        #expect(!vm.logLines.isEmpty)
    }

    // TC5.1 完整提取 → done，磁盘文件与去重结果一致
    @Test("提取产出 done 且磁盘文件正确")
    func extractionProducesDonePhaseAndFilesOnDisk() async throws {
        try seedFiles(12, distinctContents: 4)
        let vm = ExtractionViewModel()
        vm.sourceURL = root
        vm.destinationURL = dest

        await vm.startAnalysis()
        await vm.startExtraction()

        #expect(vm.phase == .done)
        #expect(abs(vm.overallProgress - 1.0) < 0.0001)
        let uniqueCount = vm.dedupResult?.uniqueFiles.count ?? -1
        #expect(vm.extractResult?.copiedCount == uniqueCount)
        #expect(try Fixtures.entries(of: dest).count == uniqueCount)
        // 平铺：目标目录下没有子目录
        var isDir: ObjCBool = false
        for name in try Fixtures.entries(of: dest) {
            FileManager.default.fileExists(atPath: dest.appendingPathComponent(name).path, isDirectory: &isDir)
            #expect(!isDir.boolValue)
        }
    }

    // TC1.5(端到端) VM 遵循用户选择的类型集合
    @Test("VM 遵循用户选择的类型集合")
    func vmRespectsSelectedExtensionFilters() async throws {
        try Fixtures.write(Fixtures.data(size: 8, fill: 1), to: root, "a.jpg")
        try Fixtures.write(Fixtures.data(size: 8, fill: 2), to: root, "b.mp4")

        let vm = ExtractionViewModel()
        vm.sourceURL = root
        vm.selectedVideoExtensions = []

        await vm.startAnalysis()

        #expect(vm.scanResult?.count == 1)
        #expect(vm.scanResult?.files.first?.url.lastPathComponent == "a.jpg")
    }

    // TC5.4 分析阶段取消 → cancelled
    @Test("分析阶段取消进入 cancelled")
    func cancelDuringAnalysisLeadsToCancelledPhase() async throws {
        let vm = ExtractionViewModel(scanner: CancellingStubScanner())
        vm.sourceURL = root

        let task = Task { await vm.startAnalysis() }
        vm.cancel()
        await task.value

        #expect(vm.phase == .cancelled)
    }

    // TC5.4 提取阶段取消 → cancelled，阶段进度值不变
    @Test("提取阶段取消进入 cancelled")
    func cancelDuringExtractionLeadsToCancelledPhase() async throws {
        try seedFiles(4, distinctContents: 4)
        let vm = ExtractionViewModel(extractor: CancellingStubExtractor())
        vm.sourceURL = root
        vm.destinationURL = dest

        await vm.startAnalysis()
        let progressBefore = vm.overallProgress
        let task = Task { await vm.startExtraction() }
        vm.cancel()
        await task.value

        #expect(vm.phase == .cancelled)
        #expect(abs(vm.overallProgress - progressBefore) < 0.0001)
    }

    // 分析失败 → failed 且带错误信息
    @Test("分析失败进入 failed 并携带错误信息")
    func failedAnalysisLeadsToFailedPhase() async throws {
        let stub = CancellingStubScanner()
        stub.error = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "boom"])
        let vm = ExtractionViewModel(scanner: stub)
        vm.sourceURL = root

        await vm.startAnalysis()

        #expect(vm.phase == .failed("boom"))
    }

    // 守卫：未选择源目录时开始分析不改变状态；未完成分析时开始提取不改变状态
    @Test("前置条件缺失时保持 idle")
    func guardsKeepPhaseIdleWhenPreconditionsMissing() async throws {
        let vm = ExtractionViewModel()

        await vm.startAnalysis()
        #expect(vm.phase == .idle)

        vm.sourceURL = root
        await vm.startExtraction()
        #expect(vm.phase == .idle)
    }

    // TC5.5 提取完成后可再次提取（续传语义）：已复制文件跳过，磁盘不重复
    @Test("提取完成后允许续传提取")
    func reExtractionAfterDoneSkipsExistingFiles() async throws {
        try seedFiles(4, distinctContents: 4)
        let vm = ExtractionViewModel()
        vm.sourceURL = root
        vm.destinationURL = dest

        await vm.startAnalysis()
        await vm.startExtraction()
        #expect(vm.phase == .done)
        #expect(vm.canStartExtraction)
        let entriesBefore = try Fixtures.entries(of: dest).count

        await vm.startExtraction()

        #expect(vm.phase == .done)
        #expect(vm.extractResult?.copiedCount == 0)
        #expect(vm.extractResult?.skippedCount == 4)
        #expect(try Fixtures.entries(of: dest).count == entriesBefore)
    }

    // TC5.3 大规模性能冒烟：600 文件（60 目录，200 种内容）限时完成
    @Test("600 文件大规模扫描+排重限时完成")
    func largeScaleScanAndDedupPerformance() async throws {
        let groupCount = 200
        for i in 0..<600 {
            let group = i % groupCount
            let fill = UInt8(group + 1)
            let size = 4096 + (group % 3) * 1024
            try Fixtures.write(Fixtures.data(size: size, fill: fill), to: root, "dir\(i % 60)/f\(i).jpg")
        }

        let start = Date()
        let scanResult = try await MediaScanner().scan(root: root, rules: .standard)
        let dedupResult = try await HashDeduplicator().deduplicate(scanResult.files)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 30, "600 文件扫描+排重应在 30 秒内完成，实际 \(elapsed)s")
        #expect(scanResult.count == 600)
        // 600 个文件由 200 种内容构成，每种 3 份 → 保留 200，重复 400
        #expect(dedupResult.uniqueFiles.count == groupCount)
        #expect(dedupResult.duplicateCount == 400)
    }
}

// MARK: - 测试桩

/// 满足 isCancelled 后抛 CancellationError 的扫描桩（可注入错误）
final class CancellingStubScanner: MediaScanning, @unchecked Sendable {
    var error: Error?

    func scan(
        root: URL,
        rules: FileCategoryRules,
        progress: ScanProgressHandler?,
        isCancelled: @escaping CancellationCheck
    ) async throws -> ScanResult {
        if let error { throw error }
        if isCancelled() { throw CancellationError() }
        progress?(ScanProgress(filesFound: 1, bytesFound: 1))
        return ScanResult(
            files: [ScannedFile(url: root.appendingPathComponent("stub.jpg"), size: 1, kind: .image)],
            totalBytes: 1
        )
    }
}

/// 满足 isCancelled 后抛 CancellationError 的提取桩
final class CancellingStubExtractor: FileExtracting, @unchecked Sendable {
    func extract(
        _ files: [ScannedFile],
        to destination: URL,
        progress: ExtractProgressHandler?,
        isCancelled: @escaping CancellationCheck
    ) async throws -> ExtractResult {
        try await Task.sleep(nanoseconds: 20_000_000)
        if isCancelled() { throw CancellationError() }
        return ExtractResult(copiedCount: 0, copiedBytes: 0, renamedFiles: [], failedCount: 0)
    }
}
