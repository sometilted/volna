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

    /// что играет: «Моя волна» или список (Мне нравится, плейлист); список кончился — назад на волну
    enum Source: Equatable {
        case wave
        case list(String)
    }
    @Published private(set) var source: Source = .wave
    @Published private(set) var playlists: [YaAPI.Playlist] = []

    private var api: YaAPI?
    private var wave: Wave?
    private var uid: Int?
    @Published private(set) var likes = Set<String>()
    private var queue: [Track] = []
    private var history: [Track] = []
    private var refilling = false
    private var gen = 0

    /// AVQueuePlayer: следующий трек подгружается заранее и стартует без паузы
    private let avp = AVQueuePlayer()
    private var nextUp: (track: Track, item: AVPlayerItem, ctx: TapContext)?
    private var preparing = false
    private var currentCtx: TapContext?
    /// поставлено на паузу из-за созвона — после созвона продолжим
    private var pausedForCall = false
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
                // следующий трек готовим сразу, как только текущий разыгрался (3 с) — переход и «вперёд» мгновенные
                if self.isPlaying, self.position > 3 { self.prepareNext() }
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
                    let pl = try? await api.playlists(uid: uid)
                    playlists = pl ?? []
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
        avp.removeAllItems()
        nextUp = nil; currentCtx = nil; preparing = false
        source = .wave; playlists = []; pausedForCall = false
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
                guard !fresh.isEmpty, source == .wave else { return }
                dropNextUp()
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
        pausedForCall = false
        pauseReasons = []
        if avp.currentItem == nil { load(c, autoplay: true); return }
        if isPlaying { avp.pause() } else { avp.play() }
    }

    func play() { if !isPlaying { toggle() } }
    func pause() { avp.pause() }

    func next() {
        guard let c = current else { return }
        waveFeedback("skip", c, position)
        pushHistory(c)
        direction = 1
        advance(autoplay: true)
    }

    func prev() {
        if position > 3 { seek(to: 0); return }
        guard let p = history.popLast() else { seek(to: 0); return }
        dropNextUp()
        if let c = current { queue.insert(c, at: 0) }
        direction = -1
        load(p, autoplay: true)
    }

    func toggleLike() {
        if let c = current { toggleLike(c) }
    }

    func isLiked(_ t: Track) -> Bool { likes.contains(t.id) }

    /// Лайк любого трека (текущего или из поиска).
    func toggleLike(_ c: Track) {
        guard let api = api, let uid = uid else { return }
        let on = !likes.contains(c.id)
        if current?.id == c.id { liked = on }
        if on { likes.insert(c.id) } else { likes.remove(c.id) }
        Task {
            do { try await api.setLike(uid: uid, track: c, on: on) }
            catch {
                if current?.id == c.id { liked = !on }
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

    // MARK: созвоны

    /// почему стоим на авто-паузе: "call" — созвон, "other" — играет другое приложение
    private var pauseReasons = Set<String>()

    /// Микрофон занят кем-то (созвон) / освободился. Возвращает true, если поставили на паузу или продолжили.
    @discardableResult
    func micChanged(_ busy: Bool) -> Bool {
        guard !busy || Prefs.shared.callPause else { return false }
        return interrupt("call", busy)
    }

    /// Другое приложение играет звук (ролик, голосовое, YouTube) / замолчало.
    @discardableResult
    func otherAudio(_ on: Bool) -> Bool {
        guard !on || Prefs.shared.otherPause else { return false }
        return interrupt("other", on)
    }

    /// Авто-пауза по причине; продолжаем, только когда ушли все причины и паузу ставили мы сами.
    private func interrupt(_ reason: String, _ on: Bool) -> Bool {
        if on {
            if pausedForCall { pauseReasons.insert(reason); return false }
            guard isPlaying else { return false }
            pauseReasons = [reason]
            pausedForCall = true
            fade(to: 0, 0.25) { [weak self] in
                guard let self = self else { return }
                if self.pausedForCall { self.avp.pause() }
                self.avp.volume = 1
            }
            ylog("auto: пауза (\(reason))")
            return true
        }
        guard pausedForCall, pauseReasons.contains(reason) else { return false }
        pauseReasons.remove(reason)
        guard pauseReasons.isEmpty else { return false }
        pausedForCall = false
        avp.volume = 0
        avp.play()
        fade(to: 1, 0.8)
        ylog("auto: продолжаем (\(reason))")
        return true
    }

    private var fadeTimer: Timer?

    /// Плавно меняет громкость плеера (без щелчка на паузе и резкого старта после созвона).
    private func fade(to target: Float, _ seconds: Double, then done: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        let from = avp.volume
        let start = Date()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self = self else { t.invalidate(); return }
                let k = Float(min(Date().timeIntervalSince(start) / seconds, 1))
                self.avp.volume = from + (target - from) * k
                if k >= 1 {
                    t.invalidate()
                    self.fadeTimer = nil
                    done?()
                }
            }
        }
    }

    // MARK: выравнивание громкости

    /// Усиление трека до −11 LUFS по данным R128 от Яндекса: не выше пика −1 dBTP, в пределах −12…+6 дБ.
    private func gain(for t: Track) -> Float {
        guard Prefs.shared.normalize, let i = t.lufs else { return 1 }
        var db = -11 - i
        if let tp = t.peak { db = min(db, -1 - tp) }
        db = min(max(db, -12), 6)
        return Float(pow(10, db / 20))
    }

    /// Переключили «Выравнивать громкость» — применить к играющему и подготовленному сразу.
    func applyNormalize() {
        if let c = current { currentCtx?.gain = gain(for: c) }
        if let n = nextUp { n.ctx.gain = gain(for: n.track) }
    }

    // MARK: библиотека

    func playWave() {
        guard source != .wave else { return }
        source = .wave
        dropNextUp()
        queue = []
        if let c = current { pushHistory(c) }
        direction = 1
        refill(thenPlay: true)
    }

    func playLikes() {
        guard let api = api, let uid = uid else { return }
        status = "Загружаю «Мне нравится»…"
        Task {
            do { playList(try await api.likedTracks(uid: uid), title: "Мне нравится") }
            catch { fail(error) }
        }
    }

    func playPlaylist(_ p: YaAPI.Playlist) {
        guard let api = api, let uid = uid else { return }
        status = "Загружаю «\(p.title)»…"
        Task {
            do { playList(try await api.playlistTracks(uid: uid, kind: p.kind), title: p.title) }
            catch { fail(error) }
        }
    }

    private func playList(_ tracks: [Track], title: String) {
        var list = tracks
        if Prefs.shared.shuffle { list.shuffle() }
        guard let first = list.first else { status = "«\(title)» пуст"; return }
        status = nil
        source = .list(title)
        dropNextUp()
        if let c = current { pushHistory(c) }
        direction = 1
        queue = Array(list.dropFirst())
        load(first, autoplay: true)
    }

    /// Поставить трек следующим: доиграет текущий — начнётся он.
    func playNext(_ t: Track) {
        guard current != nil else { playNow(t); return }
        dropNextUp()
        queue.removeAll { $0.id == t.id }
        queue.insert(t, at: 0)
        ylog("next: \(t.key) следующим")
    }

    /// Популярные треки исполнителя — как список; кончились — дальше волна.
    func playArtist(_ a: YaAPI.Artist) {
        guard let api = api else { return }
        status = "Загружаю «\(a.name)»…"
        Task {
            do { playList(try await api.artistTracks(a.id), title: a.name) }
            catch { fail(error) }
        }
    }

    /// Найденный трек — сразу, дальше играет то, что играло.
    func playNow(_ t: Track) {
        dropNextUp()
        if let c = current { pushHistory(c) }
        direction = 1
        load(t, autoplay: true)
    }

    /// Поиск с подстраховкой: Яндекс сам исправляет опечатки и формы слов; если нашлось мало —
    /// пробуем запрос в другой раскладке (ghbdtn → привет) и транслитом (kino ↔ кино) и сливаем без дублей.
    func search(_ text: String) async -> (tracks: [Track], artists: [YaAPI.Artist], bestArtist: Bool) {
        guard let api = api else { return ([], [], false) }
        let main = try? await api.search(text)
        var tracks = main?.tracks ?? []
        var artists = main?.artists ?? []
        let best = main?.bestArtist ?? false
        if tracks.count >= 5 { return (tracks, artists, best) }
        var seen = Set(tracks.map(\.id))
        for alt in Translit.variants(text) where alt != text {
            guard let more = try? await api.search(alt) else { continue }
            for t in more.tracks where !seen.contains(t.id) {
                seen.insert(t.id)
                tracks.append(t)
            }
            if artists.isEmpty { artists = more.artists }
            if tracks.count >= 7 { break }
        }
        return (tracks, artists, best)
    }

    private func waveFeedback(_ type: String, _ t: Track?, _ played: Double) {
        guard source == .wave else { return }
        wave?.feedback(type, track: t, played: played)
    }

    // MARK: очередь

    private func pushHistory(_ t: Track) {
        history.append(t)
        if history.count > 50 { history.removeFirst(history.count - 50) }
    }

    private func advance(autoplay: Bool) {
        if queue.isEmpty, source != .wave {
            ylog("список кончился — назад на волну")
            source = .wave
        }
        guard !queue.isEmpty else { refill(thenPlay: autoplay); return }
        load(queue.removeFirst(), autoplay: autoplay)
        if queue.count < 2 { refill(thenPlay: nil) }
    }

    private func refill(thenPlay: Bool?) {
        guard let wave = wave, !refilling, source == .wave else { return }
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
        loadCover(t, g)

        // уже подгружен заранее — стартуем мгновенно
        if let n = nextUp, n.track.id == t.id, startAt < 1 {
            nextUp = nil
            for it in avp.items() where it !== n.item { avp.remove(it) }
            currentCtx = n.ctx
            n.item.preferredForwardBufferDuration = 20
            observe(n.item)
            logGain(t)
            if autoplay { avp.play() }
            ylog("play \(t.key) (подготовлен)")
            waveFeedback("trackStarted", t, 0)
            updateNowPlaying()
            return
        }
        dropNextUp()
        avp.pause()
        avp.removeAllItems()
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
                waveFeedback("trackStarted", t, 0)
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
    }

    private func loadCover(_ t: Track, _ g: Int) {
        guard let api = api else { return }
        Task {
            guard let u = t.coverURL(200), let d = try? await api.data(u), g == gen else { return }
            cover = NSImage(data: d)
            tint = cover?.tintColor
            updateNowPlaying()
        }
    }

    /// Следующий из очереди: ссылка, item и tap заранее, в очередь AVQueuePlayer сразу за текущим.
    private func prepareNext() {
        guard nextUp == nil, !preparing, let api = api, let t = queue.first,
              let cur = avp.currentItem, avp.items().count == 1 else { return }
        preparing = true
        let g = gen
        Task {
            defer { preparing = false }
            guard let url = try? await api.streamURL(t), g == gen, queue.first?.id == t.id,
                  avp.currentItem === cur else { return }
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 6   // заранее — только начало трека
            let ctx = meter.attach(to: item, gain: gain(for: t))
            avp.insert(item, after: cur)
            nextUp = (t, item, ctx)
            ylog("next ready \(t.key)")
        }
    }

    private func dropNextUp() {
        if let n = nextUp { avp.remove(n.item) }
        nextUp = nil
    }

    /// AVQueuePlayer сам перешёл на подготовленный трек — обновляем всё, кроме плеера.
    private func adopt(_ n: (track: Track, item: AVPlayerItem, ctx: TapContext)) {
        let t = n.track
        ylog("gapless → \(t.key) «\(t.artists) — \(t.title)»")
        nextUp = nil
        if queue.first?.id == t.id { queue.removeFirst() } else { queue.removeAll { $0.id == t.id } }
        gen += 1
        let g = gen
        current = t
        liked = likes.contains(t.id)
        cover = nil
        position = 0
        duration = Double(t.durationMs) / 1000
        status = nil
        currentCtx = n.ctx
        n.item.preferredForwardBufferDuration = 20
        observe(n.item)
        logGain(t)
        loadCover(t, g)
        waveFeedback("trackStarted", t, 0)
        updateNowPlaying()
        if queue.count < 2 { refill(thenPlay: nil) }
    }

    private func logGain(_ t: Track) {
        let l = t.lufs.map { String(format: "%.1f LUFS", $0) } ?? "нет данных"
        ylog(String(format: "gain %@: %@ → ×%.2f", t.key, l, gain(for: t)))
    }

    private func setItem(_ item: AVPlayerItem) {
        if let c = current { logGain(c) }
        currentCtx = meter.attach(to: item, gain: current.map { gain(for: $0) } ?? 1)
        observe(item)
        avp.removeAllItems()
        avp.insert(item, after: nil)
        if pendingSeek > 1 {
            let t = pendingSeek
            avp.seek(to: CMTime(seconds: t, preferredTimescale: 1000))
            position = t
        }
        pendingSeek = 0
    }

    private func observe(_ item: AVPlayerItem) {
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
    }

    private func finished() {
        guard let c = current else { return }
        waveFeedback("trackFinished", c, duration)
        pushHistory(c)
        direction = 1
        // следующий уже в AVQueuePlayer — он играет без паузы, плеер не трогаем
        if let n = nextUp, avp.items().contains(where: { $0 === n.item }) {
            adopt(n)
            return
        }
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

/// Варианты запроса: другая раскладка клавиатуры и транслит в обе стороны.
enum Translit {
    private static let en = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.`")
    private static let ru = Array("йцукенгшщзхъфывапролджэячсмитьбюё")

    static func variants(_ s: String) -> [String] {
        let low = s.lowercased()
        var v: [String] = []
        let lat = low.contains { $0.isASCII && $0.isLetter }
        let cyr = low.contains { ("а"..."я").contains($0) || $0 == "ё" }
        if lat && !cyr {
            v.append(layout(low, from: en, to: ru))
            v.append(toCyr(low))
        } else if cyr && !lat {
            v.append(layout(low, from: ru, to: en))
            v.append(toLat(low))
        }
        var seen = Set<String>()
        return v.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func layout(_ s: String, from: [Character], to: [Character]) -> String {
        String(s.map { c in from.firstIndex(of: c).map { to[$0] } ?? c })
    }

    private static let lat2cyr: [(String, String)] = [
        ("shch", "щ"), ("sch", "щ"), ("yo", "ё"), ("zh", "ж"), ("kh", "х"), ("ts", "ц"), ("ch", "ч"),
        ("sh", "ш"), ("yu", "ю"), ("ya", "я"), ("ye", "е"), ("a", "а"), ("b", "б"), ("v", "в"), ("w", "в"),
        ("g", "г"), ("d", "д"), ("e", "е"), ("z", "з"), ("i", "и"), ("j", "й"), ("y", "ы"), ("k", "к"),
        ("l", "л"), ("m", "м"), ("n", "н"), ("o", "о"), ("p", "п"), ("r", "р"), ("s", "с"), ("t", "т"),
        ("u", "у"), ("f", "ф"), ("h", "х"), ("c", "к"), ("x", "кс"), ("q", "к"),
    ]

    private static func toCyr(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        outer: while i < s.endIndex {
            for (l, c) in lat2cyr where s[i...].hasPrefix(l) {
                out += c
                i = s.index(i, offsetBy: l.count)
                continue outer
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    private static let cyr2lat: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo", "ж": "zh", "з": "z",
        "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    ]

    private static func toLat(_ s: String) -> String {
        s.map { cyr2lat[$0] ?? String($0) }.joined()
    }
}
