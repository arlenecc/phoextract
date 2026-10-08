import Foundation
@testable import PhotoExtractorCore

/// 测试夹具：创建临时目录与文件
enum Fixtures {
    static func makeDir(_ name: String = "root") throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoExtractorTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @discardableResult
    static func write(_ bytes: Data, to dir: URL, _ relativePath: String) throws -> URL {
        let url = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: url)
        return url
    }

    /// 生成指定大小、指定字节填充的数据
    static func data(size: Int, fill: UInt8) -> Data {
        Data(repeating: fill, count: size)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func entries(of dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }
}

extension Data {
    /// 将自身重复 count 次拼接
    func repeated(_ count: Int) -> Data {
        var result = Data()
        result.reserveCapacity(self.count * count)
        for _ in 0..<count { result.append(self) }
        return result
    }
}
