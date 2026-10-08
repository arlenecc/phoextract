import Foundation
import Observation

/// 视图模型：串联 扫描 → 排重 → 提取 三个阶段，管理阶段状态、日志与总体进度。
/// 后台高频进度事件先进入缓冲，由低频刷新任务（120ms）批量应用到可观察属性，
/// 保证海量文件场景下 UI 不卡顿。
///
/// 使用 @Observable（而非 ObservableObject）以避免依赖 SwiftUI 属性包装宏，
/// 便于在仅含 CommandLineTools 的环境下用 SwiftPM 直接构建。
@Observable
@MainActor
public final class ExtractionViewModel {

    public enum Phase: Equatable {
        case idle
        case scanning
        case deduplicating
        case ready
        case extracting
        case done
        case cancelled
        case failed(String)
    }

    // MARK: 输入配置（UI 可观察）
    public var sourceURL: URL?
    public var destinationURL: URL?
    public var selectedImageExtensions: Set<String> = FileCategoryRules.standard.imageExtensions
    public var selectedVideoExtensions: Set<String> = FileCategoryRules.standard.videoExtensions
    public var showSourceImporter = false
    public var showDestImporter = false

    // MARK: 状态输出（UI 可观察）
    public private(set) var phase: Phase = .idle
    public private(set) var scanProgress: ScanProgress = .zero
    public private(set) var dedupProgress: DedupProgress = .zero
    public private(set) var extractProgress: ExtractProgress = .zero
    public private(set) var scanResult: ScanResult?
    public private(set) var dedupResult: DedupResult?
    public private(set) var extractResult: ExtractResult?
    public private(set) var logLines: [String] = []
    public private(set) var overallProgress: Double = 0

    public var currentRules: FileCategoryRules {
        FileCategoryRules(
            imageExtensions: selectedImageExtensions,
            videoExtensions: selectedVideoExtensions
        )
    }

    public var isBusy: Bool {
        switch phase {
        case .scanning, .deduplicating, .extracting: return true
        default: return false
        }
    }

    /// 是否允许开始提取：完成过分析（有排重结果）且当前不处于运行中的扫描/排重阶段。
    /// 允许从 ready（首次）、done（重复提取）、cancelled（中断续传）、failed（失败重试）进入。
    public var canStartExtraction: Bool {
        guard dedupResult != nil else { return false }
        switch phase {
        case .ready, .done, .cancelled, .failed: return true
        default: return false
        }
    }

    // MARK: 私有
    @ObservationIgnored private let scanner: any MediaScanning
    @ObservationIgnored private let deduplicator: any HashDeduplicating
    @ObservationIgnored private let extractor: any FileExtracting
    @ObservationIgnored private let token = CancellationToken()
    @ObservationIgnored private let scanBuffer: ProgressBuffer<ScanProgress>
    @ObservationIgnored private let dedupBuffer: ProgressBuffer<DedupProgress>
    @ObservationIgnored private let extractBuffer: ProgressBuffer<ExtractProgress>
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var lastLoggedScanK = 0

    public init(
        scanner: any MediaScanning = MediaScanner(),
        deduplicator: any HashDeduplicating = HashDeduplicator(),
        extractor: any FileExtracting = FileExtractor()
    ) {
        self.scanner = scanner
        self.deduplicator = deduplicator
        self.extractor = extractor
        self.scanBuffer = ProgressBuffer { _, latest in latest }
        self.dedupBuffer = ProgressBuffer { _, latest in latest }
        self.extractBuffer = ProgressBuffer { _, latest in latest }
    }

    // MARK: - 对外操作

