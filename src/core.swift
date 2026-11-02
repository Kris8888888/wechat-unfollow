import Cocoa
import Vision
import ApplicationServices

// MARK: - 路径 / 日志

let toolRoot: URL = {
    // bin/wxunf 的上一级就是工具根目录
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return exe.deletingLastPathComponent().deletingLastPathComponent()
}()
let dataDir = toolRoot.appendingPathComponent("data")
let shotsDir = dataDir.appendingPathComponent("shots")
let pauseFile = dataDir.appendingPathComponent("PAUSE")

func ensureDirs() {
    try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
}

/// 给 server.py 的进度事件：一行一个 JSON
func emit(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj),
          let s = String(data: d, encoding: .utf8) else { return }
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}
func logMsg(_ s: String) { emit(["type": "log", "msg": s]) }

func sleepMs(_ ms: Int) { usleep(UInt32(ms) * 1000) }

// MARK: - 权限

enum Perm {
    static var ax: Bool { AXIsProcessTrusted() }
    static var screen: Bool { CGPreflightScreenCaptureAccess() }
    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        _ = CGRequestScreenCaptureAccess()
    }
}

// MARK: - 窗口

struct Win {
    var id: Int
    var rect: CGRect   // 全局坐标，左上原点，单位 pt
}

func wechatApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat").first
}

func activateWeChat() {
    wechatApp()?.activate(options: [.activateAllWindows])
}

/// 屏幕上某个点最上层的窗口 id（菜单栏、Dock 这类不算）
func topWindowID(at p: CGPoint) -> Int? {
    guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in raw where (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let ww = b["Width"], let hh = b["Height"] else { continue }
        if CGRect(x: x, y: y, width: ww, height: hh).contains(p) { return w[kCGWindowNumber as String] as? Int }
    }
    return nil
}

/// 微信当前在屏幕上的普通窗口（可能有聊天主窗口和「关注」窗口两个）
func wechatWindows() -> [Win] {
    guard let pid = wechatApp()?.processIdentifier,
          let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [Win] = []
    for w in raw {
        guard (w[kCGWindowOwnerPID as String] as? Int) == Int(pid),
              (w[kCGWindowLayer as String] as? Int) == 0,
              let id = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let ww = b["Width"], let hh = b["Height"],
              ww >= 500, hh >= 400 else { continue }
        out.append(Win(id: id, rect: CGRect(x: x, y: y, width: ww, height: hh)))
    }
    return out
}

func windowRect(_ id: Int) -> CGRect? {
    guard let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
          let w = raw.first, let b = w[kCGWindowBounds as String] as? [String: CGFloat],
          let x = b["X"], let y = b["Y"], let ww = b["Width"], let hh = b["Height"] else { return nil }
    return CGRect(x: x, y: y, width: ww, height: hh)
}

// MARK: - 截屏 + OCR

/// OCR 出来的一行字。坐标都换算成全局屏幕 pt，左上原点。
struct Line {
    var text: String
    var conf: Float
    var rect: CGRect
    var midY: CGFloat { rect.midY }
}

/// 截图：winID 非空时只截这个窗口（被挡住也能截到列表），
/// 否则按屏幕区域截（能截到右键菜单、确认框这类独立的小窗口）。
func capture(winID: Int?, region: CGRect, keep: String? = nil) -> (CGImage, CGRect)? {
    let path = keep.map { shotsDir.appendingPathComponent($0).path }
        ?? (NSTemporaryDirectory() + "wxunf-cap.png")
    try? FileManager.default.removeItem(atPath: path)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    if let id = winID {
        p.arguments = ["-l", String(id), "-o", "-x", path]
    } else {
        p.arguments = ["-x", "-R", "\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", path]
    }
    do { try p.run(); p.waitUntilExit() } catch { return nil }
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
          cg.width > 10 else { return nil }
    return (cg, region)
}

/// 把高饱和度的像素刷成白色再识字。
/// 号名后面的黄色认证徽章会被 OCR 读成「必 / 女 / 心」粘在名字上，
/// 名字和副标题都是黑灰色，刷掉彩色不伤字。
func desaturate(_ cg: CGImage) -> CGImage {
    let w = cg.width, h = cg.height
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cg }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let buf = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return cg }
    for i in stride(from: 0, to: w * h * 4, by: 4) {
        let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
        if max(r, g, b) - min(r, g, b) > 70 {
            buf[i] = 255; buf[i + 1] = 255; buf[i + 2] = 255
        } else {
            // 灰字压深一点，右侧那列浅灰小字的时间才认得全
            let v = (r + g + b) / 3
            let o = UInt8(v >= 238 ? 255 : v * 55 / 100)
            buf[i] = o; buf[i + 1] = o; buf[i + 2] = o
        }
    }
    return ctx.makeImage() ?? cg
}

