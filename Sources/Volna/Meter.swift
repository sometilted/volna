import AVFoundation
import Accelerate
import MediaToolbox
import QuartzCore
import os

/// Что видит интерфейс в текущем кадре.
struct MeterFrame {
    var bands: [Float]   // 0…1, низ → верх
    var level: Float     // общая громкость относительно недавнего диапазона трека
    var bass: Float      // низ (бочка, бас)
    var kick: Float      // импульс удара: 1 в момент удара, затухает ~180 мс
    var phase: Double    // фаза волны: бежит быстрее на громких местах и рывком на ударах

    static let zero = MeterFrame(bands: [Float](repeating: 0, count: LevelMeter.bands),
                                 level: 0, bass: 0, kick: 0, phase: 0)

    /// Сжать полосы до n столбиков: среднее группы (максимум держал столбики почти всегда полными).
    func bars(_ n: Int) -> [Float] {
        let m = bands.count
        return (0..<n).map { i in
            let a = i * m / n, b = min(max((i + 1) * m / n, a + 1), m)
            var s: Float = 0
            for j in a..<b { s += bands[j] }
            return s / Float(b - a)
        }
    }
}

/// Спектр из реального звука через MTAudioProcessingTap.
/// Аудиопоток: FFT 2048 (Accelerate), 16 логарифмических полос 40 Гц…14 кГц, детектор ударов по низу.
/// Каждая полоса нормируется к своему недавнему диапазону (пик опускается, «пол» поднимается),
/// поэтому и пережатый поп, и тихий эмбиент используют всю высоту.
/// Без аллокаций в аудиопотоке: все буферы выделены заранее.
final class LevelMeter: @unchecked Sendable {
    static let bands = 16
    private static let log2n: vDSP_Length = 11
    private static let n = 2048
    private static let fMin = 40.0, fMax = 14000.0

    private var lock = os_unfair_lock()
    // под lock
    private var target = [Float](repeating: 0, count: LevelMeter.bands)
    private var tLevel: Float = 0
    private var tBass: Float = 0
    private var beats = 0
    private var beatPower: Float = 0

