import SwiftUI
import UniformTypeIdentifiers
import PhotoExtractorCore

/// 主界面布局：
/// 上 1/3 = 配置区（目录选择 + 类型选择 + 开始分析）
/// 下 2/3 = 处理显示区（统计信息 + 开始提取按钮 + 过程日志）
/// 底部   = 总体进度状态栏
///
/// 说明：本视图层刻意不使用 @State/@Binding/@ObservedObject 等 SwiftUI 宏，
/// 依赖 VM 的 @Observable 宏（Observation 框架）实现属性级刷新，
/// 手动 Binding(get:set:) 替代属性包装器。
struct ContentView: View {
    let vm: ExtractionViewModel

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ConfigSection(vm: vm)
                    .frame(height: geo.size.height / 3)

                Divider()

                ProcessSection(vm: vm)
                    .frame(maxHeight: .infinity)

                StatusBarView(vm: vm)
                    .frame(height: 30)
            }
        }
    }
}

// MARK: - 配置区（上 1/3）

struct ConfigSection: View {
    let vm: ExtractionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("配置")
                    .font(.headline)
                Spacer()
                Text("源目录下所有选中的媒体类型将在全部子目录间全局排重后平铺提取")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DirectoryField(
                title: "源目录",
                placeholder: "选择要分析的目录",
                text: Binding(
                    get: { vm.sourceURL?.path ?? "" },
                    set: { vm.sourceURL = Self.normalizedURL($0) }
                ),
                isPresented: Binding(
                    get: { vm.showSourceImporter },
                    set: { vm.showSourceImporter = $0 }
                )
            )

            DirectoryField(
                title: "目标目录",
                placeholder: "选择提取结果放置目录（不存在会自动创建）",
                text: Binding(
                    get: { vm.destinationURL?.path ?? "" },
                    set: { vm.destinationURL = Self.normalizedURL($0) }
                ),
                isPresented: Binding(
                    get: { vm.showDestImporter },
                    set: { vm.showDestImporter = $0 }
                )
            )

            HStack(alignment: .top, spacing: 24) {
                ExtensionGroupView(
                    vm: vm,
                    title: "图片类型",
                    all: FileCategoryRules.standard.imageExtensions,
                    isImageGroup: true
                )
                ExtensionGroupView(
                    vm: vm,
                    title: "视频类型",
                    all: FileCategoryRules.standard.videoExtensions,
                    isImageGroup: false
                )
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    Button {
                        Task { await vm.startAnalysis() }
                    } label: {
                        Label("开始分析", systemImage: "magnifyingglass")
                            .frame(minWidth: 110)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(vm.isBusy || vm.sourceURL == nil)

                    Button("取消") {
                        vm.cancel()
                    }
                    .disabled(!vm.isBusy)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
    }

    /// 规范化手输路径：修剪首尾空白；空串或仅根 "/" 视为未设置，
    /// 防止 TextField 与 VM 状态短暂失步时把 "/" 当作有效目录。
    private static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return nil }
        return URL(fileURLWithPath: trimmed)
    }
}

// MARK: - 目录选择行

struct DirectoryField: View {
    let title: String
    let placeholder: String
    let text: Binding<String>
    let isPresented: Binding<Bool>

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 56, alignment: .leading)
                .font(.system(.body, design: .monospaced))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Button("浏览…") { isPresented.wrappedValue = true }
                .fixedSize()
        }
        .fileImporter(
            isPresented: isPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                text.wrappedValue = url.path
            }
        }
    }
}

// MARK: - 扩展名选择组

struct ExtensionGroupView: View {
    let vm: ExtractionViewModel
    let title: String
    let all: Set<String>
    let isImageGroup: Bool

    private let columns = [GridItem(.adaptive(minimum: 58), spacing: 4)]