/// clean：识别列表时把彩色刷掉（去认证徽章）；识别菜单和确认框时不能刷，「不再关注」按钮是红字
func ocr(_ cg: CGImage, region: CGRect, clean: Bool = true) -> [Line] {
    let img = clean ? desaturate(cg) : cg
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["zh-Hans", "en-US"]
    req.usesLanguageCorrection = false
    do { try VNImageRequestHandler(cgImage: img, options: [:]).perform([req]) } catch { return [] }
    var out: [Line] = []
    for o in req.results ?? [] {
        guard let c = o.topCandidates(1).first else { continue }
        let bb = o.boundingBox  // 归一化，左下原点
        let r = CGRect(x: region.minX + bb.minX * region.width,
                       y: region.minY + (1 - bb.maxY) * region.height,
                       width: bb.width * region.width,
                       height: bb.height * region.height)
        out.append(Line(text: c.string.trimmingCharacters(in: .whitespaces), conf: c.confidence, rect: r))
    }
    return out
}

/// 只识别截图里的一小块（pt 坐标），用来重认被头像粘住的名字
func ocrCrop(_ cg: CGImage, region: CGRect, crop: CGRect) -> [Line] {
    let s = CGFloat(cg.width) / region.width
    let px = CGRect(x: (crop.minX - region.minX) * s, y: (crop.minY - region.minY) * s,
                    width: crop.width * s, height: crop.height * s).integral
    guard let c = cg.cropping(to: px) else { return [] }
    return ocr(c, region: crop)
}

/// 截窗口并识字，顺带返回一个「重认某块区域」的函数给解析用
func ocrWindowWithRefine(_ w: Win, keep: String? = nil) -> ([Line], (CGRect) -> Line?) {
    guard let r = windowRect(w.id), let (cg, reg) = capture(winID: w.id, region: r, keep: keep) else {
        return ([], { _ in nil })
    }
    return (ocr(cg, region: reg), { crop in
        ocrCrop(cg, region: reg, crop: crop).min { $0.rect.minY < $1.rect.minY }
    })
}

func ocrWindow(_ w: Win, keep: String? = nil) -> [Line] {
    ocrWindowWithRefine(w, keep: keep).0
}

func ocrRegion(_ r: CGRect, keep: String? = nil) -> [Line] {
    guard let (cg, reg) = capture(winID: nil, region: r, keep: keep) else { return [] }
    return ocr(cg, region: reg, clean: false)
}

// MARK: - 鼠标键盘

/// 我们自己合成的事件都打上这个标记，监听 Esc 时用来区分「程序按的」和「人按的」
let SYNTH_TAG: Int64 = 0x5758_554E

func post(_ e: CGEvent?) {
    e?.setIntegerValueField(.eventSourceUserData, value: SYNTH_TAG)
    e?.post(tap: .cghidEventTap)
}

func moveMouse(_ p: CGPoint) {
    synthPoint = p
    synthAt = Date()
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
    sleepMs(60)
}

func click(_ p: CGPoint) {
    moveMouse(p)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
    usleep(UInt32.random(in: 50_000...90_000))
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
}

func rightClick(_ p: CGPoint) {
    moveMouse(p)
    post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: p, mouseButton: .right))
    usleep(UInt32.random(in: 60_000...100_000))
    post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: p, mouseButton: .right))
}

func pressEsc() {
    synthEscAt = Date()
    post(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
    sleepMs(50)
    post(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false))
}

/// 一个像素单位的滚轮事件。正数往上，负数往下。
func scroll(_ px: Int32, at p: CGPoint) {
    moveMouse(p)
    post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: px, wheel2: 0, wheel3: 0))
}

// MARK: - 暂停：人一动鼠标、按 Esc、或界面上点暂停，都立刻停

/// 程序自己最后一次把光标放在哪、什么时候放的。
/// 光标离开这个位置，说明是人在动鼠标。
var synthPoint: CGPoint? = nil
var synthAt = Date.distantPast
var synthEscAt = Date.distantPast

final class PauseWatch {
    static var requested = false
    static var reason = ""

    /// 不用键盘监听（那个要「输入监控」权限），改成每 60ms 看一次光标位置和 Esc 键状态
    static func start() {
        try? FileManager.default.removeItem(at: pauseFile)
        let th = Thread {
            while true {
                usleep(60_000)
                // 终端窗口被关掉、服务没了，就自己退出，不留下没人管的进程
                if getppid() == 1 { exit(0) }
                if requested { continue }
                if FileManager.default.fileExists(atPath: pauseFile.path) { stop("界面上点了暂停") }
                if CGEventSource.keyState(.combinedSessionState, key: 53),
                   Date().timeIntervalSince(synthEscAt) > 0.5 { stop("按了 Esc") }
                if let sp = synthPoint, Date().timeIntervalSince(synthAt) > 0.25,
                   let cur = CGEvent(source: nil)?.location,
                   hypot(cur.x - sp.x, cur.y - sp.y) > 25 { stop("你动了鼠标") }
            }
        }
        th.start()
    }

    static func stop(_ why: String) {
        guard !requested else { return }
        requested = true
        reason = why
        emit(["type": "pausing", "reason": why])
    }

    static var shouldPause: Bool { requested }
}

// MARK: - JSON 读写

func readJSON(_ name: String) -> Any? {
    guard let d = try? Data(contentsOf: dataDir.appendingPathComponent(name)) else { return nil }
    return try? JSONSerialization.jsonObject(with: d)
}

func writeJSON(_ name: String, _ obj: Any) {
    ensureDirs()
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? d.write(to: dataDir.appendingPathComponent(name), options: .atomic)
}

func nowStamp() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date())
}
