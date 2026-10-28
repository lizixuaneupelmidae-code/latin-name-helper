import Foundation

enum LUnit {
    case cons(String)
    case vowel(String)

    var text: String {
        switch self {
        case .cons(let s), .vowel(let s): return s
        }
    }
    var isVowel: Bool {
        if case .vowel = self { return true }
        return false
    }
}

struct Pronunciation {

    struct Word {
        var syllables: [String]
        var stress: Int
        var ipa: String
        var respell: String

        var display: String {
            syllables.enumerated()
                .map { $0.offset == stress ? $0.element.uppercased() : $0.element }
                .joined(separator: "·")
        }
    }

    let word: String
    let words: [Word]

    /// go·NA·to·pus  dis·TINC·tus
    var display: String {
        words.map { $0.display }.joined(separator: "  ")
    }

    /// /ɡəˈnætəpəs dɪsˈtɪnktəs/
    var ipa: String {
        let body = words.map { $0.ipa }.filter { !$0.isEmpty }.joined(separator: " ")
        return body.isEmpty ? "" : "/\(body)/"
    }

    /// 仅供语音合成，界面不显示
    var respell: String {
        words.map { $0.respell }.joined(separator: ", ")
    }
}

enum LatinEngine {

    static let vowelChars: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    // MARK: - 文本归一化

    /// 清理 PDF 复制来的断行、软连字符、多余空白
    static func clean(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "\u{00AD}", with: "")
        s = s.replacingOccurrences(of: "-\r\n", with: "")
        s = s.replacingOccurrences(of: "-\n", with: "")
        s = s.replacingOccurrences(of: "\r\n", with: " ")
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\t", with: " ")
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        return collapse(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapse(_ s: String) -> String {
        var out = ""
        var lastSpace = false
        for ch in s {
            if ch == " " {
                if !lastSpace { out.append(ch) }
                lastSpace = true
            } else {
                out.append(ch)
                lastSpace = false
            }
        }
        return out
    }

    private static let stopWords: Set<String> = [
        "sp.", "sp", "spp.", "spp", "cf.", "cf", "aff.", "aff",
        "nr.", "nr", "nov.", "n.", "?", "×", "et", "&"
    ]

    /// 从一段选中文字里抽出学名（最多属 + 种加词）
    static func extractName(_ raw: String) -> String? {
        let s = clean(raw)
        guard !s.isEmpty else { return nil }

        // 去掉括号内的亚属 / 命名人
        var stripped = s
        while let r = stripped.range(of: "\\([^()]*\\)", options: .regularExpression) {
            stripped.replaceSubrange(r, with: " ")
        }
        stripped = collapse(stripped)

        var tokens = stripped.components(separatedBy: " ").filter { !$0.isEmpty }

        // 第一个词不是纯拉丁字母（比如中英混排）→ 用正则捞一个
        if let first = tokens.first, !isLatinWord(first) {
            if let m = firstLatinWord(in: stripped) { tokens = [m] }
        }

        guard let head = tokens.first, isLatinWord(head) else { return nil }
        let lower = head.lowercased()

        // 科级 / 亚科 / 族级词尾
        if lower.hasSuffix("idae") || lower.hasSuffix("inae") || lower.hasSuffix("ini")
            || lower.hasSuffix("oidea") || lower.hasSuffix("aceae") || lower.hasSuffix("ales") {
            return normalizeCase(head)
        }

        var name = normalizeCase(head)
        if tokens.count > 1 {
            let second = tokens[1]
            if !stopWords.contains(second.lowercased()),
               second.count >= 2,
               isLatinWord(second),
               second.first?.isLowercase == true {
                name += " " + second.lowercased()
            }
        }
        return name
    }

    private static func isLatinWord(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var hasLetter = false
        for ch in s.unicodeScalars {
            let v = ch.value
            if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) { hasLetter = true; continue }
            if v == 45 || v == 46 { continue }
            return false
        }
        return hasLetter
    }

    private static func firstLatinWord(in s: String) -> String? {
        guard let r = s.range(of: "[A-Z][a-z]{2,}", options: .regularExpression) else { return nil }
        return String(s[r])
    }

