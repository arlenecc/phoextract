import SwiftUI
import PhotoExtractorCore

@main
struct PhotoExtractorApp: App {
    // App 协议隔离在 MainActor 上，可直接创建 @MainActor 视图模型；
    // VM 为 @Observable，View 内普通 let 引用即可获得属性级追踪。
    private let vm = ExtractionViewModel()

    var body: some Scene {
        WindowGroup("图片视频提取工具") {
            ContentView(vm: vm)
                .frame(minWidth: 1000, minHeight: 700)
        }
    }
}
