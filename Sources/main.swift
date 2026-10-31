import AppKit

let argv = CommandLine.arguments

// 命令行探针模式：不启动 GUI，用于验证引擎与接口
if let idx = argv.firstIndex(of: "--probe") {
    let rest = idx + 1 < argv.count ? Array(argv[(idx + 1)...]) : []
    Probe.run(rest)
    exit(0)
}

// 渲染自检：真实查询 iNat 后生成面板截图并退出
if let ridx = argv.firstIndex(of: "--render"), ridx + 1 < argv.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let target = (ridx + 2 < argv.count) ? argv[ridx + 2] : "Dryinidae"
    let chineseMode = LatinEngine.containsCJK(target)
    var name = chineseMode
        ? (LatinEngine.extractChineseName(target) ?? target)
        : (LatinEngine.extractName(target) ?? target)
    var p = chineseMode ? Pronunciation(word: "", words: []) : LatinEngine.pronounce(name)

    var common: String?
    var rank: String?
    var tid: Int?
    var note: String?
    let sem = DispatchSemaphore(value: 0)
    INatClient.shared.lookup(name, direction: chineseMode ? .chinese : .latin,
                             queue: DispatchQueue.global()) { result in
        switch result {
        case .found(let t, let exact):
            common = t.preferred_common_name; rank = t.rank; tid = t.id
            if chineseMode {
                name = t.name
                p = LatinEngine.pronounce(t.name)
                if !exact { note = "没有完全相同的中文名，显示最接近的一条" }
            } else if !exact {
                note = "种加词未收录，显示的是属级 \(t.name)"
            }
        case .notFound:
            let parts = name.split(separator: " ")
            var lines: [String] = []
            if parts.count == 2 {
                let sem2 = DispatchSemaphore(value: 0)
                INatClient.shared.lookup(String(parts[0]), queue: DispatchQueue.global()) { r in
                    if case .found(let g, _) = r {
                        let cn = g.preferred_common_name
                        lines.append((cn?.isEmpty ?? true)
                                     ? "iNat 没有这个种名。属 \(g.name) 的中文名待补"
                                     : "iNat 没有这个种名。属 \(g.name) ＝ \(cn!)")
                    }
                    sem2.signal()
                }
                _ = sem2.wait(timeout: .now() + 10)
            } else {
                lines.append("iNat 没有收录这个名称")
            }
            let sem3 = DispatchSemaphore(value: 0)
            GBIFClient.shared.match(name, queue: DispatchQueue.global()) { r in
                switch r {
                case .accepted(let a, let rank): lines.append("GBIF：接受名 \(a)（\(rank.lowercased())）")
                case .synonym(let a, let cur): lines.append("GBIF：\(cur) 为异名，接受名 \(a)")
                case .higherRank(let h): lines.append("GBIF：只匹配到 \(h)")
                case .none: lines.append("GBIF 也没匹配到，请检查拼写")
                case .failed: break
                }
                sem3.signal()
            }
            _ = sem3.wait(timeout: .now() + 10)
            note = lines.joined(separator: "\n")
        case .failed(let msg):
            note = "查询失败：\(msg)"
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 10)

    let scheme = LatinEngine.Scheme(rawValue: ProcessInfo.processInfo.environment["LATIN_SCHEME"] ?? "british") ?? .british
    p = LatinEngine.pronounce(name, scheme: scheme)

    var hierarchyText = ""
    if let id = tid {
        let semA = DispatchSemaphore(value: 0)
        INatClient.shared.ancestors(of: id, queue: DispatchQueue.global()) { chain in
            hierarchyText = AppDelegate.formatHierarchy(chain)
            semA.signal()
        }
        _ = semA.wait(timeout: .now() + 10)
    }

    let hud = HUDController()
    hud.show(HUDModel(name: name, pronunciation: p, commonName: common,
                      rank: rank, taxonId: tid, note: note, isPending: false,
                      hierarchy: hierarchyText, schemeTitle: scheme.title))
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
        _ = hud.snapshot(to: argv[ridx + 1])
        exit(0)
    }
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
