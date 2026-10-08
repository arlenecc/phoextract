# PhotoExtractor（图片视频提取工具）

一个 macOS 原生（SwiftUI）桌面工具：从一个源目录的**全部子目录**中递归找出图片与视频，
做**全局内容去重**后，**平铺**复制到一个目标目录。适用于整理散落在多层文件夹里的照片／视频、
合并多个备份目录、导出相机 / 手机相册归档等场景。

- 只按**文件内容**（SHA-256）判重，不受文件名、目录位置影响；
- 目标目录**绝不覆盖**任何既有文件，同名自动追加 `-n` 序号；
- 提取过程是**幂等**的：中断后重新提取会跳过已完成的部分，等价于续传。

---

## 功能特性

### 1. 递归扫描（Scan）

- 深度优先遍历源目录下所有子目录，逐条产出，内存中仅保存元信息（路径 / 尺寸 / 类型），不加载文件内容；
- **跳过隐藏文件与隐藏目录**（`.git`、`.DS_Store` 等）；
- **不追踪符号链接**（避免目录链接成环、文件链接重复计数）；
- 过滤非常规文件（伪装成 `.jpg` 的目录不计入）与不可读文件；
- 单个条目读取失败不会中断整体遍历；
- 支持**按扩展名自定义识别规则**，默认集合：

  | 类别 | 扩展名 |
  | --- | --- |
  | 图片 | `jpg` `jpeg` `png` `heic` `heif` `gif` `bmp` `tiff` `tif` `webp` `dng` `raw` `cr2` `cr3` `nef` `arw` `raf` `orf` `rw2` |
  | 视频 | `mp4` `mov` `m4v` `avi` `mkv` `wmv` `flv` `webm` `mpg` `mpeg` `3gp` `mts` `m2ts` `ts` `vob` `rmvb` |

- 扩展名匹配大小写不敏感；结果按路径排序，保证每次运行的选择结果稳定可复现。

### 2. 全局排重（Dedup）

采用「尺寸分组 → 按需哈希 → 同哈希归组」三级策略，尽可能少读磁盘：

1. 先按**文件尺寸**分组：尺寸在集合中唯一的文件必然内容唯一，**无需计算哈希**直接判为唯一；
2. 仅对发生**尺寸碰撞**的文件做 SHA-256，并以**有限并发滑动窗口**执行（默认窗口 = CPU 活跃核数，上限 16）；
3. 同一哈希的多个文件中，**保留路径排序最靠前**的那一个，其余计为重复。

- SHA-256 采用 1 MB 分块流式读取，无论多大的视频文件，内存占用恒定，且大文件哈希过程中可及时响应取消。

### 3. 平铺提取（Extract）

- 去重后的文件**平铺**复制到目标目录，**不带任何子目录结构**；
- 目标目录不存在时自动创建（含多级父目录）；
- **同名冲突自动重命名**：`pic.jpg` → `pic-1.jpg` → `pic-2.jpg` …，无扩展名文件同样适用；
- **绝不覆盖**：包含目标目录中已存在的文件也参与占位判断（大小写不敏感，适配 APFS 默认行为）；
- **幂等跳过**：目标中「同名 + 同尺寸」的文件，若源哈希可用则用哈希验证内容一致后跳过复制；
  源哈希不可用时退化为尺寸启发式判定。因此重复提取 / 中断续传不会产生重复数据；
- 有限并发复制（默认 4），**单个文件复制失败不会中断整体**，最终统计在 `失败 N 个` 中体现。

### 4. 交互与进度

- 三阶段流水线：`扫描 → 排重 → （就绪）→ 提取`，对应状态 `idle / scanning / deduplicating / ready / extracting / done / cancelled / failed(msg)`；
- 后台高频进度事件先进线程安全缓冲，由 **120 ms 低频刷新任务**批量合并（取最新值）后应用到 UI，
  海量文件场景下界面不卡顿；
- 底部状态条展示总体进度条，阶段权重为：扫描 `0–20%`、排重 `20–50%`、提取 `50–100%`；
- 日志区实时输出关键节点（每扫描满 1000 个文件打印一次里程碑），最多保留最近 500 行；
- 任意阶段可**取消**（协作式取消令牌，取消后可再次点击「开始提取」续传）；
- 「图片类型 / 视频类型」两组扩展名可全选、清空或逐项勾选；
- 安全限制：源/目标目录为根路径 `/` 时视为无效输入。

---

## 环境要求

- macOS **14.0** 及以上
- Swift 6 工具链（SwiftPM，`swift-tools-version: 6.0`，语言模式 Swift 5）
- 核心库刻意使用 `@Observable`（而非 `ObservableObject`）并避免了 SwiftUI 属性包装宏，
  因此在仅安装 **Xcode Command Line Tools** 的环境下也能用 SwiftPM 直接构建。