    // только аудиопоток
    private let fft: FFTSetup
    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: LevelMeter.n)
    private let win = UnsafeMutablePointer<Float>.allocate(capacity: LevelMeter.n)
    private let buf = UnsafeMutablePointer<Float>.allocate(capacity: LevelMeter.n)
    private let re = UnsafeMutablePointer<Float>.allocate(capacity: LevelMeter.n / 2)
    private let im = UnsafeMutablePointer<Float>.allocate(capacity: LevelMeter.n / 2)
    private let mags = UnsafeMutablePointer<Float>.allocate(capacity: LevelMeter.n / 2)
    private let db = UnsafeMutablePointer<Float>.allocate(capacity: LevelMeter.bands)
    private let prevDb = UnsafeMutablePointer<Float>.allocate(capacity: LevelMeter.bands)
    private let hi = UnsafeMutablePointer<Float>.allocate(capacity: LevelMeter.bands)
    private let lo = UnsafeMutablePointer<Float>.allocate(capacity: LevelMeter.bands)
    private var binLo = [Int](repeating: 1, count: LevelMeter.bands)
    private var binHi = [Int](repeating: 2, count: LevelMeter.bands)
    private var ringPos = 0
    private var levelHi: Float = -20, levelLo: Float = -50
    private var fluxAvg: Float = 2
    private var sinceBeat: Double = 1
    private var sampleRate: Double = 44100
    private var logFrames = 0
    private var logBeats = 0
    private var isFloat = true

    // только главный поток
    private var display = [Float](repeating: 0, count: LevelMeter.bands)
    private var dLevel: Float = 0, dBass: Float = 0, dKick: Float = 0
    private var phase: Double = 0
    private var seenBeats = 0
    private var lastFrame = CACurrentMediaTime()
    private var cached = MeterFrame.zero

    init() {
        fft = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(win, vDSP_Length(Self.n), Int32(vDSP_HANN_NORM))
        ring.initialize(repeating: 0, count: Self.n)
        for k in 0..<Self.bands {
            prevDb[k] = -80; hi[k] = -30; lo[k] = -60
        }
    }

    /// Значения для текущего кадра: быстрый подъём (~20 мс), спад ~120 мс, удар гаснет ~180 мс.
    /// Несколько вьюх за один кадр получают одно и то же.
    func frame() -> MeterFrame {
        let now = CACurrentMediaTime()
        let raw = now - lastFrame
        if raw < 0.004 { return cached }
        lastFrame = now
        let dt = min(raw, 0.1)
        os_unfair_lock_lock(&lock)
        let t = target, tl = tLevel, tb = tBass, b = beats, bp = beatPower
        os_unfair_lock_unlock(&lock)
        let up = Float(1 - exp(-dt / 0.02))
        let down = Float(1 - exp(-dt / 0.085))
        @inline(__always) func ease(_ cur: Float, _ to: Float) -> Float {
            cur + (to - cur) * (to > cur ? up : down)
        }
        for i in 0..<Self.bands { display[i] = ease(display[i], t[i]) }
        dLevel = ease(dLevel, tl)
        dBass = ease(dBass, tb)
        if b != seenBeats {
            seenBeats = b
            dKick = max(dKick, bp)
        } else {
            dKick *= Float(exp(-dt / 0.18))
        }
        phase += dt * (1.2 + 3.5 * Double(dLevel) + 9 * Double(dKick))
        cached = MeterFrame(bands: display, level: dLevel, bass: dBass, kick: dKick, phase: phase)
        return cached
    }

    /// Пауза: всё в ноль, фаза сохраняется — волна не прыгает при продолжении.
    func idle() -> MeterFrame {
        MeterFrame(bands: [Float](repeating: 0, count: Self.bands), level: 0, bass: 0, kick: 0, phase: phase)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        for i in 0..<Self.bands { target[i] = 0 }
        tLevel = 0
        tBass = 0
        os_unfair_lock_unlock(&lock)
    }

    fileprivate func prepare(sampleRate: Double, isFloat: Bool) {
        self.isFloat = isFloat
        let sr = max(sampleRate, 8000)
        self.sampleRate = sr
        logFrames = 0
        let binHz = sr / Double(Self.n)
        let top = Self.n / 2
        for k in 0..<Self.bands {
            let f0 = Self.fMin * pow(Self.fMax / Self.fMin, Double(k) / Double(Self.bands))
            let f1 = Self.fMin * pow(Self.fMax / Self.fMin, Double(k + 1) / Double(Self.bands))
            var a = max(1, Int(f0 / binHz))
            var b = max(a + 1, Int(f1 / binHz))
            b = min(b, top)
            a = min(a, b - 1)
            binLo[k] = a
            binHi[k] = b
        }
        ylog("meter: prepare sr=\(Int(sr)) float32=\(isFloat) fft=\(Self.n) bands=\(Self.bands)")
    }

    /// Приводит dB к 0…1 по диапазону последних секунд: пик опускается 3 дБ/с, пол поднимается 3 дБ/с,
    /// окно ≥ 18 дБ. Квадрат — середина уходит вниз, до верха достают только настоящие пики.
    @inline(__always)
    private static func norm(_ v: Float, _ hi: inout Float, _ lo: inout Float, _ dt: Float) -> Float {
        hi = max(v, hi - 3 * dt)
        lo = min(v, lo + 3 * dt)
        if hi - lo < 18 { lo = hi - 18 }
        let x = min(max((v - lo) / (hi - lo), 0), 1)
        return x * x
    }

    fileprivate func process(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard isFloat, frames > 0 else { return }
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        guard bufs.count > 0, let p0 = bufs[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let ch = max(Int(bufs[0].mNumberChannels), 1)
        let p1: UnsafeMutablePointer<Float>? = bufs.count > 1 ? bufs[1].mData?.assumingMemoryBound(to: Float.self) : nil
        let n = Self.n, half = n / 2

        // моно в кольцевой буфер + RMS нового куска
        var sq: Float = 0
        var pos = ringPos
        for i in 0..<frames {
            let x: Float
            if let p1 = p1 {
                x = (p0[i] + p1[i]) * 0.5
            } else if ch > 1 {
                x = (p0[i * ch] + p0[i * ch + 1]) * 0.5
            } else {
                x = p0[i]
            }
            ring[pos] = x
            pos += 1
            if pos == n { pos = 0 }
            sq += x * x
        }
        ringPos = pos
        let dt = Float(Double(frames) / sampleRate)
        sinceBeat += Double(dt)
        let rmsDb = 10 * log10(max(sq / Float(frames), 1e-12))

        if rmsDb < -70 {
            os_unfair_lock_lock(&lock)
            for k in 0..<Self.bands { target[k] = 0 }
            tLevel = 0
            tBass = 0
            os_unfair_lock_unlock(&lock)
            return
        }

        // окно последних n сэмплов по порядку, Ханн, FFT
        let tail = n - pos
        buf.update(from: ring + pos, count: tail)
        if pos > 0 { (buf + tail).update(from: ring, count: pos) }
        vDSP_vmul(buf, 1, win, 1, buf, 1, vDSP_Length(n))
        var split = DSPSplitComplex(realp: re, imagp: im)
        buf.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, mags, 1, vDSP_Length(half))

        // полосы, поток ударов по низу (40…250 Гц)
        var flux: Float = 0
        for k in 0..<Self.bands {
            var s: Float = 0
            let a = binLo[k], b = binHi[k]
            for j in a..<b { s += mags[j] }
            let v = 10 * log10(max(s / Float(b - a), 1e-12))
            db[k] = v
            if k < 5 { flux += max(0, v - prevDb[k]) }
            prevDb[k] = v
        }
        fluxAvg += (flux - fluxAvg) * 0.04
        var beat: Float = 0
        if flux > max(2.0 * fluxAvg, 2.5), sinceBeat > 0.16 {
            sinceBeat = 0
            beat = min(max(0.55 + 0.15 * (flux / max(fluxAvg, 0.5) - 2), 0.55), 1)
        }

        var vals = (Float(0), Float(0))   // (бас, общий) — без массивов
        os_unfair_lock_lock(&lock)
        for k in 0..<Self.bands {
            let x = Self.norm(db[k], &hi[k], &lo[k], dt)
            target[k] = max(x, 0.03)
            if k < 5 { vals.0 += x / 5 }   // среднее низа: максимум почти всегда был у потолка
        }
        vals.1 = Self.norm(rmsDb, &levelHi, &levelLo, dt)
        tBass = vals.0
        tLevel = vals.1
        if beat > 0 {
            beats &+= 1
            beatPower = beat
        }
        os_unfair_lock_unlock(&lock)

        // диагностика раз в ~4 с
        if beat > 0 { logBeats += 1 }
        logFrames += frames
        if logFrames > Int(sampleRate * 4) {
            logFrames = 0
            ylog(String(format: "meter: rms=%.0f dB bass=%.2f level=%.2f beats/4s=%ld flux~%.1f",
                        rmsDb, vals.0, vals.1, logBeats, fluxAvg))
            logBeats = 0
        }
    }

    /// Вешает tap на аудиодорожку item: анализ для визуализатора + усиление gain (выравнивание громкости).
    /// Возвращает контекст, через который gain можно поменять на лету. Если не вышло — звук не трогается.
    @discardableResult
    func attach(to item: AVPlayerItem, gain: Float = 1) -> TapContext {
        let ctx = TapContext(meter: self, gain: gain)
        let asset = item.asset
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
                ylog("meter: нет аудиодорожки")
                return
            }
            // контекст живёт, пока жив tap: retain здесь, release в finalize
            let ptr = Unmanaged.passRetained(ctx).toOpaque()
            var cb = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: ptr,
                init: tapInit,
                finalize: tapFinalize,
                prepare: tapPrepare,
                unprepare: nil,
                process: tapProcess
            )
            var tap: MTAudioProcessingTap?
            let st = MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
            guard st == noErr, let tap = tap else {
                Unmanaged<TapContext>.fromOpaque(ptr).release()
                ylog("meter: tap create \(st)")
                return
            }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            await MainActor.run { item.audioMix = mix }
        }
        return ctx
    }
}

