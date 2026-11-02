import Cocoa

// MARK: - 「关注」页的一屏

/// 列表里的一个号
struct Row {
    var name: String
    var sub: String          // 名字下面那行灰字：最新文章标题 / 暂无更新 / 该账号暂不可用
    var date: String?        // 右侧时间原文：08:16 / 昨天 / 星期三 / 10月20日 / 2016年5月11日
    var section: String?     // 所在分组的标题，比如「星标账号」
    var point: CGPoint       // 名字中心，全局 pt，右键就点这里
    var dead: Bool { DEAD_WORDS.contains { sub.contains($0) } }
    var noUpdate: Bool { sub.contains("暂无更新") }
}

let DEAD_WORDS = ["暂不可用", "已冻结", "已注销", "已迁移", "已封禁", "违规", "已停止"]

struct Page {
    var tab: String?         // 当前选中的是「最近更新」还是「最近关注」（看不出来就是 nil）
    var tabPoints: [String: CGPoint]
    var rows: [Row]
    var listRect: CGRect     // 列表区域，滚轮放在这里
    var bottomY: CGFloat     // 窗口底边
}

func looksLikeDate(_ s: String) -> Bool {
    let t = s.replacingOccurrences(of: " ", with: "")
    if t.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return true }
    if t.range(of: #"^(昨天|前天)(\d{1,2}:\d{2})?$"#, options: .regularExpression) != nil { return true }
    if t.range(of: #"^星期[一二三四五六日天]$"#, options: .regularExpression) != nil { return true }
    if t.range(of: #"^(\d{4}年)?\d{1,2}月\d{1,2}日$"#, options: .regularExpression) != nil { return true }
    if t.range(of: #"^\d{4}[/-]\d{1,2}[/-]\d{1,2}$"#, options: .regularExpression) != nil { return true }
    return false
}

/// 时间原文 → yyyy-MM-dd
func parseDate(_ raw: String?, today: Date = Date()) -> String? {
    guard let raw else { return nil }
    let t = raw.replacingOccurrences(of: " ", with: "")
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    func out(_ d: Date) -> String { fmt.string(from: d) }
    if t.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return out(today) }
    if t.hasPrefix("昨天") { return out(cal.date(byAdding: .day, value: -1, to: today)!) }
    if t.hasPrefix("前天") { return out(cal.date(byAdding: .day, value: -2, to: today)!) }
    if t.hasPrefix("星期") {
        let names: [Character: Int] = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
        guard let wd = t.last.flatMap({ names[$0] }) else { return nil }
        let cur = cal.component(.weekday, from: today)
        var back = (cur - wd + 7) % 7
        if back == 0 { back = 7 }
        return out(cal.date(byAdding: .day, value: -back, to: today)!)
    }
    let nums = t.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    var y = cal.component(.year, from: today), m = 0, d = 0
    if nums.count == 3 { (y, m, d) = (nums[0], nums[1], nums[2]) }
    else if nums.count == 2 {
        (m, d) = (nums[0], nums[1])
        // 「10月20日」不带年份。比今天还晚就是去年的。
        if let c = cal.date(from: DateComponents(year: y, month: m, day: d)), c > today { y -= 1 }
    } else { return nil }
    guard let dt = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
    return out(dt)
}

/// 号名清理：只去掉明显是徽章残渣的部分，不动名字本身的字
func cleanName(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespaces)
    // 名字后面空一格、再跟一个孤零零的字符，基本是徽章被读出来的残渣
    let parts = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    if parts.count >= 2, let last = parts.last, last.count == 1, parts.dropLast().joined().count >= 2 {
        t = parts.dropLast().joined(separator: " ")
    }
    return t
}

/// 比对用：去掉空格和标点，统一小写，常见形近字归一
func normName(_ s: String) -> String {
    var out = ""
    for u in s.unicodeScalars {
        let c = u.properties.generalCategory
        if [.spaceSeparator, .otherPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
            .initialPunctuation, .finalPunctuation, .connectorPunctuation,
            .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol].contains(c) { continue }
        out.unicodeScalars.append(u)
    }
    // OCR 常把 I / l / 1 混着读，统一成一个
    return out.lowercased().replacingOccurrences(of: "l", with: "i").replacingOccurrences(of: "1", with: "i")
}

func editDistance(_ a: String, _ b: String) -> Int {
    let x = Array(a), y = Array(b)
    if x.isEmpty { return y.count }
    if y.isEmpty { return x.count }
    var prev = Array(0...y.count), cur = prev
    for i in 1...x.count {
        cur[0] = i
        for j in 1...y.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
        }
        swap(&prev, &cur)
    }
    return prev[y.count]
}

/// 两个名字像不像：0 完全一样，越大越不像；超出容忍就是 nil。
/// 容忍度跟名字长短挂钩：短名字差一个字就是另一个号了。
func nameDistance(_ a: String, _ b: String) -> Int? {
    let x = normName(a), y = normName(b)
    if x.isEmpty || y.isEmpty { return nil }
    if x == y { return 0 }
    let n = min(x.count, y.count)
    let allow = n >= 7 ? 2 : (n >= 3 ? 1 : 0)
    let d = editDistance(x, y)
    return d <= allow ? d : nil
}

