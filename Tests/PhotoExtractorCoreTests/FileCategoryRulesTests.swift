import Testing
@testable import PhotoExtractorCore

/// TC1 文件类型识别
@Suite("TC1 文件类型识别")
struct FileCategoryRulesTests {

    // TC1.1 常见图片扩展名识别为图片
    @Test("常见图片扩展名识别为图片")
    func classifyCommonImageExtensions() {
        let rules = FileCategoryRules.standard
        #expect(rules.kind(ofExtension: "jpg") == .image)
        #expect(rules.kind(ofExtension: "jpeg") == .image)
        #expect(rules.kind(ofExtension: "png") == .image)
        #expect(rules.kind(ofExtension: "heic") == .image)
        #expect(rules.kind(ofExtension: "gif") == .image)
        #expect(rules.kind(ofExtension: "webp") == .image)
    }

    // TC1.2 常见视频扩展名识别为视频
    @Test("常见视频扩展名识别为视频")
    func classifyCommonVideoExtensions() {
        let rules = FileCategoryRules.standard
        #expect(rules.kind(ofExtension: "mp4") == .video)
        #expect(rules.kind(ofExtension: "mov") == .video)
        #expect(rules.kind(ofExtension: "mkv") == .video)
        #expect(rules.kind(ofExtension: "avi") == .video)
        #expect(rules.kind(ofExtension: "m4v") == .video)
    }

    // TC1.3 非媒体文件扩展名返回 nil
    @Test("非媒体扩展名返回 nil")
    func nonMediaExtensionReturnsNil() {
        let rules = FileCategoryRules.standard
        #expect(rules.kind(ofExtension: "txt") == nil)
        #expect(rules.kind(ofExtension: "pdf") == nil)
        #expect(rules.kind(ofExtension: "doc") == nil)
        #expect(rules.kind(ofExtension: "xlsx") == nil)
        #expect(rules.kind(ofExtension: "") == nil)
    }

    // TC1.4 扩展名大小写不敏感
    @Test("扩展名大小写不敏感")
    func extensionMatchingIsCaseInsensitive() {
        let rules = FileCategoryRules.standard
        #expect(rules.kind(ofExtension: "JPG") == .image)
        #expect(rules.kind(ofExtension: "Png") == .image)
        #expect(rules.kind(ofExtension: "MP4") == .video)
        #expect(rules.kind(ofExtension: "MoV") == .video)
    }

    // TC1.5 用户自定义类型集合：移除的类型不再识别
    @Test("移除的扩展名不再识别")
    func customRulesRespectRemovedExtensions() {
        var rules = FileCategoryRules.standard
        rules.imageExtensions.remove("jpg")
        rules.videoExtensions.remove("mp4")

        #expect(rules.kind(ofExtension: "jpg") == nil)
        #expect(rules.kind(ofExtension: "mp4") == nil)
        #expect(rules.kind(ofExtension: "png") == .image)
        #expect(rules.kind(ofExtension: "mov") == .video)
    }

    // TC1.6 用户可向类型集合添加自定义扩展名
    @Test("新增自定义扩展名生效")
    func customRulesSupportAddedExtensions() {
        var rules = FileCategoryRules.standard
        rules.imageExtensions.insert("raf")
        rules.videoExtensions.insert("ts")

        #expect(rules.kind(ofExtension: "raf") == .image)
        #expect(rules.kind(ofExtension: "ts") == .video)
    }
}
