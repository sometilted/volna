import AppKit
import WebKit

enum YaOAuth {
    // client_id / secret официального приложения Яндекс Музыки
    static let clientId = "23cabbbdc6cd418abb4b39c32c41195d"
    static let clientSecret = "53bc75238f0c4d08a118e51fe9203300"
}

/// Вход «как на телевизоре»: показываем код, открываем ya.ru/device в браузере,
/// где пользователь уже залогинен, и ждём подтверждения. Без WebView.
@MainActor
final class DeviceLogin: ObservableObject {
    @Published private(set) var userCode: String?
    @Published private(set) var verifyURL: URL?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    /// done — токен; fallback — вызывается, если device flow не поддержан
    func start(done: @escaping (String) -> Void, fallback: @escaping () -> Void) {
        cancel()
        error = nil
        task = Task {
            do {
                let r = try await post("https://oauth.yandex.ru/device/code", [
                    "client_id": YaOAuth.clientId,
                    "device_name": "Volna (\(Host.current().localizedName ?? "Mac"))",
                ])
                guard let dc = r["device_code"] as? String, let uc = r["user_code"] as? String else {
                    ylog("device/code: \(r)")
                    fallback()
                    return
                }
                let vurl = URL(string: r["verification_url"] as? String ?? "") ?? URL(string: "https://ya.ru/device")!
                let interval = max((r["interval"] as? NSNumber)?.doubleValue ?? 5, 2)
                let expires = (r["expires_in"] as? NSNumber)?.doubleValue ?? 300
                userCode = uc
                verifyURL = vurl
                copyCode()
                NSWorkspace.shared.open(vurl)

                let deadline = Date().addingTimeInterval(expires)
                while Date() < deadline {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    let t = try await post("https://oauth.yandex.ru/token", [
                        "grant_type": "device_code",
                        "code": dc,
                        "client_id": YaOAuth.clientId,
                        "client_secret": YaOAuth.clientSecret,
                    ])
                    if let tok = t["access_token"] as? String {
                        userCode = nil
                        verifyURL = nil
                        done(tok)
                        return
                    }
                    let err = t["error"] as? String ?? ""
                    if err == "authorization_pending" || err == "slow_down" { continue }
                    throw APIError.bad((t["error_description"] as? String) ?? (err.isEmpty ? "ошибка входа" : err))
                }
                throw APIError.bad("Код истёк — нажми «Войти» ещё раз")
            } catch is CancellationError {
            } catch {
                userCode = nil
                verifyURL = nil
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        userCode = nil
        verifyURL = nil
    }

    func copyCode() {
        guard let c = userCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c, forType: .string)
    }

    func reopen() {
        if let u = verifyURL { NSWorkspace.shared.open(u) }
    }

    /// POST form; 4xx тоже разбираем — /token отдаёт authorization_pending с кодом 400
    private func post(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.http(code, String(decoding: data, as: UTF8.self))
        }
        return d
    }
}

/// Запасной вход через oauth.yandex.ru в окне. WebView живёт только пока открыто окно.
@MainActor
final class LoginWindow: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var web: WKWebView?
    private var done: ((String) -> Void)?

    func show(done: @escaping (String) -> Void) {
        self.done = done
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let h = min(1000, vis.height - 20)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: h), configuration: cfg)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        // страница рассчитана на высокий экран — уменьшаем, чтобы QR влезал целиком
        if h < 950 { web.pageZoom = max(0.7, h / 950) }

        let w = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Вход в Яндекс"
        w.isReleasedWhenClosed = false
        w.contentView = web
        w.delegate = self
        w.setFrameTopLeftPoint(NSPoint(x: vis.midX - 260, y: vis.maxY - 10))
        self.window = w
        self.web = web

        let url = URL(string: "https://oauth.yandex.ru/authorize?response_type=token&client_id=\(YaOAuth.clientId)")!
        web.load(URLRequest(url: url))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func token(from s: String) -> String? {
        guard let r = s.range(of: "access_token=") else { return nil }
        let t = s[r.upperBound...].prefix { $0 != "&" && $0 != "#" }
        return t.isEmpty ? nil : String(t)
    }

    private func check(_ url: URL?) -> Bool {
        guard let s = url?.absoluteString, let t = Self.token(from: s) else { return false }
        let d = done
        done = nil
        DispatchQueue.main.async { [weak self] in
            self?.teardown()
            d?(t)
        }
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if check(navigationAction.request.url) {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        _ = check(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        _ = check(webView.url)
    }

    func windowWillClose(_ notification: Notification) {
        web?.stopLoading()
        web?.navigationDelegate = nil
        web = nil
        window?.delegate = nil
        window = nil
        done = nil
    }

    private func teardown() {
        guard let w = window else { return }
        w.delegate = nil
        web?.stopLoading()
        web?.navigationDelegate = nil
        w.contentView = nil
        w.orderOut(nil)
        web = nil
        window = nil
    }
}
