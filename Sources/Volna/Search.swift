import AppKit
import SwiftUI

/// Поиск прямо в нотче: нотч раскрывается в строку поиска и список результатов — исполнители и треки.
/// Enter — сыграть выбранное (исполнитель — его популярные треки), ⇧Enter — трек следующим.
/// Если результаты ещё от старого запроса — Enter сначала ищет новый. ↑/↓ — выбор, Esc — закрыть.
/// Пустая строка — недавние треки из поиска. У строки трека справа: сыграть, следующим, лайк.

enum SearchHit: Equatable {
    case track(Track)
    case artist(YaAPI.Artist)

    var trackID: String? {
        if case .track(let t) = self { return t.id }
        return nil
    }

    var key: String {
        switch self {
        case .track(let t): return "t" + t.key
        case .artist(let a): return "a" + a.id
        }
    }
}

@MainActor
final class SearchModel: ObservableObject {
    static let shared = SearchModel()

    @Published private(set) var query = ""
    @Published private(set) var results: [SearchHit] = []
    /// запрос, к которому относятся results
    @Published private(set) var resultsFor = ""
    @Published private(set) var busy = false
    @Published var selected = 0
    @Published private(set) var history: [Track] = []
    /// трек, только что поставленный следующим — строка коротко показывает «✓ следующим»
    @Published private(set) var queuedKey: String?

    weak var player: Player?
    /// открыть / закрыть поиск — выставляет NotchController
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    private var debounce: DispatchWorkItem?
    private var task: Task<Void, Never>?
    private static let historyKey = "searchHistory"
    static let maxRows = 7

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.historyKey),
           let h = try? JSONDecoder().decode([Track].self, from: d) {
            history = h
        }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    var isEmptyQuery: Bool { trimmed.isEmpty }
    /// что показываем: пустой запрос — недавние, иначе результаты (только для текущего запроса)
    var shown: [SearchHit] {
        if trimmed.isEmpty { return Array(history.prefix(Self.maxRows)).map { .track($0) } }
        return resultsFor == trimmed ? results : []
    }

    func open() { onOpen?() }
    func close() { onClose?() }

    func reset() {
        task?.cancel()
        debounce?.cancel()
        query = ""
        results = []
        resultsFor = ""
        busy = false
        selected = 0
        queuedKey = nil
    }

    func textChanged(_ q: String) {
        query = q
        selected = 0
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.run(then: nil) }
        }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: w)
    }

    /// Enter / ⇧Enter
    func submit(next: Bool) {
        let list = shown
        if !list.isEmpty {
            let h = list[min(selected, list.count - 1)]
            if next, case .track(let t) = h { queueNext(t) } else { play(h) }
        } else if !trimmed.isEmpty {
            debounce?.cancel()
            run(then: next ? .next : .play)
        }
    }

    func move(_ d: Int) {
        let n = shown.count
        guard n > 0 else { return }
        selected = min(max(selected + d, 0), n - 1)
    }

    func play(_ h: SearchHit) {
        switch h {
        case .track(let t):
            remember(t)
            player?.playNow(t)
        case .artist(let a):
            player?.playArtist(a)
        }
        close()
    }

    /// Следующим — поиск не закрывается, можно набрать очередь из нескольких.
    func queueNext(_ t: Track) {
        remember(t)
        player?.playNext(t)
        let k = SearchHit.track(t).key
        queuedKey = k
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            MainActor.assumeIsolated { if self?.queuedKey == k { self?.queuedKey = nil } }
        }
    }

    func like(_ t: Track) { player?.toggleLike(t) }

    private func remember(_ t: Track) {
        history.removeAll { $0.id == t.id }
        history.insert(t, at: 0)
        if history.count > 8 { history.removeLast(history.count - 8) }
        if let d = try? JSONEncoder().encode(history) { UserDefaults.standard.set(d, forKey: Self.historyKey) }
    }

    private enum After { case play, next }

    /// Исполнители сверху, если Яндекс считает их лучшим совпадением или имя похоже на запрос; иначе — после треков.
    private func run(then after: After?) {
        task?.cancel()
        let q = trimmed
        guard q.count >= 2, let player = player else {
            busy = false
            return
        }
        busy = true
        task = Task {
            let r = await player.search(q)
            guard !Task.isCancelled, trimmed == q else { return }
            // похожесть имени: без регистра, пробелов и знаков, плюс варианты раскладки / транслита запроса
            func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
            let qs = ([q] + Translit.variants(q)).map(norm).filter { !$0.isEmpty }
            let named = r.artists.filter { a in
                let n = norm(a.name)
                return !n.isEmpty && qs.contains { $0.contains(n) || n.contains($0) }
            }
            let artists = Array((named.isEmpty && r.bestArtist ? Array(r.artists.prefix(1)) : named).prefix(2))
            var hits = artists.map { SearchHit.artist($0) }
            hits += r.tracks.prefix(Self.maxRows - hits.count).map { SearchHit.track($0) }
            results = hits
            resultsFor = q
            selected = 0
            busy = false
            if let after = after, let first = hits.first {
                if after == .next, case .track(let t) = first { queueNext(t) } else { play(first) }
            }
        }
    }
}

/// У приложения без меню «Правка» ⌘A/⌘X/⌘C/⌘V/⌘Z до поля не доходят — отправляем их сами.
final class EditField: NSTextField {
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .command || mods == [.command, .shift], let c = e.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: e)
        }
        let sel: Selector?
        switch c {
        case "a": sel = #selector(NSText.selectAll(_:))
        case "x": sel = #selector(NSText.cut(_:))
        case "c": sel = #selector(NSText.copy(_:))
        case "v": sel = #selector(NSText.paste(_:))
        case "z": sel = mods.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        default: sel = nil
        }
        if let sel = sel, NSApp.sendAction(sel, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: e)
    }
}

