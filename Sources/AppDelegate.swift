import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let hud = HUDController()
    private let hotKey = GlobalHotKey()

    private var lastForeignApp: NSRunningApplication?
    private var currentName = ""
    private var currentRespell = ""
    private var currentTaxon: Taxon?
    private var currentCommon: String?
    private var schemeItem: NSMenuItem?
    private var lastQuery: String = ""
    private var lastDirection: Direction = .latin
    private var hotKeyStatus: OSStatus = -1

    private var scheme: LatinEngine.Scheme {
        LatinEngine.Scheme(rawValue: Config.current.scheme) ?? .british
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        wireHUD()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self?.lastForeignApp = app
            }
        }

        hotKey.onPress = { [weak self] in self?.trigger() }
        hotKeyStatus = hotKey.register(keyCode: Config.current.hotKeyCode,
                                       modifiers: Config.current.hotKeyModifiers)
        refreshHotKeyItem()

        if !Selection.hasAccessibility() {
            Selection.requestAccessibility()
        }
    }

    // MARK: - 菜单栏

    private var hotKeyItem: NSMenuItem?

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // 只用文字标题：SF Symbol 图标在部分系统版本上会缩成一个点
            button.image = nil
            button.title = "Aa"
            button.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        }
        let menu = NSMenu()
        let hk = NSMenuItem(title: "查询选中的学名（⌘4）", action: #selector(menuTrigger), keyEquivalent: "")
        hotKeyItem = hk
        menu.addItem(hk)
        menu.addItem(NSMenuItem(title: "显示示例面板", action: #selector(showDemo), keyEquivalent: ""))
        menu.addItem(buildSchemeMenu())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "辅助功能权限…", action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "清空缓存（重新联网查）", action: #selector(clearCacheMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开配置文件夹", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        dumpStatusState("after-create")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.verifyStatusItem()
        }
    }

    private func refreshHotKeyItem() {
        if hotKeyStatus == 0 {
            hotKeyItem?.title = "查询选中的学名（⌘4）"
        } else {
            hotKeyItem?.title = "⚠️ 快捷键注册失败（已被其他程序占用）"
        }
    }

    // MARK: - 临时诊断

    private var logStarted = false

    private func log(_ s: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LatinNameHelper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("status.log")
        let line = "\(Date()) \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !logStarted {
            logStarted = true
            try? data.write(to: url, options: .atomic)
            return
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func dumpStatusState(_ tag: String) {
        let b = statusItem?.button
        log("[\(tag)] item=\(statusItem != nil) button=\(b != nil) frame=\(b?.frame.debugDescription ?? "nil") hidden=\(b?.isHidden ?? true) window=\(b?.window?.frame.debugDescription ?? "nil") winVisible=\(b?.window?.isVisible ?? false) thickness=\(NSStatusBar.system.thickness) ax=\(Selection.hasAccessibility())")
    }

    private var didRebuildStatusItem = false

    /// 某些情况下系统会把状态栏项挪到屏幕外，检测到就重建一次
    private func verifyStatusItem() {
        guard let button = statusItem?.button, let window = button.window else {
            log("[verify] 没有按钮/窗口")
            return
        }
        let onBar = window.frame.origin.y > 600 && window.frame.width > 4
        dumpStatusState(onBar ? "verify-ok" : "verify-offbar")
        guard !onBar, !didRebuildStatusItem else { return }
        didRebuildStatusItem = true
        if let old = statusItem {
            NSStatusBar.system.removeStatusItem(old)
            statusItem = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            self.setupStatusItem()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.dumpStatusState("after-rebuild")
            }
        }
    }

    @objc private func menuTrigger() { trigger() }

    @objc private func showDemo() {
        present("Dryinidae")
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openConfig() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LatinNameHelper")
        NSWorkspace.shared.open(dir)
    }

    @objc private func clearCacheMenu() {
        INatClient.shared.clearCache()
        hud.flash("缓存已清空")
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - 主流程

    private func wireHUD() {
        hud.onPlayLatin = { [weak self] in
            guard let self = self, !self.currentRespell.isEmpty else { NSSound.beep(); return }
            Speech.shared.speakLatin(self.currentRespell, scheme: self.scheme)
        }
        hud.onPlayChinese = { [weak self] in
            guard let self = self else { return }
            Speech.shared.speakChinese(self.currentCommon ?? "暂无中文名")
        }
        hud.onCopyLatin = { [weak self] in
            guard let self = self, !self.currentName.isEmpty else { NSSound.beep(); return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(self.currentName, forType: .string)
            self.hud.flash("已复制拉丁名  \(self.currentName)")
        }
        hud.onCopyChinese = { [weak self] in
            guard let self = self else { return }
            guard let cn = self.currentCommon, !cn.isEmpty else {
                self.hud.flash("暂无中文名，无可复制")
                return
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(cn, forType: .string)
            self.hud.flash("已复制中文名  \(cn)")
        }
        hud.onRefresh = { [weak self] in
            guard let self = self, !self.lastQuery.isEmpty else { return }
            if self.lastDirection == .chinese {
                self.presentChinese(self.lastQuery, force: true)
            } else {
                self.present(self.lastQuery, force: true)
            }
        }
        hud.onOpenINat = { [weak self] in
            guard let self = self else { return }
            var urlString = "https://www.inaturalist.org/search?q=\(self.currentName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            if let t = self.currentTaxon {
                urlString = "https://www.inaturalist.org/taxa/\(t.id)"
            }
            if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
        }
    }

    private func trigger() {
        guard Selection.hasAccessibility() else {
            Selection.requestAccessibility()
            showMessage("需要「辅助功能」权限",
                        note: "系统设置 → 隐私与安全性 → 辅助功能 → 勾选「拉丁名助手」，再按一次 ⌘4")
            return
        }
        let raw = lastForeignApp != nil ? Selection.read(from: lastForeignApp) : Selection.read()
        guard let text = raw else {
            showMessage("没有检测到选中的文字", note: "先在 PDF / 网页 / Word 里选中一个学名，再按 ⌘4")
            return
        }
        if LatinEngine.containsCJK(text) {
            guard let chinese = LatinEngine.extractChineseName(text) else {
                showMessage("没认出中文名", note: "选中的内容：" + String(text.prefix(48)))
                return
            }
            presentChinese(chinese)
            return
        }

        guard let name = LatinEngine.extractName(text) else {
            showMessage("没认出学名", note: "选中的内容：" + String(text.prefix(48)))
            return
        }
        present(name)
    }

    private func present(_ name: String, force: Bool = false) {
        lastQuery = name
        lastDirection = .latin
        currentName = name
        currentTaxon = nil
        currentCommon = nil

        let p = LatinEngine.pronounce(name, scheme: scheme)
        currentRespell = p.respell

        hud.show(HUDModel(name: name, pronunciation: p, commonName: nil,
                          rank: nil, taxonId: nil, note: nil, isPending: true,
                          schemeTitle: scheme.title))

        INatClient.shared.lookup(name, forceRefresh: force) { [weak self] result in
            guard let self = self else { return }
            var common: String?
            var rank: String?
            var tid: Int?
            var note: String?

            switch result {
            case .found(let taxon, let exact):
                self.currentTaxon = taxon
                common = taxon.preferred_common_name
                rank = taxon.rank
                tid = taxon.id
                if !exact {
                    note = "种加词未收录，显示的是属级 \(taxon.name)"
                }
                if (common ?? "").isEmpty {
                    note = "iNat 上暂无中文名。补录后按 ⌘R 重新查询"
                }
            case .notFound:
                self.resolveMissing(name: name, pronunciation: p, force: force)
                return
            case .failed(let msg):
                note = "网络查询失败：\(msg)"
            }

            self.currentCommon = common
            let model = HUDModel(name: name, pronunciation: p, commonName: common,
                                 rank: rank, taxonId: tid, note: note, isPending: false,
                                 schemeTitle: self.scheme.title)
            self.hud.update(model)
            if let id = tid { self.attachHierarchy(to: model, taxonID: id, force: force) }
        }
    }

    /// 中文名 → 拉丁名
    private func presentChinese(_ query: String, force: Bool = false) {
        lastQuery = query
        lastDirection = .chinese
        currentName = ""
        currentRespell = ""
        currentTaxon = nil
        currentCommon = query

        let empty = Pronunciation(word: "", words: [])
        hud.show(HUDModel(name: query, pronunciation: empty, commonName: nil,
                          rank: nil, taxonId: nil, note: nil, isPending: true))

        // 选中内容可能混着别的字，逐次去掉开头的字再试
        tryChinese(LatinEngine.chineseCandidates(query), at: 0, original: query,
                   empty: empty, force: force)
    }

    private func tryChinese(_ candidates: [String], at index: Int,
                            original: String, empty: Pronunciation, force: Bool) {
        guard index < candidates.count else {
            hud.update(HUDModel(name: original, pronunciation: empty, commonName: nil,
                                rank: nil, taxonId: nil,
                                note: "iNat 上没有与这个中文名对应的条目", isPending: false))
            return
        }
        let query = candidates[index]

        INatClient.shared.lookup(query, direction: .chinese, forceRefresh: force) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .found(let taxon, let exact):
                let p = LatinEngine.pronounce(taxon.name, scheme: self.scheme)
                self.currentTaxon = taxon
                self.currentName = taxon.name
                self.currentRespell = p.respell
                self.currentCommon = taxon.preferred_common_name ?? query

                var note: String?
                if !exact { note = "没有完全相同的中文名，显示最接近的一条" }
                if (taxon.preferred_common_name ?? "").isEmpty { note = "该条目在 iNat 上没有中文名" }
                if query != original { note = "按「\(query)」查得" }

                let model = HUDModel(name: taxon.name, pronunciation: p,
                                     commonName: self.currentCommon, rank: taxon.rank,
                                     taxonId: taxon.id, note: note, isPending: false,
                                     schemeTitle: self.scheme.title)
                self.hud.update(model)
                self.attachHierarchy(to: model, taxonID: taxon.id, force: force)
            case .notFound:
                self.tryChinese(candidates, at: index + 1, original: original,
                                empty: empty, force: force)
            case .failed(let msg):
                self.hud.update(HUDModel(name: original, pronunciation: empty, commonName: nil,
                                         rank: nil, taxonId: nil,
                                         note: "网络查询失败：\(msg)", isPending: false))
            }
        }
    }

    /// iNat 查不到时：退一步找属的中文名，并让 GBIF 判断这个名字是否真实有效
    private func resolveMissing(name: String, pronunciation p: Pronunciation, force: Bool) {
        let parts = name.split(separator: " ")
        let genusName: String? = parts.count == 2 ? String(parts[0]) : nil

        var genusLatin: String?
        var genusCN: String?
        var gbifLine: String?

        let group = DispatchGroup()

        if let genus = genusName {
            group.enter()
            INatClient.shared.lookup(genus, forceRefresh: force) { result in
                if case .found(let t, _) = result {
                    genusLatin = t.name
                    genusCN = t.preferred_common_name
                }
                group.leave()
            }
        }

        group.enter()
        GBIFClient.shared.match(name, forceRefresh: force) { result in
            switch result {
            case .accepted(let accepted, let rank):
                gbifLine = "GBIF：接受名 \(accepted)（\(rank.lowercased())）"
            case .synonym(let accepted, let current):
                gbifLine = "GBIF：\(current) 为异名，接受名 \(accepted)"
            case .higherRank(let higher):
                gbifLine = "GBIF：只匹配到 \(higher)"
            case .none:
                gbifLine = "GBIF 也没匹配到，请检查拼写"
            case .failed:
                gbifLine = nil
            }
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            var lines: [String] = []
            if let latin = genusLatin {
                if let cn = genusCN, !cn.isEmpty {
                    lines.append("iNat 没有这个种名。属 \(latin) ＝ \(cn)")
                } else {
                    lines.append("iNat 没有这个种名。属 \(latin) 的中文名待补")
                }
            } else {
                lines.append("iNat 没有收录这个名称")
            }
            if let gbif = gbifLine { lines.append(gbif) }

            self.hud.update(HUDModel(name: name, pronunciation: p, commonName: nil,
                                     rank: nil, taxonId: nil,
                                     note: lines.joined(separator: "\n"), isPending: false))
        }
    }

    // MARK: - 发音习惯

    private func buildSchemeMenu() -> NSMenuItem {
        let sub = NSMenu()
        for (idx, s) in LatinEngine.Scheme.allCases.enumerated() {
            let item = NSMenuItem(title: s.title, action: #selector(changeScheme(_:)), keyEquivalent: "")
            item.tag = idx
            item.target = self
            item.state = (s == scheme) ? .on : .off
            sub.addItem(item)
        }
        let parent = NSMenuItem(title: "发音习惯", action: nil, keyEquivalent: "")
        parent.submenu = sub
        schemeItem = parent
        return parent
    }

    @objc private func changeScheme(_ sender: NSMenuItem) {
        let all = LatinEngine.Scheme.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        let chosen = all[sender.tag]
        Config.current.scheme = chosen.rawValue
        Config.current.save()
        sender.menu?.items.forEach { $0.state = ($0.tag == sender.tag) ? .on : .off }

        guard !lastQuery.isEmpty else { return }
        if lastDirection == .chinese {
            presentChinese(lastQuery)
        } else {
            present(lastQuery)
        }
    }

    // MARK: - 上级分类

    private func attachHierarchy(to model: HUDModel, taxonID: Int, force: Bool) {
        INatClient.shared.ancestors(of: taxonID, forceRefresh: force) { [weak self] chain in
            guard let self = self else { return }
            let text = AppDelegate.formatHierarchy(chain)
            guard !text.isEmpty else { return }
            var updated = model
            updated.hierarchy = text
            self.hud.update(updated)
        }
    }

    static func formatHierarchy(_ chain: [Ancestor]) -> String {
        let wanted: Set<String> = ["superfamily", "family", "subfamily", "tribe", "subtribe", "genus"]
        var picked = chain.filter { wanted.contains($0.rank) }
        // 只剩一两条时，补上更高级的目/总科，避免只显示一个词
        if picked.count < 2 { picked = Array(chain.suffix(3)) }
        return picked.map { ancestor -> String in
            let cn = ancestor.preferred_common_name ?? ""
            return cn.isEmpty ? ancestor.name : cn
        }.joined(separator: " › ")
    }

    private func showMessage(_ title: String, note: String?) {
        let empty = Pronunciation(word: "", words: [])
        currentName = ""
        currentRespell = ""
        currentTaxon = nil
        currentCommon = nil
        hud.show(HUDModel(name: title, pronunciation: empty, commonName: nil,
                          rank: nil, taxonId: nil, note: note, isPending: false))
    }
}
