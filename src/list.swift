import Cocoa

/// 微信「关注」窗口里的号列表：找窗口、切页签、回到顶部、一屏一屏往下翻。
/// 往下翻的每一步都要求新的一屏和上一屏至少有一个号重合，
/// 没重合说明滚过头了，往回退一半再看，保证中间没有漏掉的行。
final class FollowList {
    var win: Win
    var page: Page
    var gapWarnings = 0
    private var factor: CGFloat = 1.0   // 滚轮像素 → 实际移动距离的校正系数

    private init(win: Win, page: Page) { self.win = win; self.page = page }

    static func open() -> FollowList? {
        activateWeChat()
        sleepMs(500)
        for w in wechatWindows() {
            let (lines, refine) = ocrWindowWithRefine(w)
            if let r = windowRect(w.id), let p = parsePage(lines, win: r, refine: refine) {
                return FollowList(win: w, page: p)
            }
        }
        return nil
    }

    /// 保证「关注」窗口在最前面。滚轮和点击都是发给光标下最上层窗口的，
    /// 被浏览器之类挡住的话就会点到别人身上。
    /// 新版 macOS 不允许后台程序强行把别的应用叫到前台，叫不动就点一下窗口标题栏的空白处。
    func ensureFront() {
        for i in 0..<4 {
            guard let r = windowRect(win.id) else { return }
            win.rect = r
            let probe = CGPoint(x: r.midX, y: r.midY)
            if topWindowID(at: probe) == win.id { return }
            activateWeChat()
            sleepMs(400)
            if topWindowID(at: probe) == win.id { return }
            if i == 1 {
                // 用系统的「打开应用」把微信叫到前台，这个后台程序也有权限做
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-b", "com.tencent.xinWeChat"]
                try? p.run(); p.waitUntilExit()
                sleepMs(600)
            } else if i >= 2 {
                // 还不行就点「关注」页左栏下方的空白处。不点标题栏：那里是一排标签，点上去会切到别的页面
                click(CGPoint(x: r.minX + r.width * 0.08, y: r.minY + r.height * 0.8))
                sleepMs(400)
            }
        }
        logMsg("⚠ 没能把「关注」窗口带到最前面")
    }

    @discardableResult
    func read(keep: String? = nil) -> Page {
        for _ in 0..<3 {
            if let r = windowRect(win.id) {
                win.rect = r
                let (lines, refine) = ocrWindowWithRefine(win, keep: keep)
                if let p = parsePage(lines, win: r, refine: refine) { page = p; return p }
                // 不在「关注」页（比如某个号的主页被打开了）：点标题栏里的「关注」标签回去
                if let tab = lines.first(where: { $0.text == "关注" && $0.rect.midY < r.minY + 45 }) {
                    logMsg("不在「关注」页，点标题栏的「关注」回去")
                    click(CGPoint(x: tab.rect.midX, y: tab.rect.midY))
                    sleepMs(900)
                    continue
                }
            }
            activateWeChat()
            sleepMs(600)
        }
        return page
    }

    /// 切页签，并确认真的切过去了（看列表长相：「最近关注」只有名字一行）
    func switchTab(_ name: String) -> Bool {
        for _ in 0..<3 {
            ensureFront()
            if read().tab == name { return true }
            if PauseWatch.shouldPause { return false }
            if let p = page.tabPoints[name] { click(p) }
            sleepMs(1200)
            if read().tab == name { return true }
        }
        return false
    }

    private func names(_ p: Page) -> [String] { p.rows.map { normName($0.name) } }

    func toTop() {
        ensureFront()
        var last: [String] = []
        for _ in 0..<60 {
            if PauseWatch.shouldPause { return }
            for _ in 0..<4 { scroll(3000, at: center); sleepMs(30) }
            sleepMs(350)
            let cur = names(read())
            if cur == last && !cur.isEmpty { return }
            last = cur
        }
    }

    var center: CGPoint {
        CGPoint(x: page.listRect.midX, y: page.listRect.midY)
    }

    enum Step { case moved, end, paused, stuck }

    /// 往下翻一屏
    func stepDown() -> Step {
        if PauseWatch.shouldPause { return .paused }
        ensureFront()
        let prev = page
        let want = max(120, page.listRect.height * 0.5)
        scroll(-Int32(want * factor), at: center)
        sleepMs(450)
        var cur = read()

        if names(cur) == names(prev) {
            // 没动：可能是列表还在加载，等一下再滚一次
            sleepMs(1200)
            if PauseWatch.shouldPause { return .paused }
            scroll(-Int32(want * factor), at: center)
            sleepMs(600)
            cur = read()
            if names(cur) == names(prev) {
                // 还是没动。往上滚一下试试：能动说明真到底了；也不动说明滚轮没生效，不能当成到底
                scroll(Int32(want * factor), at: center)
                sleepMs(500)
                let up = read()
                if names(up) != names(prev) {
                    scroll(-Int32(want * factor * 2), at: center)
                    sleepMs(500)
                    read()
                    return .end
                }
                logMsg("⚠ 列表滚不动了")
                return .stuck
            }
        }

        var tries = 0
        while overlapCount(prev.rows, cur.rows) == 0 && tries < 4 {
            if PauseWatch.shouldPause { return .paused }
            tries += 1
            scroll(Int32(want * factor / 2), at: center)
            sleepMs(450)
            cur = read()
        }
        if overlapCount(prev.rows, cur.rows) == 0 {
            gapWarnings += 1
            logMsg("⚠ 翻页时没对上上一屏，可能漏了几行（\(prev.rows.last?.name ?? "?") 之后）")
        } else {
            // 用两屏都有的号算出实际滚了多远，修正下一次的滚动量
            var shifts: [CGFloat] = []
            for r in cur.rows {
                if let o = prev.rows.first(where: { nameDistance($0.name, r.name) == 0 }) {
                    shifts.append(o.point.y - r.point.y)
                }
            }
            if let s = shifts.sorted().dropFirst(shifts.count / 2).first, s > 20, tries == 0 {
                factor = min(4, max(0.25, factor * want / s))
            }
        }
        return .moved
    }
}

/// 名单合并：新的一屏里，上一屏已经有的号跳过，只追加新出现的。
/// 同一个号在两屏可能被识别成略不同的字，副标题一样又名字很像的算同一个。
func appendNew(_ rows: [Row], into all: inout [Row]) {
    for r in rows {
        let recent = all.suffix(30)
        let dup = recent.contains { o in
            if nameDistance(o.name, r.name) == 0 { return true }
            return nameDistance(o.name, r.name) != nil && o.sub == r.sub && !r.sub.isEmpty
        }
        if !dup { all.append(r) }
    }
}
