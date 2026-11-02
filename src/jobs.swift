import Cocoa

// MARK: - 翻完一个页签

enum Collect {
    case ok([Row])
    case stopped(String)   // 暂停了，或者出了问题（原因给人看）
}

func stopReason(_ list: FollowList) -> String {
    PauseWatch.shouldPause ? "已暂停（\(PauseWatch.reason)）" : "列表滚不动了，请确认微信「关注」窗口没被挡住、没最小化"
}

/// 把一个页签从头翻到尾，返回按列表顺序排好的号
func collectTab(_ list: FollowList, tab: String, keepFirst: String?, phase: String) -> Collect {
    if list.page.tab != tab || list.read().tab != tab {
        guard list.switchTab(tab) else {
            return .stopped(PauseWatch.shouldPause ? stopReason(list) : "切不到「\(tab)」页签")
        }
    }
    list.toTop()
    if PauseWatch.shouldPause { return .stopped(stopReason(list)) }
    var all: [Row] = []
    var carried: String? = nil   // 分组标题滚出屏幕后，下面的号仍属于这个分组
    func take(_ p: Page) {
        var rows = p.rows
        for i in rows.indices {
            if rows[i].section == nil { rows[i].section = carried } else { carried = rows[i].section }
        }
        appendNew(rows, into: &all)
        emit(["type": "progress", "phase": phase, "tab": tab, "count": all.count])
    }
    take(list.read(keep: keepFirst))
    for _ in 0..<800 {
        switch list.stepDown() {
        case .moved: take(list.page)
        case .end: return .ok(all)
        case .paused, .stuck: return .stopped(stopReason(list))
        }
    }
    return .ok(all)
}

// MARK: - 采集名单

func accountDict(_ r: Row, rank: Int?) -> [String: Any] {
    var d: [String: Any] = [
        "name": r.name, "sub": r.sub, "dead": r.dead, "noUpdate": r.noUpdate,
        "star": (r.section ?? "").contains("星标"),
    ]
    if let raw = r.date { d["dateRaw"] = raw }
    if let dt = parseDate(r.date) { d["date"] = dt }
    if let rank { d["followRank"] = rank }
    return d
}

/// 在一组号里找和 name 最像的那个的下标
func bestIndex(_ name: String, in names: [String]) -> Int? {
    var best: (Int, Int)? = nil
    for (i, n) in names.enumerated() {
        if let d = nameDistance(name, n), best == nil || d < best!.1 { best = (i, d) }
    }
    return best?.0
}

let NO_WINDOW = "没找到微信的「关注」窗口。请在微信里打开「关注」，窗口别最小化、别被挡住。"

func cmdHarvest() {
    PauseWatch.start()
    guard let list = FollowList.open() else { emit(["type": "error", "msg": NO_WINDOW]); return }

    // 先在「最近关注」里记下关注先后，最后停在「最近更新」，取关也在这个页签里做
    let followsResult = collectTab(list, tab: "最近关注", keepFirst: "harvest-follows.png", phase: "harvest")
    guard case .ok(let follows) = followsResult else {
        if case .stopped(let why) = followsResult { emit(["type": "stopped", "msg": "采集没完成，名单没有更新。\(why)"]) }
        return
    }
    let updatesResult = collectTab(list, tab: "最近更新", keepFirst: "harvest-updates.png", phase: "harvest")
    guard case .ok(let updates) = updatesResult else {
        if case .stopped(let why) = updatesResult { emit(["type": "stopped", "msg": "采集没完成，名单没有更新。\(why)"]) }
        return
    }

    // 以「最近更新」为主，关注先后从「最近关注」补
    let folNames = follows.map { $0.name }
    var used = Set<Int>()
    var out: [[String: Any]] = []
    for u in updates {
        var rank: Int? = nil
        if let i = bestIndex(u.name, in: folNames), !used.contains(i) { used.insert(i); rank = i }
        out.append(accountDict(u, rank: rank))
    }
    // 只在「最近关注」里认到的（多半是识别差异），也收进来，宁多勿漏
    for (i, f) in follows.enumerated() where !used.contains(i) {
        out.append(accountDict(f, rank: i))
    }
    // 星标分组如果没有收尾的标题，后面所有号都会被算进星标；占比离谱就当没认出来
    let starCount = out.filter { ($0["star"] as? Bool) == true }.count
    if out.count > 20 && starCount * 10 > out.count * 4 {
        for i in out.indices { out[i]["star"] = false }
        logMsg("星标分组没认准，这次不标星标")
    }
    writeJSON("accounts.json", ["updatedAt": nowStamp(), "accounts": out])
    writeJSON("harvest-debug.json", ["sections": Array(Set(updates.compactMap { $0.section })),
                                     "gaps": list.gapWarnings, "starCount": starCount,
                                     "updatesCount": updates.count, "followsCount": follows.count])
    emit(["type": "harvested", "count": out.count, "gaps": list.gapWarnings])
}

