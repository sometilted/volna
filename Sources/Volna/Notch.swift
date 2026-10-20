import AppKit
import Combine
import SwiftUI

struct NotchActions {
    let login: () -> Void
    let pasteToken: () -> Void
    let logout: () -> Void
    let setLaunchAtLogin: (Bool) -> Void
    let quit: () -> Void
}

@MainActor
struct Notice: Equatable {
    let id = UUID()
    let icon: NSImage
    let text: String
}

final class NotchModel: ObservableObject {
    @Published var expanded = false
    /// раскрыто само на смену трека, мышь не перехватываем
    @Published var peeking = false
    /// идёт вход по коду — панель держим открытой
    @Published var pinned = false
    /// короткое уведомление в свёрнутом нотче (иконка + текст)
    @Published var notice: Notice?
    @Published var notchW: CGFloat = 0
    @Published var notchH: CGFloat = 32
    let expandedW: CGFloat = 400
    /// стиль «Дизайн» выше обычного: макет 400×177 pt (800×354 @2x)
    @Published var tall = false
    var expandedH: CGFloat { tall ? max(177, notchH + 112) : notchH + 112 }

    func collapsedW(hasTrack: Bool) -> CGFloat {
        guard hasTrack else { return notchW }
        return max(notchW, 60) + 2 * (notchH + 4)
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
protocol MenuSource: AnyObject {
    func buildMenu() -> NSMenu
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    weak var menuSource: MenuSource?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) {
        if let m = menuSource?.buildMenu() {
            NSMenu.popUpContextMenu(m, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

/// NSMenuItem с замыканием вместо target/selector
final class MenuAction: NSObject {
    let fn: () -> Void
    init(_ fn: @escaping () -> Void) { self.fn = fn }
    @objc func fire() { fn() }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, checked: Bool = false, _ fn: @escaping () -> Void) -> NSMenuItem {
        let a = MenuAction(fn)
        let it = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        it.target = a
        it.representedObject = a
        it.state = checked ? .on : .off
        addItem(it)
        return it
    }

    func submenu(_ title: String, build: (NSMenu) -> Void) {
        let sub = NSMenu(title: title)
        build(sub)
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = sub
        addItem(it)
    }
}

@MainActor
final class NotchController: MenuSource {
    private let panel: NotchPanel
    private let model = NotchModel()
    private let player: Player
    private var monitors: [Any] = []
    private var bag = Set<AnyCancellable>()
    private var peekWork: DispatchWorkItem?
    private var noticeWork: DispatchWorkItem?
    private let tg = TelegramWatcher()
    private let actions: NotchActions
    private let panelW: CGFloat = 440
    private let panelH: CGFloat = 200

    init(player: Player, login: DeviceLogin, actions: NotchActions) {
        self.player = player
        self.actions = actions
        panel = NotchPanel(contentRect: .zero,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let host = FirstMouseHostingView(rootView: NotchView(player: player, model: model, login: login,
                                                             prefs: Prefs.shared, actions: actions))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: panelW, height: panelH)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        layout()
        panel.orderFrontRegardless()
        host.menuSource = self

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.track() }
            return e
        }) { monitors.append(m) }
        panel.acceptsMouseMovedEvents = true

        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }

        player.$current
            .map { $0?.id }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] id in
                guard id != nil else { return }
                MainActor.assumeIsolated { self?.peek() }
            }
            .store(in: &bag)

        tg.onNew = { [weak self] icon, n in self?.notify(icon: icon, text: "\(n)") }
        Updater.shared.onAvailable = { [weak self] r in
            let img = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Обновление")?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange])) ?? NSImage()
            self?.notify(icon: img, text: r.version, seconds: 4)
        }
        if Prefs.shared.tgNotify { tg.start() }

        Prefs.shared.$style
            .map { $0 == UIStyle.designer.rawValue }
            .removeDuplicates()
            .sink { [weak self] t in
                MainActor.assumeIsolated { self?.model.tall = t }
            }
            .store(in: &bag)

        login.$userCode
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] on in
                MainActor.assumeIsolated { self?.setPinned(on) }
            }
            .store(in: &bag)
    }

    private func setPinned(_ on: Bool) {
        model.pinned = on
        if on {
            peekWork?.cancel()
            model.peeking = false
            model.expanded = true
            panel.ignoresMouseEvents = false
        } else {
            track()
        }
    }

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let p = Prefs.shared
        let up = Updater.shared
        if let r = up.available {
            m.add("Обновить до \(r.version)…") { up.prompt() }
            m.addItem(.separator())
        }
        let player = self.player
        if player.loggedIn {
            let wave: (String, [(String, String)], ReferenceWritableKeyPath<Prefs, String>) -> Void = { title, opts, kp in
                m.submenu(title) { sub in
                    for (name, value) in opts {
                        sub.add(name, checked: p[keyPath: kp] == value) {
                            guard p[keyPath: kp] != value else { return }
                            p[keyPath: kp] = value
                            player.applyWaveSettings()
                        }
                    }
                }
            }
            wave("Настроение", [("Любое", "all"), ("Бодрое", "active"), ("Весёлое", "fun"),
                                ("Спокойное", "calm"), ("Грустное", "sad")], \.mood)
            wave("Характер", [("По умолчанию", "default"), ("Любимое", "favorite"),
                              ("Незнакомое", "discover"), ("Популярное", "popular")], \.diversity)
            wave("Язык", [("Любой", "any"), ("Русский", "russian"), ("Иностранный", "not-russian")], \.language)
            m.addItem(.separator())
        }
        m.submenu("Стиль") { sub in
            for st in UIStyle.allCases {
                sub.add(st.title, checked: p.style == st.rawValue) { p.style = st.rawValue }
            }
        }
        m.add("Показывать смену трека", checked: p.peek) { p.peek.toggle() }
        let tg = self.tg
        m.add("Сообщения Telegram в нотче", checked: p.tgNotify) {
            p.tgNotify.toggle()
            if p.tgNotify { tg.start() } else { tg.stop() }
        }
        let a = actions
        m.add("Запускать при входе", checked: p.launchAtLogin) { a.setLaunchAtLogin(!p.launchAtLogin) }
        m.addItem(.separator())
        if player.loggedIn {
            m.add("Выйти из аккаунта", a.logout)
        } else {
            m.add("Войти через Яндекс", a.login)
            m.add("Вставить токен из буфера", a.pasteToken)
        }
        m.addItem(.separator())
        m.add("Проверить обновления") { up.check(manual: true) }
        let ver = NSMenuItem(title: "Volna \(Updater.current)", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        m.addItem(ver)
        m.add("Закрыть Volna", a.quit)
        return m
    }

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func layout() {
        guard let s = screen else { return }
        let f = s.frame
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            model.notchW = f.width - l.width - r.width
            model.notchH = s.safeAreaInsets.top
        } else {
            model.notchW = 0
            model.notchH = NSStatusBar.system.thickness
        }
        panel.setFrame(NSRect(x: f.midX - panelW / 2, y: f.maxY - panelH, width: panelW, height: panelH), display: true)
    }

    private var expandedRect: NSRect {
        let top = panel.frame.maxY, mid = panel.frame.midX
        let w = model.expandedW + 24, h = model.expandedH + 14
        return NSRect(x: mid - w / 2, y: top - h, width: w, height: h + 2)
    }

    private func track() {
        let p = NSEvent.mouseLocation
        if model.pinned { return }
        if model.peeking {
            // мышь зашла в выехавшую панель — превращаем пик в обычное раскрытие
            if expandedRect.contains(p) {
                peekWork?.cancel()
                model.peeking = false
                panel.ignoresMouseEvents = false
            }
            return
        }
        if model.expanded {
            if !expandedRect.contains(p) { setExpanded(false) }
        } else {
            let top = panel.frame.maxY, mid = panel.frame.midX
            let has = player.current != nil || !player.loggedIn
            let w = max(model.collapsedW(hasTrack: has), 120)
            let r = NSRect(x: mid - w / 2, y: top - model.notchH, width: w, height: model.notchH + 2)
            if r.contains(p) { setExpanded(true) }
        }
    }

    private func setExpanded(_ v: Bool) {
        peekWork?.cancel()
        model.peeking = false
        guard model.expanded != v else { return }
        if v { revealSoon() } else { Reveal.shared.on = false; HoverModel.shared.key = nil }
        model.expanded = v
        panel.ignoresMouseEvents = !v
    }

    /// Сбросить и на следующем цикле включить флаг появления — элементы Emil проявятся по очереди.
    private func revealSoon() {
        Reveal.shared.on = false
        DispatchQueue.main.async { Reveal.shared.on = true }
    }

    /// На ~2.5 с показывает иконку и текст в свёрнутом нотче; если панель раскрыта — не мешаем.
    private func notify(icon: NSImage, text: String, seconds: Double = 2.5) {
        guard !model.expanded || model.peeking else { return }
        if model.peeking {
            peekWork?.cancel()
            model.peeking = false
            model.expanded = false
        }
        model.notice = Notice(icon: icon, text: text)
        noticeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.model.notice = nil }
        }
        noticeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func peek() {
        guard Prefs.shared.peek else { return }
        guard !model.expanded || model.peeking else { return }
        model.peeking = true
        revealSoon()
        model.expanded = true
        peekWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, self.model.peeking else { return }
                self.model.peeking = false
                self.model.expanded = false
            }
        }
        peekWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }
}