/// 把一屏 OCR 结果解析成号的列表。
/// 每个号在屏幕上是两行左对齐的字（名字 + 灰色副标题），右边和名字齐平的是时间。
/// 判断「这是名字」靠两个特征之一：正下方 12~26pt 有一行副标题，或者右边有时间。
/// 被顶部挡住一半的号只剩副标题，两个特征都没有，会被跳过，滚到下一屏再收。
func parsePage(_ lines: [Line], win: CGRect, refine: ((CGRect) -> Line?)? = nil) -> Page? {
    var tabPoints: [String: CGPoint] = [:]
    var tabBottom: CGFloat = -1
    var tabLeft: CGFloat = .greatestFiniteMagnitude
    for l in lines {
        let t = l.text.replacingOccurrences(of: " ", with: "")
        for tab in ["最近更新", "最近关注"] {
            // 两个页签有时被识别成一行「最近更新 最近关注」，按字的位置拆开
            guard let rg = t.range(of: tab) else { continue }
            let n = CGFloat(max(t.count, 1))
            let a = CGFloat(t.distance(from: t.startIndex, to: rg.lowerBound))
            let x = l.rect.minX + l.rect.width * (a + 2) / n
            tabPoints[tab] = CGPoint(x: x, y: l.rect.midY)
            tabBottom = max(tabBottom, l.rect.maxY)
            tabLeft = min(tabLeft, l.rect.minX)
        }
    }
    guard tabPoints.count == 2 else { return nil }

    let content = lines.filter { $0.rect.minY > tabBottom + 4 && $0.rect.minX > tabLeft - 40 }
    let dates = content.filter { looksLikeDate($0.text) }
    let texts = content.filter { !looksLikeDate($0.text) }

    // 名字列的左边：所有文字左边缘里出现最多的那个位置（名字和副标题共用这条线）
    var bins: [Int: [CGFloat]] = [:]
    for l in texts { bins[Int((l.rect.minX / 6).rounded()), default: []].append(l.rect.minX) }
    guard let best = bins.max(by: { $0.value.count < $1.value.count }), best.value.count >= 2 else {
        return Page(tab: nil, tabPoints: tabPoints, rows: [], listRect: .zero, bottomY: win.maxY)
    }
    let colX = best.value.sorted()[best.value.count / 2]

    // 深色头像会和名字识别成一行（「C专注业绩主升」），左边越过了名字列。
    // 把名字列右边那段单独再认一次。
    var fixed = texts
    if let refine {
        for i in fixed.indices {
            let l = fixed[i]
            guard l.rect.minX < colX - 8, l.rect.minX > colX - 70, l.rect.maxX > colX + 15 else { continue }
            let crop = CGRect(x: colX - 2, y: l.rect.minY - 3, width: l.rect.maxX - colX + 8, height: l.rect.height + 6)
            if let t = refine(crop), !t.text.isEmpty, abs(t.rect.minX - colX) <= 8,
               !fixed.contains(where: { $0.text == t.text && abs($0.midY - t.midY) < 4 }) {
                fixed[i] = t
            }
        }
    }
    let col = fixed.filter { abs($0.rect.minX - colX) <= 8 }.sorted { $0.midY < $1.midY }

    var rows: [Row] = []
    var used = Set<Int>()
    var twoLine = 0
    for (i, l) in col.enumerated() where !used.contains(i) {
        if l.rect.maxY > win.maxY - 3 { continue }   // 贴着窗口底边，可能只露半截
        let date = dates.first { abs($0.midY - l.midY) <= 7 && $0.rect.minX > colX + 120 }
        var sub: Line? = nil
        if i + 1 < col.count {
            let n = col[i + 1]
            let gap = n.midY - l.midY
            if gap >= 12 && gap <= 26 { sub = n; used.insert(i + 1) }
        }
        if date != nil || sub != nil {
            twoLine += 1
        } else {
            // 「最近关注」页签每个号只有一行名字，没有副标题和时间。
            // 孤零零一行、上下 30pt 内都没别的字，才算名字；
            // 紧贴页签下沿的是被挡住一半的上一个号的副标题，不算。
            let prevGap = i > 0 ? l.midY - col[i - 1].midY : 999
            let nextGap = i + 1 < col.count ? col[i + 1].midY - l.midY : 999
            if prevGap < 30 || nextGap < 30 || l.rect.minY < tabBottom + 30 { continue }
        }
        let name = cleanName(l.text)
        guard !name.isEmpty else { continue }
        rows.append(Row(name: name, sub: sub?.text ?? "", date: date?.text, section: nil,
                        point: CGPoint(x: l.rect.minX + min(l.rect.width / 2, 30), y: l.midY)))
    }

    // 分组标题（星标账号）在名字列左边一点。头像里的字也落在这个位置，
    // 凡是和名字列里任何一行字纵向挨着的都是头像，不是标题。
    let headers = texts.filter { h in
        h.rect.minX < colX - 8 && h.rect.minX > colX - 70 && h.text.count <= 10
            && (h.text.contains("星标") || !col.contains { abs($0.midY - h.midY) < 30 })
    }
    for i in rows.indices {
        rows[i].section = headers.filter { $0.midY < rows[i].point.y }.max { $0.midY < $1.midY }?.text
    }

    // 「最近更新」里大部分号都有时间或副标题，「最近关注」里一个都没有
    let tab: String? = rows.isEmpty ? nil : (twoLine * 2 >= rows.count ? "最近更新" : "最近关注")
    let listRect = CGRect(x: colX - 60, y: tabBottom + 10, width: max(200, win.maxX - colX - 40),
                          height: max(100, win.maxY - tabBottom - 20))
    return Page(tab: tab, tabPoints: tabPoints, rows: rows, listRect: listRect, bottomY: win.maxY)
}

/// 两屏之间有没有共同的号（判断滚动有没有跳过东西）
func overlapCount(_ a: [Row], _ b: [Row]) -> Int {
    var n = 0
    for r in b where a.contains(where: { nameDistance($0.name, r.name) == 0 }) { n += 1 }
    return n
}
