import Cocoa

setvbuf(stdout, nil, _IONBF, 0)
ensureDirs()
let args = Array(CommandLine.arguments.dropFirst())

switch args.first ?? "" {
case "check":
    // 权限 + 能不能找到「关注」窗口
    var d: [String: Any] = ["type": "check", "ax": Perm.ax, "screen": Perm.screen,
                            "wechat": wechatApp() != nil]
    if !Perm.ax || !Perm.screen { Perm.prompt() }
    d["window"] = (Perm.screen && FollowList.open() != nil)
    emit(d)
case "harvest":
    cmdHarvest()
case "run":
    cmdRun()
case "parse":
    // 离线调试：把一张「关注」窗口截图当成窗口在 (0,0) 来解析
    guard args.count >= 2, let img = NSImage(contentsOfFile: args[1]),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
    let scale = CGFloat(args.count >= 3 ? Double(args[2]) ?? 2 : 2)
    let r = CGRect(x: 0, y: 0, width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
    let lines = ocr(cg, region: r)
    if args.count >= 4 { for l in lines { print(String(format: "%.0f,%.0f %.0fx%.0f", l.rect.minX, l.rect.minY, l.rect.width, l.rect.height), l.text) } }
    let refine: (CGRect) -> Line? = { c in ocrCrop(cg, region: r, crop: c).min { $0.rect.minY < $1.rect.minY } }
    guard let p = parsePage(lines, win: r, refine: refine) else { print("不是「关注」页"); exit(0) }
    for row in p.rows {
        print([row.name, row.sub, row.date ?? "-", parseDate(row.date) ?? "-", row.section ?? "-",
               row.dead ? "死号" : "", String(format: "(%.0f,%.0f)", row.point.x, row.point.y)].joined(separator: " | "))
    }
default:
    print("用法: wxunf check | harvest | run | parse <截图.png> [缩放]")
}