// MARK: - Views

/// Форма как у Dynamic Island: сверху «плечи» — вогнутые скругления, которыми панель вливается
/// в край экрана; снизу — настоящие круглые углы (дуги, а не квадратичные кривые).
/// shoulder — ширина плеча с каждой стороны, она добавляется к ширине панели.
struct NotchShape: Shape {
    var radius: CGFloat
    var shoulder: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, shoulder) }
        set { radius = newValue.first; shoulder = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let s = max(0, min(shoulder, r.width / 4, r.height / 2))
        let left = r.minX + s, right = r.maxX - s
        let rad = max(0, min(radius, r.height - s, (right - left) / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        if s > 0 {
            p.addArc(tangent1End: CGPoint(x: left, y: r.minY), tangent2End: CGPoint(x: left, y: r.minY + s), radius: s)
        }
        p.addLine(to: CGPoint(x: left, y: r.maxY - rad))
        p.addArc(tangent1End: CGPoint(x: left, y: r.maxY), tangent2End: CGPoint(x: left + rad, y: r.maxY), radius: rad)
        p.addLine(to: CGPoint(x: right - rad, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: right, y: r.maxY), tangent2End: CGPoint(x: right, y: r.maxY - rad), radius: rad)
        p.addLine(to: CGPoint(x: right, y: r.minY + s))
        if s > 0 {
            p.addArc(tangent1End: CGPoint(x: right, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: s)
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

let accent = Color(red: 1.0, green: 0.53, blue: 0.0)

struct NotchView: View {
    @ObservedObject var player: Player
    @ObservedObject var model: NotchModel
    @ObservedObject var login: DeviceLogin
    @ObservedObject var prefs: Prefs
    let actions: NotchActions
    @ObservedObject private var updater = Updater.shared

    private var showPill: Bool { player.current != nil || !player.loggedIn || model.notice != nil }
    private var width: CGFloat {
        model.expanded ? model.expandedW : model.collapsedW(hasTrack: showPill)
    }
    private var height: CGFloat { model.expanded ? model.expandedH : model.notchH }
    private var style: UIStyle { UIStyle(rawValue: prefs.style) ?? .classic }
    /// фон стиля «Дизайн»: чёрный → #0B0A0A (55%) → #282320, прозрачность 82%
    private var designerBackground: some ShapeStyle {
        LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: Color(red: 11 / 255, green: 10 / 255, blue: 10 / 255), location: 0.553),
            .init(color: Color(red: 40 / 255, green: 35 / 255, blue: 32 / 255), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .opacity(0.82)
    }

    /// круглые нижние углы и вогнутые «плечи» сверху, как у Dynamic Island
    private var cornerRadius: CGFloat {
        guard model.expanded else { return 10 }
        return style == .designer ? 23 : 24
    }
    private var shoulder: CGFloat { model.expanded ? 12 : 6 }

    /// Анимация раскрытия под стиль; при «Уменьшить движение» — короткий ease-out без пружины.
    private var expandAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.15) }
        switch style {
        case .classic: return .spring(response: 0.32, dampingFraction: 0.82)
        case .impeccable: return .spring(response: 0.3, dampingFraction: 1)
        case .taste: return .spring(response: 0.4, dampingFraction: 0.86)
        // Emil: без отскока, закрытие быстрее открытия (асимметрия)
        case .emil, .candy, .designer:
            return model.expanded ? .spring(response: 0.38, dampingFraction: 1) : .spring(response: 0.24, dampingFraction: 1)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // фон с плечами — шире контента на 2×shoulder
                NotchShape(radius: cornerRadius, shoulder: shoulder)
                    .fill(style == .designer && model.expanded && player.loggedIn
                          ? AnyShapeStyle(designerBackground) : AnyShapeStyle(Color.black))
                    .frame(width: width + 2 * shoulder, height: height)
                if style == .taste && model.expanded && player.loggedIn {
                    NotchShape(radius: cornerRadius, shoulder: shoulder)
                        .fill(LinearGradient(colors: [Color.black, (player.tint ?? accent).opacity(0.45)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: width + 2 * shoulder, height: height)
                        .transition(.opacity)
                }
                ZStack(alignment: .top) {
                if model.expanded && style == .designer && player.loggedIn {
                    DesignerExpanded(player: player).transition(.opacity)
                } else if model.expanded {
                    expandedContent.transition(.opacity)
                } else if showPill {
                    collapsedContent.transition(.opacity)
                }
                // справа от выреза: есть обновление — маленькая кнопка с версией
                if model.expanded, let r = updater.available {
                    HStack {
                        Spacer()
                        Button { updater.prompt() } label: {
                            Label(r.version, systemImage: "arrow.down.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(accent)
                        }
                        .buttonStyle(PressStyle())
                        .help("Вышла Volna \(r.version) — что нового и обновить")
                        .padding(.trailing, 18)
                    }
                    .frame(height: max(model.notchH - 6, 18))
                    .transition(.opacity)
                }
                }
                .frame(width: width, height: height)
                .clipShape(NotchShape(radius: cornerRadius))
            }
            .frame(width: width + 2 * shoulder, height: height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(expandAnimation, value: model.expanded)
        .animation(.easeOut(duration: 0.4), value: player.tint)
        .animation(.easeInOut(duration: 0.25), value: player.current?.id)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.notice)
        .foregroundColor(.white)
    }

    // MARK: свёрнуто

    @ViewBuilder private var collapsedContent: some View {
        if let n = model.notice {
            HStack(spacing: 0) {
                Image(nsImage: n.icon)
                    .resizable()
                    .frame(width: model.notchH - 8, height: model.notchH - 8)
                    .padding(.leading, 8)
                Spacer(minLength: 0)
                Text(n.text)
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundColor(accent)
                    .padding(.trailing, 12)
            }
            .frame(height: model.notchH)
            .contentShape(Rectangle())
            .onTapGesture { TelegramWatcher.open() }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else {
            trackPill
        }
    }

    private var trackPill: some View {
        HStack(spacing: 0) {
            CoverView(image: player.cover, size: model.notchH - 10, radius: 5)
                .padding(.leading, 9)
            Spacer(minLength: 0)
            Group {
                switch style {
                case .taste:
                    MiniWave(playing: player.isPlaying, meter: player.meter, color: player.tint ?? accent)
                case .impeccable, .candy, .designer:
                    Bars(playing: player.isPlaying, meter: player.meter, color: Color.white.opacity(0.85))
                default:
                    Bars(playing: player.isPlaying, meter: player.meter)
                }
            }
            .frame(width: 23, height: model.notchH - 12)
            .padding(.trailing, 9)
        }
        .frame(height: model.notchH)
    }

    // MARK: раскрыто

    private var expandedContent: some View {
        VStack(spacing: 12) {
            Color.clear.frame(height: max(model.notchH - 6, 0))
            if player.loggedIn {
                switch style {
                case .classic:
                    trackRow
                    controls
                case .impeccable:
                    ImpeccableExpanded(player: player)
                case .taste:
                    TasteExpanded(player: player)
                case .emil:
                    EmilExpanded(player: player)
                case .candy, .designer:
                    CandyExpanded(player: player)
                }
            } else {
                loginBlock
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    private var trackRow: some View {
        HStack(spacing: 12) {
            CoverView(image: player.cover, size: 52, radius: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(player.current?.title ?? "—")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let s = player.status {
                    Text(s).font(.system(size: 11)).foregroundColor(accent).lineLimit(1)
                } else {
                    Text(player.current?.artists ?? "")
                        .font(.system(size: 11)).foregroundColor(.gray).lineLimit(1)
                }
                ProgressLine(position: player.position, duration: player.duration) { player.seek(fraction: $0) }
                    .padding(.top, 3)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            btn("hand.thumbsdown", 14) { player.dislike() }
            Spacer()
            btn("backward.fill", 16) { player.prev() }
            Spacer()
            btn(player.isPlaying ? "pause.fill" : "play.fill", 22) { player.toggle() }
            Spacer()
            btn("forward.fill", 16) { player.next() }
            Spacer()
            btn(player.liked ? "heart.fill" : "heart", 15, tint: player.liked ? accent : .white) { player.toggleLike() }
        }
        .padding(.horizontal, 26)
    }

    @ViewBuilder private var loginBlock: some View {
        if let code = login.userCode {
            VStack(spacing: 6) {
                Text("Подтверди вход в браузере — код уже скопирован")
                    .font(.system(size: 11)).foregroundColor(.gray)
                Text(code)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
                    .onTapGesture { login.copyCode() }
                HStack(spacing: 14) {
                    Button("Открыть страницу") { login.reopen() }.buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                    Button("Отмена") { login.cancel() }.buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundColor(.gray)
                }
            }
        } else {
            VStack(spacing: 8) {
                Text(login.error ?? player.status ?? "Яндекс Музыка: нужен вход")
                    .font(.system(size: 12))
                    .foregroundColor(login.error == nil && player.status == nil ? .gray : accent)
                    .lineLimit(2).multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button(action: actions.login) {
                        Text("Войти через Яндекс").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(accent))
                    }.buttonStyle(.plain)
                    Button(action: actions.pasteToken) {
                        Text("Токен из буфера").font(.system(size: 12))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().stroke(Color.gray, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                Text("Яндекс попросит доступ к Диску — это стандартные права приложения Музыки, Volna Диск не трогает")
                    .font(.system(size: 9)).foregroundColor(.gray)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
        }
    }

    private func btn(_ icon: String, _ size: CGFloat, tint: Color = .white, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CoverView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundColor(.gray)
                }
            }
        }
        .frame(width: max(size, 1), height: max(size, 1))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct Bars: View {
    let playing: Bool
    let meter: LevelMeter
    var color: Color = accent

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing)) { _ in
            let l = playing ? meter.frame() : [Float](repeating: 0, count: LevelMeter.bands)
            GeometryReader { g in
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<LevelMeter.bands, id: \.self) { i in
                        Capsule()
                            .fill(color.opacity(0.55 + 0.45 * Double(l[i])))
                            .frame(width: 3, height: 3 + (g.size.height - 3) * CGFloat(l[i]))
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
    }
}

struct ProgressLine: View {
    let position: Double
    let duration: Double
    let onSeek: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(fmt(position)).font(.system(size: 9).monospacedDigit()).foregroundColor(.gray)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(Color.white)
                        .frame(width: duration > 0 ? g.size.width * CGFloat(min(position / duration, 1)) : 0)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { loc in
                    onSeek(Double(loc.x / max(g.size.width, 1)))
                }
            }
            .frame(height: 12)
            Text(fmt(duration)).font(.system(size: 9).monospacedDigit()).foregroundColor(.gray)
        }
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let i = Int(s)
        return String(format: "%d:%02d", i / 60, i % 60)
    }
}