// MARK: - 取关

struct Target {
    var name: String
    var status: String      // pending / clicked / failed / gone / still
    var reason: String = ""
    var shot: String = ""
}

func loadRun() -> ([String: Any], [Target]) {
    let run = (readJSON("run.json") as? [String: Any]) ?? [:]
    let ts = (run["targets"] as? [[String: Any]] ?? []).map {
        Target(name: $0["name"] as? String ?? "", status: $0["status"] as? String ?? "pending",
               reason: $0["reason"] as? String ?? "", shot: $0["shot"] as? String ?? "")
    }
    return (run, ts)
}

func saveRun(_ base: [String: Any], _ ts: [Target], phase: String, round: Int, note: String? = nil) {
    var r = base
    r["phase"] = phase
    r["round"] = round
    r["updatedAt"] = nowStamp()
    if let note { r["note"] = note } else { r.removeValue(forKey: "note") }
    r["targets"] = ts.map { ["name": $0.name, "status": $0.status, "reason": $0.reason, "shot": $0.shot] }
    writeJSON("run.json", r)
}

/// 屏幕上这一行是不是要取关的号。
/// 先在全部已知的号里找最像它的；最像的必须是目标、且没有同样像的非目标号，才动手，
/// 宁可漏点（对账时会再补），也不能误取关一个没勾的号。
func matchTarget(_ row: Row, targets: [Target], known: [String]) -> Int? {
    var bestT: (Int, Int)? = nil
    for (i, t) in targets.enumerated() where t.status == "pending" {
        if let d = nameDistance(row.name, t.name), bestT == nil || d < bestT!.1 { bestT = (i, d) }
    }
    guard let (ti, td) = bestT else { return nil }
    let targetNames = Set(targets.map { normName($0.name) })
    for k in known where !targetNames.contains(normName(k)) {
        if let d = nameDistance(row.name, k), d <= td { return nil }
    }
    return ti
}

enum Outcome { case ok, failed(String, String), paused }

var trailWinID: Int? = nil

/// 每个号每一步都留一张图（只留最近 10 个号的），出问题时能看到工具当时看到了什么
func trail(_ tag: String, _ step: String) {
    let dir = shotsDir.appendingPathComponent("trail")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if step.hasPrefix("1-"), let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
        let tags = Set(files.compactMap { $0.components(separatedBy: "_").first }).sorted {
            (Int($0.split(separator: "-").last ?? "") ?? 0) < (Int($1.split(separator: "-").last ?? "") ?? 0)
        }
        for old in tags.dropLast(9) { for f in files where f.hasPrefix(old + "_") { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) } }
    }
    guard let id = trailWinID, let r = windowRect(id) else { return }
    _ = capture(winID: nil, region: r, keep: "trail/\(tag)_\(step).png")
}