---

## 构建与运行

```bash
# 构建（Debug）
swift build

# 直接运行 App
swift run PhotoExtractor

# 运行单元测试
swift test

# Release 构建
swift build -c release
```

### 打包正式分发包

```bash
./scripts/package.sh
```

脚本依次完成：Release 构建 → 用 `scripts/make_icon.swift` 生成应用图标并转 `.icns` →
组装 `build/PhotoExtractor.app`（含 `Info.plist`）→ ad-hoc 代码签名 →
生成带 Applications 快捷方式的拖拽安装 DMG，产物位于 `dist/PhotoExtractor-1.0.0.dmg`。

---

## 项目结构

```
Package.swift                      # SwiftPM 清单：PhotoExtractorCore / PhotoExtractor / 测试目标
Sources/
  PhotoExtractorCore/              # 与 UI 无关的核心引擎（可独立复用与测试）
    Protocols.swift                # MediaScanning / HashDeduplicating / FileExtracting 协议
    Models.swift                   # FileKind、FileCategoryRules、ScannedFile、各阶段 Progress/Result、ScanError、CancellationToken
    MediaScanner.swift             # 递归遍历
    HashDeduplicator.swift         # 尺寸分组 + 并发 SHA256 排重
    FileExtractor.swift            # 平铺复制 / 重命名 / 幂等跳过
    SHA256Util.swift               # 分块流式 SHA256
    Progressing.swift              # ProgressThrottler、ProgressBuffer（节流与缓冲）
    ExtractionViewModel.swift      # 流水线编排 + @Observable 视图模型
  PhotoExtractor/                  # SwiftUI 界面层
    PhotoExtractorApp.swift        # App 入口，窗口标题「图片视频提取工具」
    ContentView.swift              # 配置区（上 1/3） / 处理区（下 2/3） / 状态栏
Tests/PhotoExtractorCoreTests/     # Swift Testing 单元测试 + Fixtures
scripts/
  make_icon.swift                  # 程序化绘制应用图标
  package.sh                       # 打包 .app 与 DMG
build/                             # 打包中间产物（.app、图标、临时 DMG）
dist/                              # 最终 DMG
```

---

## 使用流程

1. 选择**源目录**（可手输路径或点「浏览…」）；
2. 选择**目标目录**（不存在时会自动创建）；
3. 按需勾选要参与的图片 / 视频扩展名；
4. 点「开始分析」（⌘↩），等待扫描与排重完成，界面会显示：
   - 已分析：扫到的文件数与总字节数
   - 排重后预估：唯一文件数与字节数
   - 可去除重复：重复文件数与可回收字节数
5. 点「开始提取」，等待复制完成；过程中可随时「取消」，再次点击即续传。

---

## 测试覆盖

使用 Swift Testing（`swift test`），共 6 个 Suite：

| Suite | 覆盖内容 |
| --- | --- |
| TC1 文件类型识别 | 图片/视频扩展名归类、非媒体返回 nil、大小写不敏感、自定义增删规则 |
| TC2 目录遍历 | 递归扫描过滤、空目录、根目录不存在、隐藏项跳过、大写扩展名、不可读文件、目录伪装扩展名、符号链接不追踪、进度终值与结果一致 |
| TC3 Hash 排重 | SHA256 标准测试向量、3 MB 分块哈希、`跨子目录同内容去重`、同名不同内容保留、同尺寸不同内容保留、独占尺寸免哈希、重复组保留路径序靠前者、进度终值一致、可取消 |
| TC4 提取 | 平铺无子目录、去重后无重复内容、同名冲突自动重命名、自动创建目标目录、统计与磁盘一致、取消不落盘、无扩展名重命名、目标已有同名不覆盖、重复提取跳过已完成、同尺寸不同内容不误跳过 |
| TC5 流水线与 VM 状态机 | 分析→ready、提取→done、遵循用户勾选的类型集合、分析/提取取消→cancelled、失败→failed 携带信息、前置缺失保持 idle、完成后允许续传、600 文件规模扫描+排重限时完成 |
| TC5.2 进度节流与缓冲 | 间隔内抑制、到期放行、`forceDeliver` 必达、并发提交合并为最终值 |

---

## 已知约定与边界

- 磁盘空间：目标目录需能容纳排重后的全部字节数，界面「排重后预估」即为所需空间参考；
- 「排重后预估」是提取前的估算值，若源目录在分析后发生变更，请以重新分析的结果为准；
- 若源文件未参与哈希（尺寸独占），幂等跳过退化为**同名同尺寸**的尺寸启发式判定；
- 提取阶段按去重后的**唯一文件列表**执行，若分析后源文件被删除，对应项会计入失败数；
- App 以 ad-hoc 方式签名，首次运行时 macOS 可能提示确认，可在「系统设置 → 隐私与安全性」中允许打开。