/// Состояние одного тапа (одного трека): куда слать анализ и какое усиление применять.
final class TapContext: @unchecked Sendable {
    let meter: LevelMeter
    /// целевое усиление, линейное; меняется с главного потока (запись Float атомарна на arm64/x86_64)
    var gain: Float
    fileprivate var cur: Float
    fileprivate var isFloat = true

    init(meter: LevelMeter, gain: Float) {
        self.meter = meter
        self.gain = gain
        self.cur = gain
    }

    /// Усиление с плавным переходом (без щелчков) и жёстким ограничителем на ±1.
    fileprivate func apply(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let g = gain
        if abs(g - 1) < 0.001 && abs(cur - 1) < 0.001 { return }
        let start = cur
        let step = (g - start) / Float(max(frames, 1))
        for b in UnsafeMutableAudioBufferListPointer(abl) {
            guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = max(Int(b.mNumberChannels), 1)
            let n = min(Int(b.mDataByteSize) / 4, frames * ch)
            var k = start
            for i in 0..<n {
                if i % ch == 0 { k += step }
                p[i] = min(max(p[i] * k, -1), 1)
            }
        }
        cur = g
    }
}

// C-колбэки: без захвата контекста, TapContext достаём из storage тапа.

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, asbd in
    let c = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let f = asbd.pointee
    let isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && f.mBitsPerChannel == 32
    c.isFloat = isFloat
    c.meter.prepare(sampleRate: f.mSampleRate, isFloat: isFloat)
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, abl, framesOut, flagsOut in
    let st = MTAudioProcessingTapGetSourceAudio(tap, frames, abl, flagsOut, nil, framesOut)
    guard st == noErr else { return }
    let c = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let n = Int(framesOut.pointee)
    if c.isFloat { c.apply(abl, frames: n) }
    c.meter.process(abl, frames: n)
}
