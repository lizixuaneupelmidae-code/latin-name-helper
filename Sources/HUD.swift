import AppKit

enum RankCN {
    static func label(_ rank: String) -> String {
        switch rank {
        case "kingdom": return "界"
        case "phylum": return "门"
        case "class": return "纲"
        case "order": return "目"
        case "superfamily": return "总科"
        case "family": return "科"
        case "subfamily": return "亚科"
        case "tribe": return "族"
        case "subtribe": return "亚族"
        case "genus": return "属"
        case "subgenus": return "亚属"
        case "section": return "组"
        case "complex": return "复合种"
        case "species": return "种"
        case "subspecies": return "亚种"
        case "variety": return "变种"
        case "form": return "变型"
        default: return rank
        }
    }
}

struct HUDModel {
    var name: String
    var pronunciation: Pronunciation
    var commonName: String?
    var rank: String?
    var taxonId: Int?
    var note: String?
    var isPending: Bool
    var hierarchy: String = ""
    var schemeTitle: String = ""
}

final class HUDPanel: NSPanel {
    var onKey: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        onKey?(event)
    }

    // ⌘R 这类带修饰键的按键可能走 performKeyEquivalent，拦一道保险
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "r" {
            onKey?(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class HUDController: NSObject {

    private let panel: HUDPanel
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let syllLabel = NSTextField(labelWithString: "")
    private let ipaLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let hierarchyLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")

    private var model: HUDModel?
    private var footerRestoreWork: DispatchWorkItem?
    private let refreshButton = NSButton()
    private var previousApp: NSRunningApplication?

    var onPlayLatin: (() -> Void)?
    var onPlayChinese: (() -> Void)?
    var onCopyLatin: (() -> Void)?
    var onCopyChinese: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenINat: (() -> Void)?

    private let width: CGFloat = 520

    override init() {
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        super.init()
        buildUI()
        panel.onKey = { [weak self] event in self?.handle(event) }
    }

    private func buildUI() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        nameLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail

        metaLabel.font = .systemFont(ofSize: 15, weight: .regular)
        metaLabel.textColor = .secondaryLabelColor

        syllLabel.font = .monospacedSystemFont(ofSize: 19, weight: .medium)
        syllLabel.textColor = .labelColor

        ipaLabel.font = .systemFont(ofSize: 15, weight: .regular)
        ipaLabel.textColor = .secondaryLabelColor

        hierarchyLabel.font = .systemFont(ofSize: 12, weight: .regular)
        hierarchyLabel.textColor = .secondaryLabelColor
        hierarchyLabel.lineBreakMode = .byWordWrapping
        hierarchyLabel.maximumNumberOfLines = 2

        noteLabel.font = .systemFont(ofSize: 12, weight: .regular)
        noteLabel.textColor = .tertiaryLabelColor
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 2

        footerLabel.font = .systemFont(ofSize: 11, weight: .regular)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.stringValue = "1 读拉丁    2 读中文    ↵ 打开 iNat    esc 关闭"
        footerLabel.attributedStringValue = footerAttributed()

        let sep = NSBox()
        sep.boxType = .separator

        let stack = NSStackView(views: [nameLabel, metaLabel, sep, syllLabel, ipaLabel, hierarchyLabel, noteLabel, footerLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(2, after: nameLabel)
        stack.setCustomSpacing(14, after: metaLabel)
        stack.setCustomSpacing(14, after: sep)
        stack.setCustomSpacing(2, after: syllLabel)
        stack.setCustomSpacing(10, after: ipaLabel)
        stack.setCustomSpacing(16, after: noteLabel)
        stack.setCustomSpacing(18, after: ipaLabel)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 18, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.isBordered = false
        refreshButton.bezelStyle = .inline
        refreshButton.title = "↻"
        refreshButton.font = .systemFont(ofSize: 16, weight: .medium)
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.toolTip = "重新联网查询（⌘R）"
        refreshButton.target = self
        refreshButton.action = #selector(didTapRefresh)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(refreshButton)

        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        NSLayoutConstraint.activate([
            refreshButton.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            refreshButton.topAnchor.constraint(equalTo: effect.topAnchor, constant: 16),
            refreshButton.widthAnchor.constraint(equalToConstant: 24),
            refreshButton.heightAnchor.constraint(equalToConstant: 22),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -8),
            noteLabel.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -24),
            hierarchyLabel.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -24)
        ])
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true

        panel.contentView = effect
    }

    private func footerAttributed() -> NSAttributedString {
        let s = NSMutableAttributedString()
        let items: [(String, String)] = [
            ("1", " 拉丁发音"), ("2", " 中文发音"),
            ("3", " 复制拉丁"), ("4", " 复制中文"),
            ("⌘R", " 刷新"), ("↵", " iNat"), ("esc", " 关闭")
        ]
        let font = NSFont.systemFont(ofSize: 11)
        let keyFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        for (i, item) in items.enumerated() {
            if i > 0 {
                s.append(NSAttributedString(string: "    ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            s.append(NSAttributedString(string: item.0, attributes: [.font: keyFont, .foregroundColor: NSColor.secondaryLabelColor]))
            s.append(NSAttributedString(string: item.1, attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return s
    }

    // MARK: - 展示

    func show(_ model: HUDModel) {
        self.model = model
        restoreFooter()

        nameLabel.stringValue = model.name

        var meta: [String] = []
        if model.isPending {
            meta.append("查询中…")
        } else if let cn = model.commonName, !cn.isEmpty {
            meta.append(cn)
        } else {
            meta.append("暂无中文名")
        }
        if let rank = model.rank { meta.append(RankCN.label(rank)) }
        if let tid = model.taxonId { meta.append("iNat #\(tid)") }
        metaLabel.stringValue = meta.joined(separator: " · ")
        if !model.isPending && (model.commonName == nil || model.commonName!.isEmpty) {
            metaLabel.textColor = .tertiaryLabelColor
        } else {
            metaLabel.textColor = .secondaryLabelColor
        }

        syllLabel.attributedStringValue = syllablesAttributed(model.pronunciation)
        ipaLabel.stringValue = model.schemeTitle.isEmpty
            ? model.pronunciation.ipa
            : model.pronunciation.ipa + "    · " + model.schemeTitle
        hierarchyLabel.stringValue = model.hierarchy
        hierarchyLabel.isHidden = model.hierarchy.isEmpty
        noteLabel.stringValue = model.note ?? ""
        noteLabel.isHidden = (model.note ?? "").isEmpty

        layoutAndShow()
    }

    func update(_ model: HUDModel) {
        guard panel.isVisible else { return }
        show(model)
    }

    private func syllablesAttributed(_ p: Pronunciation) -> NSAttributedString {
        let base = NSFont.monospacedSystemFont(ofSize: 19, weight: .medium)
        let strong = NSFont.monospacedSystemFont(ofSize: 19, weight: .bold)
        let s = NSMutableAttributedString()
        let dim: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: NSColor.labelColor]
        let hot: [NSAttributedString.Key: Any] = [.font: strong, .foregroundColor: NSColor.systemOrange]
        let gap: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: NSColor.tertiaryLabelColor]

        for (wi, word) in p.words.enumerated() {
            if wi > 0 { s.append(NSAttributedString(string: "  ", attributes: gap)) }
            for (i, syl) in word.syllables.enumerated() {
                if i > 0 { s.append(NSAttributedString(string: "·", attributes: gap)) }
                let txt = i == word.stress ? syl.uppercased() : syl
                s.append(NSAttributedString(string: txt, attributes: i == word.stress ? hot : dim))
            }
        }
        return s
    }

    private func layoutAndShow() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        var size = content.fittingSize
        size.width = width
        panel.setContentSize(NSSize(width: width, height: max(size.height, 150)))

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let x = visible.midX - width / 2
            let y = visible.maxY - panel.frame.height - 120
            panel.setFrameOrigin(NSPoint(x: x, y: max(y, visible.minY + 40)))
        }

        if !panel.isVisible {
            panel.alphaValue = 0
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }
        panel.makeKey()
    }

    func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.panel.orderOut(nil)
            if let prev = self.previousApp, prev.bundleIdentifier != Bundle.main.bundleIdentifier {
                prev.activate(options: [])
            }
        })
    }

    /// 离屏渲染一张 PNG，用于检查排版（不依赖录屏权限）
    @discardableResult
    func snapshot(to path: String) -> Bool {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// 临时把底栏换成提示文字（如「已复制」），1.4 秒后恢复
    func flash(_ text: String) {
        guard panel.isVisible else { return }
        footerRestoreWork?.cancel()
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        footerLabel.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.systemGreen])
        let work = DispatchWorkItem { [weak self] in self?.restoreFooter() }
        footerRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    @objc private func didTapRefresh() {
        onRefresh?()
    }

    private func restoreFooter() {
        footerLabel.attributedStringValue = footerAttributed()
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - 键盘

    private func handle(_ event: NSEvent) {
        switch event.keyCode {
        case 53: // esc
            hide()
        case 36, 76: // return
            onOpenINat?()
            hide()
        case 49: // space
            onPlayLatin?()
        default:
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "r" {
                onRefresh?()
                return
            }
            switch event.charactersIgnoringModifiers {
            case "1": onPlayLatin?()
            case "2": onPlayChinese?()
            case "3": onCopyLatin?()
            case "4": onCopyChinese?()
            case "q": hide()
            default: break
            }
        }
    }
}
