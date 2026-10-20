/// Заполняется скриптом scripts/setup-release.sh перед первым релизом.
enum UpdateConfig {
    /// owner/repo на GitHub, откуда брать релизы
    static let repo = "sometilted/volna"
    /// публичный ключ ed25519 (base64) — им проверяется подпись каждого обновления
    static let publicKey = "p2hp4X9ocSGxlPt8U9gb/F9oDds4hvpipN5/AE9oTUs="

    static var enabled: Bool { !repo.hasPrefix("OWNER/") && publicKey != "PUBKEY" }
}
