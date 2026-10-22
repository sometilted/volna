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
    /// нотч раскрыт в поиск: держит клавиатуру, не сворачивается от мыши
    @Published var searching = false
    /// короткое уведомление в свёрнутом нотче (иконка + текст)
    @Published var notice: Notice?
    /// громкость / яркость — показываем ~1.5 с вместо системной плашки
    @Published var hud: HUD?
    @Published var notchW: CGFloat = 0
    @Published var notchH: CGFloat = 32
    let expandedW: CGFloat = 400
    /// от стиля зависит высота: @opiatolove — макет 400×177 pt, Стекло — карточка под нотчем
    @Published var kind = UIStyle.candy
    /// смена стиля: панель целиком прячется в вырез, потом раскрывается уже новым стилем
    @Published var switching = false
    var expandedH: CGFloat {
        switch kind {
        case .designer: return max(177, notchH + 112) + designerShift
        case .glass: return notchH + 184
        default: return notchH + 136
        }
    }
    /// макет дизайнера рассчитан на низкий вырез: если текст залезает под вырез — сдвигаем всё вниз
    var designerShift: CGFloat { max(0, notchH + 10 - 30.5) }

    func collapsedW(hasTrack: Bool) -> CGFloat {
        guard hasTrack else { return notchW }
        return max(notchW, 60) + 2 * (notchH + 4)
    }
}

/// Клавиатуру панель берёт только после клика по раскрытому нотчу (для хоткеев) и отдаёт,
/// как только нотч свернулся или нажата любая не наша клавиша — та пересылается обратно в систему.
final class NotchPanel: NSPanel {
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
}

/// Команды из SwiftUI в контроллер (шестерёнка открывает то же меню, что правый клик).
@MainActor
final class NotchCommands {
    static let shared = NotchCommands()
    var openMenu: (() -> Void)?
}

@MainActor
protocol MenuSource: AnyObject {
    func popMenu(with event: NSEvent, for view: NSView) -> Bool
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    weak var menuSource: MenuSource?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) {
        if menuSource?.popMenu(with: event, for: self) != true {
            super.rightMouseDown(with: event)
        }
    }
}

