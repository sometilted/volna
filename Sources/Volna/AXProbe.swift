import AppKit
import ApplicationServices

/// Разведка: что macOS рисует в правой части меню-бара (там же появляются Live Activities с iPhone)
/// и что из этого видно через Accessibility. Пишет дерево в ~/Library/Logs/Volna-ax.txt.
@MainActor
enum AXProbe {
    static let out: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Volna-ax.txt")

    static func run() {
        guard AXIsProcessTrusted() else {
            ylog("ax: нет доступа к Универсальному доступу")
            return
        }
        var lines: [String] = ["# \(Date())"]
        for app in NSWorkspace.shared.runningApplications {
            let el = AXUIElementCreateApplication(app.processIdentifier)
            guard let extras = attr(el, "AXExtrasMenuBar") else { continue }
            let name = app.localizedName ?? "?"
            let bid = app.bundleIdentifier ?? "?"
            lines.append("== \(name) [\(bid)] pid=\(app.processIdentifier)")
            dump(extras as! AXUIElement, depth: 1, into: &lines)
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: out, atomically: true, encoding: .utf8)
        ylog("ax: снято \(lines.count) строк → \(out.path)")
    }

    private static func dump(_ e: AXUIElement, depth: Int, into lines: inout [String]) {
        guard depth <= 6, lines.count < 3000 else { return }
        let role = attr(e, kAXRoleAttribute) as? String ?? ""
        let sub = attr(e, kAXSubroleAttribute) as? String ?? ""
        let title = attr(e, kAXTitleAttribute) as? String ?? ""
        let desc = attr(e, kAXDescriptionAttribute) as? String ?? ""
        let help = attr(e, kAXHelpAttribute) as? String ?? ""
        let ident = attr(e, "AXIdentifier") as? String ?? ""
        var value = ""
        if let v = attr(e, kAXValueAttribute) { value = "\(v)" }
        var frame = ""
        if let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) {
            var pt = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &pt)
            AXValueGetValue(s as! AXValue, .cgSize, &sz)
            frame = " @\(Int(pt.x)),\(Int(pt.y)) \(Int(sz.width))x\(Int(sz.height))"
        }
        let pad = String(repeating: "  ", count: depth)
        var parts = ["\(role)\(sub.isEmpty ? "" : "/" + sub)"]
        if !title.isEmpty { parts.append("title=«\(title)»") }
        if !desc.isEmpty { parts.append("desc=«\(desc)»") }
        if !value.isEmpty { parts.append("value=«\(value.prefix(120))»") }
        if !help.isEmpty { parts.append("help=«\(help)»") }
        if !ident.isEmpty { parts.append("id=\(ident)") }
        lines.append(pad + parts.joined(separator: " ") + frame)
        let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for k in kids { dump(k, depth: depth + 1, into: &lines) }
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
}
