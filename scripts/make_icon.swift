import AppKit

// 生成 1024x1024 应用图标 PNG（macOS Big Sur 风格圆角方形 + 照片卡片 + 播放按钮）
// 用法: swift make_icon.swift <输出路径.png>

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "AppIcon.png"

let S: CGFloat = 1024
let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocus()

// ---- 圆角方形底板（824/1024，留边距，Big Sur 规格）----
let board = NSBezierPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                         xRadius: 184, yRadius: 184)

// 渐变背景：天蓝 → 靛蓝
let bg = NSGradient(colors: [
    NSColor(srgbRed: 0.36, green: 0.62, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.23, green: 0.31, blue: 0.86, alpha: 1),
])!
bg.draw(in: board, angle: -55)

// 顶部高光（半透明白，增强立体感）
NSGraphicsContext.current?.saveGraphicsState()
let highlight = NSBezierPath(roundedRect: CGRect(x: 100, y: 524, width: 824, height: 400),
                             xRadius: 184, yRadius: 184)
NSColor(white: 1.0, alpha: 0.10).setFill()
highlight.addClip()
highlight.fill()
NSGraphicsContext.current?.restoreGraphicsState()

// 细描边（内圈白色微透明，模拟系统图标质感）
NSColor(white: 1.0, alpha: 0.25).setStroke()
let stroke = NSBezierPath(roundedRect: CGRect(x: 102, y: 102, width: 820, height: 820),
                          xRadius: 182, yRadius: 182)
stroke.lineWidth = 4
stroke.stroke()

// ---- 照片卡片（白色圆角矩形）----
let cardRect = CGRect(x: 262, y: 360, width: 500, height: 360)
let card = NSBezierPath(roundedRect: cardRect, xRadius: 40, yRadius: 40)
NSColor.white.setFill()
card.fill()

// 卡片内部内容（裁剪到卡片范围）
NSGraphicsContext.current?.saveGraphicsState()
card.addClip()

// 太阳
NSColor(srgbRed: 1.00, green: 0.78, blue: 0.28, alpha: 1).setFill()
NSBezierPath(ovalIn: CGRect(x: 588, y: 606, width: 96, height: 96)).fill()

// 远山（浅蓝）
let far = NSBezierPath()
far.move(to: CGPoint(x: 462, y: 360))
far.line(to: CGPoint(x: 612, y: 560))
far.line(to: CGPoint(x: 762, y: 360))
far.close()
NSColor(srgbRed: 0.55, green: 0.72, blue: 1.00, alpha: 1).setFill()
far.fill()

// 近山（深蓝）
let near = NSBezierPath()
near.move(to: CGPoint(x: 262, y: 360))
near.line(to: CGPoint(x: 440, y: 660))
near.line(to: CGPoint(x: 618, y: 360))
near.close()
NSColor(srgbRed: 0.25, green: 0.42, blue: 0.90, alpha: 1).setFill()
near.fill()

NSGraphicsContext.current?.restoreGraphicsState()

// ---- 播放按钮（右下角圆形 + 三角）----
let btnCenter = CGPoint(x: 700, y: 350)
let btnRadius: CGFloat = 118

// 按钮底色用主题靛蓝，白描边压在卡片与背景交界处
let btn = NSBezierPath(ovalIn: CGRect(
    x: btnCenter.x - btnRadius, y: btnCenter.y - btnRadius,
    width: btnRadius * 2, height: btnRadius * 2))
NSColor(srgbRed: 0.23, green: 0.35, blue: 0.92, alpha: 1).setFill()
btn.fill()
NSColor(white: 1.0, alpha: 0.9).setStroke()
btn.lineWidth = 12
btn.stroke()

// 播放三角（视觉居中微调）
let tri = NSBezierPath()
tri.move(to: CGPoint(x: btnCenter.x - 32, y: btnCenter.y + 54))
tri.line(to: CGPoint(x: btnCenter.x + 62, y: btnCenter.y))
tri.line(to: CGPoint(x: btnCenter.x - 32, y: btnCenter.y - 54))
tri.close()
NSColor.white.setFill()
tri.fill()

image.unlockFocus()

// ---- 写出 PNG ----
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("图标渲染失败\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("图标已生成: \(outPath)")