/// NSMenuItem с замыканием вместо target/selector
final class MenuAction: NSObject {
    let fn: () -> Void
    init(_ fn: @escaping () -> Void) { self.fn = fn }
    /// Выполняется после закрытия меню: иначе перестройка панели под ним может съесть выбор.
    @objc func fire() {
        let fn = self.fn
        DispatchQueue.main.async { fn() }
    }
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
    private let calls = CallWatcher()
    private let keys = MediaKeys()
    private var hudWork: DispatchWorkItem?
    private let actions: NotchActions
    private let panelW: CGFloat = 440
    private let panelH: CGFloat = 420
    /// пока открыто контекстное меню, наведение не сворачивает панель (курсор уходит в меню)
    private var menuOpen = false

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
        // клик по раскрытому нотчу — берём клавиатуру для хоткеев
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            MainActor.assumeIsolated {
                guard let self = self, e.window === self.panel, self.model.expanded else { return }
                self.panel.allowKey = true
                self.panel.makeKey()
            }
            return e
        }) { monitors.append(m) }
        // клик мимо нотча — закрыть поиск
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { if self?.model.searching == true { self?.closeSearch() } }
        }) { monitors.append(m) }
        let sm = SearchModel.shared
        sm.player = player
        sm.onOpen = { [weak self] in self?.openSearch() }
        sm.onClose = { [weak self] in self?.closeSearch() }
        NotchCommands.shared.openMenu = { [weak self] in
            guard let self = self, let e = NSApp.currentEvent, let v = self.panel.contentView else { return }
            _ = self.popMenu(with: e, for: v)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            MainActor.assumeIsolated { (self?.handleKey(e) ?? false) ? nil : e }
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
        // авто-пауза молча: без всплывашек в нотче
        calls.onChange = { [weak self] busy in _ = self?.player.micChanged(busy) }
        calls.onOther = { [weak self] on, _ in _ = self?.player.otherAudio(on) }
        calls.update(mic: Prefs.shared.callPause, other: Prefs.shared.otherPause)
        keys.onChange = { [weak self] h in self?.showHUD(h) }
        if Prefs.shared.hudKeys { keys.start() }

        Prefs.shared.$style
            .map { UIStyle.from($0) }
            .removeDuplicates()
            .sink { [weak self] k in
                MainActor.assumeIsolated { self?.model.kind = k }
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

    func popMenu(with event: NSEvent, for view: NSView) -> Bool {
        menuOpen = true
        NSMenu.popUpContextMenu(buildMenu(), with: event, for: view)   // блокирует до закрытия
        menuOpen = false
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.track() } }
        return true
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
            // что играть
            m.add("Моя волна", checked: player.source == .wave) { player.playWave() }
            m.add("Мне нравится", checked: player.source == .list("Мне нравится")) { player.playLikes() }
            let lists = player.playlists.filter { $0.count > 0 }
            if !lists.isEmpty {
                m.submenu("Плейлисты") { sub in
                    for pl in lists {
                        sub.add("\(pl.title) · \(pl.count)", checked: player.source == .list(pl.title)) {
                            player.playPlaylist(pl)
                        }
                    }
                }
            }
            let s = m.add("Поиск…") { [weak self] in self?.openSearch() }
            s.keyEquivalent = "f"
            s.keyEquivalentModifierMask = .command
            m.add("Вперемешку", checked: p.shuffle) { p.shuffle.toggle() }
            m.addItem(.separator())
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
        // стили — сразу в меню, без подменю: один клик
        let head = NSMenuItem(title: "Стиль", action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        for (i, st) in UIStyle.allCases.enumerated() {
            let it = m.add("   " + st.title, checked: p.style == st.rawValue) { [weak self] in self?.switchStyle(st) }
            it.keyEquivalent = "\(i + 1)"
            it.keyEquivalentModifierMask = .command
        }
        m.addItem(.separator())
        m.add("Выравнивать громкость", checked: p.normalize) {
            p.normalize.toggle()
            player.applyNormalize()
        }
        let calls = self.calls
        m.add("Пауза на созвонах", checked: p.callPause) {
            p.callPause.toggle()
            calls.update(mic: p.callPause, other: p.otherPause)
        }
        m.add("Пауза, когда играет другое", checked: p.otherPause) {
            p.otherPause.toggle()
            calls.update(mic: p.callPause, other: p.otherPause)
        }
        m.add("Показывать смену трека", checked: p.peek) { p.peek.toggle() }
        let keys = self.keys
        m.add("Громкость и яркость в нотче", checked: p.hudKeys) {
            p.hudKeys.toggle()
            if p.hudKeys { keys.start() } else { keys.stop() }
        }
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
        if model.pinned || menuOpen || model.switching || model.searching { return }
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

    /// ⌘1…⌘4 — стиль, пробел — пауза, ←/→ — трек, Esc — свернуть.
    /// Любая другая клавиша: отдаём фокус и пересылаем её системе — она попадёт туда, где печатали.
    private func handleKey(_ e: NSEvent) -> Bool {
        guard e.window === panel, !model.searching else { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == .command, e.charactersIgnoringModifiers == "f", player.loggedIn {
            openSearch()
            return true
        }
        if mods == .command, let c = e.charactersIgnoringModifiers, let n = Int(c),
           n >= 1, n <= UIStyle.allCases.count {
            switchStyle(UIStyle.allCases[n - 1])
            return true
        }
        if mods.isEmpty {
            switch e.keyCode {
            case 49: player.toggle(); return true
            case 123: player.prev(); return true
            case 124: player.next(); return true
            case 53: setExpanded(false); return true
            default: break
            }
        }
        let cg = e.cgEvent
        releaseKey()
        DispatchQueue.main.async { cg?.post(tap: .cghidEventTap) }
        return true
    }

    /// Нотч раскрывается в поиск и берёт клавиатуру (панель не активирует приложение — как Spotlight).
    func openSearch() {
        guard player.loggedIn else { return }
        peekWork?.cancel()
        model.peeking = false
        SearchModel.shared.reset()
        model.searching = true
        model.expanded = true
        panel.ignoresMouseEvents = false
        panel.allowKey = true
        panel.makeKey()
    }

    func closeSearch() {
        guard model.searching else { return }
        model.searching = false
        releaseKey()
        // мышь уже не над нотчем — свернуть
        if !expandedRect.contains(NSEvent.mouseLocation) { setExpanded(false) }
    }

    /// Вернуть клавиатуру приложению, в котором работали.
    private func releaseKey() {
        panel.allowKey = false
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    private func setExpanded(_ v: Bool) {
        peekWork?.cancel()
        model.peeking = false
        if !v { model.searching = false; releaseKey() }
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

    /// Громкость / яркость: свёрнутый нотч расширяется и показывает значение, через 1.5 с без нажатий — прячет.
    private func showHUD(_ h: HUD) {
        model.hud = h
        hudWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.model.hud = nil }
        }
        hudWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
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

    /// Прячет панель в вырез (~0.4 с), меняет стиль и раскрывает уже новым на 3 с (как смена трека).
    private func switchStyle(_ st: UIStyle) {
        guard Prefs.shared.style != st.rawValue else { return }
        peekWork?.cancel()
        model.peeking = false
        model.switching = true
        model.expanded = false
        panel.ignoresMouseEvents = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
            MainActor.assumeIsolated {
                Prefs.shared.style = st.rawValue
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    MainActor.assumeIsolated {
                        guard let self = self else { return }
                        self.model.switching = false
                        self.peek(force: true, seconds: 3)
                    }
                }
            }
        }
    }

    private func peek(force: Bool = false, seconds: Double = 2.5) {
        guard force || Prefs.shared.peek else { return }
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
                self.releaseKey()
            }
        }
        peekWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
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


struct NotchView: View {
    @ObservedObject var player: Player
    @ObservedObject var model: NotchModel
    @ObservedObject var login: DeviceLogin
    @ObservedObject var prefs: Prefs
    let actions: NotchActions
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var search = SearchModel.shared

    private var showPill: Bool { player.current != nil || !player.loggedIn || model.notice != nil || model.hud != nil }
    /// на сколько шире свёрнутый нотч, пока показывает громкость / яркость
    private var hudExtra: CGFloat { model.hud != nil && !model.expanded ? 110 : 0 }
    private var style: UIStyle { UIStyle.from(prefs.style) }
    /// Стекло: свёрнуто — два стёклышка слева и справа от выреза, раскрыто — одно цельное стекло
    private var glassMode: Bool { style == .glass && player.loggedIn }
    /// уведомление Telegram в свёрнутом виде показываем обычной чёрной таблеткой
    private var useGlass: Bool {
        glassMode && !model.switching && (model.expanded || (model.notice == nil && model.hud == nil))
    }
    private var grown: Bool { model.expanded && !model.switching }
    /// свернуться в голый вырез при смене стиля
    private var bare: Bool { model.switching }
    private var width: CGFloat {
        if bare { return model.notchW }
        return grown ? model.expandedW : model.collapsedW(hasTrack: showPill) + hudExtra
    }
    private var height: CGFloat { grown ? model.expandedH : model.notchH }
    /// фон стиля «@opiatolove»: чёрный → #0B0A0A (55%) → #282320, непрозрачный
    private var designerBackground: some ShapeStyle {
        LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: Color(red: 11 / 255, green: 10 / 255, blue: 10 / 255), location: 0.553),
            .init(color: Color(red: 40 / 255, green: 35 / 255, blue: 32 / 255), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    /// круглые нижние углы и вогнутые «плечи» сверху, как у Dynamic Island
    private var cornerRadius: CGFloat {
        guard grown else { return 10 }
        return style == .designer ? 23 : 24
    }
    private var shoulder: CGFloat { grown ? 12 : 6 }

    /// Раскрытие: мягкая пружина ~0.5 с с едва заметным дотягом, закрытие короче и без отскока.
    /// Контент проявляется с задержкой — сначала форма, потом содержимое (см. contentIn).
    private var expandAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.2) }
        guard model.expanded else { return .spring(response: 0.38, dampingFraction: 1) }
        switch style {
        case .taste: return .spring(response: 0.52, dampingFraction: 0.84)
        default: return .spring(response: 0.5, dampingFraction: 0.9)
        }
    }

    /// содержимое раскрытой панели: появляется, когда форма уже почти раскрылась; уходит сразу
    private var contentIn: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                .animation(.easeOut(duration: 0.28).delay(reduceMotion ? 0 : 0.12)),
            removal: .opacity.animation(.easeIn(duration: 0.1)))
    }

    var body: some View {
        Group {
            if model.searching { searchBody.transition(.opacity) }
            else if useGlass { glassBody.transition(.opacity) } else { solidBody }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(expandAnimation, value: model.expanded)
        .animation(.spring(response: 0.38, dampingFraction: 1), value: model.switching)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: model.searching)
        .animation(.easeOut(duration: 0.4), value: player.tint)
        .animation(.easeInOut(duration: 0.25), value: player.current?.id)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.notice)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.hud != nil)
        .foregroundColor(.white)
    }

    // MARK: превью смены трека

    /// Новый трек: крупная обложка, название и исполнитель крупно, без кнопок.
    /// Мышь зашла в нотч — превью превращается в обычную панель с управлением.
    private func peekContent(top: CGFloat) -> some View {
        let side = max(min(model.expandedH - top - 14, 120), 60)
        return VStack(spacing: 0) {
            Color.clear.frame(height: top)
            HStack(spacing: 16) {
                CoverView(image: player.cover, size: side, radius: side * 0.14)
                    .shadow(color: Color.black.opacity(0.45), radius: 12, y: 5)
                VStack(alignment: .leading, spacing: 5) {
                    Text(player.current?.title ?? "")
                        .font(.system(size: 20, weight: .bold))
                        .tracking(-0.4)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    Text(player.current?.artists ?? "")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if case .list(let name) = player.source {
                        Text(name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.45))
                            .lineLimit(1)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 22)
            Spacer(minLength: 0)
        }
        .id(player.current?.id)
    }

    // MARK: поиск

    private var searchBody: some View {
        let empty = search.query.trimmingCharacters(in: .whitespaces).isEmpty
        let rows = search.shown.count
        let h = SearchPanel.height(notchH: model.notchH, rows: rows, header: empty && rows > 0)
        let w = model.expandedW + 20
        return ZStack(alignment: .top) {
            NotchShape(radius: 24, shoulder: 12)
                .fill(style == .designer ? AnyShapeStyle(designerBackground) : AnyShapeStyle(Color.black))
                .frame(width: w + 24, height: h)
            SearchPanel(model: search, player: player, top: model.notchH + 8, accent: accent)
                .frame(width: w, height: h)
                .clipShape(NotchShape(radius: 24))
        }
        .frame(width: w + 24, height: h)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: h)
    }

    /// Верхний ряд по бокам выреза — зеркало нижнего: лупа над дизлайком, шестерёнка над лайком,
    /// тот же размер и тот же отступ от края; по высоте — по центру полосы выреза.
    /// Есть обновление — кнопка с версией рядом с шестерёнкой.
    private var cornerButtons: some View {
        HStack(spacing: 4) {
            EmilButton(icon: "magnifyingglass", label: "Поиск (⌘F)", size: 13, dim: true) { search.open() }
            Spacer()
            if let r = updater.available {
                Button { updater.prompt() } label: {
                    Label(r.version, systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(accent)
                }
                .buttonStyle(PressStyle())
                .help("Вышла Volna \(r.version) — что нового и обновить")
            }
            EmilButton(icon: "gearshape", label: "Настройки", size: 13, dim: true) { NotchCommands.shared.openMenu?() }
        }
        .padding(.horizontal, 20)
        .frame(width: model.expandedW, height: model.notchH)
    }

    // MARK: стекло

    private var glassBody: some View {
        let e = model.expanded
        let has = player.current != nil
        let ch = max(model.notchH - 6, 16)              // высота боковых стёклышек
        let sw = ch + 8                                  // их ширина
        let sideX = model.notchW / 2 + 6 + sw / 2        // центр стёклышка от центра выреза
        return ZStack(alignment: .top) {
            GlassShell(expanded: e, visible: e || has, W: model.expandedW, H: model.expandedH,
                       sw: sw, ch: ch, sideX: sideX)
            // сам вырез — чёрный, стекло его обтекает
            NotchShape(radius: 10, shoulder: 6)
                .fill(Color.black)
                .frame(width: model.notchW + 12, height: model.notchH)
            if e && model.peeking && player.current != nil {
                peekContent(top: model.notchH + 12)
                    .frame(width: model.expandedW)
                    .transition(contentIn)
            } else if e {
                GlassExpanded(player: player, top: model.notchH + 14)
                    .frame(width: model.expandedW)
                    .transition(contentIn)
                cornerButtons.transition(.opacity)
            } else if has {
                CoverView(image: player.cover, size: ch - 8, radius: 6)
                    .offset(x: -sideX, y: 3 + 4)
                    .transition(.opacity)
                Visualizer(style: .glass, playing: player.isPlaying, meter: player.meter)
                    .frame(width: sw - 12, height: ch - 12)
                    .offset(x: sideX, y: 3 + 6)
                    .transition(.opacity)
            }
        }
        .frame(width: model.expandedW + 24, height: model.expandedH, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var solidBody: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // фон с плечами — шире контента на 2×shoulder
                NotchShape(radius: cornerRadius, shoulder: shoulder)
                    .fill(style == .designer && model.expanded && player.loggedIn
                          ? AnyShapeStyle(designerBackground) : AnyShapeStyle(Color.black))
                    .frame(width: width + 2 * shoulder, height: height)
                if style == .taste && model.expanded && player.loggedIn {
                    SunsetGlow(playing: player.isPlaying, meter: player.meter, tint: player.tint ?? accent,
                               blackTo: model.notchH / max(height, 1))
                        .clipShape(NotchShape(radius: cornerRadius, shoulder: shoulder))
                        .frame(width: width + 2 * shoulder, height: height)
                        .transition(.opacity)
                }
                ZStack(alignment: .top) {
                if bare {
                    Color.clear
                } else if model.expanded && model.peeking && player.current != nil {
                    peekContent(top: model.notchH + 10).transition(contentIn)
                } else if model.expanded && style == .designer && player.loggedIn {
                    DesignerExpanded(player: player)
                        .padding(.top, model.designerShift)
                        .transition(contentIn)
                } else if model.expanded {
                    expandedContent.transition(contentIn)
                } else if showPill {
                    collapsedContent.transition(.opacity)
                }
                if grown && player.loggedIn && !model.peeking {
                    cornerButtons.transition(.opacity)
                }
                }
                .frame(width: width, height: height)
                .clipShape(NotchShape(radius: cornerRadius))
                .id(prefs.style)   // смена стиля — пересобрать содержимое с новым акцентом
            }
            .frame(width: width + 2 * shoulder, height: height)
            Spacer(minLength: 0)
        }
    }

    // MARK: свёрнуто

    @ViewBuilder private var collapsedContent: some View {
        if let h = model.hud {
            hudView(h)
        } else if let n = model.notice {
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

    /// Слева от выреза — иконка и проценты, справа — полоска в цвете акцента.
    private func hudView(_ h: HUD) -> some View {
        let icon: String
        switch h.kind {
        case .volume:
            icon = h.muted ? "speaker.slash.fill"
                : h.value < 0.34 ? "speaker.wave.1.fill" : h.value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .brightness:
            icon = h.value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
        let shown = h.muted ? 0 : h.value
        return HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(h.muted ? Color.white.opacity(0.5) : .white)
                .frame(width: 22)
                .padding(.leading, 12)
                .modifier(SymbolSwap())
            Text(h.muted ? "выкл" : "\(Int((shown * 100).rounded()))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(Color.white.opacity(0.75))
                .frame(width: 36, alignment: .leading)
                .padding(.leading, 4)
            Spacer(minLength: 0)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(accent)
                        .frame(width: g.size.width * CGFloat(shown))
                }
            }
            .frame(width: 70, height: 5)
            .padding(.trailing, 14)
        }
        .frame(height: model.notchH)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: h)
        .transition(.opacity)
    }

    private var trackPill: some View {
        HStack(spacing: 0) {
            CoverView(image: player.cover, size: model.notchH - 10, radius: 5)
                .padding(.leading, 9)
            Spacer(minLength: 0)
            Visualizer(style: style, playing: player.isPlaying, meter: player.meter, tint: player.tint)
            .frame(width: 23, height: model.notchH - 12)
            .padding(.trailing, 9)
        }
        .frame(height: model.notchH)
    }

    // MARK: раскрыто

    private var expandedContent: some View {
        VStack(spacing: 12) {
            // явный отступ от выреза до трека
            Color.clear.frame(height: model.notchH + 6)
            if player.loggedIn {
                switch style {
                case .taste:
                    TasteExpanded(player: player)
                case .candy, .designer, .glass:
                    CandyExpanded(player: player, style: style)
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
    static let count = 5
    let playing: Bool
    let meter: LevelMeter
    var color: Color = accent

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing)) { _ in
            let m = playing ? meter.frame() : meter.idle()
            let l = m.bars(Self.count)
            GeometryReader { g in
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<Self.count, id: \.self) { i in
                        // удар подбрасывает все столбики, сильнее — низкие
                        let v = min(CGFloat(l[i]) + CGFloat(m.kick) * (0.3 - 0.05 * CGFloat(i)), 1)
                        Capsule()
                            .fill(color.opacity(0.5 + 0.5 * Double(v)))
                            .frame(width: 3, height: 3 + (g.size.height - 3) * v)
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
