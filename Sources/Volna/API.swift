import Foundation
import CryptoKit

func anyStr(_ v: Any?) -> String? {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

struct Track: Equatable, Codable {
    let id: String
    let albumId: String?
    let title: String
    let artists: String
    let coverUri: String?
    let durationMs: Int
    /// громкость трека по EBU R128 (интегральная, LUFS) и истинный пик (dBTP) — для выравнивания
    var lufs: Double? = nil
    var peak: Double? = nil

    var key: String { albumId.map { "\(id):\($0)" } ?? id }

    func coverURL(_ size: Int = 200) -> URL? {
        guard let c = coverUri else { return nil }
        return URL(string: "https://" + c.replacingOccurrences(of: "%%", with: "\(size)x\(size)"))
    }

    static func parse(_ any: Any?) -> Track? {
        guard let d = any as? [String: Any], let id = anyStr(d["id"]) else { return nil }
        if let avail = d["available"] as? Bool, !avail { return nil }
        let album = (d["albums"] as? [[String: Any]])?.first
        let artists = (d["artists"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String }
            .joined(separator: ", ") ?? ""
        let r128 = d["r128"] as? [String: Any]
        return Track(
            id: id,
            albumId: anyStr(album?["id"]),
            title: d["title"] as? String ?? "—",
            artists: artists,
            coverUri: (d["coverUri"] as? String) ?? (album?["coverUri"] as? String),
            durationMs: (d["durationMs"] as? NSNumber)?.intValue ?? 0,
            lufs: (r128?["i"] as? NSNumber)?.doubleValue,
            peak: (r128?["tp"] as? NSNumber)?.doubleValue
        )
    }
}

enum APIError: LocalizedError {
    case http(Int, String)
    case bad(String)

    var errorDescription: String? {
        switch self {
        case .http(let c, let b): return "HTTP \(c): \(b.prefix(160))"
        case .bad(let s): return s
        }
    }

    var isAuth: Bool {
        if case .http(let c, _) = self { return c == 401 || c == 403 }
        return false
    }
}

final class YaAPI {
    let token: String
    private let session: URLSession
    private let base = "https://api.music.yandex.net"

    init(token: String) {
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
    }

    private func authorize(_ req: inout URLRequest) {
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("ru", forHTTPHeaderField: "Accept-Language")
    }

    @discardableResult
    func call(_ method: String, _ path: String,
              query: [String: String] = [:],
              json: Any? = nil,
              form: [String: String]? = nil,
              headers: [String: String] = [:]) async throws -> Any {
        var comps = URLComponents(string: base + path)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        authorize(&req)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let json = json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let form = form {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            req.httpBody = form.map { k, v in
                "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
            }.joined(separator: "&").data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let body = String(decoding: data, as: UTF8.self)
            ylog("HTTP \(code) \(method) \(path): \(body.prefix(300))")
            throw APIError.http(code, body)
        }
        if data.isEmpty { return [String: Any]() }
        let obj = try JSONSerialization.jsonObject(with: data)
        return (obj as? [String: Any])?["result"] ?? obj
    }

    func data(_ url: URL) async throws -> Data {
        try await session.data(from: url).0
    }

    // MARK: аккаунт и лайки

    func uid() async throws -> Int {
        let r = try await call("GET", "/account/status")
        guard let acc = (r as? [String: Any])?["account"] as? [String: Any],
              let uid = (acc["uid"] as? NSNumber)?.intValue else {
            throw APIError.http(401, "нет uid — токен не подходит")
        }
        return uid
    }

    func likedKeys(uid: Int) async throws -> Set<String> {
        let r = try await call("GET", "/users/\(uid)/likes/tracks")
        let lib = (r as? [String: Any])?["library"] as? [String: Any]
        let tracks = lib?["tracks"] as? [[String: Any]] ?? []
        var s = Set<String>()
        for t in tracks {
            guard let id = anyStr(t["id"]) else { continue }
            s.insert(id)
        }
        return s
    }

    func setLike(uid: Int, track: Track, on: Bool) async throws {
        let path = on ? "/users/\(uid)/likes/tracks/add-multiple" : "/users/\(uid)/likes/tracks/remove"
        try await call("POST", path, form: ["track-ids": track.key])
    }

    func dislike(uid: Int, track: Track) async throws {
        try await call("POST", "/users/\(uid)/dislikes/tracks/add-multiple", form: ["track-ids": track.key])
    }

    // MARK: библиотека

    struct Playlist {
        let kind: Int
        let title: String
        let count: Int
    }

    /// «Мне нравится» в порядке добавления (новые сверху), полные данные треков — до limit штук.
    func likedTracks(uid: Int, limit: Int = 500) async throws -> [Track] {
        let r = try await call("GET", "/users/\(uid)/likes/tracks")
        let lib = (r as? [String: Any])?["library"] as? [String: Any]
        let items = (lib?["tracks"] as? [[String: Any]] ?? []).prefix(limit)
        let keys: [String] = items.compactMap { t in
            guard let id = anyStr(t["id"]) else { return nil }
            return anyStr(t["albumId"]).map { "\(id):\($0)" } ?? id
        }
        return try await tracks(keys)
    }

    /// Полные треки по ключам id:albumId, порциями по 100, порядок сохраняется.
    func tracks(_ keys: [String]) async throws -> [Track] {
        var out: [Track] = []
        var i = 0
        while i < keys.count {
            let part = Array(keys[i..<min(i + 100, keys.count)])
            let r = try await call("POST", "/tracks", form: ["track-ids": part.joined(separator: ",")])
            out += (r as? [Any] ?? []).compactMap { Track.parse($0) }
            i += 100
        }
        return out
    }

    func playlists(uid: Int) async throws -> [Playlist] {
        let r = try await call("GET", "/users/\(uid)/playlists/list")
        return (r as? [[String: Any]] ?? []).compactMap { d in
            guard let kind = (d["kind"] as? NSNumber)?.intValue else { return nil }
            return Playlist(kind: kind, title: d["title"] as? String ?? "Плейлист",
                            count: (d["trackCount"] as? NSNumber)?.intValue ?? 0)
        }
    }

    func playlistTracks(uid: Int, kind: Int) async throws -> [Track] {
        let r = try await call("GET", "/users/\(uid)/playlists/\(kind)", query: ["rich-tracks": "true"])
        let items = (r as? [String: Any])?["tracks"] as? [[String: Any]] ?? []
        return items.compactMap { Track.parse($0["track"]) }
    }

    struct Artist: Equatable {
        let id: String
        let name: String
        let coverUri: String?

        func coverURL(_ size: Int = 100) -> URL? {
            guard let c = coverUri else { return nil }
            return URL(string: "https://" + c.replacingOccurrences(of: "%%", with: "\(size)x\(size)"))
        }

        static func parse(_ any: Any?) -> Artist? {
            guard let d = any as? [String: Any], let id = anyStr(d["id"]), let name = d["name"] as? String else { return nil }
            let cover = (d["cover"] as? [String: Any])?["uri"] as? String
            return Artist(id: id, name: name, coverUri: cover ?? (d["ogImage"] as? String))
        }
    }

    /// Поиск сразу по трекам и исполнителям; bestArtist — Яндекс считает лучшим совпадением исполнителя.
    func search(_ text: String) async throws -> (tracks: [Track], artists: [Artist], bestArtist: Bool) {
        let r = try await call("GET", "/search", query: ["text": text, "type": "all", "page": "0", "nocorrect": "false"])
        let d = r as? [String: Any]
        let tr = (d?["tracks"] as? [String: Any])?["results"] as? [Any] ?? []
        let ar = (d?["artists"] as? [String: Any])?["results"] as? [Any] ?? []
        let bestD = d?["best"] as? [String: Any]
        let best = bestD?["type"] as? String
        var artists = ar.compactMap { Artist.parse($0) }
        // лучший результат — исполнитель: он первым, даже если в списке исполнителей его нет
        if best == "artist", let a = Artist.parse(bestD?["result"]) {
            artists.removeAll { $0.id == a.id }
            artists.insert(a, at: 0)
        }
        ylog("search «\(text)»: треков \(tr.count), исполнителей \(artists.count), best=\(best ?? "-") \(artists.prefix(3).map(\.name))")
        return (tr.compactMap { Track.parse($0) }, artists, best == "artist")
    }

    /// Популярные треки исполнителя.
    func artistTracks(_ id: String) async throws -> [Track] {
        let r = try await call("GET", "/artists/\(id)/tracks", query: ["page": "0", "page-size": "50"])
        let items = (r as? [String: Any])?["tracks"] as? [Any] ?? []
        return items.compactMap { Track.parse($0) }
    }

    // MARK: поток

    func streamURL(_ t: Track) async throws -> URL {
        let r = try await call("GET", "/tracks/\(t.id)/download-info")
        guard let infos = r as? [[String: Any]], !infos.isEmpty else {
            throw APIError.bad("нет download-info")
        }
        func br(_ d: [String: Any]) -> Int { (d["bitrateInKbps"] as? NSNumber)?.intValue ?? 0 }
        // кандидаты: сначала mp3 по убыванию битрейта, потом остальные
        let mp3 = infos.filter { ($0["codec"] as? String) == "mp3" }.sorted { br($0) > br($1) }
        let rest = infos.filter { ($0["codec"] as? String) != "mp3" }.sorted { br($0) > br($1) }
        var lastError: Error = APIError.bad("кривой ответ download-info")
        for info in mp3 + rest {
            guard let s = info["downloadInfoUrl"] as? String, let u = URL(string: s) else { continue }
            // direct=true — по ссылке сразу аудио, а не XML
            if (info["direct"] as? Bool) == true { return u }
            // по одной попытке на вариант: при 500 «no more reliable hosts» повторы не помогают, быстрее перейти дальше
            do {
                return try await resolveDownloadInfo(u)
            } catch {
                lastError = error
                ylog("download-info \(t.id) \(info["codec"] ?? "?")/\(br(info)): \(error)")
            }
        }
        throw lastError
    }

    private func resolveDownloadInfo(_ u: URL) async throws -> URL {
        var req = URLRequest(url: u)
        authorize(&req)
        let (xmlData, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let xml = String(decoding: xmlData, as: UTF8.self)

        func tag(_ n: String) -> String? {
            guard let a = xml.range(of: "<\(n)>"),
                  let b = xml.range(of: "</\(n)>", range: a.upperBound..<xml.endIndex) else { return nil }
            return String(xml[a.upperBound..<b.lowerBound])
        }
        guard let host = tag("host"), let path = tag("path"), let ts = tag("ts"), let sv = tag("s") else {
            throw APIError.bad("кривой ответ download-info (HTTP \(code)): \(xml.prefix(120))")
        }
        let raw = "XGRlBW9FXlekgbPrRHuSiA" + String(path.dropFirst()) + sv
        let sign = Insecure.MD5.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: "https://\(host)/get-mp3/\(sign)/\(ts)\(path)") else {
            throw APIError.bad("не собрался URL")
        }
        return url
    }
}

// MARK: Моя волна

final class Wave {
    private let api: YaAPI
    private var sessionId: String?
    private var batchId: String?
    private var legacy = false
    private let station = "user:onyourwave"

    init(api: YaAPI) { self.api = api }

    private func seq(_ r: Any) -> [Track] {
        let d = r as? [String: Any]
        if let b = anyStr(d?["batchId"]) { batchId = b }
        if let s = anyStr(d?["radioSessionId"]) { sessionId = s }
        let items = d?["sequence"] as? [[String: Any]] ?? []
        return items.compactMap { Track.parse($0["track"]) }
    }

    func start() async throws -> [Track] {
        do {
            let r = try await api.call("POST", "/rotor/session/new",
                                       json: ["seeds": [station], "includeTracksInResponse": true])
            let t = seq(r)
            ylog("wave: session \(sessionId ?? "nil"), tracks \(t.count)")
            if sessionId != nil, !t.isEmpty { return t }
        } catch let e as APIError where e.isAuth {
            throw e
        } catch {
            ylog("wave: session/new failed: \(error)")
        }
        // запасной путь — старое API станций
        legacy = true
        let r = try await api.call("GET", "/rotor/station/\(station)/tracks", query: ["settings2": "true"])
        let t = seq(r)
        ylog("wave: legacy station, tracks \(t.count)")
        feedback("radioStarted", track: nil, played: 0)
        return t
    }

    /// Сохраняет настройки волны в аккаунте и перезапускает сессию.
    func apply(mood: String, diversity: String, language: String) async throws -> [Track] {
        try await api.call("POST", "/rotor/station/\(station)/settings3",
                           json: ["moodEnergy": mood, "diversity": diversity, "language": language, "type": "rotor"])
        sessionId = nil
        batchId = nil
        legacy = false
        return try await start()
    }

    func more(played: [Track]) async throws -> [Track] {
        if !legacy, let sid = sessionId {
            let r = try await api.call("POST", "/rotor/session/\(sid)/tracks",
                                       json: ["queue": played.suffix(10).map(\.key)])
            return seq(r)
        }
        var q = ["settings2": "true"]
        if let last = played.last { q["queue"] = last.id }
        let r = try await api.call("GET", "/rotor/station/\(station)/tracks", query: q)
        return seq(r)
    }

    /// trackStarted / trackFinished / skip / radioStarted — best effort, ошибки игнорируются
    func feedback(_ type: String, track: Track?, played: Double) {
        let api = self.api
        if !legacy, let sid = sessionId {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var ev: [String: Any] = ["type": type, "timestamp": iso.string(from: Date())]
            if let t = track { ev["trackId"] = t.key }
            if type != "trackStarted" { ev["totalPlayedSeconds"] = played }
            var body: [String: Any] = ["event": ev]
            if let b = batchId { body["batchId"] = b }
            Task.detached { try? await api.call("POST", "/rotor/session/\(sid)/feedback", json: body) }
        } else {
            var ev: [String: Any] = ["type": type, "timestamp": Date().timeIntervalSince1970]
            if let t = track { ev["trackId"] = t.key }
            if type == "radioStarted" { ev["from"] = "Volna" }
            if type == "skip" || type == "trackFinished" { ev["totalPlayedSeconds"] = played }
            var q: [String: String] = [:]
            if let b = batchId { q["batch-id"] = b }
            let path = "/rotor/station/\(station)/feedback"
            Task.detached { try? await api.call("POST", path, query: q, json: ev) }
        }
    }
}
