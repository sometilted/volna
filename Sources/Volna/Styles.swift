import AppKit
import SwiftUI

/// Варианты оформления раскрытой панели. Переключаются в меню «Стиль», прежние не затираются.
enum UIStyle: String, CaseIterable {
    case classic, impeccable, taste, emil, candy, designer

    var title: String {
        switch self {
        case .classic: "Штиль"
        case .impeccable: "Глубина"
        case .taste: "Закат"
        case .emil: "Течение"
        case .candy: "Прилив"
        case .designer: "@opiatolove"
        }
    }
}

func fmtTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let i = Int(s)
    return String(format: "%d:%02d", i / 60, i % 60)
}

var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

// MARK: - общие кирпичи
// Без @State: в SDK macOS 27 @State стал макросом, а в Command Line Tools нет его плагина.

/// Какой элемент сейчас под курсором (одна панель — один hover за раз).
final class HoverModel: ObservableObject {
    static let shared = HoverModel()
    @Published var key: String?

    func set(_ k: String, _ on: Bool) {
        if on { key = k } else if key == k { key = nil }
    }
}

/// Флаг «панель раскрылась» для ступенчатого появления; переключает NotchController.
final class Reveal: ObservableObject {
    static let shared = Reveal()
    @Published var on = false
}

/// Отклик на нажатие: масштаб на press-down, быстрый ease-out (Emil: 100–160 мс).
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.88

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Появление с размытием и небольшим сдвигом, со ступенькой по задержке.
struct StaggerIn: ViewModifier {
    let delay: Double
    @ObservedObject private var reveal = Reveal.shared

    init(delay: Double) { self.delay = delay }

    func body(content: Content) -> some View {
        let r = reduceMotion
        let shown = reveal.on
        return content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || r ? 0 : 8)
            .scaleEffect(shown || r ? 1 : 0.95, anchor: .top)
            .offset(y: shown || r ? 0 : -8)
            .animation(r ? .easeOut(duration: 0.15) : .easeOut(duration: 0.35).delay(delay), value: shown)
    }
}

struct BlurFade: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 4 : 0)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
    }
}

/// Смена play ↔ pause как у системных символов (macOS 14+), на 13 — просто смена.
struct SymbolSwap: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content
        }
    }
}

/// Подпрыгивание сердечка при лайке (macOS 14+).
struct HeartPop: ViewModifier {
    let value: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.symbolEffect(.bounce, value: value)
        } else {
            content
        }
    }
}

/// Кнопка-иконка с hover-подложкой и подписью для VoiceOver.
struct IconButton: View {
    let icon: String
    let label: String
    var size: CGFloat = 15
    var box: CGFloat = 30
    var tint: Color? = nil
    var dim = false
    let action: () -> Void
    @ObservedObject private var hm = HoverModel.shared

    private var hover: Bool { hm.key == label }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(tint ?? Color.white.opacity(dim && !hover ? 0.55 : 1))
                .frame(width: box, height: box)
                .background(Circle().fill(Color.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(scale: 0.92))
        .onHover { hm.set(label, $0) }
        .animation(.easeOut(duration: 0.12), value: hover)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Тонкий прогресс, утолщается при наведении — видно, что за него можно взяться.
struct HoverProgress: View {
    let position: Double
    let duration: Double
    let onSeek: (Double) -> Void
    @ObservedObject private var hm = HoverModel.shared

    private var hover: Bool { hm.key == "progress" }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { g in
                let f = duration > 0 ? CGFloat(min(position / duration, 1)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: g.size.width * f)
                }
                .frame(height: hover ? 5 : 3)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { loc in
                    onSeek(Double(loc.x / max(g.size.width, 1)))
                }
            }
            .frame(height: 10)
            HStack {
                Text(fmtTime(position))
                Spacer()
                Text(fmtTime(duration))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(Color.white.opacity(0.45))
        }
        .onHover { hm.set("progress", $0) }
        .animation(.easeOut(duration: 0.15), value: hover)
        .accessibilityElement()
        .accessibilityLabel("Позиция \(fmtTime(position)) из \(fmtTime(duration))")
    }
}