    private static func normalizeCase(_ w: String) -> String {
        guard let f = w.first else { return w }
        return String(f).uppercased() + w.dropFirst().lowercased()
    }

    // MARK: - 分词成「辅音单元 / 元音核」

    static func units(_ word: String) -> [LUnit] {
        let a = Array(word.lowercased())
        var out: [LUnit] = []
        var i = 0
        while i < a.count {
            let two: String = (i + 1 < a.count) ? String([a[i], a[i + 1]]) : ""
            if ["ch", "ph", "th", "rh"].contains(two) { out.append(.cons(two)); i += 2; continue }
            if two == "qu" { out.append(.cons(two)); i += 2; continue }
            if two == "gu", i + 2 < a.count, vowelChars.contains(a[i + 2]) {
                out.append(.cons(two)); i += 2; continue
            }
            if ["ae", "oe", "au", "eu", "ei"].contains(two) { out.append(.vowel(two)); i += 2; continue }
            if vowelChars.contains(a[i]) { out.append(.vowel(String(a[i]))) }
            else { out.append(.cons(String(a[i]))) }
            i += 1
        }
        return out
    }

    private static let onsetClusters: Set<String> = [
        "bl", "br", "cl", "cr", "dr", "fl", "fr", "gl", "gr", "pl", "pr", "tr"
    ]

    /// 切音节
    static func syllabify(_ word: String) -> [String] {
        let us = units(word)
        guard !us.isEmpty else { return [word] }
        let nuclei = us.indices.filter { us[$0].isVowel }
        guard !nuclei.isEmpty else { return [word] }

        var result: [[LUnit]] = []
        var start = 0
        for k in nuclei.indices {
            let p = nuclei[k]
            var end = us.count
            if k + 1 < nuclei.count {
                let q = nuclei[k + 1]
                let cluster = Array(us[(p + 1)..<q])
                let n = cluster.count
                var coda = 0
                if n >= 2 {
                    let tailUnits = Array(cluster.suffix(2)).map { $0.text }
                    let tail = tailUnits.joined()
                    let digraphLiquid = ["ch", "ph", "th", "rh"].contains(tailUnits[0])
                        && ["l", "r"].contains(tailUnits[1])
                    coda = (onsetClusters.contains(tail) || digraphLiquid) ? n - 2 : n - 1
                }
                end = p + 1 + coda
            }
            if end <= start { end = min(start + 1, us.count) }
            result.append(Array(us[start..<end]))
            start = end
        }
        if start < us.count { result[result.count - 1].append(contentsOf: us[start...]) }
        return result.map { $0.map { $0.text }.joined() }
    }

    /// 科级名称按「词干 + 固定词尾」切分，避免 Dryinidae 被切成 dry-i-ni-dae
    static func syllablesForName(_ name: String) -> [String] {
        let lower = name.lowercased()
        var stem = ""
        var tail: [String] = []
        if lower.hasSuffix("oidea"), name.count > 6 {
            stem = String(name.dropLast(5)) + "o"; tail = ["i", "de", "a"]
        } else if lower.hasSuffix("idae"), name.count > 5 {
            stem = String(name.dropLast(4)); tail = ["i", "dae"]
        } else if lower.hasSuffix("inae"), name.count > 5 {
            stem = String(name.dropLast(4)); tail = ["i", "nae"]
        } else if lower.hasSuffix("ini"), name.count > 4 {
            stem = String(name.dropLast(3)); tail = ["i", "ni"]
        }
        guard !stem.isEmpty else { return syllabify(name) }
        var head = syllabify(stem)
        if head.isEmpty { return syllabify(name) }

        // 词干末尾是「塞音 + 流音」时，流音归入词尾音节（Platygaster → gas-tri）
        if let lastSyl = head.last, lastSyl.count >= 2, !tail.isEmpty {
            let arr = Array(lastSyl)
            let pair = String([arr[arr.count - 2], arr[arr.count - 1]])
            if onsetClusters.contains(pair) {
                head[head.count - 1] = String(arr.dropLast())
                tail[0] = String(arr[arr.count - 1]) + tail[0]
            }
        }
        return head + tail
    }

    // MARK: - 重音

