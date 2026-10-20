import AVFoundation
import MediaToolbox
import QuartzCore
import os

/// Уровни полос (низ → верх) из реального звука через MTAudioProcessingTap.
/// Аудиопоток: однополюсные фильтры, без FFT и без аллокаций.
/// UI: тап приходит ~10 раз в секунду, поэтому между пакетами значения плавно интерполируются в frame().
final class LevelMeter: @unchecked Sendable {
    static let bands = 5
    private static let cutoffs: [Double] = [150, 500, 1500, 4500]      // границы полос, Гц
    private static let gains: [Float] = [1.0, 1.4, 2.0, 3.0, 4.5]       // верхние полосы тише — подтягиваем

    private var lock = os_unfair_lock()
    private var target = [Float](repeating: 0, count: LevelMeter.bands)   // под lock

    // только аудиопоток
    private var coef = [Float](repeating: 0, count: 4)
    private var lp = [Float](repeating: 0, count: 4)
    private var energy = [Float](repeating: 0, count: LevelMeter.bands)
    private var avg = [Float](repeating: -30, count: LevelMeter.bands)   // скользящий пик dB по полосе
    private var sampleRate: Double = 44100
    private var logFrames = 0
    private var isFloat = true

    // только главный поток
    private var display = [Float](repeating: 0, count: LevelMeter.bands)
    private var lastFrame = CACurrentMediaTime()

    /// Значения для текущего кадра: быстрый подъём (~25 мс), плавный спад (~160 мс).
    func frame() -> [Float] {
        let now = CACurrentMediaTime()
        let dt = min(now - lastFrame, 0.1)
        lastFrame = now
        os_unfair_lock_lock(&lock)
        let t = target
        os_unfair_lock_unlock(&lock)
        let up = Float(1 - exp(-dt / 0.025))
        let down = Float(1 - exp(-dt / 0.16))
        for i in 0..<Self.bands {
            let k = t[i] > display[i] ? up : down
            display[i] += (t[i] - display[i]) * k
        }
        return display
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        for i in 0..<Self.bands { target[i] = 0 }
        os_unfair_lock_unlock(&lock)
    }

    fileprivate func prepare(sampleRate: Double, isFloat: Bool) {
        self.isFloat = isFloat
        let sr = max(sampleRate, 8000)
        self.sampleRate = sr
        logFrames = 0
        ylog("meter: prepare sr=\(Int(sr)) float32=\(isFloat)")
        for i in 0..<4 {
            coef[i] = Float(1 - exp(-2 * Double.pi * Self.cutoffs[i] / sr))
            lp[i] = 0
        }
    }

    fileprivate func process(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard isFloat, frames > 0 else { return }
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        guard bufs.count > 0, let p0 = bufs[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let ch = max(Int(bufs[0].mNumberChannels), 1)
        let p1: UnsafeMutablePointer<Float>? = bufs.count > 1 ? bufs[1].mData?.assumingMemoryBound(to: Float.self) : nil

        var l0 = lp[0], l1 = lp[1], l2 = lp[2], l3 = lp[3]
        let c0 = coef[0], c1 = coef[1], c2 = coef[2], c3 = coef[3]
        var e0: Float = 0, e1: Float = 0, e2: Float = 0, e3: Float = 0, e4: Float = 0
        for i in 0..<frames {
            let x: Float
            if let p1 = p1 {
                x = (p0[i] + p1[i]) * 0.5
            } else if ch > 1 {
                x = (p0[i * ch] + p0[i * ch + 1]) * 0.5
            } else {
                x = p0[i]
            }
            l0 += c0 * (x - l0)
            l1 += c1 * (x - l1)
            l2 += c2 * (x - l2)
            l3 += c3 * (x - l3)
            let b1 = l1 - l0, b2 = l2 - l1, b3 = l3 - l2, b4 = x - l3
            e0 += l0 * l0; e1 += b1 * b1; e2 += b2 * b2; e3 += b3 * b3; e4 += b4 * b4
        }
        lp[0] = l0; lp[1] = l1; lp[2] = l2; lp[3] = l3
        energy[0] = e0; energy[1] = e1; energy[2] = e2; energy[3] = e3; energy[4] = e4

        // Абсолютный уровень у сжатой современной музыки почти всегда у потолка — столбики стояли бы ровно.
        // Поэтому каждая полоса нормируется к своему недавнему пику (окно 12 дБ).
        let n = Float(frames)
        var dbs = [Float](repeating: 0, count: Self.bands)
        os_unfair_lock_lock(&lock)
        for k in 0..<Self.bands {
            let rms = (energy[k] / n).squareRoot() * Self.gains[k]
            let db = 20 * log10(max(rms, 1e-6))
            dbs[k] = db
            if db < -70 {
                target[k] = 0
                continue
            }
            // АРУ по полосе: пик держится и медленно опускается (~4 дБ/с), уровень = насколько близко к пику.
            // Громкие доли — у потолка, провалы между ними — вниз; тихий и громкий трек выглядят одинаково живо.
            avg[k] = max(db, avg[k] - 4 * Float(Double(frames) / sampleRate))
            target[k] = min(max(1 - (avg[k] - db) / 12, 0.04), 1)
        }
        let snapshot = target
        os_unfair_lock_unlock(&lock)

        // диагностика раз в ~4 с: есть ли вообще звук в тапе и как он раскладывается по полосам
        logFrames += frames
        if logFrames > Int(sampleRate * 4) {
            logFrames = 0
            let d = dbs.map { String(Int($0)) }.joined(separator: " ")
            let t = snapshot.map { String(format: "%.2f", $0) }.joined(separator: " ")
            ylog("meter: frames=\(frames) dB[\(d)] t[\(t)]")
        }
    }

    /// Вешает tap на аудиодорожку item. Если не вышло — пишет в лог, звук не трогается.
    func attach(to item: AVPlayerItem) {
        let asset = item.asset
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
                ylog("meter: нет аудиодорожки")
                return
            }
            var cb = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: ptr,
                init: tapInit,
                finalize: nil,
                prepare: tapPrepare,
                unprepare: nil,
                process: tapProcess
            )
            var tap: MTAudioProcessingTap?
            let st = MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
            guard st == noErr, let tap = tap else {
                ylog("meter: tap create \(st)")
                return
            }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            await MainActor.run { item.audioMix = mix }
        }
    }
}

// C-колбэки: без захвата контекста, LevelMeter достаём из storage тапа.
// LevelMeter живёт всё время работы приложения (свойство Player), поэтому unretained безопасен.

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, asbd in
    let m = Unmanaged<LevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let f = asbd.pointee
    let isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && f.mBitsPerChannel == 32
    m.prepare(sampleRate: f.mSampleRate, isFloat: isFloat)
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, abl, framesOut, flagsOut in
    let st = MTAudioProcessingTapGetSourceAudio(tap, frames, abl, flagsOut, nil, framesOut)
    guard st == noErr else { return }
    let m = Unmanaged<LevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    m.process(abl, frames: Int(framesOut.pointee))
}