// MARK: - волна (Taste: «Моя волна» становится самой линией прогресса)

struct WaveShape: Shape {
    var phase: Double
    var amp: CGFloat
    var freq: Double

    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = max(r.width, 1)
        let steps = max(Int(w / 2), 2)
        for i in 0...steps {
            let x = CGFloat(i) / CGFloat(steps) * w
            let y = r.midY + CGFloat(sin(Double(x / w) * freq * 2 * Double.pi + phase)) * amp
            if i == 0 { p.move(to: CGPoint(x: r.minX + x, y: y)) } else { p.addLine(to: CGPoint(x: r.minX + x, y: y)) }
        }
        return p
    }
}

/// Для волны берём самую активную полосу: среднее по полосам гасит удары друг о друга.
private func energy(_ l: [Float]) -> CGFloat {
    CGFloat(l.max() ?? 0)
}

/// Прогресс-волна: амплитуда — реальная громкость, сыгранная часть белая.
struct WaveProgress: View {
    let position: Double
    let duration: Double
    let playing: Bool
    let meter: LevelMeter
    let onSeek: (Double) -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing)) { ctx in
            let e = playing ? energy(meter.frame()) : 0
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                let f = duration > 0 ? CGFloat(min(position / duration, 1)) : 0
                let wave = WaveShape(phase: t * 3, amp: 1.2 + 6 * e, freq: 4)
                let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                ZStack(alignment: .leading) {
                    wave.stroke(Color.white.opacity(0.22), style: style)
                    wave.stroke(Color.white, style: style)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: g.size.width * f)
                        }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { loc in
                    onSeek(Double(loc.x / max(g.size.width, 1)))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Позиция \(fmtTime(position)) из \(fmtTime(duration))")
    }
}

/// Маленькая волна для свёрнутого нотча.
struct MiniWave: View {
    let playing: Bool
    let meter: LevelMeter
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing)) { ctx in
            let e = playing ? energy(meter.frame()) : 0
            WaveShape(phase: ctx.date.timeIntervalSinceReferenceDate * 6, amp: 1 + 6 * e, freq: 1.5)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

extension NSImage {
    /// Усреднённый цвет обложки, чуть насыщеннее и не темнее 0.6 — для фона Taste.
    var tintColor: Color? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { return nil }
        let ns = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                         blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(s * 1.3, 1)), brightness: Double(max(b, 0.6)))
    }
}

// MARK: - Impeccable: Operate-режим, сдержанность, нативные состояния (hover, VoiceOver), цвет только как акцент

struct ImpeccableExpanded: View {
    @ObservedObject var player: Player

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                CoverView(image: player.cover, size: 56, radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "—")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(player.status ?? player.current?.artists ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(player.status == nil ? Color.white.opacity(0.6) : accent)
                        .lineLimit(1)
                    HoverProgress(position: player.position, duration: player.duration) { player.seek(fraction: $0) }
                        .padding(.top, 4)
                }
            }
            HStack(spacing: 4) {
                IconButton(icon: "hand.thumbsdown", label: "Не нравится", size: 13, dim: true) { player.dislike() }
                Spacer()
                IconButton(icon: "backward.fill", label: "Предыдущий", size: 15) { player.prev() }
                IconButton(icon: player.isPlaying ? "pause.fill" : "play.fill",
                           label: player.isPlaying ? "Пауза" : "Играть", size: 20, box: 36) { player.toggle() }
                IconButton(icon: "forward.fill", label: "Следующий", size: 15) { player.next() }
                Spacer()
                IconButton(icon: player.liked ? "heart.fill" : "heart",
                           label: player.liked ? "Убрать из любимых" : "Нравится",
                           size: 13, tint: player.liked ? accent : nil, dim: true) { player.toggleLike() }
            }
        }
    }
}

// MARK: - Taste: идея из предмета — волна; крупный шрифт, поле цвета из обложки, одна живая вещь