/// 对一行做取关：右键 → 不再关注 → 有确认框就确认 → 回头看它从列表里消失了没有
func unfollowRow(_ row: Row, list: FollowList, tag: String) -> Outcome {
    list.ensureFront()
    // 窗口可能刚被带到前面或挪过位置，重新认一下这一行现在在哪
    guard let now = list.read().rows.first(where: { nameDistance($0.name, row.name) == 0 }) else {
        return .failed("要点的时候它不在屏幕上了", "")
    }
    if PauseWatch.shouldPause { return .paused }
    trailWinID = list.win.id
    trail(tag, "1-before")
    rightClick(now.point)
    let menuRect = CGRect(x: now.point.x - 60, y: now.point.y - 320, width: 420, height: 640)

    // 菜单要连续两次截图都在同一个位置才点：防止菜单还没出来或已经消失时点下去，
    // 那样会点穿到下面那一行，把那个号的主页打开
    func menuItem() -> Line? {
        ocrRegion(menuRect).first {
            $0.text.contains("不再关注") && $0.text.count <= 6
                && $0.rect.minX > now.point.x - 40 && abs($0.midY - now.point.y) < 300
        }
    }
    var item: Line? = nil
    var last: Line? = nil
    for _ in 0..<8 {
        sleepMs(250)
        if PauseWatch.shouldPause { pressEsc(); return .paused }
        let cur = menuItem()
        if let c = cur, let l = last, abs(c.midY - l.midY) < 3, abs(c.rect.midX - l.rect.midX) < 3 { item = c; break }
        last = cur
    }
    trail(tag, "2-menu")
    guard let it = item else {
        let shot = "fail-\(tag)-menu.png"
        _ = ocrRegion(menuRect, keep: shot)
        pressEsc()
        return .failed("右键菜单里没找到「不再关注」", shot)
    }
    if PauseWatch.shouldPause { pressEsc(); return .paused }
    click(CGPoint(x: it.rect.midX, y: it.rect.midY))
    sleepMs(300)
    trail(tag, "3-after-menu")

    // 确认框长这样：「不再关注“xxx”，你将不再收到其下发的消息」，下面两个按钮「仍要关注」「不再关注」。
    // 认法：找「仍要关注」（或「取消」），再找和它同一水平线上的「不再关注」，点后者。
    let winRect = (windowRect(list.win.id) ?? list.win.rect).insetBy(dx: -40, dy: -40)
    let keepWords = ["仍要关注", "取消"]
    func dialogButtons() -> (Line, Line)? {
        let ls = ocrRegion(winRect)
        guard let keep = ls.first(where: { keepWords.contains($0.text) }),
              let go = ls.first(where: { ["不再关注", "确定", "确认"].contains($0.text) && abs($0.midY - keep.midY) < 14 })
        else { return nil }
        return (keep, go)
    }
    // 同样要连续两次看到确认框、按钮位置不变才点
    var confirmed = false
    var lastGo: Line? = nil
    for _ in 0..<8 {
        sleepMs(250)
        let cur = dialogButtons()?.1
        if let c = cur, let l = lastGo, abs(c.midY - l.midY) < 3, abs(c.rect.midX - l.rect.midX) < 3 {
            click(CGPoint(x: c.rect.midX, y: c.rect.midY))
            confirmed = true
            break
        }
        lastGo = cur
    }
    trail(tag, "4-after-dialog")
    if confirmed {
        // 点完只等它自己消失，绝不再点第二下：框在淡出时再点，会点穿到下面的号，把号的主页打开。
        var gone = false
        for _ in 0..<10 {
            sleepMs(300)
            if dialogButtons() == nil { gone = true; break }
        }
        if !gone {
            // 3 秒后还稳稳地在，说明没点上；这时点「仍要关注」关掉它是安全的，下一轮再试
            let shot = "fail-\(tag)-dialog.png"
            _ = ocrRegion(winRect, keep: shot)
            if let (keep, _) = dialogButtons() { click(CGPoint(x: keep.rect.midX, y: keep.rect.midY)) }
            sleepMs(600)
            return .failed("确认框里的「不再关注」没点上", shot)
        }
    }

    for _ in 0..<8 {
        sleepMs(400)
        let p = list.read()
        if !p.rows.contains(where: { nameDistance($0.name, row.name) != nil }) { return .ok }
    }
    let shot = "fail-\(tag)-still.png"
    list.read(keep: shot)
    return .failed("点了「不再关注」，但它还在列表里", shot)
}

