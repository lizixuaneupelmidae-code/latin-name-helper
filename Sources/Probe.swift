import Foundation

enum Probe {
    static func run(_ args: [String]) {
        setvbuf(stdout, nil, _IONBF, 0)
        let raw = args.joined(separator: " ")

        // 中文名 → 拉丁名
        if LatinEngine.containsCJK(raw) {
            guard let chinese = LatinEngine.extractChineseName(raw) else {
                print("✗ 未识别出中文名：\(raw)")
                return
            }
            print("查询      \(chinese)  （中文 → 拉丁）")
            for candidate in LatinEngine.chineseCandidates(chinese) {
                let sem = DispatchSemaphore(value: 0)
                var lines: [String] = []
                var hit = false
                INatClient.shared.lookup(candidate, direction: .chinese,
                                         queue: DispatchQueue.global()) { result in
                    switch result {
                    case .found(let t, let exact):
                        hit = true
                        let p = LatinEngine.pronounce(t.name)
                        lines.append("学名      \(t.name)  [\(t.rank)]  #\(t.id)" + (exact ? "" : "  (近似)"))
                        lines.append("中文名    \(t.preferred_common_name ?? "暂无中文名")")
                        lines.append("音节重音  \(p.display)")
                        lines.append("IPA       \(p.ipa)")
                        lines.append("合成转写  \(p.respell)")
                        if candidate != chinese { lines.append("实际查询  \(candidate)") }
                    case .notFound:
                        break
                    case .failed(let msg):
                        lines.append("iNat      查询失败：\(msg)")
                    }
                    sem.signal()
                }
                if sem.wait(timeout: .now() + 15) == .timedOut {
                    print("iNat      超时")
                    return
                }
                if hit || !lines.isEmpty {
                    for l in lines { print(l) }
                    return
                }
            }
            print("iNat      未收录这个中文名")
            return
        }

        // 拉丁名 → 中文名
        guard let name = LatinEngine.extractName(raw) else {
            print("✗ 未识别出学名：\(raw)")
            return
        }
        let p = LatinEngine.pronounce(name)
        print("学名      \(name)")
        print("音节重音  \(p.display)")
        for scheme in LatinEngine.Scheme.allCases {
            let q = LatinEngine.pronounce(name, scheme: scheme)
            print("IPA(\(scheme.title)) \(q.ipa)")
            print("  转写    \(q.respell)")
        }

        let sem = DispatchSemaphore(value: 0)
        var lines: [String] = []
        INatClient.shared.lookup(name, direction: .latin,
                                 queue: DispatchQueue.global()) { result in
            switch result {
            case .found(let t, let exact):
                lines.append("iNat      \(t.name)  [\(t.rank)]  #\(t.id)" + (exact ? "" : "  (近似/属级)"))
                lines.append("中文名    \(t.preferred_common_name ?? "暂无中文名")")
            case .notFound:
                lines.append("iNat      未收录")
            case .failed(let msg):
                lines.append("iNat      查询失败：\(msg)")
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 15) == .timedOut {
            print("iNat      超时")
            return
        }
        for l in lines { print(l) }
    }
}