struct TasteExpanded: View {
    @ObservedObject var player: Player

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                CoverView(image: player.cover, size: 58, radius: 12)
                    .shadow(color: Color.black.opacity(0.5), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "—")
                        .font(.system(size: 16, weight: .bold))
                        .tracking(-0.3)
                        .lineLimit(1)
                    Text(player.status ?? player.current?.artists ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.72))
                        .lineLimit(1)
                    WaveProgress(position: player.position, duration: player.duration,
                                 playing: player.isPlaying, meter: player.meter) { player.seek(fraction: $0) }
                        .frame(height: 18)
                        .padding(.top, 4)
                }
            }
            HStack(spacing: 22) {
                plain("hand.thumbsdown", 14, "Не нравится") { player.dislike() }
                plain("backward.fill", 16, "Предыдущий") { player.prev() }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white))
                }
                .buttonStyle(PressStyle(scale: 0.9))
                .accessibilityLabel(player.isPlaying ? "Пауза" : "Играть")
                plain("forward.fill", 16, "Следующий") { player.next() }
                plain(player.liked ? "heart.fill" : "heart", 15, "Нравится",
                      tint: player.liked ? accent : .white) { player.toggleLike() }
            }
        }
    }

    private func plain(_ icon: String, _ size: CGFloat, _ label: String, tint: Color = .white,
                       _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - кирпичи движения (Emil / Apple fluid interfaces)

/// Где сейчас палец на прогрессе при перетаскивании (nil — не тащим).
final class ScrubModel: ObservableObject {
    static let shared = ScrubModel()
    @Published var frac: Double?
}

extension AnyTransition {
    /// Пространственная последовательность: следующий трек въезжает справа, предыдущий — слева.
    static func trackSlide(_ dir: Int) -> AnyTransition {
        if reduceMotion { return .opacity }
        let ins: Edge = dir >= 0 ? .trailing : .leading
        let rem: Edge = dir >= 0 ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: ins).combined(with: .opacity),
                           removal: .move(edge: rem).combined(with: .opacity))
    }
}

/// Иконка: hover — подложка и лёгкое увеличение на пружине, press — проседание, смена символа анимирована.
struct EmilButton: View {
    let icon: String
    let label: String
    var size: CGFloat = 16
    var box: CGFloat = 30
    var tint: Color = .white
    var dim = false
    var pressScale: CGFloat = 0.85
    var heart = false
    let action: () -> Void
    @ObservedObject private var hm = HoverModel.shared

    private var hover: Bool { hm.key == label }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(dim && !hover ? tint.opacity(0.55) : tint)
                .modifier(SymbolSwap())
                .modifier(HeartPop(value: heart))
                .frame(width: box, height: box)
                .background(Circle().fill(Color.white.opacity(hover ? 0.1 : 0)))
                .scaleEffect(hover && !reduceMotion ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(scale: pressScale))
        .onHover { hm.set(label, $0) }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Белая круглая play/pause с hover и смещением символа.
struct PlayCircle: View {
    let playing: Bool
    var size: CGFloat = 34
    let action: () -> Void
    @ObservedObject private var hm = HoverModel.shared

    private var hover: Bool { hm.key == "play" }

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundColor(.black)
                .modifier(SymbolSwap())
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white))
                .scaleEffect(hover && !reduceMotion ? 1.06 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(scale: 0.86))
        .onHover { hm.set("play", $0) }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        .animation(.easeOut(duration: 0.15), value: playing)
        .accessibilityLabel(playing ? "Пауза" : "Играть")
    }
}

/// Волна под прогресс: амплитуда — реальная громкость.
struct WaveFill: View {
    let frac: CGFloat
    let playing: Bool
    let meter: LevelMeter

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing)) { ctx in
            let e = playing ? energy(meter.frame()) : 0
            GeometryReader { g in
                let wave = WaveShape(phase: ctx.date.timeIntervalSinceReferenceDate * 3, amp: 1 + 4 * e, freq: 5)
                let st = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                ZStack(alignment: .leading) {
                    wave.stroke(Color.white.opacity(0.2), style: st)
                    wave.stroke(Color.white, style: st)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: g.size.width * frac)
                        }
                }
            }
        }
    }
}

