import AppKit
import ApplicationServices

/// Следит за счётчиком непрочитанных на иконке Telegram в Доке (Accessibility API).
/// Уведомления в самом Telegram могут быть выключены — счётчик на иконке всё равно обновляется,
/// если в Telegram включён «Счётчик на иконке». Опрос раз в 2 с, без сети.
@MainActor
final class TelegramWatcher {
    var onNew: (@MainActor (NSImage, Int) -> Void)?
    private var timer: Timer?
    private var last = -1
    private var cachedIcon: NSImage?
    private var activity: NSObjectProtocol?
    private static let bundleIDs = ["ru.keepcoder.Telegram", "org.telegram.desktop", "com.tdesktop.Telegram"]

    var running: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        ylog("tg: accessibility trusted=\(trusted)")
        last = -1
        // фоновое приложение без окон macOS «усыпляет» (App Nap) — таймер срабатывает с большой задержкой
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Telegram badge watcher")
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
    }

    private func poll() {
        guard AXIsProcessTrusted() else { return }
        let n = badge() ?? 0
        if last >= 0, n > last, let icon = icon() {
            ylog("tg: непрочитанных \(last) → \(n)")
            onNew?(icon, n)
        }
        last = n
    }

    /// nil — Telegram не в Доке; 0 — без счётчика.
    private func badge() -> Int? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        for list in children(app) where role(list) == "AXList" {
            for item in children(list) {
                guard let title = attr(item, kAXTitleAttribute) as? String,
                      title.lowercased().contains("telegram") else { continue }
                let label = attr(item, "AXStatusLabel") as? String ?? ""
                return Int(label.filter(\.isNumber)) ?? 0
            }
        }
        return nil
    }

    private func icon() -> NSImage? {
        if let c = cachedIcon { return c }
        for id in Self.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                cachedIcon = NSWorkspace.shared.icon(forFile: url.path)
                return cachedIcon
            }
        }
        return nil
    }

    static func open() {
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }

    private func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private func children(_ e: AXUIElement) -> [AXUIElement] {
        attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func role(_ e: AXUIElement) -> String? {
        attr(e, kAXRoleAttribute) as? String
    }
}
