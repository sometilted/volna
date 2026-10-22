import AppKit
import ServiceManagement

@main
struct VolnaMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var player: Player!
    private var notch: NotchController!
    private let login = LoginWindow()
    private let device = DeviceLogin()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Migration.run()
        Log.rotate()
        let hasToken = TokenStore.load() != nil
        ylog("=== launch, token: \(hasToken)")
        player = Player()
        let actions = NotchActions(
            login: { [weak self] in self?.doLogin() },
            pasteToken: { [weak self] in self?.pasteToken() },
            logout: { [weak self] in self?.logout() },
            setLaunchAtLogin: { on in Self.setLaunchAtLogin(on) },
            quit: { NSApp.terminate(nil) }
        )
        notch = NotchController(player: player, login: device, actions: actions)
        Updater.shared.start()
        if let t = TokenStore.load() {
            player.start(token: t, autoplay: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        player.saveState()
    }

    private func doLogin() {
        let onToken: (String) -> Void = { [weak self] token in
            TokenStore.save(token)
            self?.player.start(token: token, autoplay: true)
        }
        device.start(done: onToken, fallback: { [weak self] in
            self?.login.show(done: onToken)
        })
    }

    private func pasteToken() {
        guard let s = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
        let token = LoginWindow.token(from: s) ?? s
        guard token.count > 20, !token.contains(" ") else { return }
        device.cancel()
        TokenStore.save(token)
        player.start(token: token, autoplay: true)
    }

    private func logout() {
        TokenStore.clear()
        Player.clearSaved()
        player.stop()
    }

    private static func setLaunchAtLogin(_ on: Bool) {
        let svc = SMAppService.mainApp
        do {
            if on { try svc.register() } else { try svc.unregister() }
        } catch {
            ylog("login item: \(error)")
        }
        if svc.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        Prefs.shared.launchAtLogin = svc.status == .enabled
    }
}

// MARK: - Настройки

@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var peek: Bool { didSet { d.set(peek, forKey: "peek") } }
    @Published var style: String { didSet { d.set(style, forKey: "style") } }
    @Published var tgNotify: Bool { didSet { d.set(tgNotify, forKey: "tgNotify") } }
    /// moodEnergy: all | active | fun | calm | sad
    @Published var mood: String { didSet { d.set(mood, forKey: "mood") } }
    /// diversity: default | favorite | discover | popular
    @Published var diversity: String { didSet { d.set(diversity, forKey: "diversity") } }
    /// language: any | russian | not-russian
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    @Published var launchAtLogin: Bool
    /// выравнивать громкость треков (R128)
    @Published var normalize: Bool { didSet { d.set(normalize, forKey: "normalize") } }
    /// пауза, пока микрофон занят созвоном
    @Published var callPause: Bool { didSet { d.set(callPause, forKey: "callPause") } }
    /// пауза, пока другое приложение играет звук (ролик, голосовое, YouTube)
    @Published var otherPause: Bool { didSet { d.set(otherPause, forKey: "otherPause") } }
    /// громкость и яркость показывать в нотче вместо системной плашки
    @Published var hudKeys: Bool { didSet { d.set(hudKeys, forKey: "hudKeys") } }
    /// списки (Мне нравится, плейлисты) — вперемешку
    @Published var shuffle: Bool { didSet { d.set(shuffle, forKey: "shuffle") } }

    private init() {
        peek = d.object(forKey: "peek") as? Bool ?? true
        style = UIStyle.from(d.string(forKey: "style")).rawValue   // старые стили 0.1.x → Прилив
        tgNotify = d.object(forKey: "tgNotify") as? Bool ?? true
        mood = d.string(forKey: "mood") ?? "all"
        diversity = d.string(forKey: "diversity") ?? "default"
        language = d.string(forKey: "language") ?? "any"
        launchAtLogin = SMAppService.mainApp.status == .enabled
        normalize = d.object(forKey: "normalize") as? Bool ?? true
        callPause = d.object(forKey: "callPause") as? Bool ?? true
        otherPause = d.object(forKey: "otherPause") as? Bool ?? true
        hudKeys = d.object(forKey: "hudKeys") as? Bool ?? true
        shuffle = d.object(forKey: "shuffle") as? Bool ?? false
    }

    var waveIsDefault: Bool { mood == "all" && diversity == "default" && language == "any" }
}

/// Переезд с YaNotch: токен и настройки забираем один раз, чтобы не входить заново.
enum Migration {
    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromYaNotch") else { return }
        defer { d.set(true, forKey: "migratedFromYaNotch") }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if TokenStore.load() == nil,
           let t = try? String(contentsOf: base.appendingPathComponent("YaNotch/token"), encoding: .utf8) {
            let token = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { TokenStore.save(token) }
        }
        if let old = UserDefaults(suiteName: "com.alex.yanotch") {
            for k in ["peek", "tgNotify", "style", "mood", "diversity", "language", "lastTrack"] {
                if d.object(forKey: k) == nil, let v = old.object(forKey: k) { d.set(v, forKey: k) }
            }
        }
    }
}

enum TokenStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Volna")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("token")
    }

    static func load() -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func save(_ token: String) {
        try? token.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