/// Прогресс с прямым управлением: тянешь — следует за курсором 1:1, отпустил — перемотка.
/// При наведении утолщается и показывает бегунок; под ним прошло / осталось.
struct ScrubBar: View {
    let position: Double
    let duration: Double
    var wave = false
    var playing = false
    var meter: LevelMeter? = nil
    let onSeek: (Double) -> Void
    @ObservedObject private var hm = HoverModel.shared
    @ObservedObject private var sm = ScrubModel.shared

    private var active: Bool { hm.key == "scrub" || sm.frac != nil }
    private var frac: CGFloat {
        if let f = sm.frac { return CGFloat(f) }
        return duration > 0 ? CGFloat(min(position / duration, 1)) : 0
    }
    private var shownTime: Double { sm.frac.map { $0 * duration } ?? position }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { g in
                let w = max(g.size.width, 1)
                ZStack(alignment: .leading) {
                    if wave, let meter = meter {
                        WaveFill(frac: frac, playing: playing, meter: meter)
                    } else {
                        Capsule().fill(Color.white.opacity(0.16))
                            .frame(height: active ? 5 : 3)
                        Capsule().fill(Color.white.opacity(0.9))
                            .frame(width: w * frac, height: active ? 5 : 3)
                    }
                    Circle()
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                        .shadow(color: Color.black.opacity(0.4), radius: 2)
                        .scaleEffect(active ? 1 : 0.3)
                        .opacity(active ? 1 : 0)
                        .offset(x: w * frac - 5)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in sm.frac = Double(min(max(v.location.x / w, 0), 1)) }
                        .onEnded { v in
                            onSeek(Double(min(max(v.location.x / w, 0), 1)))
                            sm.frac = nil
                        }
                )
            }
            .frame(height: wave ? 16 : 10)
            HStack {
                Text(fmtTime(shownTime))
                Spacer()
                Text("−" + fmtTime(max(duration - shownTime, 0)))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(Color.white.opacity(0.45))
        }
        .onHover { hm.set("scrub", $0) }
        .animation(.spring(response: 0.25, dampingFraction: 1), value: active)
        .accessibilityElement()
        .accessibilityLabel("Позиция \(fmtTime(position)) из \(fmtTime(duration))")
    }
}

// MARK: - Emil: раскладка классики, но всё движется по правилам — направленная смена трека,
// поочерёдное появление, перетаскиваемый прогресс, отклик на наведение и нажатие

struct EmilExpanded: View {
    @ObservedObject var player: Player

    var body: some View {
        let slide = AnyTransition.trackSlide(player.direction)
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    CoverView(image: player.cover, size: 52, radius: 9)
                        .id(player.current?.id)
                        .transition(slide)
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .modifier(StaggerIn(delay: 0))
                VStack(alignment: .leading, spacing: 3) {
                    ZStack(alignment: .leading) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.current?.title ?? "—")
                                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(player.status ?? player.current?.artists ?? "")
                                .font(.system(size: 11))
                                .foregroundColor(player.status == nil ? .gray : accent)
                                .lineLimit(1)
                        }
                        .id(player.current?.id)
                        .transition(slide)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    ScrubBar(position: player.position, duration: player.duration) { player.seek(fraction: $0) }
                        .padding(.top, 2)
                }
                .modifier(StaggerIn(delay: 0.06))
            }
            HStack(spacing: 0) {
                EmilButton(icon: "hand.thumbsdown", label: "Не нравится", size: 14) { player.dislike() }
                Spacer()
                EmilButton(icon: "backward.fill", label: "Предыдущий") { player.prev() }
                Spacer()
                EmilButton(icon: player.isPlaying ? "pause.fill" : "play.fill",
                           label: player.isPlaying ? "Пауза" : "Играть",
                           size: 22, pressScale: 0.8) { player.toggle() }
                Spacer()
                EmilButton(icon: "forward.fill", label: "Следующий") { player.next() }
                Spacer()
                EmilButton(icon: player.liked ? "heart.fill" : "heart", label: "Нравится", size: 15,
                           tint: player.liked ? accent : .white, heart: player.liked) { player.toggleLike() }
            }
            .padding(.horizontal, 22)
            .modifier(StaggerIn(delay: 0.12))
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1),
                   value: player.current?.id)
        .animation(.easeOut(duration: 0.15), value: player.isPlaying)
    }
}

