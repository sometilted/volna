import AppKit
import AudioToolbox
import CoreAudio

/// Что показать в нотче вместо системной плашки громкости / яркости.
struct HUD: Equatable {
    enum Kind { case volume, brightness }
    let kind: Kind
    let value: Float      // 0…1
    let muted: Bool
}

/// Перехват клавиш громкости, mute и яркости (CGEventTap, нужен Универсальный доступ).
/// Нажатие не уходит в систему — системная плашка не появляется; громкость / яркость меняем сами
/// и сообщаем значение в onChange. Если сделать сами не можем (у устройства нет регулировки громкости,
/// нет встроенного экрана) — клавишу пропускаем системе как есть.
/// Шаг как у системы: 1/16; с ⌥⇧ — 1/64.
@MainActor
final class MediaKeys {
    var onChange: ((HUD) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    // коды NX_KEYTYPE_* из IOKit/hidsystem/ev_keymap.h
    private static let soundUp = 0, soundDown = 1, brightUp = 2, brightDown = 3, mute = 7
    // некоторые клавиатуры шлют яркость обычными keyDown
    private static let kvBrightUp: Int64 = 144, kvBrightDown: Int64 = 145

    var running: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            ylog("keys: нет Универсального доступа — громкость и яркость остаются системными")
            return
        }
        let mask: CGEventMask = (1 << 14) | (1 << CGEventType.keyDown.rawValue)   // 14 = NX_SYSDEFINED
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: keyTapCallback, userInfo: me) else {
            ylog("keys: не удалось создать перехват клавиш")
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        ylog("keys: громкость и яркость — в нотче")
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
    }

    /// true — съели клавишу (сделали сами), false — пропустить системе.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return false
        }
        if type == .keyDown {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            guard kc == Self.kvBrightUp || kc == Self.kvBrightDown else { return false }
            return brightness(up: kc == Self.kvBrightUp, fine: Self.fine(event.flags))
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let data = ns.data1
        let code = (data & 0xFFFF_0000) >> 16
        let state = (data & 0xFF00) >> 8          // 0xA — нажата, 0xB — отпущена
        guard [Self.soundUp, Self.soundDown, Self.brightUp, Self.brightDown, Self.mute].contains(code) else { return false }
        let fine = Self.fine(event.flags)
        if state != 0xA {
            // отпускание: съедаем, только если нажатие тоже было наше
            switch code {
            case Self.brightUp, Self.brightDown: return Brightness.available
            default: return SystemVolume.adjustable
            }
        }
        switch code {
        case Self.soundUp: return volume(+1, fine: fine)
        case Self.soundDown: return volume(-1, fine: fine)
        case Self.mute: return toggleMute()
        case Self.brightUp: return brightness(up: true, fine: fine)
        case Self.brightDown: return brightness(up: false, fine: fine)
        default: return false
        }
    }

    private static func fine(_ f: CGEventFlags) -> Bool { f.contains(.maskShift) && f.contains(.maskAlternate) }

    private func volume(_ dir: Float, fine: Bool) -> Bool {
        guard SystemVolume.adjustable, let v = SystemVolume.volume else { return false }
        let step: Float = fine ? 1 / 64 : 1 / 16
        let nv = min(max((v / step).rounded() * step + dir * step, 0), 1)
        SystemVolume.volume = nv
        if SystemVolume.muted && dir > 0 { SystemVolume.muted = false }
        onChange?(HUD(kind: .volume, value: nv, muted: SystemVolume.muted || nv == 0))
        return true
    }

    private func toggleMute() -> Bool {
        guard SystemVolume.adjustable else { return false }
        let m = !SystemVolume.muted
        SystemVolume.muted = m
        onChange?(HUD(kind: .volume, value: SystemVolume.volume ?? 0, muted: m))
        return true
    }

    private func brightness(up: Bool, fine: Bool) -> Bool {
        guard let b = Brightness.value else { return false }
        let step: Float = fine ? 1 / 64 : 1 / 16
        let nb = min(max((b / step).rounded() * step + (up ? step : -step), 0), 1)
        Brightness.value = nb
        onChange?(HUD(kind: .brightness, value: nb, muted: false))
        return true
    }
}

/// C-колбэк перехвата: MediaKeys живёт всё время работы приложения, поэтому unretained безопасен.
/// Источник добавлен в главный run loop — вызывается на главном потоке.
private let keyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<MediaKeys>.fromOpaque(refcon).takeUnretainedValue()
    let eaten = MainActor.assumeIsolated { keys.handle(type, event) }
    return eaten ? nil : Unmanaged.passUnretained(event)
}

/// Громкость текущего устройства вывода (CoreAudio).
enum SystemVolume {
    private static func device() -> AudioObjectID? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    private static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// у устройства есть регулировка громкости (у HDMI-мониторов часто нет — тогда клавиши остаются системе)
    static var adjustable: Bool {
        guard let d = device() else { return false }
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(d, &a) && AudioObjectIsPropertySettable(d, &a, &settable) == noErr && settable.boolValue
    }

    static var volume: Float? {
        get {
            guard let d = device() else { return nil }
            var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr ? v : nil
        }
        set {
            guard let d = device(), var v = newValue else { return }
            var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    static var muted: Bool {
        get {
            guard let d = device() else { return false }
            var a = addr(kAudioDevicePropertyMute)
            var v: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr && v != 0
        }
        set {
            guard let d = device() else { return }
            var a = addr(kAudioDevicePropertyMute)
            guard AudioObjectHasProperty(d, &a) else { return }
            var v: UInt32 = newValue ? 1 : 0
            AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
        }
    }
}

/// Яркость встроенного экрана через DisplayServices (системная библиотека без публичного заголовка;
/// ею пользуются почти все утилиты яркости). Нет встроенного экрана или библиотеки — nil, клавиши остаются системе.
enum Brightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: GetFn? = lib.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = lib.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFn.self) }

    private static func builtin() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var available: Bool { value != nil }

    static var value: Float? {
        get {
            guard let f = getFn, let d = builtin() else { return nil }
            var v: Float = 0
            return f(d, &v) == 0 ? v : nil
        }
        set {
            guard let f = setFn, let d = builtin(), let v = newValue else { return }
            _ = f(d, v)
        }
    }
}
