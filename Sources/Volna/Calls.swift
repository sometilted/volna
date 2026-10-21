import CoreAudio
import Foundation

/// Следит, занят ли микрофон кем-то, кроме нас (Zoom, Телемост, Telegram, FaceTime…).
/// Без доступа к микрофону: CoreAudio только сообщает, что вход кем-то используется.
/// macOS 14.2+: по процессам (точно, AirPods тоже). Раньше — по устройствам, у которых есть только вход.
/// Опрос 4 раза в секунду, со сглаживанием: занят ≥ 0.3 с — созвон начался, свободен ≥ 1 с — кончился.
/// Там же — звук других приложений (macOS 14.2+): играет ≥ 1 с — пауза, тишина ≥ 2 с — продолжаем.
/// Короткие системные звуки и уведомления до порога не дотягивают.
@MainActor
final class CallWatcher {
    var onChange: ((Bool) -> Void)?
    /// другое приложение играет звук; строка — кто (bundle id), для лога
    var onOther: ((Bool, String) -> Void)?
    var watchMic = true
    var watchOther = true
    private var timer: Timer?
    private(set) var busy = false
    private var since = Date()
    private var raw = false
    private(set) var other = false
    private var otherSince = Date()
    private var otherRaw = false
    private var otherWho = ""

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if busy { busy = false; onChange?(false) }
        if other { other = false; onOther?(false, otherWho) }
    }

    /// включить / выключить по настройкам: таймер работает, только пока нужен хоть один из сигналов
    func update(mic: Bool, other: Bool) {
        watchMic = mic
        watchOther = other
        if !mic, busy { busy = false; onChange?(false) }
        if !other, self.other { self.other = false; onOther?(false, otherWho) }
        if mic || other { start() } else { stop() }
    }

    private func tick() {
        if watchOther { tickOther() }
        guard watchMic else { return }
        let now = Self.micInUse()
        if now != raw { raw = now; since = Date() }
        let held = Date().timeIntervalSince(since)
        if raw != busy, held >= (raw ? 0.3 : 1) {
            busy = raw
            ylog("call: микрофон \(busy ? "занят" : "свободен")")
            onChange?(busy)
        }
    }

    private func tickOther() {
        let who = Self.otherOutput()
        let now = who != nil
        if now != otherRaw { otherRaw = now; otherSince = Date() }
        if let w = who { otherWho = w }
        if otherRaw != other, Date().timeIntervalSince(otherSince) >= (otherRaw ? 1.5 : 2) {
            other = otherRaw
            ylog("media: другой звук " + (other ? "играет — " + otherWho : "стих"))
            onOther?(other, otherWho)
        }
    }

    /// Кто ещё играет звук, кроме нас (bundle id) — или nil. Системные демоны Apple не считаются,
    /// а Safari / WebKit, Музыка, TV, QuickTime, Подкасты, FaceTime — считаются.
    static func otherOutput() -> String? {
        guard #available(macOS 14.2, *) else { return nil }
        let me = getpid()
        let appleMedia = ["com.apple.Safari", "com.apple.WebKit", "com.apple.Music", "com.apple.TV",
                          "com.apple.QuickTimePlayerX", "com.apple.podcasts", "com.apple.FaceTime",
                          "com.apple.VoiceMemos", "com.apple.iWork", "com.apple.Photos", "com.apple.finder"]
        for p in objects(kAudioHardwarePropertyProcessObjectList) {
            guard u32(p, kAudioProcessPropertyIsRunningOutput) == 1 else { continue }
            var pid: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            var a = addr(kAudioProcessPropertyPID)
            if AudioObjectGetPropertyData(p, &a, 0, nil, &size, &pid) == noErr, pid == me { continue }
            // без bundle id — консольные afplay / say (звук «готово» в терминале и т.п.), это не медиа
            guard let bid = bundleID(p) else { continue }
            if bid.hasPrefix("com.apple."), !appleMedia.contains(where: { bid.hasPrefix($0) }) { continue }
            return bid
        }
        return nil
    }

    @available(macOS 14.2, *)
    private static func bundleID(_ p: AudioObjectID) -> String? {
        var a = addr(kAudioProcessPropertyBundleID)
        var s: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(p, &a, 0, nil, &size, &s) == noErr, let v = s else { return nil }
        let str = v.takeRetainedValue() as String
        return str.isEmpty ? nil : str
    }

    static func micInUse() -> Bool {
        if #available(macOS 14.2, *) { return byProcess() }
        return byDevice()
    }

    @available(macOS 14.2, *)
    private static func byProcess() -> Bool {
        let me = getpid()
        for p in objects(kAudioHardwarePropertyProcessObjectList) {
            guard u32(p, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            var pid: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            var a = addr(kAudioProcessPropertyPID)
            if AudioObjectGetPropertyData(p, &a, 0, nil, &size, &pid) == noErr, pid == me { continue }
            return true
        }
        return false
    }

    private static func byDevice() -> Bool {
        for dev in objects(kAudioHardwarePropertyDevices) {
            // у AirPods и подобных вход и выход — одно устройство, и «работает» оно от нашей же музыки
            guard streams(dev, kAudioObjectPropertyScopeInput) > 0,
                  streams(dev, kAudioObjectPropertyScopeOutput) == 0 else { continue }
            if u32(dev, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1 { return true }
        }
        return false
    }

    // MARK: CoreAudio

    private static func addr(_ sel: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func objects(_ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = addr(sel)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
        var a = addr(sel)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr else { return 0 }
        return v
    }

    private static func streams(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = addr(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}