// MARK: - Конфетка: внешний вид Impeccable + движение Emil

struct CandyExpanded: View {
    @ObservedObject var player: Player

    var body: some View {
        let slide = AnyTransition.trackSlide(player.direction)
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    CoverView(image: player.cover, size: 56, radius: 10)
                        .id(player.current?.id)
                        .transition(slide)
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .modifier(StaggerIn(delay: 0))
                VStack(alignment: .leading, spacing: 2) {
                    ZStack(alignment: .leading) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.current?.title ?? "—")
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text(player.status ?? player.current?.artists ?? "")
                                .font(.system(size: 12))
                                .foregroundColor(player.status == nil ? Color.white.opacity(0.6) : accent)
                                .lineLimit(1)
                        }
                        .id(player.current?.id)
                        .transition(slide)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    ScrubBar(position: player.position, duration: player.duration) { player.seek(fraction: $0) }
                        .padding(.top, 4)
                }
                .modifier(StaggerIn(delay: 0.06))
            }
            HStack(spacing: 4) {
                EmilButton(icon: "hand.thumbsdown", label: "Не нравится", size: 13, dim: true) { player.dislike() }
                Spacer()
                EmilButton(icon: "backward.fill", label: "Предыдущий", size: 15) { player.prev() }
                EmilButton(icon: player.isPlaying ? "pause.fill" : "play.fill",
                           label: player.isPlaying ? "Пауза" : "Играть",
                           size: 20, box: 36, pressScale: 0.8) { player.toggle() }
                EmilButton(icon: "forward.fill", label: "Следующий", size: 15) { player.next() }
                Spacer()
                EmilButton(icon: player.liked ? "heart.fill" : "heart",
                           label: player.liked ? "Убрать из любимых" : "Нравится", size: 13,
                           tint: player.liked ? accent : .white, dim: !player.liked,
                           heart: player.liked) { player.toggleLike() }
            }
            .modifier(StaggerIn(delay: 0.12))
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1),
                   value: player.current?.id)
    }
}

// MARK: - Дизайн: макет дизайнера из Figma (кадр 800×354 @2x → 400×177 pt), движение как в Emil.
// Все координаты — из макета, делённые на 2: обложка 30/30.5 77.5×77.5 r11.5, текст с x=127.5,
// линия прогресса y=90 ширина 232.5, ряд кнопок по центру y=133.5, play — круг 35.

private let designerGray = Color(red: 217 / 255, green: 217 / 255, blue: 217 / 255)

/// Тонкая линия прогресса как в макете (1 px); при наведении и перетаскивании — 3 pt и бегунок.
struct DesignerProgress: View {
    let position: Double
    let duration: Double
    let onSeek: (Double) -> Void
    @ObservedObject private var hm = HoverModel.shared
    @ObservedObject private var sm = ScrubModel.shared

    private var active: Bool { hm.key == "dscrub" || sm.frac != nil }
    private var frac: CGFloat {
        if let f = sm.frac { return CGFloat(f) }
        return duration > 0 ? CGFloat(min(position / duration, 1)) : 0
    }

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3))
                    .frame(height: active ? 3 : 1)
                Capsule().fill(Color.white)
                    .frame(width: w * frac, height: active ? 3 : 1)
                Circle()
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .scaleEffect(active ? 1 : 0.3)
                    .opacity(active ? 1 : 0)
                    .offset(x: w * frac - 4.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in sm.frac = Double(min(max(v.location.x / w, 0), 1)) }
                    .onEnded { v in
                        onSeek(Double(min(max(v.location.x / w, 0), 1)))
                        sm.frac = nil
                    }
            )
        }
        .frame(height: 12)
        .onHover { hm.set("dscrub", $0) }
        .animation(.spring(response: 0.25, dampingFraction: 1), value: active)
        .accessibilityElement()
        .accessibilityLabel("Позиция \(fmtTime(position)) из \(fmtTime(duration))")
    }
}

