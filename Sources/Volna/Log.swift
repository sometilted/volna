import Foundation

/// Лог в ~/Library/Logs/Volna.log (+ системный лог). Смотреть: tail -f ~/Library/Logs/Volna.log
enum Log {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Volna.log")
    }()

    private static let queue = DispatchQueue(label: "volna.log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static func rotate() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? NSNumber, size.intValue > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func write(_ s: String) {
        NSLog("Volna %@", s as NSString)
        queue.async {
            let line = "\(fmt.string(from: Date())) \(s)\n"
            guard let d = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(d)
                try? h.close()
            } else {
                try? d.write(to: url)
            }
        }
    }
}

func ylog(_ s: String) { Log.write(s) }