    private var selected: Set<String> {
        isImageGroup ? vm.selectedImageExtensions : vm.selectedVideoExtensions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline).bold()
                Button("全选") { setSelected(all) }.font(.caption)
                Button("清空") { setSelected([]) }.font(.caption)
                Text("已选 \(selected.count)/\(all.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(all.sorted(), id: \.self) { ext in
                    Toggle(ext, isOn: Binding(
                        get: { selected.contains(ext) },
                        set: { on in setMembership(ext, on) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, design: .monospaced))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setSelected(_ newValue: Set<String>) {
        if isImageGroup {
            vm.selectedImageExtensions = newValue
        } else {
            vm.selectedVideoExtensions = newValue
        }
    }

    private func setMembership(_ ext: String, _ on: Bool) {
        if isImageGroup {
            if on { vm.selectedImageExtensions.insert(ext) }
            else { vm.selectedImageExtensions.remove(ext) }
        } else {
            if on { vm.selectedVideoExtensions.insert(ext) }
            else { vm.selectedVideoExtensions.remove(ext) }
        }
    }
}

// MARK: - 处理显示区（下 2/3）

struct ProcessSection: View {
    let vm: ExtractionViewModel

    var body: some View {
        VStack(spacing: 0) {
            // 统计信息 + 开始提取按钮（排重结果显示在按钮左侧）
            HStack(spacing: 24) {
                StatBlock(
                    title: "已分析",
                    count: vm.scanResult.map { "\($0.count) 个文件" } ?? "—",
                    bytes: vm.scanResult.map { ByteCountFormatter.string(fromByteCount: $0.totalBytes, countStyle: .file) } ?? "—",
                    color: .primary
                )
                StatBlock(
                    title: "排重后预估",
                    count: vm.dedupResult.map { "\($0.uniqueFiles.count) 个文件" } ?? "—",
                    bytes: vm.dedupResult.map { ByteCountFormatter.string(fromByteCount: $0.uniqueBytes, countStyle: .file) } ?? "—",
                    color: .accentColor
                )
                if let dedup = vm.dedupResult, dedup.duplicateCount > 0 {
                    StatBlock(
                        title: "可去除重复",
                        count: "\(dedup.duplicateCount) 个文件",
                        bytes: ByteCountFormatter.string(fromByteCount: dedup.duplicateBytes, countStyle: .file),
                        color: .orange
                    )
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Button {
                        Task { await vm.startExtraction() }
                    } label: {
                        Label("开始提取", systemImage: "arrow.down.doc")
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canStartExtraction)
                    if let renamed = vm.extractResult?.renamedFiles, !renamed.isEmpty {
                        Text("重命名 \(renamed.count) 个同名文件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // 处理过程日志
            LogView(lines: vm.logLines)
        }
    }
}

struct StatBlock: View {
    let title: String
    let count: String
    let bytes: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(count)
                .font(.title3)
                .bold()
                .foregroundStyle(color)
            Text(bytes)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 110, alignment: .leading)
    }
}

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
            // 用内容而非 count 比较：日志封顶（500 条）后 count 不再变化，
            // 依赖 count 的 onChange 会导致自动滚动失效
            .onChange(of: lines) { _, _ in
                if !lines.isEmpty {
                    proxy.scrollTo(lines.count - 1, anchor: .bottom)
                }
            }
            .defaultScrollAnchor(.bottom)
        }
    }
}

// MARK: - 状态栏

struct StatusBarView: View {
    let vm: ExtractionViewModel

    private var phaseText: String {
        switch vm.phase {
        case .idle: return "就绪"
        case .scanning: return "正在扫描…"
        case .deduplicating: return "正在排重…"
        case .ready: return "分析完成，可以提取"
        case .extracting: return "正在提取…"
        case .done: return "提取完成"
        case .cancelled: return "已取消"
        case .failed(let msg): return "失败：\(msg)"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(phaseText)
                .font(.caption)
                .foregroundStyle(vm.phase.isFailed ? .red : .secondary)
                .lineLimit(1)

            ProgressView(value: vm.overallProgress)
                .frame(maxWidth: .infinity)

            Text("\(Int(vm.overallProgress * 100))%")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }
}

extension PhotoExtractorCore.ExtractionViewModel.Phase {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