/// Светло-серый круг play как в макете (Ø35), тёмный символ внутри.
struct DesignerPlay: View {
    let playing: Bool
    let action: () -> Void
    @ObservedObject private var hm = HoverModel.shared

    private var hover: Bool { hm.key == "dplay" }

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Color(red: 40 / 255, green: 35 / 255, blue: 32 / 255))
                .modifier(SymbolSwap())
                .frame(width: 35, height: 35)
                .background(Circle().fill(designerGray))
                .scaleEffect(hover && !reduceMotion ? 1.06 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(scale: 0.86))
        .onHover { hm.set("dplay", $0) }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        .animation(.easeOut(duration: 0.15), value: playing)
        .accessibilityLabel(playing ? "Пауза" : "Играть")
    }
}

struct DesignerExpanded: View {
    @ObservedObject var player: Player

    var body: some View {
        let slide = AnyTransition.trackSlide(player.direction)
        ZStack(alignment: .topLeading) {
            // обложка 77.5×77.5, r 11.5
            ZStack {
                CoverView(image: player.cover, size: 77.5, radius: 11.5)
                    .id(player.current?.id)
                    .transition(slide)
            }
            .frame(width: 77.5, height: 77.5)
            .clipShape(RoundedRectangle(cornerRadius: 11.5, style: .continuous))
            .offset(x: 30, y: 30.5)
            .modifier(StaggerIn(delay: 0))

            // название 16 / исполнитель 12, обычное начертание, белые
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(player.current?.title ?? "—")
                        .font(.system(size: 16))
                        .lineLimit(1)
                    Text(player.status ?? player.current?.artists ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(player.status == nil ? .white : accent)
                        .lineLimit(1)
                }
                .id(player.current?.id)
                .transition(slide)
            }
            .frame(width: 232.5, alignment: .leading)
            .clipped()
            .offset(x: 127.5, y: 30.5)
            .modifier(StaggerIn(delay: 0.05))

            // линия прогресса: y = 90, ширина 232.5
            DesignerProgress(position: player.position, duration: player.duration) { player.seek(fraction: $0) }
                .frame(width: 232.5)
                .offset(x: 127.5, y: 84)
                .modifier(StaggerIn(delay: 0.08))

            // ряд кнопок по центру y = 133.5: дизлайк · назад · play · вперёд · лайк
            HStack(spacing: 0) {
                EmilButton(icon: "hand.thumbsdown", label: "Не нравится", size: 14, tint: designerGray) { player.dislike() }
                Spacer(minLength: 0)
                EmilButton(icon: "backward.fill", label: "Предыдущий", size: 17, tint: designerGray) { player.prev() }
                Spacer(minLength: 0)
                DesignerPlay(playing: player.isPlaying) { player.toggle() }
                Spacer(minLength: 0)
                EmilButton(icon: "forward.fill", label: "Следующий", size: 17, tint: designerGray) { player.next() }
                Spacer(minLength: 0)
                EmilButton(icon: player.liked ? "heart.fill" : "heart",
                           label: player.liked ? "Убрать из любимых" : "Нравится", size: 14,
                           tint: player.liked ? accent : designerGray, heart: player.liked) { player.toggleLike() }
            }
            .frame(width: 246, height: 35)
            .offset(x: 120.5, y: 116)
            .modifier(StaggerIn(delay: 0.12))
        }
        .frame(width: 400, height: 177, alignment: .topLeading)
        .foregroundColor(.white)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1),
                   value: player.current?.id)
    }
}
