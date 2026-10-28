import Foundation

/// GBIF 只用来回答一个问题：iNat 查不到的名字，是不是一个真实有效的学名。
enum GBIFResult {
    case accepted(String, String)      // 接受名, 阶元
    case synonym(String, String)       // 接受名, 你查的名字
    case higherRank(String)            // 只匹配到更高阶元（如只到属）
    case none
    case failed(String)
}

private struct GBIFRaw: Codable {
    let matchType: String?
    let confidence: Int?
    let status: String?
    let rank: String?
    let canonicalName: String?
    let scientificName: String?
    let acceptedUsageKey: Int?
}

private struct GBIFName: Codable {
    let canonicalName: String?
    let scientificName: String?
    let rank: String?
    let taxonomicStatus: String?
}

private struct GBIFCacheEntry: Codable {
    let result: GBIFResult
    let time: Date
}

/// GBIFResult 需要可编码
extension GBIFResult: Codable {
    private enum CodingKeys: String, CodingKey { case kind, a, b }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let a = try c.decodeIfPresent(String.self, forKey: .a)
        let b = try c.decodeIfPresent(String.self, forKey: .b)
        switch kind {
        case "accepted": self = .accepted(a ?? "", b ?? "")
        case "synonym": self = .synonym(a ?? "", b ?? "")
        case "higherRank": self = .higherRank(a ?? "")
        case "failed": self = .failed(a ?? "")
        default: self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted(let a, let b):
            try c.encode("accepted", forKey: .kind); try c.encode(a, forKey: .a); try c.encode(b, forKey: .b)
        case .synonym(let a, let b):
            try c.encode("synonym", forKey: .kind); try c.encode(a, forKey: .a); try c.encode(b, forKey: .b)
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
           let decoded = try? JSONDecoder().decode([String: GBIFCacheEntry].self, from: data) {
            memory = decoded
        }
    }

    private func save() {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(memory) else { return }
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

            switch matchType {
            case "EXACT", "FUZZY":
                if (raw.status ?? "") == "SYNONYM", let key = raw.acceptedUsageKey {
                    self.fetchAcceptedName(key) { accepted in
                        completion(.synonym(accepted ?? "（未知）", canonical))
                    }
                    return
                }
                completion(.accepted(canonical, rank))
            case "HIGHERRANK":
                completion(.higherRank(canonical))
            default:
                completion(.none)
            }
        }.resume()
    }

    private func fetchAcceptedName(_ key: Int, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://api.gbif.org/v1/species/\(key)") else {
            completion(nil)
            return
        }
        session.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let parsed = try? JSONDecoder().decode(GBIFName.self, from: data) else {
                completion(nil)
                return
            }
            completion(parsed.canonicalName ?? parsed.scientificName)
        }.resume()
    }
}
