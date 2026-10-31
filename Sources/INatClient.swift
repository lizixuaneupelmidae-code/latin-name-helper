import Foundation

struct Taxon: Codable {
    let id: Int
    let name: String
    let rank: String
    let preferred_common_name: String?
}

struct TaxonResponse: Codable {
    let results: [Taxon]
}

struct Ancestor: Codable {
    let id: Int
    let name: String
    let rank: String
    let preferred_common_name: String?
}

private struct TaxonDetail: Codable {
    let id: Int
    let ancestors: [Ancestor]?
}

private struct TaxonDetailResponse: Codable {
    let results: [TaxonDetail]
}

struct CacheEntry: Codable {
    let taxon: Taxon?
    let queriedAs: String
    let time: Date
}

enum Direction {
    case latin
    case chinese
}

enum LookupResult {
    case found(Taxon, exact: Bool)
    case notFound
    case failed(String)
}

final class INatClient {

    static let shared = INatClient()

    private var memory: [String: CacheEntry] = [:]
    private var ancestry: [String: [Ancestor]] = [:]
    private var ancestryURL: URL?
    private var cacheURL: URL?
    // 查到中文名的结果可以放久一点；没有中文名/没收录的，很快过期
    // —— 你在 iNat 上补一个中文名，不该等一周才生效
    private func ttl(for entry: CacheEntry) -> TimeInterval {
        guard let taxon = entry.taxon else { return 30 * 60 }
        if (taxon.preferred_common_name ?? "").isEmpty { return 10 * 60 }
        return 30 * 24 * 3600
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.httpAdditionalHeaders = [
            "User-Agent": "LatinNameHelper/1.0 (personal taxonomic reading aid; macOS)"
        ]
        return URLSession(configuration: cfg)
    }()

    private init() {
        loadCache()
    }

    // MARK: - 路径

