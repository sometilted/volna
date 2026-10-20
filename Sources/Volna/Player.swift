import AppKit
import AVFoundation
import MediaPlayer
import SwiftUI

@MainActor
final class Player: ObservableObject {
    @Published private(set) var loggedIn = false
    @Published private(set) var current: Track?
    @Published private(set) var cover: NSImage?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var liked = false
    @Published private(set) var status: String?
    /// цвет обложки для стиля Taste
    @Published private(set) var tint: Color?
    /// откуда пришёл трек: +1 вперёд (next / доиграл), -1 назад — для направленной анимации смены
    @Published private(set) var direction = 1

    private var api: YaAPI?
    private var wave: Wave?
    private var uid: Int?
    private var likes = Set<String>()
    private var queue: [Track] = []
    private var history: [Track] = []
    private var refilling = false
    private var gen = 0

    private let avp = AVPlayer()
    private var endObs: NSObjectProtocol?
    private var timeObs: Any?
    private var stateObs: NSKeyValueObservation?
    private var itemObs: NSKeyValueObservation?
    private var pendingSeek: Double = 0
    private var streamFailures = 0
    private var lastSave = Date.distantPast

    /// реальные уровни звука для эквалайзера в нотче
    let meter = LevelMeter()

    // MARK: последний трек и позиция (переживает перезапуск)

    private struct Saved: Codable {
        let track: Track
        let position: Double
    }

    private static let savedKey = "lastTrack"