    private static let longPenultSuffixes = [
        "atus", "ata", "atum", "alis", "ale", "are", "arum", "orum",
        "anus", "ana", "anum", "osus", "osa", "osum", "ensis", "ense",
        "ianus", "iana", "eanus", "ellus", "illa", "illus", "issimus"
    ]

    static func stressIndex(_ syllables: [String], word: String) -> Int {
        let n = syllables.count
        if n <= 2 { return 0 }
        let w = word.lowercased()
        if w.hasSuffix("idae") || w.hasSuffix("inae") || w.hasSuffix("ini") {
            return max(0, n - 3)
        }
        if w.hasSuffix("oidea") { return max(0, n - 4) }
        for suf in longPenultSuffixes where w.hasSuffix(suf) { return n - 2 }
        let penult = syllables[n - 2]
        return isHeavy(penult) ? n - 2 : n - 3
    }

    /// 倒数第二音节是否为「长」（闭音节或含双元音）
    private static func isHeavy(_ syl: String) -> Bool {
        guard let last = syl.last else { return false }
        if !vowelChars.contains(last) { return true }
        if syl.contains("ae") || syl.contains("oe") || syl.contains("au")
            || syl.contains("eu") || syl.contains("ei") { return true }
        return false
    }

    // MARK: - IPA（英式学院派）

    static func ipa(_ syllables: [[LUnit]], stress: Int) -> String {
        var flat: [LUnit] = []
        var bounds: [Int] = []
        for s in syllables { bounds.append(flat.count); flat.append(contentsOf: s) }
        guard !bounds.isEmpty, stress < bounds.count else { return "" }

        let starts = Set(bounds)
        var out = ""
        var sylIndex = 0
        var lastCons = ""

        for i in flat.indices {
            if sylIndex + 1 < bounds.count && i == bounds[sylIndex + 1] { sylIndex += 1 }
            if i == bounds[stress] { out += "ˈ"; lastCons = "" }
            let unit = flat[i]
            let next: LUnit? = i + 1 < flat.count ? flat[i + 1] : nil

            switch unit {
            case .vowel(let v):
                let open = (i + 1 >= flat.count) || starts.contains(i + 1)
                out += vowelIPA(v, stressed: sylIndex == stress, open: open,
                                isFinal: sylIndex == bounds.count - 1)
                lastCons = ""
            case .cons(let c):
                let chunk = consIPA(c, next: next?.text ?? "", initial: i == 0)
                // 叠辅音在英式读法里只发一次
                if chunk.count == 1 && chunk == lastCons { continue }
                out += chunk
                lastCons = chunk
            }
        }
        return out
    }

    private static func vowelIPA(_ v: String, stressed: Bool, open: Bool, isFinal: Bool) -> String {
        switch v {
        case "ae", "oe": return "iː"
        case "au": return "ɔː"
        case "eu": return "juː"
        case "ei": return "eɪ"
        default: break
        }
        if v == "y" { return open ? "aɪ" : "ɪ" }
        if isFinal && !open {
            if v == "u" || v == "a" { return "ə" }
            if v == "o" { return "ɒ" }
            if v == "e" { return "ɪ" }
        }
        if stressed {
            switch v {
            case "a": return "æ"
            case "e": return "e"
            case "i": return open ? "aɪ" : "ɪ"
            case "o": return "ɒ"
            case "u": return "ʌ"
            default: return "ə"
            }
        }
        if open {
            switch v {
            case "e", "i": return "ɪ"
            default: return "ə"
            }
        }
        switch v {
        case "a": return "æ"
        case "e": return "e"
        case "i": return "ɪ"
        case "o": return "ɒ"
        case "u": return "ʌ"
        default: return "ə"
        }
    }

    private static func consIPA(_ c: String, next: String, initial: Bool) -> String {
        let soft = next.hasPrefix("e") || next.hasPrefix("i") || next.hasPrefix("y")
            || next.hasPrefix("ae") || next.hasPrefix("oe")
        switch c {
        case "ch": return "k"
        case "ph": return "f"
        case "th": return "θ"
        case "rh": return "r"
        case "qu": return "kw"
        case "gu": return "ɡw"
        case "c": return soft ? "s" : "k"
        case "g": return soft ? "dʒ" : "ɡ"
        case "x": return initial ? "z" : "ks"
        case "y": return "j"
        case "j": return "dʒ"
        default: return c
        }
    }

