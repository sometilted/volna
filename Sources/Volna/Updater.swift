import AppKit
import CryptoKit

struct Release {
    let version: String
    let notes: String
    let page: URL?
    let zip: URL
    let sig: URL
}

/// Обновления через GitHub Releases: раз в сутки смотрит последний релиз, показывает ченджлог,
/// по согласию качает zip, проверяет подпись ed25519 и подменяет приложение.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    @Published private(set) var available: Release?
    @Published private(set) var busy = false
    var onAvailable: (@MainActor (Release) -> Void)?

    private var timer: Timer?
    private let d = UserDefaults.standard

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func start() {
        guard UpdateConfig.enabled else {
            ylog("update: репозиторий не настроен, проверка выключена")
            return
        }
        // первая проверка через 10 с после запуска, дальше раз в час смотрим, прошли ли сутки (переживает сон)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        t.tolerance = 300
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func checkIfDue() {
        let last = d.double(forKey: "updateLastCheck")
        if Date().timeIntervalSince1970 - last >= 86_400 { check(manual: false) }
    }

    func check(manual: Bool) {
        guard UpdateConfig.enabled else {
            if manual { info("Обновления не настроены", "В этой сборке не указан репозиторий.") }
            return
        }
        Task {
            do {
                let r = try await fetchLatest()
                d.set(Date().timeIntervalSince1970, forKey: "updateLastCheck")
                if let r = r, Self.isNewer(r.version, than: Self.current) {
                    if !manual && d.string(forKey: "updateSkip") == r.version { return }
                    available = r
                    ylog("update: доступна \(r.version)")
                    onAvailable?(r)
                    if manual { prompt() }
                } else if manual {
                    info("Обновлений нет", "У тебя последняя версия — \(Self.current).")
                }
            } catch {
                ylog("update: проверка: \(error)")
                if manual { info("Не удалось проверить обновления", error.localizedDescription) }
            }
        }
    }

    private func fetchLatest() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(UpdateConfig.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Volna/\(Self.current)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }  // релизов ещё нет
        guard code == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.http(code, String(decoding: data.prefix(200), as: UTF8.self))
        }
        let tag = (j["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let assets = j["assets"] as? [[String: Any]] ?? []
        func asset(_ suffix: String) -> URL? {
            for a in assets {
                if let n = a["name"] as? String, n.hasSuffix(suffix),
                   let s = a["browser_download_url"] as? String, let u = URL(string: s) { return u }
            }
            return nil
        }
        guard let zip = asset(".zip"), let sig = asset(".zip.sig") else {
            ylog("update: в релизе \(tag) нет zip/sig")
            return nil
        }
        // всё после «---» в тексте релиза — для страницы GitHub (команда установки), в окне обновления не показываем
        let body = j["body"] as? String ?? ""
        let notes = (body.components(separatedBy: "\n---").first ?? body).trimmingCharacters(in: .whitespacesAndNewlines)
        return Release(version: tag, notes: notes,
                       page: (j["html_url"] as? String).flatMap { URL(string: $0) }, zip: zip, sig: sig)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: диалог

    func prompt() {
        guard let r = available else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Вышла Volna \(r.version)"
        a.informativeText = "Сейчас у тебя \(Self.current). Что нового:"
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 180))
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        let tv = NSTextView(frame: sv.bounds)
        // markdown из релиза показываем чистым текстом: без **, ` и ``` (списки «- » оставляем)
        let clean = r.notes
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n- ", with: "\n• ")
        tv.string = clean.isEmpty ? "—" : (clean.hasPrefix("- ") ? "• " + clean.dropFirst(2) : clean)
        tv.isEditable = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 12)
        tv.autoresizingMask = [.width]
        sv.documentView = tv
        a.accessoryView = sv
        a.addButton(withTitle: "Обновить")
        a.addButton(withTitle: "Позже")
        a.addButton(withTitle: "Пропустить эту версию")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            install(r)
        case .alertThirdButtonReturn:
            d.set(r.version, forKey: "updateSkip")
            available = nil
        default:
            break
        }
    }

    private func info(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: установка

    func install(_ r: Release) {
        guard !busy else { return }
        let dest = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            if let p = r.page { NSWorkspace.shared.open(p) }
            info("Нет прав на папку", "Не могу заменить \(dest.path). Открыл страницу релиза — скачай вручную.")
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("VolnaUpdate-\(r.version)", isDirectory: true)
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let (tmpZip, _) = try await URLSession.shared.download(from: r.zip)
                let zip = dir.appendingPathComponent("Volna.zip")
                try FileManager.default.moveItem(at: tmpZip, to: zip)
                let (sig, _) = try await URLSession.shared.data(from: r.sig)
                guard try Self.verify(zip: zip, sig: sig) else {
                    throw APIError.bad("подпись обновления не совпала — ставить не буду")
                }
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
                let newApp = dir.appendingPathComponent("Volna.app")
                guard FileManager.default.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/Volna").path) else {
                    throw APIError.bad("в архиве нет Volna.app")
                }
                try swapAndRelaunch(newApp: newApp, dest: dest)
            } catch {
                ylog("update: установка: \(error)")
                info("Не удалось обновить", error.localizedDescription)
            }
        }
    }

    private static func verify(zip: URL, sig: Data) throws -> Bool {
        let sigText = String(decoding: sig, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pk = Data(base64Encoded: UpdateConfig.publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pk),
              let s = Data(base64Encoded: sigText) else { return false }
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        return key.isValidSignature(s, for: data)
    }

    private static func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw APIError.bad("\(exe) завершился с кодом \(p.terminationStatus)") }
    }

    /// Ждём выхода, меняем бандл (со страховкой: при сбое возвращаем старый), запускаем новую версию.
    private func swapAndRelaunch(newApp: URL, dest: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let sh = """
        #!/bin/bash
        DEST="\(dest.path)"
        NEW="\(newApp.path)"
        OLD="$DEST.old-$$"
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        if mv "$DEST" "$OLD" && mv "$NEW" "$DEST"; then
          rm -rf "$OLD"
        else
          [ -d "$OLD" ] && [ ! -d "$DEST" ] && mv "$OLD" "$DEST"
        fi
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        open "$DEST"
        """
        let script = newApp.deletingLastPathComponent().appendingPathComponent("swap.sh")
        try sh.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        try p.run()
        ylog("update: ставлю \(newApp.path) → \(dest.path), перезапуск")
        NSApp.terminate(nil)
    }
}