    public func startAnalysis() async {
        guard let source = sourceURL, isValidDirectory(source) else {
            appendLog("请先选择有效的源目录")
            return
        }
        guard !isBusy else { return }

        scanResult = nil
        dedupResult = nil
        extractResult = nil
        scanProgress = .zero
        dedupProgress = .zero
        extractProgress = .zero
        lastLoggedScanK = 0
        phase = .scanning
        recomputeOverallProgress()
        appendLog("开始分析：\(source.path)")
        startFlushLoop()

        do {
            let result = try await scanner.scan(
                root: source,
                rules: currentRules,
                progress: { [scanBuffer] in scanBuffer.submit($0) },
                isCancelled: { [token] in token.isCancelled }
            )
            scanResult = result
            scanProgress = ScanProgress(filesFound: result.count, bytesFound: result.totalBytes)
            phase = .deduplicating
            recomputeOverallProgress()
            appendLog("扫描完成：发现 \(result.count) 个媒体文件，共 \(byteText(result.totalBytes))，开始全局排重…")

            let dedup = try await deduplicator.deduplicate(
                result.files,
                progress: { [dedupBuffer] in dedupBuffer.submit($0) },
                isCancelled: { [token] in token.isCancelled }
            )
            dedupResult = dedup
            phase = .ready
            appendLog("排重完成：唯一 \(dedup.uniqueFiles.count) 个（\(byteText(dedup.uniqueBytes))），重复 \(dedup.duplicateCount) 个（\(byteText(dedup.duplicateBytes))）。可以开始提取。")
        } catch is CancellationError {
            phase = .cancelled
            appendLog("分析已取消")
        } catch {
            phase = .failed(error.localizedDescription)
            appendLog("分析失败：\(error.localizedDescription)")
        }
        await finishActiveLoop()
    }

    public func startExtraction() async {
        guard canStartExtraction, let unique = dedupResult?.uniqueFiles, let dest = destinationURL, isValidDirectory(dest) else {
            appendLog("请先完成分析并选择有效的目标目录")
            return
        }

        extractProgress = .zero
        extractResult = nil
        phase = .extracting
        recomputeOverallProgress()
        appendLog("开始提取 \(unique.count) 个文件到 \(dest.path)（平铺）")
        startFlushLoop()

        do {
            let result = try await extractor.extract(
                unique,
                to: dest,
                progress: { [extractBuffer] in extractBuffer.submit($0) },
                isCancelled: { [token] in token.isCancelled }
            )
            extractResult = result
            phase = .done
            var message = "提取完成：复制 \(result.copiedCount) 个文件（\(byteText(result.copiedBytes))）"
            if result.skippedCount > 0 { message += "，跳过 \(result.skippedCount) 个已存在" }
            if result.failedCount > 0 { message += "，失败 \(result.failedCount) 个" }
            if !result.renamedFiles.isEmpty { message += "，重命名 \(result.renamedFiles.count) 个" }
            appendLog(message)
        } catch is CancellationError {
            phase = .cancelled
            appendLog("提取已取消（可再次点击开始提取续传）")
        } catch {
            phase = .failed(error.localizedDescription)
            appendLog("提取失败：\(error.localizedDescription)")
        }
        await finishActiveLoop()
    }

    public func cancel() {
        token.cancel()
    }

    // MARK: - 私有实现

    /// 目录有效性：非根 "/"（根目录扫描/写入属于明显的误操作来源）
    private func isValidDirectory(_ url: URL) -> Bool {
        url.path.count > 1
    }

    private func finishActiveLoop() {
        flushTask?.cancel()
        flushTask = nil
        token.reset() // 本次操作已结束，复位取消请求，保证下一次操作干净启动
        applyBufferedProgress()
        recomputeOverallProgress()
    }

    /// 低频刷新：把后台缓冲的最新进度应用到可观察属性
    private func startFlushLoop() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                await self?.applyBufferedProgress()
            }
        }
    }

    private func applyBufferedProgress() {
        if let p = scanBuffer.takePending() {
            scanProgress = p
            maybeLogScanMilestone(p)
        }
        if let p = dedupBuffer.takePending() {
            dedupProgress = p
        }
        if let p = extractBuffer.takePending() {
            extractProgress = p
        }
        recomputeOverallProgress()
    }

    private func maybeLogScanMilestone(_ p: ScanProgress) {
        let k = p.filesFound / 1000
        if k > lastLoggedScanK {
            lastLoggedScanK = k
            appendLog("已扫描 \(p.filesFound) 个文件（\(byteText(p.bytesFound))）…")
        }
    }

    /// 总体进度权重：扫描 0–0.2，排重 0.2–0.5，提取 0.5–1.0
    private func recomputeOverallProgress() {
        switch phase {
        case .idle:
            overallProgress = 0
        case .scanning:
            overallProgress = 0.05
        case .deduplicating:
            let total = max(1, scanResult?.count ?? 1)
            overallProgress = 0.2 + 0.3 * Double(dedupProgress.filesChecked) / Double(total)
        case .ready:
            overallProgress = 0.5
        case .extracting:
            let total = max(1, extractProgress.totalFiles)
            overallProgress = 0.5 + 0.5 * Double(extractProgress.filesCopied) / Double(total)
        case .done:
            overallProgress = 1.0
        case .cancelled, .failed:
            break // 保持当前值
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
