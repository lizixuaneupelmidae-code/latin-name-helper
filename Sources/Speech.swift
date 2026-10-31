import AppKit
import AVFoundation

struct Config: Codable {
    var latinVoice: String = "Daniel"
    var chineseVoice: String = "Tingting"
    var rate: Int = 160
    var hotKeyCode: UInt32 = 21 // kVK_ANSI_4
    var hotKeyModifiers: UInt32 = 256 // cmdKey
    var scheme: String = "british"          // british / ecclesiastical / classical
    var ecclesiasticalVoice: String = "Alice"

    static var current: Config = load()

    func save() {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return }
        let url = base.appendingPathComponent("LatinNameHelper/config.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func load() -> Config {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return Config() }
        let url = base.appendingPathComponent("LatinNameHelper/config.json")
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        let cfg = Config()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cfg) {
            try? data.write(to: url)
        }
        return cfg
    }
}

/// 用 AVSpeechSynthesizer 而不是 `say` 子进程：
/// `say` 在进程退出时会截掉最后一个音节的播放尾巴（"单节螯蜂属" 听成 "单节螯蜂"）。
final class Speech: NSObject, AVSpeechSynthesizerDelegate {

    static let shared = Speech()

    private let synth = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synth.delegate = self
    }

    func speakLatin(_ text: String, scheme: LatinEngine.Scheme = .british) {
        let italian = (scheme == .ecclesiastical)
        speak(text,
              voiceName: italian ? Config.current.ecclesiasticalVoice : Config.current.latinVoice,
              language: italian ? "it-IT" : "en-GB",
              wpm: Config.current.rate)
    }

    func speakChinese(_ text: String) {
        speak(text, voiceName: Config.current.chineseVoice, language: "zh-CN", wpm: Config.current.rate + 15)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    private func speak(_ text: String, voiceName: String, language: String, wpm: Int) {
        guard !text.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = resolveVoice(name: voiceName, language: language)
        utterance.rate = rateFor(wpm: wpm)
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0.08
        synth.speak(utterance)
    }

    private func rateFor(wpm: Int) -> Float {
        // AVSpeechUtterance 的 rate 是 0…1，0.5 约等于正常语速
        let r = Float(wpm) / 350.0
        return min(max(r, 0.3), 0.7)
    }

    private func resolveVoice(name: String, language: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let exact = voices.first(where: { $0.identifier == name }) { return exact }
        if let byName = voices.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.language.hasPrefix(language.prefix(2))
        }) { return byName }
        if let byLang = voices.first(where: { $0.language == language }) { return byLang }
        return AVSpeechSynthesisVoice(language: language)
    }
}