    func saveState() {
        guard let t = current else { return }
        let s = Saved(track: t, position: position)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: Self.savedKey) }
        lastSave = Date()
    }

    static func clearSaved() {
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    private static func loadSaved() -> Saved? {
        guard let d = UserDefaults.standard.data(forKey: savedKey) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: d)
    }

    init() {
        avp.automaticallyWaitsToMinimizeStalling = true
        timeObs = avp.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                let s = t.seconds
                if s.isFinite, self.avp.currentItem != nil { self.position = s }
                if let d = self.avp.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                if self.isPlaying, Date().timeIntervalSince(self.lastSave) >= 1 { self.saveState() }
            }
        }
        stateObs = avp.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in
                guard let self = self, self.isPlaying != playing else { return }
                self.isPlaying = playing
                if !playing { self.saveState(); self.meter.reset() }
                self.updateNowPlaying()
            }
        }
        setupRemote()
    }

    // MARK: сессия

    func start(token: String, autoplay: Bool) {
        stop()
        let api = YaAPI(token: token)
        let wave = Wave(api: api)
        self.api = api
        self.wave = wave
        // токен есть — считаем, что вошли; разлогиниваем только на 401/403
        loggedIn = true
        status = "Загрузка…"
        let g = gen
        let p = Prefs.shared
        Task {
            var delay: UInt64 = 3
            while g == gen {
                do {
                    let uid: Int
                    do { uid = try await api.uid() } catch let e as APIError where e.isAuth {
                        // только отказ в /account/status означает мёртвый токен
                        logout(e); return
                    }
                    guard g == gen else { return }
                    ylog("start: uid \(uid)")
                    self.uid = uid
                    if let l = try? await api.likedKeys(uid: uid) { likes = l }
                    let first: [Track]
                    if p.waveIsDefault {
                        first = try await wave.start()
                    } else {
                        first = try await wave.apply(mood: p.mood, diversity: p.diversity, language: p.language)
                    }
                    guard g == gen else { return }
                    queue = first
                    status = nil
                    if let saved = Self.loadSaved() {
                        ylog("resume \(saved.track.key) @ \(Int(saved.position)) c")
                        queue.removeAll { $0.id == saved.track.id }
                        load(saved.track, autoplay: autoplay, startAt: saved.position)
                        if queue.count < 2 { refill(thenPlay: nil) }
                    } else {
                        advance(autoplay: autoplay)
                    }
                    return
                } catch {
                    guard g == gen else { return }
                    ylog("start: \(error)")
                    status = "\(error.localizedDescription.prefix(60)) — повтор через \(delay) с"
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    delay = min(delay * 2, 60)
                }
            }
        }
    }

    func stop() {
        gen += 1
        avp.pause()
        avp.replaceCurrentItem(with: nil)
        api = nil; wave = nil; uid = nil
        likes = []; queue = []; history = []
        current = nil; cover = nil; tint = nil
        position = 0; duration = 0; liked = false
        loggedIn = false; status = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func logout(_ error: Error) {
        ylog("auth: \(error)")
        Self.clearSaved()
        stop()
        status = "Токен не подошёл — войди заново"
    }

    private func fail(_ error: Error) {
        ylog("error: \(error)")
        status = error.localizedDescription
    }

    /// Применить настройки волны из Prefs: текущий трек доигрывает, очередь пересобирается.
    func applyWaveSettings() {
        guard let wave = wave else { return }
        let p = Prefs.shared
        let g = gen
        status = "Перенастраиваю волну…"
        Task {
            do {
                let fresh = try await wave.apply(mood: p.mood, diversity: p.diversity, language: p.language)
                status = nil
                guard !fresh.isEmpty else { return }
                queue = fresh
                if current == nil, g == gen { advance(autoplay: true) }
            } catch {
                fail(error)
            }
        }
    }

    // MARK: управление

    func toggle() {
        guard let c = current else { return }
        if avp.currentItem == nil { load(c, autoplay: true); return }
        if isPlaying { avp.pause() } else { avp.play() }
    }

    func play() { if !isPlaying { toggle() } }
    func pause() { avp.pause() }

    func next() {
        guard let c = current else { return }
        wave?.feedback("skip", track: c, played: position)
        pushHistory(c)
        direction = 1
        advance(autoplay: true)
    }

    func prev() {
        if position > 3 { seek(to: 0); return }
        guard let p = history.popLast() else { seek(to: 0); return }
        if let c = current { queue.insert(c, at: 0) }
        direction = -1
        load(p, autoplay: true)
    }

    func toggleLike() {
        guard let api = api, let uid = uid, let c = current else { return }
        let on = !liked
        liked = on
        if on { likes.insert(c.id) } else { likes.remove(c.id) }
        Task {
            do { try await api.setLike(uid: uid, track: c, on: on) }
            catch {
                if current == c { liked = !on }
                if on { likes.remove(c.id) } else { likes.insert(c.id) }
                status = "Лайк не прошёл"
            }
        }
    }

    func dislike() {
        guard let api = api, let uid = uid, let c = current else { return }
        Task { try? await api.dislike(uid: uid, track: c) }
        if liked { likes.remove(c.id) }
        next()
    }

    func seek(to seconds: Double) {
        let t = max(0, seconds)
        avp.seek(to: CMTime(seconds: t, preferredTimescale: 1000))
        position = t
        updateNowPlaying()
    }

    func seek(fraction: Double) {
        guard duration > 0 else { return }
        seek(to: duration * min(max(fraction, 0), 1))
    }

    // MARK: очередь

    private func pushHistory(_ t: Track) {
        history.append(t)
        if history.count > 50 { history.removeFirst(history.count - 50) }
    }

    private func advance(autoplay: Bool) {
        guard !queue.isEmpty else { refill(thenPlay: autoplay); return }
        load(queue.removeFirst(), autoplay: autoplay)
        if queue.count < 2 { refill(thenPlay: nil) }
    }

    private func refill(thenPlay: Bool?) {
        guard let wave = wave, !refilling else { return }
        refilling = true
        let played = history + [current].compactMap { $0 }
        let g = gen
        Task {
            defer { refilling = false }
            do {
                let more = try await wave.more(played: played)
                guard g == gen else { return }
                let known = Set(queue.map(\.id) + played.suffix(20).map(\.id))
                queue += more.filter { !known.contains($0.id) }
                if let p = thenPlay {
                    if queue.isEmpty { status = "Волна ничего не вернула" }
                    else { load(queue.removeFirst(), autoplay: p) }
                }
            } catch {
                guard g == gen else { return }
                fail(error)
            }
        }
    }

    private func load(_ t: Track, autoplay: Bool, startAt: Double = 0) {
        ylog("load \(t.key) «\(t.artists) — \(t.title)» autoplay=\(autoplay)")
        gen += 1
        let g = gen
        current = t
        liked = likes.contains(t.id)
        cover = nil
        position = startAt
        pendingSeek = startAt
        meter.reset()
        duration = Double(t.durationMs) / 1000
        status = nil
        avp.pause()
        avp.replaceCurrentItem(with: nil)
        itemObs = nil
        updateNowPlaying()

        guard let api = api else { return }
        Task {
            do {
                let url = try await api.streamURL(t)
                guard g == gen else { return }
                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 20
                ylog("play \(t.key)")
                streamFailures = 0
                setItem(item)
                if autoplay { avp.play() }
                wave?.feedback("trackStarted", track: t, played: 0)
            } catch {
                guard g == gen else { return }
                fail(error)
                // трек не отдаётся — не застреваем, идём дальше (но не больше 3 раз подряд)
                streamFailures += 1
                // в том числе при восстановлении после перезапуска: битый сохранённый трек забываем
                if streamFailures <= 3, !((error as? APIError)?.isAuth ?? false) {
                    Self.clearSaved()
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard g == gen else { return }
                    ylog("skip \(t.key): не отдаётся, следующий")
                    advance(autoplay: autoplay)
                }
            }
        }
        Task {
            guard let u = t.coverURL(200), let d = try? await api.data(u), g == gen else { return }
            cover = NSImage(data: d)
            tint = cover?.tintColor
            updateNowPlaying()
        }
    }

    private func setItem(_ item: AVPlayerItem) {
        if let o = endObs { NotificationCenter.default.removeObserver(o) }
        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
        itemObs = item.observe(\.status, options: [.new]) { it, _ in
            guard it.status == .failed else { return }
            ylog("item failed: \(String(describing: it.error))")
        }
        meter.attach(to: item)
        avp.replaceCurrentItem(with: item)
        if pendingSeek > 1 {
            let t = pendingSeek
            avp.seek(to: CMTime(seconds: t, preferredTimescale: 1000))
            position = t
        }
        pendingSeek = 0
    }

    private func finished() {
        guard let c = current else { return }
        wave?.feedback("trackFinished", track: c, played: duration)
        pushHistory(c)
        direction = 1
        advance(autoplay: true)
    }

    // MARK: медиаклавиши / Control Center

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }; return .success
        }
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }; return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }; return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.prev() }; return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = current else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artists,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let img = cover {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}