    // MARK: - 英语转写（只给 say 用）

    static func respelling(_ syllables: [[LUnit]], stress: Int) -> String {
        var parts: [String] = []
        for (si, syl) in syllables.enumerated() {
            var s = ""
            for (ui, u) in syl.enumerated() {
                switch u {
                case .vowel(let v):
                    s += respellVowel(v, stressed: si == stress, open: ui == syl.count - 1)
                case .cons(let c):
                    let nextText = ui + 1 < syl.count ? syl[ui + 1].text : ""
                    s += respellCons(c, next: nextText)
                }
            }
            parts.append(s)
        }
        return parts.joined(separator: "-")
    }

    private static func respellVowel(_ v: String, stressed: Bool, open: Bool) -> String {
        switch v {
        case "ae", "oe": return "ee"
        case "au": return "aw"
        case "eu": return "yoo"
        case "ei": return "ay"
        default: break
        }
        if v == "y" && open { return "y" }
        if !stressed {
            if v == "i" || v == "y" || v == "e" { return "ih" }
            return "uh"
        }
        switch v {
        case "a": return "a"
        case "e": return "e"
        case "i": return "i"
        case "y": return "y"
        case "o": return "o"
        case "u": return "u"
        default: return "uh"
        }
    }

    private static func respellCons(_ c: String, next: String) -> String {
        let soft = next.hasPrefix("e") || next.hasPrefix("i") || next.hasPrefix("y")
        switch c {
        case "ch": return "k"
        case "ph": return "f"
        case "th": return "th"
        case "rh": return "r"
        case "qu": return "kw"
        case "gu": return "gw"
        case "c": return soft ? "s" : "k"
        case "g": return soft ? "j" : "g"
        case "x": return "ks"
        default: return c
        }
    }

    // MARK: - 中文名

    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { isCJK($0.value) }
    }

    /// 从一段选中文字里抽出最长的连续汉字串（"螯蜂科（Dryinidae）" → "螯蜂科"）
    static func extractChineseName(_ raw: String) -> String? {
        let s = clean(raw)
        guard !s.isEmpty else { return nil }
        var best = ""
        var current = ""
        for u in s.unicodeScalars {
            if isCJK(u.value) {
                current.unicodeScalars.append(u)
            } else {
                if current.count > best.count { best = current }
                current = ""
            }
        }
        if current.count > best.count { best = current }
        guard !best.isEmpty else { return nil }

        // "螯蜂科的寄生蜂" → 截到最后一个分类阶元字尾
        let suffixes = ["总科", "亚科", "亚属", "亚种", "科", "属", "族", "种"]
        var cut = best.endIndex
        for suf in suffixes {
            if let r = best.range(of: suf, options: .backwards) {
                if r.upperBound > cut || cut == best.endIndex { cut = r.upperBound }
            }
        }
        if cut < best.endIndex { best = String(best[best.startIndex..<cut]) }
        return best
    }

    /// 中文名候选：先原样，再逐次去掉开头的字
    static func chineseCandidates(_ q: String) -> [String] {
        var out = [q]
        var shortened = q
        for _ in 0..<3 where shortened.count > 3 {
            shortened = String(shortened.dropFirst())
            out.append(shortened)
        }
        return out
    }

    private static func isCJK(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    // MARK: - 对外主入口

    static func pronounceWord(_ word: String) -> Pronunciation.Word {
        let syls = syllablesForName(word)
        let stress = stressIndex(syls, word: word)
        let us = syls.map { units($0) }
        return Pronunciation.Word(syllables: syls,
                                  stress: stress,
                                  ipa: ipa(us, stress: stress),
                                  respell: respelling(us, stress: stress))
    }

    static func pronounce(_ name: String) -> Pronunciation {
        let parts = name.split(separator: " ").map(String.init)
        let words = parts.map { pronounceWord($0) }
        return Pronunciation(word: name, words: words)
    }
}