    private var supportDir: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("LatinNameHelper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadCache() {
        guard let dir = supportDir else { return }
        ancestryURL = dir.appendingPathComponent("ancestors.json")
        if let data = try? Data(contentsOf: dir.appendingPathComponent("ancestors.json")),
           let decoded = try? JSONDecoder().decode([String: [Ancestor]].self, from: data) {
            ancestry = decoded
        }
        let url = dir.appendingPathComponent("cache.json")
        cacheURL = url
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return }
        // 只保留「已经查到中文名」的缓存。
        // 没有中文名的条目正是最容易变的（你补一个名字就该立刻生效），下次启动一律重查。
        memory = decoded.filter { _, entry in
            !((entry.taxon?.preferred_common_name) ?? "").isEmpty
        }
        AppLog.write("cache loaded raw=\(decoded.count) kept=\(memory.count)")
    }

    func clearCache() {
        memory.removeAll()
        ancestry.removeAll()
        if let url = cacheURL { try? FileManager.default.removeItem(at: url) }
    }

    private func saveAncestry() {
        guard let url = ancestryURL,
              let data = try? JSONEncoder().encode(ancestry) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 取某个 taxon 的上级链（含中文名），带缓存
    func ancestors(of taxonID: Int, forceRefresh: Bool = false,
                   queue: DispatchQueue = .main,
                   completion: @escaping ([Ancestor]) -> Void) {
        let key = String(taxonID)
        if !forceRefresh, let hit = ancestry[key], !hit.isEmpty {
            completion(hit)
            return
        }
        guard let url = URL(string: "https://api.inaturalist.org/v1/taxa/\(taxonID)?locale=zh-CN") else {
            completion([])
            return
        }
        var request = URLRequest(url: url)
        request.setValue("LatinNameHelper/1.0", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, _, _ in
            var chain: [Ancestor] = []
            if let data = data,
               let resp = try? JSONDecoder().decode(TaxonDetailResponse.self, from: data),
               let first = resp.results.first {
                chain = first.ancestors ?? []
            }
            if !chain.isEmpty {
                self.ancestry[key] = chain
                self.saveAncestry()
            }
            queue.async { completion(chain) }
        }.resume()
    }

    private func saveCache() {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(memory) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 查询

    func lookup(_ query: String, direction: Direction = .latin, forceRefresh: Bool = false,
                queue: DispatchQueue = .main,
                completion: @escaping (LookupResult) -> Void) {
        let key = (direction == .chinese ? "zh:" : "la:") + query.lowercased()
        let skipCache = ProcessInfo.processInfo.environment["LATIN_NO_CACHE"] != nil
        let age = memory[key].map { Date().timeIntervalSince($0.time) } ?? -1
        let limit = memory[key].map { ttl(for: $0) } ?? -1
        AppLog.write("lookup key=\(key) force=\(forceRefresh) cached=\(memory[key] != nil) age=\(Int(age))s ttl=\(Int(limit))s")
        if !forceRefresh, !skipCache, let hit = memory[key],
           Date().timeIntervalSince(hit.time) < ttl(for: hit) {
            AppLog.write("  -> cache HIT common=\((hit.taxon?.preferred_common_name) ?? "nil")")
            if let t = hit.taxon {
                let exact: Bool
                if direction == .chinese {
                    exact = (t.preferred_common_name ?? "").caseInsensitiveCompare(query) == .orderedSame
                } else {
                    exact = t.name.caseInsensitiveCompare(query) == .orderedSame
                }
                completion(.found(t, exact: exact))
            } else {
                completion(.notFound)
            }
            return
        }
        fetch(query, direction: direction, queue: queue) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .found(let taxon, _):
                AppLog.write("  -> FETCH found \(taxon.name) common=\(taxon.preferred_common_name ?? "nil")")
                self.memory[key] = CacheEntry(taxon: taxon, queriedAs: query, time: Date())
            case .notFound:
                AppLog.write("  -> FETCH notFound")
                self.memory[key] = CacheEntry(taxon: nil, queriedAs: query, time: Date())
            case .failed(let m):
                AppLog.write("  -> FETCH failed \(m)")
                break
            }
            self.saveCache()
            completion(result)
        }
    }

    private func fetch(_ query: String, direction: Direction, queue: DispatchQueue,
                       completion: @escaping (LookupResult) -> Void) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.inaturalist.org/v1/taxa/autocomplete?q=\(encoded)&locale=zh-CN&per_page=10")
        else {
            completion(.failed("查询词无法编码"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("LatinNameHelper/1.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, _, error in
            queue.async {
                if let error = error {
                    completion(.failed(error.localizedDescription))
                    return
                }
                if ProcessInfo.processInfo.environment["LATIN_DEBUG"] != nil, let d = data {
                    FileHandle.standardError.write(d)
                    FileHandle.standardError.write("\n".data(using: .utf8)!)
                }
                guard let data = data,
                      let resp = try? JSONDecoder().decode(TaxonResponse.self, from: data) else {
                    completion(.failed("返回数据无法解析"))
                    return
                }
                if direction == .chinese {
                    // 中文反查：先找中文名完全一致的
                    if let exact = resp.results.first(where: {
                        ($0.preferred_common_name ?? "").caseInsensitiveCompare(query) == .orderedSame
                    }) {
                        completion(.found(exact, exact: true))
                        return
                    }
                    // 中文名常有「XX属」「XX科」的写法差异，取第一条最接近的
                    if let first = resp.results.first {
                        completion(.found(first, exact: false))
                        return
                    }
                    completion(.notFound)
                    return
                }

                // 1) 完全同名
                if let exact = resp.results.first(where: {
                    $0.name.caseInsensitiveCompare(query) == .orderedSame
                }) {
                    completion(.found(exact, exact: true))
                    return
                }
                // 2) 种加词没收录时，退化到属
                let parts = query.components(separatedBy: " ")
                if parts.count == 2,
                   let genus = resp.results.first(where: {
                       $0.name.caseInsensitiveCompare(parts[0]) == .orderedSame
                   }) {
                    completion(.found(genus, exact: false))
                    return
                }
                // 3) 首字母大写差别的兜底
                if let loose = resp.results.first(where: {
                    $0.name.lowercased() == query.lowercased()
                }) {
                    completion(.found(loose, exact: true))
                    return
                }
                completion(.notFound)
            }
        }.resume()
    }
}
