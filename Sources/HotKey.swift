import AppKit
import Carbon.HIToolbox

final class GlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onPress: (() -> Void)?

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData = userData else { return noErr }
            let obj = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { obj.onPress?() }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C41544E), id: 1) // 'LATN'
        return RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let h = handlerRef {
            RemoveEventHandler(h)
            handlerRef = nil
        }
    }
}

enum Selection {

    static func hasAccessibility() -> Bool {
        return AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func read(from app: NSRunningApplication? = nil) -> String? {
        if let s = readViaAX(app: app) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return readViaClipboard()
    }

    private static func readViaAX(app: NSRunningApplication? = nil) -> String? {
        let candidate = app ?? NSWorkspace.shared.frontmostApplication
        guard let front = candidate,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }

        let axApp = AXUIElementCreateApplication(front.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }

        // 有些应用把选中文本放在 focused element，有些放在 window
        if let s = selectedText(from: element as! AXUIElement) { return s }

        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success,
           let w = window {
            if let s = selectedText(from: w as! AXUIElement) { return s }
        }
        return nil
    }

    private static func selectedText(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard err == .success, let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 退化方案：模拟 ⌘C，读剪贴板，再还原
    private static func readViaClipboard() -> String? {
        guard hasAccessibility() else { return nil }

        let pb = NSPasteboard.general
        let savedString = pb.string(forType: .string)
        let savedTypes = pb.types ?? []

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 0x08
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false) else {
            return nil
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        var waited = 0.0
        var result: String?
        while waited < 0.5 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            waited += 0.02
            if let s = pb.string(forType: .string), s != savedString {
                result = s
                break
            }
        }

        // 还原剪贴板
        if let s = savedString, !savedTypes.isEmpty {
            pb.clearContents()
            pb.setString(s, forType: .string)
        }
        return result?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
