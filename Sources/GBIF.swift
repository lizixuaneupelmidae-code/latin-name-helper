import Foundation

/// GBIF 的两项用途：确认名字是否有效，以及拿回它的上级分类（目 / 科 / 属）。
struct GBIFLineage: Codable, Equatable {
    var order: String?
    var family: String?
    var genus: String?
}

enum GBIFResult {
    case accepted(String, String, String, GBIFLineage)   // 接受名, 阶元, 状态, 上级
    case synonym(String, String, GBIFLineage)    // 接受名, 你查的名字, 上级
    case higherRank(String)
    case none
    case failed(String)

    var lineage: GBIFLineage {
        switch self {
        case .accepted(_, _, _, let l), .synonym(_, _, let l): return l
        default: return GBIFLineage()
        }
    }
}

private struct GBIFRaw: Codable {
    let matchType: String?
    let confidence: Int?
    let status: String?
    let rank: String?
    let canonicalName: String?
    let scientificName: String?
    let acceptedUsageKey: Int?
    let order: String?
    let family: String?
    let genus: String?
}

private struct GBIFName: Codable {
    let canonicalName: String?
    let scientificName: String?
    let rank: String?
    let order: String?
    let family: String?
    let genus: String?
}

private struct GBIFCacheEntry: Codable {
    let result: GBIFResult
    let time: Date
}

/// 带版本号的缓存文件：结构一变（比如新增 lineage）就整体作废，避免读到旧格式
private struct GBIFCacheFile: Codable {
    let version: Int
    let entries: [String: GBIFCacheEntry]
    static let current = 3
}

extension GBIFResult: Codable {
    private enum CodingKeys: String, CodingKey { case kind, a, b, order, family, genus, status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let a = try c.decodeIfPresent(String.self, forKey: .a)
        let b = try c.decodeIfPresent(String.self, forKey: .b)
        var l = GBIFLineage()
        l.order = try c.decodeIfPresent(String.self, forKey: .order)
        l.family = try c.decodeIfPresent(String.self, forKey: .family)
        l.genus = try c.decodeIfPresent(String.self, forKey: .genus)

        switch kind {
        case "accepted": self = .accepted(a ?? "", b ?? "", try c.decodeIfPresent(String.self, forKey: .status) ?? "", l)
        case "synonym": self = .synonym(a ?? "", b ?? "", l)
        case "higherRank": self = .higherRank(a ?? "")
        case "failed": self = .failed(a ?? "")
        default: self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted(let a, let b, let st, let l):
            try c.encode("accepted", forKey: .kind)
            try c.encode(a, forKey: .a); try c.encode(b, forKey: .b)
            try c.encode(st, forKey: .status)
            try c.encodeIfPresent(l.order, forKey: .order)
            try c.encodeIfPresent(l.family, forKey: .family)
            try c.encodeIfPresent(l.genus, forKey: .genus)
        case .synonym(let a, let b, let l):
            try c.encode("synonym", forKey: .kind)
            try c.encode(a, forKey: .a); try c.encode(b, forKey: .b)
            try c.encodeIfPresent(l.order, forKey: .order)
            try c.encodeIfPresent(l.family, forKey: .family)
            try c.encodeIfPresent(l.genus, forKey: .genus)
        case .higherRank(let a):
            try c.encode("higherRank", forKey: .kind); try c.encode(a, forKey: .a)
        case .failed(let a):
            try c.encode("failed", forKey: .kind); try c.encode(a, forKey: .a)
        case .none:
            try c.encode("none", forKey: .kind)
        }
    }
}

final class GBIFClient {

    static let shared = GBIFClient()

    private var memory: [String: GBIFCacheEntry] = [:]
    private var cacheURL: URL?
    private let ttl: TimeInterval = 30 * 24 * 3600

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.httpAdditionalHeaders = ["User-Agent": "LatinNameHelper/1.0 (personal taxonomic reading aid)"]
        return URLSession(configuration: cfg)
    }()

    private init() {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return }
        let dir = base.appendingPathComponent("LatinNameHelper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("gbif.json")
        cacheURL = url
        if let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(GBIFCacheFile.self, from: data),
           file.version == GBIFCacheFile.current {
            memory = file.entries
        }
    }

    private func save() {
        guard let url = cacheURL,
              let data = try? JSONEncoder().encode(GBIFCacheFile(version: GBIFCacheFile.current,
                                                                 entries: memory)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func match(_ name: String, forceRefresh: Bool = false,
               queue: DispatchQueue = .main,
               completion: @escaping (GBIFResult) -> Void) {
        let key = name.lowercased()
        if !forceRefresh, let hit = memory[key], Date().timeIntervalSince(hit.time) < ttl {
            completion(hit.result)
            return
        }
        fetch(name) { [weak self] result in
            guard let self = self else { return }
            self.memory[key] = GBIFCacheEntry(result: result, time: Date())
            self.save()
            queue.async { completion(result) }
        }
    }

    private func fetch(_ name: String, completion: @escaping (GBIFResult) -> Void) {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.gbif.org/v1/species/match?name=\(encoded)&kingdom=Animalia")
        else {
            completion(.failed("名称无法编码"))
            return
        }
        session.dataTask(with: url) { data, _, error in
            if let error = error {
                completion(.failed(error.localizedDescription))
                return
            }
            guard let data = data,
                  let raw = try? JSONDecoder().decode(GBIFRaw.self, from: data) else {
                completion(.failed("返回数据无法解析"))
                return
            }
            let matchType = raw.matchType ?? "NONE"
            let canonical = raw.canonicalName ?? raw.scientificName ?? name
            let rank = (raw.rank ?? "").capitalized
            var lineage = GBIFLineage(order: raw.order, family: raw.family, genus: raw.genus)

            switch matchType {
            case "EXACT", "FUZZY":
                if (raw.status ?? "") == "SYNONYM", let key = raw.acceptedUsageKey {
                    self.fetchAccepted(key) { accepted, acceptedLineage in
                        if let l = acceptedLineage, !l.isEmpty { lineage = l }
                        completion(.synonym(accepted ?? "（未知）", canonical, lineage))
                    }
                    return
                }
                completion(.accepted(canonical, rank, raw.status ?? "", lineage))
            case "HIGHERRANK":
                completion(.higherRank(canonical))
            default:
                completion(.none)
            }
        }.resume()
    }

    private func fetchAccepted(_ key: Int, completion: @escaping (String?, GBIFLineage?) -> Void) {
        guard let url = URL(string: "https://api.gbif.org/v1/species/\(key)") else {
            completion(nil, nil)
            return
        }
        session.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let parsed = try? JSONDecoder().decode(GBIFName.self, from: data) else {
                completion(nil, nil)
                return
            }
            let lineage = GBIFLineage(order: parsed.order, family: parsed.family, genus: parsed.genus)
            completion(parsed.canonicalName ?? parsed.scientificName, lineage)
        }.resume()
    }
}

extension GBIFLineage {
    var isEmpty: Bool { order == nil && family == nil && genus == nil }
}