/// 从头到尾扫一遍「最近更新」，遇到目标就取关。返回 nil 表示顺利扫完，否则是停下的原因。
func sweep(_ list: FollowList, targets: inout [Target], known: [String], base: [String: Any], round: Int) -> String? {
    if list.read().tab != "最近更新" && !list.switchTab("最近更新") {
        return PauseWatch.shouldPause ? stopReason(list) : "切不到「最近更新」页签"
    }
    list.toTop()
    if PauseWatch.shouldPause { return stopReason(list) }
    var skip = Set<String>()     // 这一轮里已经失败过的，不在同一轮反复撞
    var n = 0
    while true {
        var acted = true
        while acted {
            acted = false
            for r in list.page.rows where !skip.contains(normName(r.name)) {
                guard let ti = matchTarget(r, targets: targets, known: known) else { continue }
                if PauseWatch.shouldPause { return stopReason(list) }
                emit(["type": "progress", "phase": "sweep", "round": round, "current": targets[ti].name])
                n += 1
                switch unfollowRow(r, list: list, tag: "\(round)-\(n)") {
                case .ok:
                    targets[ti].status = "clicked"; targets[ti].reason = ""; targets[ti].shot = ""
                case .failed(let why, let shot):
                    targets[ti].status = "failed"; targets[ti].reason = why; targets[ti].shot = shot
                    skip.insert(normName(r.name))
                case .paused:
                    return stopReason(list)
                }
                saveRun(base, targets, phase: "sweep", round: round)
                // 别太快，免得触发微信风控
                for _ in 0..<10 { sleepMs(Int.random(in: 120...250)); if PauseWatch.shouldPause { return stopReason(list) } }
                list.read()
                acted = true
                break   // 列表变了，从这一屏顶上重新看
            }
        }
        if !targets.contains(where: { $0.status == "pending" }) { return nil }
        switch list.stepDown() {
        case .moved: continue
        case .end: return nil
        case .paused, .stuck: return stopReason(list)
        }
    }
}

func cmdRun() {
    PauseWatch.start()
    var (base, targets) = loadRun()
    guard !targets.isEmpty else { emit(["type": "error", "msg": "取关清单是空的"]); return }
    let accounts = ((readJSON("accounts.json") as? [String: Any])?["accounts"] as? [[String: Any]]) ?? []
    let known = accounts.compactMap { $0["name"] as? String }
    guard let list = FollowList.open() else { emit(["type": "error", "msg": NO_WINDOW]); return }
    // 上次留下的确认框还开着的话，先点「仍要关注」关掉，不然它挡住所有操作
    list.ensureFront()
    let wr = (windowRect(list.win.id) ?? list.win.rect).insetBy(dx: -40, dy: -40)
    let ls = ocrRegion(wr)
    if let keep = ls.first(where: { $0.text == "仍要关注" }) {
        click(CGPoint(x: keep.rect.midX, y: keep.rect.midY))
        sleepMs(600)
    }
    var round = (base["round"] as? Int) ?? 1
    if base["startedAt"] == nil { base["startedAt"] = nowStamp() }

    func pause(_ why: String) {
        saveRun(base, targets, phase: "paused", round: round, note: why)
        emit(["type": "paused", "msg": why])
    }

    while round <= 3 {
        // 上一轮没成功的都重新排队；已经点过、等对账的不重复点
        for i in targets.indices where ["failed", "still"].contains(targets[i].status) {
            targets[i].status = "pending"
        }
        saveRun(base, targets, phase: "sweep", round: round)
        if targets.contains(where: { $0.status == "pending" }) {
            if let why = sweep(list, targets: &targets, known: known, base: base, round: round) {
                pause(why); return
            }
        }

        // 对账：把「最近更新」从头扫到尾，看勾过的号还在不在
        saveRun(base, targets, phase: "verify", round: round)
        emit(["type": "progress", "phase": "verify", "round": round])
        let res = collectTab(list, tab: "最近更新", keepFirst: nil, phase: "verify")
        guard case .ok(let fresh) = res else {
            if case .stopped(let why) = res { pause(why) }
            return
        }
        let freshNames = fresh.map { $0.name }
        var still = 0
        for i in targets.indices where targets[i].status != "gone" {
            if bestIndex(targets[i].name, in: freshNames) != nil {
                targets[i].status = "still"
                if targets[i].reason.isEmpty { targets[i].reason = "对账时还在列表里" }
                still += 1
            } else {
                targets[i].status = "gone"; targets[i].reason = ""; targets[i].shot = ""
            }
        }
        // 名单同步成对账后的真实情况，被取关掉的号从名单里拿掉
        let kept = accounts.filter { a in
            guard let n = a["name"] as? String else { return false }
            return bestIndex(n, in: freshNames) != nil
        }
        writeJSON("accounts.json", ["updatedAt": nowStamp(), "accounts": kept])

        if still == 0 || round == 3 {
            base["finishedAt"] = nowStamp()
            saveRun(base, targets, phase: "done", round: round)
            emit(["type": "done", "gone": targets.filter { $0.status == "gone" }.count, "still": still,
                  "gaps": list.gapWarnings])
            return
        }
        round += 1
    }
}