/// NSTextField вместо TextField: сразу получает фокус, ловит Enter / ↑ / ↓ / Esc.
struct SearchField: NSViewRepresentable {
    let model: SearchModel

    func makeNSView(context: Context) -> NSTextField {
        let f = EditField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 15, weight: .medium)
        f.textColor = .white
        f.cell?.usesSingleLineMode = true
        f.cell?.lineBreakMode = .byTruncatingTail
        f.placeholderAttributedString = NSAttributedString(string: "Трек или исполнитель", attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.38),
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        ])
        f.delegate = context.coordinator
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != model.query { f.stringValue = model.query }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: SearchModel
        init(model: SearchModel) { self.model = model }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            model.textChanged(f.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                model.submit(next: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
                return true
            case #selector(NSResponder.moveUp(_:)): model.move(-1); return true
            case #selector(NSResponder.moveDown(_:)): model.move(1); return true
            case #selector(NSResponder.cancelOperation(_:)): model.close(); return true
            default: return false
            }
        }
    }
}

/// Содержимое раскрытого нотча в режиме поиска.
struct SearchPanel: View {
    @ObservedObject var model: SearchModel
    @ObservedObject var player: Player
    let top: CGFloat
    let accent: Color

    static let rowH: CGFloat = 44

    /// высота под текущий список — нотч растёт и сжимается вместе с результатами
    static func height(notchH: CGFloat, rows: Int, header: Bool) -> CGFloat {
        notchH + 8 + 38 + 8 + (header ? 20 : 0) + CGFloat(max(min(rows, SearchModel.maxRows), 1)) * rowH + 12
    }

    var body: some View {
        let list = model.shown
        let empty = model.isEmptyQuery
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: top)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(accent)
                SearchField(model: model).frame(height: 22)
                if model.busy {
                    ProgressView().controlSize(.small).environment(\.colorScheme, .dark)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.09)))
            .padding(.bottom, 8)
            if empty && !list.isEmpty {
                Text("Недавние")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.45))
                    .frame(height: 20, alignment: .leading)
                    .padding(.leading, 6)
            }
            if list.isEmpty {
                Text(empty ? "Трек или исполнитель · Enter — сыграть, ⇧Enter — следующим"
                           : (model.busy ? "Ищу…" : "Enter — искать"))
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.45))
                    .frame(height: Self.rowH)
                    .padding(.leading, 6)
            }
            ForEach(Array(list.enumerated()), id: \.element.key) { i, h in
                SearchRow(hit: h, selected: i == model.selected, accent: accent,
                          liked: h.trackID.map { player.likes.contains($0) } ?? false,
                          queued: model.queuedKey == h.key, model: model)
                    .contentShape(Rectangle())
                    .onTapGesture { model.play(h) }
                    .onHover { if $0 { model.selected = i } }
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .animation(.easeOut(duration: 0.15), value: model.selected)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: list.map(\.key))
    }
}

struct SearchRow: View {
    let hit: SearchHit
    let selected: Bool
    let accent: Color
    let liked: Bool
    let queued: Bool
    let model: SearchModel

    var body: some View {
        HStack(spacing: 10) {
            switch hit {
            case .track(let t):
                cover(t.coverURL(100), round: false)
                titles(t.title, t.artists)
                Spacer(minLength: 0)
                if queued {
                    Label("следующим", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(accent)
                        .transition(.opacity)
                } else if selected {
                    HStack(spacing: 2) {
                        RowButton(icon: "play.fill", help: "Сыграть сейчас (Enter)", tint: .white) { model.play(hit) }
                        RowButton(icon: "text.line.first.and.arrowtriangle.forward", help: "Следующим (⇧Enter)", tint: .white) {
                            model.queueNext(t)
                        }
                        RowButton(icon: liked ? "heart.fill" : "heart", help: liked ? "Убрать из любимых" : "Нравится",
                                  tint: liked ? accent : .white) { model.like(t) }
                    }
                    .transition(.opacity)
                } else {
                    if liked {
                        Image(systemName: "heart.fill").font(.system(size: 10)).foregroundColor(accent)
                    }
                    Text(fmtTime(Double(t.durationMs) / 1000))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(Color.white.opacity(0.45))
                }
            case .artist(let a):
                cover(a.coverURL(100), round: true)
                titles(a.name, "Исполнитель · популярное")
                Spacer(minLength: 0)
                if selected {
                    RowButton(icon: "play.fill", help: "Слушать популярное (Enter)", tint: .white) { model.play(hit) }
                        .transition(.opacity)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.35))
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: SearchPanel.rowH)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? accent.opacity(0.22) : Color.clear))
        .animation(.easeOut(duration: 0.12), value: selected)
        .animation(.easeOut(duration: 0.15), value: queued)
    }

    private func cover(_ url: URL?, round: Bool) -> some View {
        AsyncImage(url: url) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.white.opacity(0.08)
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: round ? 17 : 7, style: .continuous))
    }

    private func titles(_ a: String, _ b: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(a).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(b).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.55)).lineLimit(1)
        }
    }
}

/// Маленькая кнопка действия в строке поиска.
struct RowButton: View {
    let icon: String
    let help: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(scale: 0.85))
        .help(help)
        .accessibilityLabel(help)
    }
}
